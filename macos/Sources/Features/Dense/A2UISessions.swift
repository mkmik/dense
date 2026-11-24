import A2UICore
import A2UISwiftUI
import Combine
import Foundation
import Network
import OrderedJSON

// ponytail: every surface is subscribed, whether or not a window shows its Space; subscribe
// per shown Space if 100s of surfaces ever make updates cost something.
/// The A2UI sessions of this app: one per Extension that has a Surface to show, over the
/// Unix socket the Extension listens on (t8y: the A2UI surfaces PRD).
///
/// Where a surface goes comes from dennet: a `Surface` of kind ui, a tab or a sidebar
/// section; what is in it comes from its Extension, as A2UI 1.0 JSON, one message per line. A session carries all of an
/// Extension's surfaces. It opens with a hello naming the surfaces it wants, and the Extension
/// answers each with a full `createSurface`; then it's plain A2UI both ways. Lines that are
/// objects with a "dense" key are dense's own: hello, and subscribe or unsubscribe as
/// surfaces come and go. Nothing is replayed after a restart: a new
/// connection asks for fresh snapshots.
@MainActor
final class A2UIHub: ObservableObject {
    static let shared = A2UIHub()

    /// Sessions by Extension id.
    @Published private(set) var sessions: [String: ExtensionSession] = [:]

    private var changes: AnyCancellable?

    private init() {
        let store = SpaceStore.shared
        changes = store.$extensions.combineLatest(store.$surfaces)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] extensions, surfaces in
                MainActor.assumeIsolated { self?.sync(extensions, surfaces) }
            }
    }

    private func sync(_ extensions: [String: DennetExtension], _ surfaces: [String: Surface]) {
        // Surface names by Extension id.
        var wanted: [String: Set<String>] = [:]
        for surface in surfaces.values {
            if let owner = surface.uiExtension { wanted[owner, default: []].insert(surface.metadata.name) }
        }
        for (id, session) in sessions where extensions[id] == nil {
            session.close()
            sessions[id] = nil
        }
        for (id, ext) in extensions {
            let names = wanted[id, default: []]
            if let session = sessions[id] {
                session.sync(endpoint: ext.spec.endpoint, surfaces: names)
            } else if !names.isEmpty {
                let session = ExtensionSession(namespace: ext.metadata.namespace ?? "default", endpoint: ext.spec.endpoint)
                sessions[id] = session
                session.sync(endpoint: ext.spec.endpoint, surfaces: names)
            }
        }
    }
}

/// One A2UI session with one Extension. Surfaces stay as they were while it is disconnected;
/// views grey them out and turn their inputs off. It dials again every two seconds.
@MainActor
final class ExtensionSession: ObservableObject {
    let namespace: String
    private(set) var endpoint: String

    /// Whether the socket is connected, and the hello sent.
    @Published private(set) var connected = false

    /// Draws the surfaces. A new one for each connection, so the snapshots that come then
    /// create surfaces afresh; the old one is kept until then, to show while disconnected.
    @Published private(set) var processor: MessageProcessor

    /// What went wrong with a surface's messages last, by surface name. Cleared when the
    /// surface is asked for again.
    @Published private(set) var errors: [String: String] = [:]

    /// The catalogs the surfaces may use: the basic catalog, and dense's own on top of it.
    let catalogs: [Catalog<ComponentImplementation>]

    /// The surfaces to show, and those asked for on the current connection.
    private var wanted: Set<String> = []
    private var subscribed: Set<String> = []
    private var conn: NWConnection?
    private var buffer = Data()
    private var closed = false
    /// When each surface was last asked for again after an error, so a surface the Extension
    /// keeps getting wrong is asked for every 10 s at most.
    private var resynced: [String: Date] = [:]
    private let urlOpener = A2UIURLOpener()

    /// Names this app to Extensions, which may use it to tell frontends apart.
    private static let frontendID = "dense-\(UUID().uuidString)"

    init(namespace: String, endpoint: String) {
        self.namespace = namespace
        self.endpoint = endpoint
        catalogs = DenseCatalog.catalogs(namespace: namespace, urlOpener: urlOpener)
        processor = MessageProcessor(catalogs: catalogs)
    }

    /// Shows `surfaces`, by name, and only those, from the Extension at `endpoint`.
    func sync(endpoint: String, surfaces: Set<String>) {
        let old = wanted
        wanted = surfaces
        if endpoint != self.endpoint {
            self.endpoint = endpoint
            conn?.cancel()
            conn = nil
            connected = false
        }
        if connected {
            for name in subscribed.subtracting(surfaces) {
                send(["unsubscribe": ["surfaceId": name]])
                deleteLocally(name)
            }
            for name in surfaces.subtracting(subscribed) { send(["subscribe": ["surfaceId": name]]) }
            subscribed = surfaces
        } else {
            for name in old.subtracting(surfaces) { deleteLocally(name) }
        }
        if conn == nil && !surfaces.isEmpty { connect() }
    }

    /// Stops for good: the Extension is gone.
    func close() {
        closed = true
        conn?.cancel()
        conn = nil
        connected = false
    }

    private func connect() {
        guard !closed else { return }
        let c = NWConnection(to: .unix(path: endpoint), using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(c, state) }
        }
        c.start(queue: .main)
    }

    private func changed(_ c: NWConnection, _ state: NWConnection.State) {
        guard c === conn else { return }
        switch state {
        case .ready:
            buffer = Data()
            errors = [:]
            resynced = [:]
            let processor = MessageProcessor(catalogs: catalogs)
            processor.outboundListener = { [weak self] message in
                MainActor.assumeIsolated { self?.outbound(message) }
            }
            self.processor = processor
            subscribed = wanted
            let capabilities = (try? processor.getRendererCapabilities(options: .init(protocolVersion: .v10)))
                .flatMap { try? JSONEncoder().encode($0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
            send(["hello": ["frontendId": Self.frontendID, "rendererCapabilities": capabilities, "surfaces": wanted.sorted()]])
            connected = true
            receive(c)
        case .waiting, .failed:
            // No one listening (yet): try again, as with a dropped connection.
            c.cancel()
        case .cancelled:
            conn = nil
            connected = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.conn == nil, !self.wanted.isEmpty else { return }
                    self.connect()
                }
            }
        default:
            break
        }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, c === self.conn else { return }
                if let data { self.buffer.append(data) }
                while let newline = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(self.buffer[..<newline])
                    self.buffer.removeSubrange(...newline)
                    self.handle(line)
                }
                if done || error != nil { return c.cancel() }
                self.receive(c)
            }
        }
    }

    /// One line from the Extension. A2UI lines go to the processor untouched.
    private func handle(_ line: Data) {
        guard !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }),
              let json = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        // dense's own messages: none go this way yet.
        if json.objectValue?["dense"] != nil { return }
        // A fresh snapshot clears what went wrong before.
        if let name = json.objectValue?["createSurface"]?.objectValue?["surfaceId"]?.stringValue { errors[name] = nil }
        try? processor.processMessages(json)
    }

    /// A message for the Extension: an action, a function call or its answer, or an error.
    /// An action marks its window as the one the surface's next ShowRequest is for. An error
    /// about a surface shows on it, and asks for the surface again.
    private func outbound(_ message: RendererToAgentMessage) {
        // An action is a click, in the window in front: a ShowRequest the Extension makes
        // of it is for that window.
        if case .action(let action) = message {
            DenseCatalog.keyController?.spaceTabs.clicked(objectID(namespace, action.surfaceID))
        }
        if case .error(let error) = message {
            let fields = (try? JSONEncoder().encode(error)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            guard let name = fields?["surfaceId"] as? String, wanted.contains(name) else { return }
            errors[name] = fields?["message"] as? String ?? "Error"
            resync(name)
        }
        guard let data = try? JSONEncoder().encode(message) else { return }
        conn?.send(content: data + Data("\n".utf8), completion: .idempotent)
    }

    /// Asks for a surface again: drops it here, then unsubscribes and subscribes, which
    /// makes the Extension send a full snapshot.
    private func resync(_ name: String) {
        guard connected, Date().timeIntervalSince(resynced[name] ?? .distantPast) > 10 else { return }
        resynced[name] = Date()
        deleteLocally(name)
        send(["unsubscribe": ["surfaceId": name]])
        send(["subscribe": ["surfaceId": name]])
    }

    private func deleteLocally(_ name: String) {
        guard processor.surfaceGroupModel[name] != nil,
              let json = try? JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: [
                  "version": "1.0", "deleteSurface": ["surfaceId": name],
              ])) else { return }
        try? processor.processMessages(json)
    }

    /// Sends one of dense's own messages.
    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["dense": message], options: .withoutEscapingSlashes) else { return }
        conn?.send(content: data + Data("\n".utf8), completion: .idempotent)
    }
}
