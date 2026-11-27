import Foundation
import Testing
@testable import Ghostty

struct UndoDeleteTests {
    private func object(_ name: String, deleted: Bool = true, _ spec: [String: Any] = [:]) -> [String: Any] {
        var meta: [String: Any] = ["name": name]
        if deleted { meta["deletionTimestamp"] = "2026-11-27T00:00:00Z" }
        return ["metadata": meta, "spec": spec]
    }

    private func tab(_ name: String, in space: String, den: String, deleted: Bool = true) -> [String: Any] {
        object(name, deleted: deleted, ["space": space, "kind": "terminal", "terminal": ["den": den]])
    }

    @Test func bringsBackTheDeletedTreeDensFirstThenParentsFirstThenTabs() {
        let objects = SpaceTabs.revivable(
            ["top"],
            spaceList: [
                object("child", ["parent": "top"]),
                object("top"),
                object("grandchild", ["parent": "child"]),
                object("other"), // deleted, but not under top
                object("live", deleted: false, ["parent": "top"]),
            ],
            surfaceList: [
                tab("t1", in: "top", den: "d1"),
                tab("t2", in: "grandchild", den: "d2"),
                tab("t3", in: "other", den: "d3"),
                tab("t4", in: "top", den: "d4", deleted: false),
            ],
            denList: [object("d1"), object("d2"), object("d3"), object("d4")])
        #expect(objects.map { "\($0.resource)/\(($0.object["metadata"] as? [String: Any])?["name"] ?? "")" } == [
            "dens/d1", "dens/d2",
            "spaces/top", "spaces/child", "spaces/grandchild",
            "surfaces/t1", "surfaces/t2",
        ])
    }

    @Test func nothingWhenDennetHasLetItGo() {
        #expect(SpaceTabs.revivable(["top"], spaceList: [object("top", deleted: false)],
                                    surfaceList: [], denList: []).isEmpty)
    }
}
