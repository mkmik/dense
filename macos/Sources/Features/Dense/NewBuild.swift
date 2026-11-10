import AppKit
import SwiftUI

/// Notices when the app on disk has been rebuilt since this copy started, by reading
/// the build date in the bundle's Info.plist every few seconds. Ghostty's own updater
/// is for released versions; this is for local builds.
final class NewBuild: ObservableObject {
    static let shared = NewBuild()

    /// True once the Info.plist on disk names another build than the one running.
    @Published private(set) var available = false

    private let running = Bundle.main.infoDictionary?["DenseBuildDate"] as? String
    private var timer: Timer?

    private init() {
        timer = .scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let running, let date = NSDictionary(contentsOf: plist)?["DenseBuildDate"] as? String,
              date != running else { return }
        available = true
        timer?.invalidate()
    }

    /// Quits, and opens the app again once this process has gone. Quitting asks first if
    /// Ghostty's quit confirmation would; the dens keep running either way.
    static func restart() {
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Gives up after 30 s, in case the quit was cancelled.
        wait.arguments = ["-c", "for i in $(seq 150); do kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$2\"; sleep 0.2; done",
                          "sh", "\(ProcessInfo.processInfo.processIdentifier)", Bundle.main.bundlePath]
        do {
            try wait.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}

/// A blue pill in the window's corner, like Ghostty's update pill, while a newer build
/// is on disk. Clicking it restarts dense.
struct NewBuildPill: View {
    @ObservedObject var build: NewBuild = .shared

    var body: some View {
        if build.available {
            Button(action: NewBuild.restart) {
                HStack(spacing: 6) {
                    Image(systemName: "power.circle").imageScale(.small)
                    Text("Restart to Use New Build").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor))
                .foregroundColor(.white)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("A newer build of dense is on disk. Click to restart into it.")
            .padding(9)
        }
    }
}
