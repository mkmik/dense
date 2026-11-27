import A2UICore
import AppKit
import A2UISwiftUI
import SwiftUI

/// One of an Extension's A2UI surfaces, by the Extension's id and the surface's name, drawn
/// with dense's catalogs. While the Extension is disconnected it stays as it was, greyed,
/// with its inputs off, under a line that says so. An error in its messages shows above it
/// until a fresh snapshot comes. It never takes the focus.
struct A2UIView: View {
    let `extension`: String
    let name: String
    @ObservedObject private var hub = A2UIHub.shared

    var body: some View {
        Group {
            if let session = hub.sessions[`extension`] {
                SessionSurface(session: session, name: name)
            } else {
                Text("No extension \(`extension`)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { hub.appeared(name) }
        .onDisappear { hub.disappeared(name) }
    }
}

/// What a tab of kind ui shows: its Extension's surface, filling the tab. The view takes
/// the focus when the tab is shown, as a page does, so typing doesn't go to a terminal
/// out of sight.
final class UIPage: TabPage {
    let root: NSView

    init(_ tab: Surface) {
        root = UIPageView(rootView: AnyView(ScrollView {
            A2UIView(extension: tab.uiExtension ?? "", name: tab.metadata.name)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }))
    }
}

private final class UIPageView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { true }
}

private struct SessionSurface: View {
    @ObservedObject var session: ExtensionSession
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !session.connected {
                Label("Disconnected", systemImage: "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = session.errors[name] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Drawn(group: session.processor.surfaceGroupModel, name: name, catalogs: session.catalogs)
                .disabled(!session.connected)
                .opacity(session.connected ? 1 : 0.5)
        }
    }
}

/// The surface itself, once its snapshot has come.
private struct Drawn: View {
    @ObservedObject var group: SurfaceGroupModel
    let name: String
    let catalogs: [Catalog<ComponentImplementation>]

    var body: some View {
        if let model = group[name] {
            A2UISwiftUI.Surface(viewModel: model, catalogs: catalogs)
        }
    }
}
