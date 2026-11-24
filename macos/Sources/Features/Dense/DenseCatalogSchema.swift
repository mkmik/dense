import A2UICore
import A2UIJSON
import BasicCatalog
import JSONSchema

/// What dense's A2UI catalog accepts: the schemas of its components and functions, and how it
/// is put together from the basic 1.0 catalog. Nothing of the app or of SwiftUI, so
/// `macos/A2UICheck` builds it on its own and checks an Extension's messages against it as
/// dense would, without building dense. `DenseCatalog` draws what this accepts.
enum DenseCatalogSchema {
    static let id = "https://dense.mkm.pub/a2ui/v1/catalog.json"

    /// The basic 1.0 Button; dense's draws it with Return as its key when it is primary.
    /// `BasicCatalogComponents.button`, without the v10, is 0.9's: it binds with "path",
    /// and rejects 1.0's "@path".
    static let button = BasicCatalogComponents.v10Button
    static let surfaceLink = component("SurfaceLink", """
        "surface": {"$ref": "\(common)DynamicString"},
        "label": {"$ref": "\(common)DynamicString"},
        "showState": {"$ref": "\(common)DynamicBoolean"}
        """, required: ["surface"])
    static let statusBadge = component("StatusBadge", """
        "kind": {"$ref": "\(common)DynamicString"},
        "text": {"$ref": "\(common)DynamicString"}
        """, required: ["kind", "text"])
    static let keyValue = component("KeyValue", """
        "rows": {"$ref": "\(common)DynamicValue"}
        """, required: ["rows"])
    static let section = component("Section", """
        "title": {"$ref": "\(common)DynamicString"},
        "collapsed": {"$ref": "\(common)DynamicBoolean"},
        "child": {"$ref": "\(common)Child"}
        """, required: ["title", "child"])
    static let toolbarButton = component("ToolbarButton", """
        "icon": {"$ref": "\(common)DynamicString"},
        "help": {"$ref": "\(common)DynamicString"},
        "kind": {"$ref": "\(common)DynamicString"},
        "action": {"$ref": "\(common)Action"}
        """, required: ["icon"])
    static let components = [button, surfaceLink, statusBadge, keyValue, section, toolbarButton]

    static let focusSurface = function("focusSurface", #"{"ref": {"type": "string"}}"#, required: ["ref"])
    static let invokeCommand = function("invokeCommand", #"{"id": {"type": "string"}, "args": {}}"#, required: ["id"])
    static let copyText = function("copyText", #"{"text": {"type": "string"}}"#, required: ["text"])
    static let functions = [focusSurface, invokeCommand, copyText]

    /// dense's catalog: `basic`'s components and functions, with `components` and `functions`
    /// added, each in place of the basic one of the same name.
    static func catalog<C: ComponentAPI>(basic: Catalog<C>, components: [C], functions: [any FunctionImplementation]) -> Catalog<C> {
        let names = Set(components.map(\.name))
        return Catalog(id: id, protocolVersion: .v10,
                       components: basic.components.values.filter { !names.contains($0.name) } + components,
                       functions: Array(basic.functions.values) + functions)
    }

    private static let common = "https://a2ui.org/specification/v1_0/common_types.json#/$defs/"

    /// A component's API: its own `properties` (JSON, without the braces) and the ones every
    /// v1.0 component has.
    private static func component(_ name: String, _ properties: String, required: [String]) -> AnyComponentAPI {
        let required = (["component"] + required).map { "\"\($0)\"" }.joined(separator: ", ")
        return AnyComponentAPI(name: name, schema: compiled("""
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
            """))
    }

    /// A function's API: renderer only, and only from a click.
    private static func function(_ name: String, _ properties: String, required: [String]) -> FunctionAPI {
        let required = required.map { "\"\($0)\"" }.joined(separator: ", ")
        return FunctionAPI(
            name: name, returnType: .void,
            schema: compiled(#"{"type": "object", "properties": \#(properties), "required": [\#(required)]}"#),
            allowedCallers: .rendererOnly, requiresUserActivation: true)
    }

    /// A schema written here. They are fixed, so a failure is a typo found on the first run.
    private static func compiled(_ json: String) -> Schema {
        do {
            return try Schema(instance: json, remoteSchemas: A2UICommonSchema.allSchemas)
        } catch {
            fatalError("dense's A2UI catalog: \(error)\n\(json)")
        }
    }
}
