import Combine
import Foundation
import Network

struct ObjectMeta: Decodable, Equatable {
    var name: String
    var namespace: String?
    var annotations: [String: String]?
}

/// An object stored in dennet (`den.mkm.pub/v1alpha1`). Only the fields dense uses are
/// decoded; other fields are ignored.
protocol DennetObject: Decodable, Equatable {
    var metadata: ObjectMeta { get }
}

extension DennetObject {
    /// "namespace/name", unique across namespaces.
    var id: String { objectID(metadata.namespace, metadata.name) }
}

func objectID(_ namespace: String?, _ name: String) -> String { "\(namespace ?? "")/\(name)" }

/// One node of the sidebar tree.
struct Space: DennetObject {
    struct Spec: Decodable, Equatable {
        var parent: String?
        var order: Int32?
        var title: String?
        var subtitle: String?
        var badges: [Badge]?
        var state: String?
        var collapsed: Bool?
        /// Free-form labels. Not shown; the sidebar filter can match them with "#tag".
        var tags: [String]?
        /// Where dens for this Space's tabs start; unset means the nearest Space above's.
        var workingDir: String?
        /// Archived Spaces are hidden from the sidebar and listed in Open Space (⌘K). dennet
        /// deletes an archived Space's tabs and Dens, and archives the Spaces under it.
        var archived: Bool?
    }

    struct Badge: Decodable, Equatable {
        var text: String
        var tone: String?
    }

    var metadata: ObjectMeta
    var spec: Spec
}

/// One tab inside a Space.
struct Surface: DennetObject {
    struct Spec: Decodable, Equatable {
        /// The name of the Space this tab belongs to, in the same namespace.
        var space: String
        var order: Int32?
        var title: String?
        var kind: String?
        var terminal: Terminal?
    }

    struct Terminal: Decodable, Equatable {
        /// The name of the Den to attach to, in the same namespace.
        var den: String
    }

    var metadata: ObjectMeta
    var spec: Spec
}

/// A program in a tab asking dense to show a Space, or a tab of one: the
/// `dense.mkm.pub/show` annotation on that tab's Surface, as JSON
/// `{"space": name, "surface": name, "at": time}`, names in the Surface's namespace. A
/// tab alone is enough; its Space is found from it. The time is there only so that every
/// request is a change to the annotation, even one asking for what the last one did.
///
/// Only the window that was just typed into the tab that asks does what it says (see
/// `SpaceTabs.obeys`), so each window keeps showing what it shows otherwise. Nothing in
/// dennet says what a window shows.
struct ShowRequest: Decodable, Equatable {
    static let annotation = "dense.mkm.pub/show"

    /// The id of the Surface that asks.
    var from = ""
    /// The ids of the Space and the tab to show.
    var space: String?
    var surface: String?

    enum CodingKeys: CodingKey { case space, surface }

    /// The request on a Surface, if it has one.
    init?(_ asking: Surface) {
        guard let json = asking.metadata.annotations?[Self.annotation],
              let names = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
              names.space != nil || names.surface != nil else { return nil }
        let namespace = asking.metadata.namespace
        from = asking.id
        space = names.space.map { objectID(namespace, $0) }
        surface = names.surface.map { objectID(namespace, $0) }
    }
}

/// A terminal session, run by den. dense creates Dens and reads their status, which den
/// (or dennet) keeps up to date.
struct Den: DennetObject {
    struct Spec: Decodable, Equatable {
        /// The program and its arguments; nil runs the user's shell.
        var command: [String]?
    }

    struct Status: Decodable, Equatable {
        /// Pending, Running, Exited, Failed or Lost.
        var phase: String?
        /// den's control socket.
        var socket: String?
        /// Whether the terminal's title is one a coding agent sets. Kept instead of the title,
        /// which an agent animates while it works, so the Den only changes when this does.
        var agentTitle = false

        enum CodingKeys: CodingKey { case phase, socket, title }

        init(phase: String? = nil, socket: String? = nil, title: String? = nil) {
            self.phase = phase
            self.socket = socket
            agentTitle = title.map(Den.agentTitle) ?? false
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(phase: try c.decodeIfPresent(String.self, forKey: .phase),
                      socket: try c.decodeIfPresent(String.self, forKey: .socket),
                      title: try c.decodeIfPresent(String.self, forKey: .title))
        }
    }

    var metadata: ObjectMeta
    var spec: Spec?
    var status: Status?

    /// Whether the den runs and has a socket to attach to.
    var running: Bool { status?.phase == "Running" && status?.socket?.isEmpty == false }

    /// Whether the den runs a coding agent: a word of its command is one, as in
    /// ["claude"] or ["/bin/zsh", "-lic", "claude --resume ID; exec /bin/zsh -l"], or one
    /// started in its shell has set the terminal's title (see `agentTitle`).
    // ponytail: only these names, and only Claude Code's titles; an agent that leaves the
    // title alone, like codex, is seen only from the command. If guessing falls short, den
    // could report the terminal's foreground program in its status.
    var agent: Bool {
        status?.agentTitle == true || (spec?.command ?? []).contains { arg in
            arg.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "&" || $0 == "|" })
                .contains { ["claude", "codex"].contains($0.split(separator: "/").last.map(String.init) ?? "") }
        }
    }
}

extension Den {
    /// Whether a terminal title is one Claude Code sets: a glyph, a space, then the task,
    /// as in "✳ logo" when it waits or "◐ more" while it works (the glyph spins).
    static func agentTitle(_ title: String) -> Bool {
        guard let glyph = title.unicodeScalars.first, title.unicodeScalars.dropFirst().first == " " else { return false }
        return "✳✢✶✻✽◐◓◑◒".unicodeScalars.contains(glyph) || (0x2801...0x28FF).contains(glyph.value)
    }
}

/// Another machine running dennet. Cluster-scoped: its objects show up here in the
/// namespace named after it. Named so as not to clash with Foundation's Host.
struct DennetHost: DennetObject {
    struct Spec: Decodable, Equatable {
        /// The ssh destination: [user@]host, an alias from ~/.ssh/config, or ssh://...
        var ssh: String
        /// The dennet socket there, if not where dennet puts it by default.
        var socketPath: String?
        /// den there; without it, den is found on the PATH of a login, interactive shell there.
        var denPath: String?
    }

    var metadata: ObjectMeta
    var spec: Spec
}

extension Space {
    /// A sidebar row: a space, how deep it sits in the tree, and the id of the row it sits
    /// under ("" at the top level). Rows with the same parent are siblings.
    struct Row: Identifiable, Equatable {
        let space: Space
        let depth: Int
        let parent: String
        var id: String { space.id }
    }

    /// Lays out spaces as sidebar rows: each space is followed by its children, and siblings
    /// are sorted by order, then name. Children of a collapsed space are left out. A space
    /// whose parent does not exist is shown at the top level. Spaces whose parents form a
    /// loop are not shown.
    static func rows(_ spaces: [Space]) -> [Row] {
        let ids = Set(spaces.map(\.id))
        let children = Dictionary(grouping: spaces) { space in
            let parent = objectID(space.metadata.namespace, space.spec.parent ?? "")
            return ids.contains(parent) ? parent : ""
        }
        var rows: [Row] = []
        func add(_ parent: String, _ depth: Int) {
            let sorted = (children[parent] ?? []).sorted {
                ($0.spec.order ?? 0, $0.metadata.name) < ($1.spec.order ?? 0, $1.metadata.name)
            }
            for space in sorted {
                rows.append(Row(space: space, depth: depth, parent: parent))
                if space.spec.collapsed != true { add(space.id, depth + 1) }
            }
        }
        add("", 0)
        return rows
    }

    /// Where tree lines go for each row, by row id. A line runs down through level k
    /// (1 ..< depth) while the row's ancestor at depth k has siblings still to come, and the
    /// row's own connector is "└" when it is its parent's last row, else "├".
    struct Guide: Equatable {
        var through: [Bool]
        var last: Bool
    }

    static func guides(_ rows: [Row]) -> [String: Guide] {
        var lastAt: [Int: Bool] = [:]
        var guides: [String: Guide] = [:]
        for (i, row) in rows.enumerated() {
            // Last unless a sibling comes before the rows leave this row's parent.
            let last = !rows[(i + 1)...].prefix { $0.depth >= row.depth }.contains { $0.depth == row.depth }
            lastAt[row.depth] = last
            guides[row.id] = Guide(through: (0..<row.depth).map { $0 > 0 && lastAt[$0] == false }, last: last)
        }
        return guides
    }

    /// The working directory for a new tab in `space`: its own, else the nearest one set
    /// on a Space above it in `spaces`. dennet leaves the inheriting to whoever makes dens.
    static func workingDir(of space: Space, in spaces: [String: Space]) -> String? {
        var seen: Set<String> = []
        var current: Space? = space
        while let s = current, seen.insert(s.id).inserted {
            if let dir = s.spec.workingDir, !dir.isEmpty { return dir }
            current = s.spec.parent.flatMap { spaces[objectID(s.metadata.namespace, $0)] }
        }
        return nil
    }

    /// The rows a sidebar filter keeps. Words of the query that start with "#" are tags: a
    /// row is kept if it, or a Space above it, has one of those tags exactly, so a tagged
    /// Space brings its subspaces along. The other words, together, must be in the title.
    /// The Spaces above a kept row stay too, to show where it is.
    static func filter(_ rows: [Row], _ query: String) -> [Row] {
        let words = query.split(whereSeparator: \.isWhitespace)
        let tags = Set(words.filter { $0.hasPrefix("#") && $0.count > 1 }.map { String($0.dropFirst()) })
        let text = words.filter { !$0.hasPrefix("#") }.joined(separator: " ")
        guard !tags.isEmpty || !text.isEmpty else { return rows }

        let parents = Dictionary(rows.map { ($0.id, $0.parent) }) { a, _ in a }
        // Rows come after the row above them, so a parent's answer is known first.
        var tagged: [String: Bool] = [:]
        var keep = Set<String>()
        for row in rows {
            tagged[row.id] = !Set(row.space.spec.tags ?? []).isDisjoint(with: tags) || tagged[row.parent] == true
            guard tags.isEmpty || tagged[row.id] == true,
                  text.isEmpty || (row.space.spec.title ?? row.space.metadata.name).localizedCaseInsensitiveContains(text)
            else { continue }
            var id: String? = row.id
            while let current = id, !current.isEmpty, keep.insert(current).inserted { id = parents[current] }
        }
        return rows.filter { keep.contains($0.id) }
    }

    /// This space's terminal Surfaces, sorted by order, then name.
    func terminals(_ surfaces: [Surface]) -> [Surface] {
        surfaces
            .filter { $0.metadata.namespace == metadata.namespace && $0.spec.space == metadata.name && $0.spec.terminal != nil }
            .sorted { ($0.spec.order ?? 0, $0.metadata.name) < ($1.spec.order ?? 0, $1.metadata.name) }
    }
}

/// Watches the Spaces, Surfaces and Dens in dennet and keeps `spaces`, `surfaces` and
/// `dens` up to date.
///
/// dennet's lists across all namespaces have only this machine's objects. So for each
/// Host it also watches the Host's namespace, which dennet forwards to that machine, and
/// stops when the Host goes away.
///
/// It speaks HTTP/1.0 over dennet's Unix socket. With HTTP/1.0 the server sends a watch
/// as plain JSON lines, one event per line, and closes the connection when the watch ends.
/// Each watch starts by sending every existing object, then a BOOKMARK event; only then is
/// the old list replaced, so a reconnect never shows an empty or half-filled sidebar.
/// When a connection drops, it reconnects after two seconds.
final class SpaceStore: ObservableObject {
    static let shared = SpaceStore(socketPath: NSString(string: "~/.local/state/dennet/dennet.sock").expandingTildeInPath)

    /// Spaces by `id`.
    @Published private(set) var spaces: [String: Space] = [:]

    /// Surfaces by `id`.
    @Published private(set) var surfaces: [String: Surface] = [:]

    /// Dens by `id`.
    @Published private(set) var dens: [String: Den] = [:]

    /// Hosts by `id`.
    @Published private(set) var hosts: [String: DennetHost] = [:] {
        didSet {
            let names = Set(hosts.values.map(\.metadata.name))
            queue.async { self.watchHosts(names) }
        }
    }

    /// Requests to show a Space or tab, as they come in. Only changes are sent: a request
    /// already there when a watch starts, or starts again, is old.
    let showRequests = PassthroughSubject<ShowRequest, Never>()

    /// Why dennet can't be reached right now, or nil while the watches are running.
    @Published private(set) var problem: String?

    /// Why a Host can't be reached right now, by Host name.
    @Published private(set) var hostProblems: [String: String] = [:]

    /// The names of the Hosts, sorted.
    var hostNames: [String] { hosts.values.map(\.metadata.name).sorted() }

    /// The Spaces on a Host, or on this machine for nil: the archived ones, or the others.
    func spaces(on host: String?, archived: Bool = false) -> [Space] {
        let names = Set(hosts.values.map(\.metadata.name))
        return spaces.values.filter { space in
            guard (space.spec.archived == true) == archived else { return false }
            guard let host else { return !names.contains(space.metadata.namespace ?? "default") }
            return space.metadata.namespace == host
        }
    }

    /// The ids each watch put in its list, by watch key ("namespace/resource", "*" for
    /// all namespaces), so a watch replaces only its own objects. Main thread only.
    private var owned: [String: Set<String>] = [:]

    /// The open watch connections by key, and the Hosts being watched. Queue only.
    private var connections: [String: NWConnection] = [:]
    private var watchedHosts: Set<String> = []

    /// True once all the lists have arrived from dennet for the first time.
    @Published private(set) var loaded = false
    private var loadedLists: Set<String> = []

    /// The Hosts whose lists have all arrived, and each Host's lists so far.
    @Published private(set) var loadedHosts: Set<String> = []
    private var hostLoadedLists: [String: Set<String>] = [:]

    /// Whether the lists for a Space's machine have arrived, so it shows all its tabs.
    func loaded(_ space: Space) -> Bool {
        let namespace = space.metadata.namespace ?? "default"
        return hosts.values.contains { $0.metadata.name == namespace } ? loadedHosts.contains(namespace) : loaded
    }

    let socketPath: String
    private let queue = DispatchQueue(label: "pub.mkm.dense.dennet")

    init(socketPath: String) {
        self.socketPath = socketPath
        queue.async {
            self.watch("spaces", \.spaces)
            self.watch("surfaces", \.surfaces)
            self.watch("dens", \.dens)
            self.watch("hosts", \.hosts)
        }
    }

    /// Starts watching new Hosts' namespaces and stops watching gone ones. On the queue.
    private func watchHosts(_ names: Set<String>) {
        for gone in watchedHosts.subtracting(names) {
            for resource in ["spaces", "surfaces", "dens"] { connections["\(gone)/\(resource)"]?.cancel() }
            DispatchQueue.main.async {
                for resource in ["spaces", "surfaces", "dens"] {
                    let ids = self.owned.removeValue(forKey: "\(gone)/\(resource)") ?? []
                    for id in ids {
                        self.spaces[id] = nil
                        self.surfaces[id] = nil
                        self.dens[id] = nil
                    }
                }
                self.hostProblems[gone] = nil
                self.hostLoadedLists[gone] = nil
                self.loadedHosts.remove(gone)
            }
        }
        for new in names.subtracting(watchedHosts) {
            watch("spaces", in: new, \.spaces)
            watch("surfaces", in: new, \.surfaces)
            watch("dens", in: new, \.dens)
        }
        watchedHosts = names
    }

    /// The Den a terminal Surface attaches to, if dennet has it.
    func den(of surface: Surface) -> Den? {
        surface.spec.terminal.flatMap { dens[objectID(surface.metadata.namespace, $0.den)] }
    }

    private struct WatchEvent<Object: Decodable>: Decodable {
        var type: String
        /// nil for events that carry no object of the watched kind, such as BOOKMARK and ERROR.
        var object: Object?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            object = try? container.decode(Object.self, forKey: .object)
        }

        enum CodingKeys: CodingKey { case type, object }
    }

    struct RequestError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends one request to dennet and returns the response body. A status other than 2xx
    /// throws, with dennet's message when it sent one.
    func request(
        _ method: String,
        _ path: String,
        json body: [String: Any]? = nil,
        contentType: String = "application/json"
    ) async throws -> Data {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await withCheckedThrowingContinuation { continuation in
            let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
            var response = Data()
            var ready = false
            var finished = false

            func finish(_ result: Result<Data, Error>) {
                guard !finished else { return }
                finished = true
                conn.cancel()
                continuation.resume(with: result)
            }

            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                    if let data { response.append(data) }
                    if let error { return finish(.failure(error)) }
                    guard done else { return receive() }

                    // HTTP/1.0: the server closes the connection after the body.
                    guard let end = response.range(of: Data("\r\n\r\n".utf8)) else {
                        return finish(.failure(RequestError(message: "dennet sent no response")))
                    }
                    let status = String(decoding: response[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
                    let body = Data(response[end.upperBound...])
                    guard status.split(separator: " ").dropFirst().first?.hasPrefix("2") == true else {
                        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                        return finish(.failure(RequestError(message: json?["message"] as? String ?? "dennet: \(status)")))
                    }
                    finish(.success(body))
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready = true
                    var head = "\(method) \(path) HTTP/1.0\r\nHost: dennet\r\n"
                    if let payload { head += "Content-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\n" }
                    conn.send(content: Data((head + "\r\n").utf8) + (payload ?? Data()), completion: .idempotent)
                    receive()
                case .waiting(let error), .failed(let error):
                    // Once connected, receive() reports how it ended. dennet closing the
                    // connection after the response can show up here first, as a failure
                    // ("Network is down"), while the whole response is still to be read.
                    if !ready { finish(.failure(error)) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Creates an object and returns it as dennet stored it.
    func create<T: Decodable>(
        _ resource: String,
        kind: String,
        namespace: String,
        metadata: [String: Any],
        spec: [String: Any]
    ) async throws -> T {
        let body: [String: Any] = ["apiVersion": "den.mkm.pub/v1alpha1", "kind": kind, "metadata": metadata, "spec": spec]
        let data = try await request("POST", "/apis/den.mkm.pub/v1alpha1/namespaces/\(namespace)/\(resource)", json: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Watches one resource, in all namespaces or in a Host's namespace. On the queue.
    private func watch<Object: DennetObject>(
        _ resource: String,
        in host: String? = nil,
        _ list: ReferenceWritableKeyPath<SpaceStore, [String: Object]>
    ) {
        let key = "\(host ?? "*")/\(resource)"
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connections[key] = conn
        var buffer = Data()
        var streaming = false
        // The full list being rebuilt from the watch's initial events; nil once it is live.
        var initial: [String: Object]? = [:]

        func fail(_ message: String) {
            DispatchQueue.main.async {
                if let host { self.hostProblems[host] = message } else { self.problem = message }
            }
            conn.cancel()
        }

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                if let data { buffer.append(data) }

                if !streaming, let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let status = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
                    guard status.contains(" 200 ") else { return fail("dennet \(resource): \(status)") }
                    buffer.removeSubrange(..<end.upperBound)
                    streaming = true
                }

                while streaming, let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let event = try? JSONDecoder().decode(WatchEvent<Object>.self, from: Data(buffer[..<newline]))
                    buffer.removeSubrange(...newline)
                    guard let event else { continue }
                    if let objects = initial {
                        // The first BOOKMARK marks the end of the initial events.
                        if event.type == "BOOKMARK" {
                            initial = nil
                            DispatchQueue.main.async {
                                var all = self[keyPath: list]
                                for id in self.owned[key] ?? [] { all[id] = nil }
                                all.merge(objects) { $1 }
                                self.owned[key] = Set(objects.keys)
                                self[keyPath: list] = all
                                if let host {
                                    self.hostProblems[host] = nil
                                    self.hostLoadedLists[host, default: []].insert(resource)
                                    if self.hostLoadedLists[host]?.count == 3 { self.loadedHosts.insert(host) }
                                } else {
                                    self.problem = nil
                                    self.loadedLists.insert(resource)
                                    if !self.loaded && self.loadedLists.count == 4 { self.loaded = true }
                                }
                            }
                        } else if let object = event.object {
                            initial?[object.id] = object
                        }
                    } else if let object = event.object {
                        let deleted = event.type == "DELETED"
                        DispatchQueue.main.async {
                            // A Den's status changes often in fields dense doesn't read.
                            let new = deleted ? nil : object
                            if let surface = new as? Surface,
                               let ask = surface.metadata.annotations?[ShowRequest.annotation],
                               ask != self.surfaces[surface.id]?.metadata.annotations?[ShowRequest.annotation],
                               let request = ShowRequest(surface) {
                                self.showRequests.send(request)
                            }
                            if deleted { self.owned[key]?.remove(object.id) } else { self.owned[key, default: []].insert(object.id) }
                            if self[keyPath: list][object.id] != new { self[keyPath: list][object.id] = new }
                        }
                    }
                }

                if let error { return fail("dennet: \(error)") }
                if done { return conn.cancel() }
                receive()
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let scope = host.map { "namespaces/\($0)/" } ?? ""
                let path = "/apis/den.mkm.pub/v1alpha1/\(scope)\(resource)?watch=1&sendInitialEvents=true&allowWatchBookmarks=true&resourceVersionMatch=NotOlderThan"
                conn.send(content: Data("GET \(path) HTTP/1.0\r\nHost: dennet\r\n\r\n".utf8), completion: .idempotent)
                receive()
            case .waiting(let error), .failed(let error):
                fail("dennet: \(error) (\(self.socketPath))")
            case .cancelled:
                // Reconnect, unless the Host is gone or another watch has taken over.
                if self.connections[key] === conn { self.connections[key] = nil }
                self.queue.asyncAfter(deadline: .now() + 2) {
                    guard self.connections[key] == nil, host.map(self.watchedHosts.contains) ?? true else { return }
                    self.watch(resource, in: host, list)
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }
}
