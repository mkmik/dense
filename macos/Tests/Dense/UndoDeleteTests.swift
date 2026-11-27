import Foundation
import Testing
@testable import Ghostty

struct UndoDeleteTests {
    private func object(_ name: String, deleted: Bool = true, _ spec: [String: Any] = [:]) -> [String: Any] {
        var meta: [String: Any] = ["name": name]
        if deleted {
            meta["deletionTimestamp"] = "2026-11-27T00:00:00Z"
            meta["finalizers"] = ["den.mkm.pub/undo"]
        }
        return ["metadata": meta, "spec": spec]
    }

    private func tab(_ name: String, in space: String, den: String, deleted: Bool = true) -> [String: Any] {
        object(name, deleted: deleted, ["space": space, "kind": "terminal", "terminal": ["den": den]])
    }

    private func names(_ objects: [SpaceTabs.Revivable]) -> [String] {
        objects.map { "\($0.resource)/\(($0.object["metadata"] as? [String: Any])?["name"] ?? "")" }
    }

    @Test func bringsBackWhatOneDeleteTookDensFirstThenParentsFirstThenTabs() {
        // A Den restarted: being deleted, but no longer kept for Undo.
        var restarted = object("d5")
        restarted["metadata"] = ["name": "d5", "deletionTimestamp": "2026-11-27T00:00:00Z", "finalizers": ["den.mkm.pub/den"]]
        let objects = SpaceTabs.revivable(
            ["grandchild", "top", "child", "live"],
            tabs: ["t1", "t2", "t4", "t5"],
            spaceList: [
                object("child", ["parent": "top"]),
                object("top"),
                object("grandchild", ["parent": "child"]),
                object("other"), // deleted, but by another delete
                object("live", deleted: false, ["parent": "top"]),
            ],
            surfaceList: [
                tab("t1", in: "top", den: "d1"),
                tab("t2", in: "grandchild", den: "d2"),
                tab("t3", in: "other", den: "d3"),
                tab("t4", in: "top", den: "d4", deleted: false),
                tab("t5", in: "live", den: "d5"),
            ],
            denList: [object("d1"), object("d2"), object("d3"), object("d4"), restarted])
        #expect(names(objects) == [
            "dens/d1", "dens/d2",
            "spaces/top", "spaces/child", "spaces/grandchild",
            "surfaces/t1", "surfaces/t2", "surfaces/t5",
        ])
    }

    @Test func aDetachedTabComesBackWithoutItsDen() {
        let objects = SpaceTabs.revivable([], tabs: ["t1"], spaceList: [object("s", deleted: false)],
                                          surfaceList: [tab("t1", in: "s", den: "d1")],
                                          denList: [object("d1", deleted: false)])
        #expect(names(objects) == ["surfaces/t1"])
    }

    @Test func nothingWhenDennetHasLetItGo() {
        #expect(SpaceTabs.revivable(["top"], tabs: [], spaceList: [object("top", deleted: false)],
                                    surfaceList: [], denList: []).isEmpty)
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func surface(_ name: String, in space: String, _ spec: String = #""kind": "terminal", "terminal": {"den": "d"}"#) throws -> Surface {
        try decode(#"{"metadata": {"name": "\#(name)", "namespace": "default"}, "spec": {"space": "\#(space)", \#(spec)}}"#)
    }

    private func space(_ name: String, archived: Bool = false) throws -> Space {
        try decode(#"{"metadata": {"name": "\#(name)", "namespace": "default"}, "spec": {"archived": \#(archived)}}"#)
    }

    @Test func undoesSpacesWithAllTheirSurfacesAndOnlyTabsOfOthers() throws {
        let live = [try space("s"), try space("archived", archived: true)]
        let (spaces, tabs) = SpaceTabs.undoable(try [
            surface("gone-tab", in: "gone"),
            surface("gone-box", in: "gone", #""placement": "review", "kind": "ui", "ui": {"extension": "dowt"}"#),
            space("gone"),
            surface("tab", in: "s"),
            surface("web", in: "s", #""kind": "web", "web": {"url": "https://example.com"}"#),
            surface("box", in: "s", #""placement": "review", "kind": "ui", "ui": {"extension": "dowt"}"#),
            surface("ui", in: "s", #""kind": "ui", "ui": {"extension": "dowt"}"#),
            surface("archived-tab", in: "archived"),
            surface("orphan", in: "missing"),
        ], spaces: Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) }))
        #expect(spaces.map(\.metadata.name) == ["gone"])
        #expect(tabs.map(\.metadata.name) == ["gone-tab", "gone-box", "tab", "web"])
    }
}
