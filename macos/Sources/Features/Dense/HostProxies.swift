import CryptoKit
import Foundation
import Network
import WebKit

/// Web tabs in a Space on a Host browse from that Host: their requests go through a SOCKS
/// proxy that ssh (-D) runs to it, so names are looked up there and connections made from
/// there, to its containers, its network and, as `<host>.localhost`, its own ports.
///
/// WebKit never sends localhost or a loopback address through a proxy, so a link to one is
/// rewritten to `<host>.localhost`, a name the Host looks up to itself (macOS does, and Linux
/// with systemd-resolved; elsewhere it needs a line in /etc/hosts).
///
/// Each Host has its own website data store, as a proxy is set on one, so its cookies are
/// its own. One ssh per Host runs until Dense quits.
///
/// ponytail: the SOCKS port listens on this Mac's loopback, so any process here can use it
/// while it runs; a unix socket would keep it to Dense, but WebKit can't use one. A page's
/// own scripts that name localhost still reach this Mac.
@MainActor
final class HostProxies {
    static let shared = HostProxies()

    private struct Proxy {
        let dest: String
        let process: Process
        /// Kept open while Dense runs. When Dense quits, even if it crashes, it closes, the
        /// command on the Host ends, and so does ssh.
        let stdin: Pipe
        let ready: Task<Void, Error>
    }

    private var proxies: [String: Proxy] = [:]
    private var stores: [String: WKWebsiteDataStore] = [:]

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// The website data store of web tabs on the Host named `host`. It is kept on disk, under
    /// an id that comes from the name, so it keeps its cookies when Dense starts again.
    @available(macOS 14, *)
    func store(_ host: String) -> WKWebsiteDataStore {
        if let store = stores[host] { return store }
        var bytes = Array(SHA256.hash(data: Data("dense.host.\(host)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50 // a name-based UUID (version 5), as it should be
        bytes[8] = bytes[8] & 0x3F | 0x80
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let store = WKWebsiteDataStore(forIdentifier: id)
        stores[host] = store
        return store
    }

    /// Where a link to this Mac points on the Host named `host`: localhost, 127.0.0.1 or
    /// ::1 become `<host>.localhost`. nil for any other link.
    nonisolated static func onHost(_ url: URL, host: String) -> URL? {
        guard ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        parts.host = "\(host).localhost"
        return parts.url
    }

    /// Returns once the Host's proxy runs and its web tabs' store uses it.
    @available(macOS 14, *)
    func connect(_ host: DennetHost) async throws {
        let name = host.metadata.name
        if let proxy = proxies[name] {
            if proxy.dest == host.spec.ssh, proxy.process.isRunning { return try await proxy.ready.value }
            proxy.process.terminate()
        }

        let port = try Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -- ends ssh's options, so the destination can't be read as one.
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
                             "-D", "127.0.0.1:\(port)", "--", host.spec.ssh, "cat >/dev/null"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        // ssh logs each connection the Host can't make; drained so it never blocks on a full
        // pipe, and the end kept to say why it failed.
        let stderr = Pipe()
        process.standardError = stderr
        let log = Log()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }
        try process.run()

        let store = store(name)
        let ready = Task {
            for _ in 0..<300 {
                if !process.isRunning {
                    let why = log.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw Failure(errorDescription: "Could not reach \(host.spec.ssh): \(why.isEmpty ? "ssh exited" : why)")
                }
                if Self.listening(port) {
                    let proxy = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                    store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: proxy)]
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            process.terminate()
            throw Failure(errorDescription: "Reaching \(host.spec.ssh) timed out.")
        }
        proxies[name] = Proxy(dest: host.spec.ssh, process: process, stdin: stdin, ready: ready)
        try await ready.value
    }

    /// A port no one here listens on, for ssh to listen on.
    ///
    /// ponytail: another process could take it before ssh does; ssh then fails, and the next
    /// page load tries another.
    private nonisolated static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(errorDescription: "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var addr = loopback(0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        guard ok else { throw Failure(errorDescription: "Could not find a free port: \(String(cString: strerror(errno)))") }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// Whether something here accepts connections on 127.0.0.1:port.
    private nonisolated static func listening(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = loopback(port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private nonisolated static func loopback(_ port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }

    /// The last 2 KB ssh wrote to stderr.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ more: Data) {
            lock.withLock { data = (data + more).suffix(2048) }
        }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
