import Combine
import Foundation
import Network

/// One node of the sidebar tree, as stored in dennet (`den.mkm.pub/v1alpha1`, kind Space).
/// Only the fields the sidebar draws are decoded; other fields are ignored.
struct Space: Decodable, Equatable {
    struct Metadata: Decodable, Equatable {
        var name: String
        var namespace: String?
    }

    struct Spec: Decodable, Equatable {
        var parent: String?
        var order: Int32?
        var title: String?
        var subtitle: String?
        var badges: [Badge]?
        var state: String?
        var collapsed: Bool?
    }

    struct Badge: Decodable, Equatable {
        var text: String
        var tone: String?
    }

    var metadata: Metadata
    var spec: Spec

    /// "namespace/name", unique across namespaces.
    var id: String { Self.id(metadata.namespace, metadata.name) }

    static func id(_ namespace: String?, _ name: String) -> String { "\(namespace ?? "")/\(name)" }
}

extension Space {
    /// A sidebar row: a space and how deep it sits in the tree.
    struct Row: Identifiable, Equatable {
        let space: Space
        let depth: Int
        var id: String { space.id }
    }

    /// Lays out spaces as sidebar rows: each space is followed by its children, and siblings
    /// are sorted by order, then name. Children of a collapsed space are left out. A space
    /// whose parent does not exist is shown at the top level. Spaces whose parents form a
    /// loop are not shown.
    static func rows(_ spaces: [Space]) -> [Row] {
        let ids = Set(spaces.map(\.id))
        let children = Dictionary(grouping: spaces) { space in
            let parent = id(space.metadata.namespace, space.spec.parent ?? "")
            return ids.contains(parent) ? parent : ""
        }
        var rows: [Row] = []
        func add(_ parent: String, _ depth: Int) {
            let sorted = (children[parent] ?? []).sorted {
                ($0.spec.order ?? 0, $0.metadata.name) < ($1.spec.order ?? 0, $1.metadata.name)
            }
            for space in sorted {
                rows.append(Row(space: space, depth: depth))
                if space.spec.collapsed != true { add(space.id, depth + 1) }
            }
        }
        add("", 0)
        return rows
    }
}

/// Watches the Spaces in dennet and keeps `spaces` up to date.
///
/// It speaks HTTP/1.0 over dennet's Unix socket. With HTTP/1.0 the server sends the watch
/// as plain JSON lines, one event per line, and closes the connection when the watch ends.
/// Each watch starts by sending every existing Space, then a BOOKMARK event; only then is
/// the old list replaced, so a reconnect never shows an empty or half-filled sidebar.
/// When the connection drops, it reconnects after two seconds.
final class SpaceStore: ObservableObject {
    static let shared = SpaceStore(socketPath: NSString(string: "~/.local/state/dennet/dennet.sock").expandingTildeInPath)

    /// Spaces by `Space.id`.
    @Published private(set) var spaces: [String: Space] = [:]

    /// Why dennet can't be reached right now, or nil while the watch is running.
    @Published private(set) var problem: String?

    private let socketPath: String
    private let queue = DispatchQueue(label: "pub.mkm.dense.dennet")

    init(socketPath: String) {
        self.socketPath = socketPath
        queue.async { self.connect() }
    }

    private struct WatchEvent: Decodable {
        var type: String
        /// nil for events that carry no Space, such as BOOKMARK and ERROR.
        var object: Space?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            object = try? container.decode(Space.self, forKey: .object)
        }

        enum CodingKeys: CodingKey { case type, object }
    }

    private func connect() {
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        var buffer = Data()
        var streaming = false
        // The full list being rebuilt from the watch's initial events; nil once it is live.
        var initial: [String: Space]? = [:]

        func fail(_ message: String) {
            DispatchQueue.main.async { self.problem = message }
            conn.cancel()
        }

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                if let data { buffer.append(data) }

                if !streaming, let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let status = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
                    guard status.contains(" 200 ") else { return fail("dennet: \(status)") }
                    buffer.removeSubrange(..<end.upperBound)
                    streaming = true
                }

                while streaming, let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let event = try? JSONDecoder().decode(WatchEvent.self, from: Data(buffer[..<newline]))
                    buffer.removeSubrange(...newline)
                    guard let event else { continue }
                    if let list = initial {
                        // The first BOOKMARK marks the end of the initial events.
                        if event.type == "BOOKMARK" {
                            initial = nil
                            DispatchQueue.main.async { self.spaces = list; self.problem = nil }
                        } else if let space = event.object {
                            initial?[space.id] = space
                        }
                    } else if let space = event.object {
                        let deleted = event.type == "DELETED"
                        DispatchQueue.main.async { self.spaces[space.id] = deleted ? nil : space }
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
                let path = "/apis/den.mkm.pub/v1alpha1/spaces?watch=1&sendInitialEvents=true&allowWatchBookmarks=true&resourceVersionMatch=NotOlderThan"
                conn.send(content: Data("GET \(path) HTTP/1.0\r\nHost: dennet\r\n\r\n".utf8), completion: .idempotent)
                receive()
            case .waiting(let error), .failed(let error):
                fail("dennet: \(error) (\(self.socketPath))")
            case .cancelled:
                self.queue.asyncAfter(deadline: .now() + 2) { self.connect() }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }
}
