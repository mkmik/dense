import A2UICore
import A2UIJSON
import A2UISwiftUI
import AppKit
import BasicCatalog
import BasicCatalogSwiftUI
import GhosttyKit
import JSONSchema
import OrderedJSON
import SwiftUI

// ponytail: no DiffStat, Code, KeyHint or denGet (the PRD's R11) yet; add them when a panel needs one.
/// dense's A2UI catalog: the basic 1.0 catalog's components and functions, and a few of
/// dense's own on top, so an Extension's panel can link to tabs, show states and run dense's
/// commands. A surface may use it as its catalog, or use the basic catalog and pick dense's
/// components one by one with "@catalogId".
///
/// Components: SurfaceLink, StatusBadge, KeyValue, Section, ToolbarButton. Functions, each only from a
/// click: focusSurface, invokeCommand, copyText. Nothing here types into a terminal or acts
/// without a click; an Extension that needs to does it through dennet.
enum DenseCatalog {
    static let id = "https://dense.mkm.pub/a2ui/v1/catalog.json"

    /// The catalogs of a session with an Extension in `namespace`, whose surface references
    /// name tabs in that namespace.
    @MainActor
    static func catalogs(namespace: String, urlOpener: A2UIURLOpener) -> [Catalog<ComponentImplementation>] {
        let basic = BasicCatalogImplementation.makeCatalog(version: .v10, openURLHandler: urlOpener)
        let components = [
            ComponentImplementation(name: "SurfaceLink", schema: schema("SurfaceLink", """
                "surface": {"$ref": "\(common)DynamicString"},
                "label": {"$ref": "\(common)DynamicString"},
                "showState": {"$ref": "\(common)DynamicBoolean"}
                """, required: ["surface"])) { SurfaceLinkView(node: $0, namespace: namespace) },
            ComponentImplementation(name: "StatusBadge", schema: schema("StatusBadge", """
                "kind": {"$ref": "\(common)DynamicString"},
                "text": {"$ref": "\(common)DynamicString"}
                """, required: ["kind", "text"])) { StatusBadgeView(node: $0) },
            ComponentImplementation(name: "KeyValue", schema: schema("KeyValue", """
                "rows": {"$ref": "\(common)DynamicValue"}
                """, required: ["rows"])) { KeyValueView(node: $0) },
            ComponentImplementation(name: "Section", schema: schema("Section", """
                "title": {"$ref": "\(common)DynamicString"},
                "collapsed": {"$ref": "\(common)DynamicBoolean"},
                "child": {"$ref": "\(common)Child"}
                """, required: ["title", "child"])) { SectionView(node: $0) },
            ComponentImplementation(name: "ToolbarButton", schema: schema("ToolbarButton", """
                "icon": {"$ref": "\(common)DynamicString"},
                "help": {"$ref": "\(common)DynamicString"},
                "kind": {"$ref": "\(common)DynamicString"},
                "action": {"$ref": "\(common)Action"}
                """, required: ["icon"])) { ToolbarButtonView(node: $0) },
        ]
        let functions: [any FunctionImplementation] = [
            DenseFunction("focusSurface", #"{"ref": {"type": "string"}}"#, required: ["ref"]) { args in
                try focus(args["ref"]?.stringValue ?? "", namespace: namespace)
            },
            DenseFunction("invokeCommand", #"{"id": {"type": "string"}, "args": {}}"#, required: ["id"]) { args in
                try invoke(args["id"]?.stringValue ?? "", args["args"])
            },
            DenseFunction("copyText", #"{"text": {"type": "string"}}"#, required: ["text"]) { args in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(args["text"]?.stringValue ?? "", forType: .string)
            },
        ]
        let dense = Catalog(id: id, protocolVersion: .v10,
                            components: Array(basic.components.values) + components,
                            functions: Array(basic.functions.values) + functions)
        return [basic, dense]
    }

    private static let common = "https://a2ui.org/specification/v1_0/common_types.json#/$defs/"

    /// A component's schema: its own `properties` (JSON, without the braces) and the ones
    /// every v1.0 component has.
    private static func schema(_ name: String, _ properties: String, required: [String]) -> Schema {
        let required = (["component"] + required).map { "\"\($0)\"" }.joined(separator: ", ")
        return compiled("""
            {
              "type": "object",
              "properties": {
                "id": {"$ref": "\(common)ComponentId"},
                "component": {"const": "\(name)"},
                "@catalogId": {"type": "string"},
                "@metadata": {"type": "object"},
                "@accessibility": {"$ref": "\(common)AccessibilityAttributes"},
                "weight": {"type": "number"},
                \(properties)
              },
              "required": [\(required)]
            }
            """)
    }

    /// A schema written here. They are fixed, so a failure is a typo found on the first run.
    fileprivate static func compiled(_ json: String) -> Schema {
        do {
            return try Schema(instance: json, remoteSchemas: A2UICommonSchema.allSchemas)
        } catch {
            fatalError("dense's A2UI catalog: \(error)\n\(json)")
        }
    }

    /// The tab a surface reference names, "surface/NAME" or just "NAME", in `namespace`.
    static func surfaceID(_ ref: String, namespace: String) -> String {
        objectID(namespace, ref.hasPrefix("surface/") ? String(ref.dropFirst("surface/".count)) : ref)
    }

    /// The window the user just clicked in.
    @MainActor
    private static var keyController: TerminalController? {
        NSApp.keyWindow?.windowController as? TerminalController
    }

    /// Shows a tab, in the Space it is in, in the window clicked in.
    @MainActor
    static func focus(_ ref: String, namespace: String) throws {
        guard let tabs = keyController?.spaceTabs, tabs.show(surfaceID: surfaceID(ref, namespace: namespace)) else {
            throw DenseFunctionError(message: "No tab \(ref)")
        }
    }

    // ponytail: only Ghostty's actions; commands from Extensions come with the extension-resources design.
    /// Runs a Ghostty action, such as "new_tab" or "goto_tab:2", on the terminal of the
    /// window clicked in, as a key binding would. `args`, if any, goes after a colon.
    @MainActor
    private static func invoke(_ id: String, _ args: JSONValue?) throws {
        let arg = args?.stringValue ?? args?.intValue.map(String.init) ?? args?.boolValue.map(String.init)
        let action = arg.map { "\(id):\($0)" } ?? id
        guard let surface = keyController?.focusedSurface?.surface,
              ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) else {
            throw DenseFunctionError(message: "Could not run \(action)")
        }
    }
}

/// Opens links from the basic catalog's openUrl in the default browser.
final class A2UIURLOpener: OpenURLHandler {
    func open(_ url: URL) {
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }
}

struct DenseFunctionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One of dense's functions: renderer only, and only from a click.
private final class DenseFunction: FunctionImplementation, @unchecked Sendable {
    let api: FunctionAPI
    private let run: @MainActor ([String: JSONValue]) throws -> Void

    init(_ name: String, _ properties: String, required: [String], run: @escaping @MainActor ([String: JSONValue]) throws -> Void) {
        let required = required.map { "\"\($0)\"" }.joined(separator: ", ")
        api = FunctionAPI(
            name: name, returnType: .void,
            schema: DenseCatalog.compiled(#"{"type": "object", "properties": \#(properties), "required": [\#(required)]}"#),
            allowedCallers: .rendererOnly, requiresUserActivation: true)
        self.run = run
    }

    @MainActor
    func evaluate(arguments: [String: JSONValue], context: DataContext) throws -> JSONValue {
        try run(arguments)
        return .null
    }
}

/// A chip for a tab: its state, an icon and a label. A click shows the tab.
private struct SurfaceLinkView: View {
    let node: Node
    let namespace: String
    @ObservedObject private var store = SpaceStore.shared

    var body: some View {
        let ref = node.string(for: "surface") ?? ""
        let tab = store.surfaces[DenseCatalog.surfaceID(ref, namespace: namespace)]
        let den = tab.flatMap(store.den(of:))
        Button {
            try? DenseCatalog.focus(ref, namespace: namespace)
        } label: {
            HStack(spacing: 4) {
                if node.bool(for: "showState") == true {
                    Circle().fill(Self.color(den?.status?.phase)).frame(width: 6, height: 6)
                }
                Image(systemName: tab?.spec.web != nil ? "globe" : tab?.spec.ui != nil ? "square.grid.2x2"
                      : den?.agent == true ? "sparkle" : "terminal")
                    .imageScale(.small)
                Text(node.string(for: "label") ?? tab?.spec.title ?? ref).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(tab == nil)
        .help(den?.status?.phase ?? (tab == nil ? "No such tab" : ""))
    }

    private static func color(_ phase: String?) -> Color {
        switch phase {
        case "Running": return .green
        case "Pending": return .orange
        case "Failed", "Lost": return .red
        default: return .secondary
        }
    }
}

/// A short state, such as a merge request's or CI's, in a color for its kind.
private struct StatusBadgeView: View {
    let node: Node

    var body: some View {
        let color = Self.color(node.string(for: "kind"))
        Text(node.string(for: "text") ?? "")
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    /// The colors of the sidebar's state dots and badges (see `SpaceRow`).
    static func color(_ kind: String?) -> Color {
        switch kind {
        case "ok": return .green
        case "warn": return .orange
        case "error": return .red
        case "busy": return .blue
        default: return .secondary
        }
    }
}

/// A button as dense draws its own in the sidebar and the titlebar: an SF Symbol in a
/// 22-point square, secondary, or in the color `kind` gives a StatusBadge. Without an
/// action it is the symbol alone, for a Modal to use as its trigger: a click on it
/// opens the Modal, which a Button would swallow.
private struct ToolbarButtonView: View {
    let node: Node

    var body: some View {
        let symbol = Image(systemName: node.string(for: "icon") ?? "questionmark")
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .foregroundStyle(StatusBadgeView.color(node.string(for: "kind")))
        Group {
            if let action = node.action(for: "action", userActivation: true) {
                Button { action() } label: { symbol }.buttonStyle(.plain)
            } else {
                symbol
            }
        }
        .help(node.string(for: "help") ?? "")
    }
}

/// Facts in two columns. `rows` is a list of {"key", "value"} objects, or one object whose
/// keys and values are the rows.
private struct KeyValueView: View {
    let node: Node

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.key).foregroundStyle(.secondary)
                    Text(row.value).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .font(.caption)
    }

    private var rows: [(key: String, value: String)] {
        switch node.jsonValue(for: "rows") {
        case .array(let items):
            return items.compactMap { item in
                guard let key = item.objectValue?["key"]?.stringValue else { return nil }
                return (key, item.objectValue?["value"].map(Self.text) ?? "")
            }
        case .object(let object):
            return object.map { ($0.key, Self.text($0.value)) }
        default:
            return []
        }
    }

    private static func text(_ value: JSONValue) -> String {
        value.stringValue ?? value.intValue.map(String.init) ?? value.doubleValue.map { String($0) }
            ?? value.boolValue.map(String.init) ?? ""
    }
}

/// A group with a title that folds away. `collapsed` bound to the data model folds it
/// there, so the Extension sees it; otherwise it folds here only.
private struct SectionView: View {
    let node: Node
    @State private var folded: Bool?

    var body: some View {
        let binding: DataBinding<Bool>? = node.dataBinding(for: "collapsed")
        let collapsed = binding?.value ?? folded ?? node.bool(for: "collapsed") ?? false
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let binding { binding.set(!collapsed) } else { folded = !collapsed }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").imageScale(.small)
                    Text(node.string(for: "title") ?? "").font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if !collapsed, let child = node.child(for: "child") {
                ComponentNodeView(node: child)
            }
        }
    }
}
