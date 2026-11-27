import A2UICore
import Foundation
import Testing
@testable import Ghostty

/// Drives an `ExtensionSession` with a fake Extension on a Unix socket: the hello, a
/// snapshot drawn with dense's catalog, a click, a bad message, and a reconnect.
@MainActor
struct A2UISessionTests {
    /// Surfaces shown longest ago go first, but never those on screen.
    @Test func trimKeepsLastShown() {
        #expect(A2UIHub.trim(["a", "b", "c", "d"], showing: [], limit: 2) == ["c", "d"])
        #expect(A2UIHub.trim(["a", "b", "c", "d"], showing: ["a"], limit: 2) == ["a", "d"])
        #expect(A2UIHub.trim(["a", "b", "c"], showing: ["a", "b", "c"], limit: 1) == ["a", "b", "c"])
        #expect(A2UIHub.trim(["a"], showing: [], limit: 0) == [])
    }

    @Test func sessionWithAnExtension() async throws {
        let ext = try FakeExtension()
        let session = ExtensionSession(namespace: "default", endpoint: ext.path)
        session.sync(endpoint: ext.path, surfaces: ["s1"])

        let hello = try await ext.next()
        #expect(hello.contains(#""hello""#) && hello.contains(#""surfaces":["s1"]"#), "\(hello)")
        #expect(hello.contains(DenseCatalog.id), "rendererCapabilities name dense's catalog: \(hello)")

        ext.send(#"""
            {"version":"1.0","createSurface":{"surfaceId":"s1","catalogId":"\#(DenseCatalog.id)",
             "dataModel":{"mr":{"kind":"ok","text":"merged"}},
             "components":[
              {"id":"root","component":"Column","children":["badge","go"]},
              {"id":"badge","component":"StatusBadge","kind":{"@path":"/mr/kind"},"text":{"@path":"/mr/text"}},
              {"id":"go","component":"Button","child":"go_l","action":{"event":{"name":"clicked","context":{"state":{"@path":"/mr/text"}}}}},
              {"id":"go_l","component":"Text","text":"Go"}]}}
            """#.replacingOccurrences(of: "\n", with: ""))
        try await until { session.processor.surfaceGroupModel["s1"]?.rootNode != nil }
        #expect(session.connected)
        let children = try #require(session.processor.surfaceGroupModel["s1"]?.rootNode).children(for: "children")
        #expect(children.map(\.type) == ["StatusBadge", "Button"])
        #expect(children.first?.string(for: "kind") == "ok")

        // An update changes the binding; a click goes to the Extension with its context.
        ext.send(#"{"version":"1.0","updateDataModel":{"surfaceId":"s1","path":"/mr/text","value":"open"}}"#)
        try await until { session.processor.surfaceGroupModel["s1"]?.rootNode?.children(for: "children").first?.string(for: "text") == "open" }
        session.processor.surfaceGroupModel["s1"]?.rootNode?.children(for: "children").last?.action(for: "action", userActivation: true)?()
        let action = try await ext.next()
        #expect(action.contains(#""name":"clicked""#) && action.contains(#""state":"open""#), "\(action)")

        // Creating it again is an error: it shows on the surface, goes to the Extension,
        // and the surface is asked for again.
        ext.send(#"{"version":"1.0","createSurface":{"surfaceId":"s1","catalogId":"\#(DenseCatalog.id)"}}"#)
        let replies = [try await ext.next(), try await ext.next(), try await ext.next()]
        #expect(replies.contains { $0.contains(#""error""#) }, "\(replies)")
        #expect(replies.contains { $0.contains(#""unsubscribe":{"surfaceId":"s1"}"#) }, "\(replies)")
        #expect(replies.contains { $0.contains(#""subscribe":{"surfaceId":"s1"}"#) }, "\(replies)")
        #expect(session.errors["s1"] != nil)

        // Disconnected, the surface stays; the session dials again and says hello.
        ext.dropClient()
        try await until { !session.connected }
        let hello2 = try await ext.next(timeout: 5)
        #expect(hello2.contains(#""hello""#), "\(hello2)")
        session.close()
    }

    private func until(_ ok: () -> Bool) async throws {
        for _ in 0..<100 where !ok() { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(ok())
    }
}

/// An Extension that takes one connection at a time and hands over each line it reads.
private final class FakeExtension: @unchecked Sendable {
    let path = NSTemporaryDirectory() + "a2ui-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32 = -1
    private var lines: [String] = []

    init() throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
            path.utf8CString.withUnsafeBytes { sunPath.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread { [self] in
            while true {
                let c = accept(listener, nil, nil)
                guard c >= 0 else { return }
                lock.withLock { client = c }
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 65536)
                while case let n = read(c, &chunk, chunk.count), n > 0 {
                    buffer.append(contentsOf: chunk[..<n])
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = String(bytes: buffer[..<newline], encoding: .utf8) ?? ""
                        buffer.removeSubrange(...newline)
                        lock.withLock { lines.append(line) }
                    }
                }
                close(c)
            }
        }.start()
    }

    deinit {
        close(listener)
        unlink(path)
    }

    func send(_ line: String) {
        let c = lock.withLock { client }
        _ = (line + "\n").utf8CString.dropLast().withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
    }

    func dropClient() {
        lock.withLock { _ = shutdown(client, SHUT_RDWR) }
    }

    /// The next line read, waiting for it.
    func next(timeout: Double = 2) async throws -> String {
        let deadline = Date() + timeout
        while Date() < deadline {
            if let line = lock.withLock({ lines.isEmpty ? nil : lines.removeFirst() }) { return line }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }
}
