import Testing
@testable import Ghostty

struct SpaceTreeTests {
    private func space(
        _ name: String, parent: String? = nil, order: Int32? = nil, collapsed: Bool? = nil, tags: [String]? = nil
    ) -> Space {
        Space(metadata: .init(name: name, namespace: "default"),
              spec: .init(parent: parent, order: order, title: name, collapsed: collapsed, tags: tags))
    }

    @Test func filterByTagKeepsTaggedSpacesTheirSubspacesAndTheSpacesAbove() {
        let rows = Space.rows([
            space("top", order: 1),
            space("work", parent: "top", order: 1, tags: ["job", "x"]),
            space("w1", parent: "work", order: 1),
            space("w11", parent: "w1"),
            space("play", parent: "top", order: 2, tags: ["jobs"]),
            space("other", order: 2, tags: ["fun"]),
        ])
        func names(_ query: String) -> [String] { Space.filter(rows, query).map(\.space.metadata.name) }
        #expect(names("#job") == ["top", "work", "w1", "w11"])
        #expect(names("#job #fun") == ["top", "work", "w1", "w11", "other"])
        #expect(names("#job w11") == ["top", "work", "w1", "w11"])
        #expect(names("#job other") == [])
        #expect(names("PLAY") == ["top", "play"])
        #expect(names("  ") == rows.map(\.space.metadata.name))
    }

    @Test func childrenFollowTheirParentInOrder() {
        let rows = Space.rows([
            space("b", order: 2),
            space("a", order: 1),
            space("a2", parent: "a", order: 2),
            space("a1", parent: "a", order: 1),
            space("orphan", parent: "gone"),
        ])
        #expect(rows.map(\.space.metadata.name) == ["orphan", "a", "a1", "a2", "b"])
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 0])
    }

    @Test func aDenRunsAnAgentWhenAWordOfItsCommandIsOne() {
        func den(_ command: [String]?) -> Den {
            Den(metadata: .init(name: "d", namespace: "default"), spec: .init(command: command))
        }
        #expect(den(["/bin/zsh", "-lic", "claude --resume 4fe3; exec /bin/zsh -l"]).agent)
        #expect(den(["/opt/homebrew/bin/codex"]).agent)
        #expect(den(["sh", "-c", "cd x;claude"]).agent)
        #expect(!den(nil).agent)
        #expect(!den(["/bin/zsh", "-l"]).agent)
        #expect(!den(["vim", "claude.md"]).agent)
    }

    @Test func aDenRunsAnAgentWhenItsTitleIsOneClaudeCodeSets() {
        func den(_ title: String) -> Den {
            Den(metadata: .init(name: "d", namespace: "default"), status: .init(phase: "Running", title: title))
        }
        #expect(den("✳ logo").agent)
        #expect(den("◐ more").agent)
        #expect(den("⠐ fix tests").agent)
        #expect(!den("main").agent)
        #expect(!den("worktree-piped-honking-backus").agent)
        #expect(!den("✳").agent)
        #expect(!den("").agent)
    }

    @Test func guidesRunDownWhileAnAncestorHasSiblingsToCome() {
        let rows = Space.rows([
            space("a", order: 1),
            space("a1", parent: "a", order: 1),
            space("a11", parent: "a1"),
            space("a2", parent: "a", order: 2),
            space("a21", parent: "a2"),
            space("b", order: 2),
        ])
        let guides = Space.guides(rows)
        func guide(_ name: String) -> Space.Guide? { guides["default/\(name)"] }
        #expect(guide("a") == .init(through: [], last: false))
        #expect(guide("a1") == .init(through: [false], last: false))
        #expect(guide("a11") == .init(through: [false, true], last: true))
        #expect(guide("a2") == .init(through: [false], last: true))
        #expect(guide("a21") == .init(through: [false, false], last: true))
        #expect(guide("b") == .init(through: [], last: true))
    }

    @Test func aSpaceWithoutAWorkingDirUsesTheNearestOneAbove() {
        var top = space("top")
        top.spec.workingDir = "/top"
        var mid = space("mid", parent: "top")
        mid.spec.workingDir = ""
        let leaf = space("leaf", parent: "mid")
        var loop = space("loop", parent: "loop")
        loop.spec.workingDir = nil
        let spaces = Dictionary(uniqueKeysWithValues: [top, mid, leaf, loop].map { ($0.id, $0) })
        #expect(Space.workingDir(of: leaf, in: spaces) == "/top")
        #expect(Space.workingDir(of: top, in: spaces) == "/top")
        #expect(Space.workingDir(of: loop, in: spaces) == nil)
    }

    @Test func collapsedSpaceHidesItsChildren() {
        let rows = Space.rows([
            space("a", collapsed: true),
            space("a1", parent: "a"),
        ])
        #expect(rows.map(\.space.metadata.name) == ["a"])
    }

    @Test func terminalsAreTheSpacesTerminalSurfacesInOrder() {
        func surface(_ name: String, space: String, order: Int32, den: String? = "d") -> Surface {
            Surface(metadata: .init(name: name, namespace: "default"),
                    spec: .init(space: space, order: order, terminal: den.map { .init(den: $0) }))
        }
        let surfaces = [
            surface("second", space: "a", order: 2),
            surface("first", space: "a", order: 1),
            surface("other", space: "b", order: 0),
            surface("browser", space: "a", order: 0, den: nil),
        ]
        #expect(space("a").terminals(surfaces).map(\.metadata.name) == ["first", "second"])
    }

    @Test func combosGlueATabBesideAnotherThatIsNotGlued() {
        func tab(_ name: String, beside: String? = nil) -> Surface {
            Surface(metadata: .init(name: name, namespace: "default"), spec: .init(space: "a", beside: beside))
        }
        func names(_ tabs: [Surface]) -> [[String]] { Space.combos(tabs).map { $0.map(\.metadata.name) } }
        // A glued tab shows right of its main tab, wherever it is in the order.
        #expect(names([tab("a"), tab("b"), tab("c", beside: "a")]) == [["a", "c"], ["b"]])
        // Gone, itself, or a tab glued itself: no glue.
        #expect(names([tab("a", beside: "gone"), tab("b", beside: "b")]) == [["a"], ["b"]])
        #expect(names([tab("a"), tab("b", beside: "a"), tab("c", beside: "b")]) == [["a", "b"], ["c"]])
        // Two tabs per combo: the first glued wins.
        #expect(names([tab("a"), tab("b", beside: "a"), tab("c", beside: "a")]) == [["a", "b"], ["c"]])
    }
}
