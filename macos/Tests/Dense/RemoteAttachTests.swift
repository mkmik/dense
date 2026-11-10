import Foundation
import Testing
@testable import Ghostty

/// Runs the script ssh would run on a Host, with a fake `den`, and a fake login shell that
/// puts it on the PATH. Both print what they were asked to do.
struct RemoteAttachTests {
    private func run(denPath: Bool = false, debug: Bool = false) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func script(_ url: URL, _ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // The shell puts den on the PATH, as .zshrc would.
        let login = dir.appendingPathComponent("login")
        try script(login, #"PATH="$PATH:\#(bin.path)"; echo login "$1" "$2" "$3"; eval "$4""#)
        let den = bin.appendingPathComponent("den")
        try script(den, #"echo den "$@""#)

        let command = SpaceTabs.remoteAttach(.init(ssh: "h", socketPath: "/s/dennet.sock", denPath: denPath ? den.path : nil), den: "d1", debug: debug)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin", "SHELL": login.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private let attach = "den attach --unix-socket /s/dennet.sock -f http://dennet/apis/den.mkm.pub/v1alpha1/namespaces/default/dens/d1\n"

    /// Clears the screen and scrollback before den draws.
    private let clear = "\u{1b}[H\u{1b}[2J\u{1b}[3J"

    @Test func runsDenFromALoginInteractiveShell() throws {
        #expect(try run() == "\u{1b}[2mStarting a login shell to run den…\u{1b}[0m\r\nlogin -l -i -c\n" + clear + attach)
    }

    @Test func runsTheHostsDenPathWithoutALoginShell() throws {
        #expect(try run(denPath: true) == "\u{1b}[2mStarting den…\u{1b}[0m\r\n" + clear + attach)
    }

    @Test func debugTimesEachStepAndKeepsTheScreen() throws {
        let out = try run(debug: true)
        #expect(!out.contains(clear))
        #expect(out.hasSuffix("Login shell ready, starting den in 5 s…\u{1b}[0m\r\n" + attach))
        // A time like 12:34:56.789 before each step.
        #expect(try out.matches(of: Regex(#"\d\d:\d\d:\d\d\.\d\d\d "#)).count == 2)
    }
}
