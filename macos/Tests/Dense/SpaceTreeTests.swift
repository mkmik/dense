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

    @Test func filterByAPastedLinkKeepsTheSpacesWithThatLink() {
        func linked(_ name: String, _ links: [String: String]) -> Space {
            var s = space(name, parent: "top")
            s.metadata.annotations = links.reduce(into: ["other/key": "https://x/pull/9"]) { $0[Space.linkPrefix + $1.key] = $1.value }
            return s
        }
        let rows = Space.rows([
            space("top"),
            linked("a", ["review": "https://x/pull/12"]),
            linked("b", ["review": "https://x/pull/123", "issue": " https://j/browse/T-1\n"]),
        ])
        func names(_ query: String) -> [String] { Space.filter(rows, query).map(\.space.metadata.name) }
        #expect(names("https://x/pull/12") == ["top", "a"])
        #expect(names("https://x/pull/12/files") == ["top", "a"])
        #expect(names("https://x/pull/12#discussion") == ["top", "a"])
        #expect(names("https://x/pull/123") == ["top", "b"])
        #expect(names("https://j/browse/T-1") == ["top", "b"])
        #expect(names("https://x/pull/9") == [])
        #expect(names("https://x/pull/1") == [])
        #expect(names("https://x/pull/12 b") == [])
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

    @Test func aSpaceShowsTheSpacesItGathersAfterItsChildrenOneLevelDeep() {
        var work = space("work", order: 2)
        work.spec.gather = ["b", "gone", "work2"]
        var work2 = space("work2", order: 3)
        work2.spec.gather = ["work"]
        let rows = Space.rows([
            space("a", order: 1),
            space("b", parent: "a"),
            space("b1", parent: "b"),
            work,
            space("w1", parent: "work"),
            work2,
        ])
        #expect(rows.map(\.space.metadata.name) == ["a", "b", "b1", "work", "w1", "b", "work2", "work2", "work"])
        #expect(rows.map(\.depth) == [0, 1, 2, 0, 1, 1, 1, 0, 1])
        #expect(rows.map(\.gathered) == [false, false, false, false, false, true, true, false, true])
        #expect(Set(rows.map(\.id)).count == rows.count)
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

    private func surface(_ name: String, space: String, order: Int32 = 0, placement: String? = nil, den: String? = "d",
                         web: Surface.Web? = nil, ui: Surface.UI? = nil) -> Surface {
        Surface(metadata: .init(name: name, namespace: "default"),
                spec: .init(space: space, order: order, placement: placement, terminal: den.map { .init(den: $0) },
                            web: web, ui: ui))
    }

    @Test func tabsAndBoxesAreTheSpacesSurfacesInOrder() {
        let surfaces = [
            surface("second", space: "a", order: 2),
            surface("first", space: "a", order: 1),
            surface("other", space: "b", order: 0),
            surface("page", space: "a", order: 3, den: nil, web: .init(html: "<p>")),
            surface("notes", space: "a", order: 0, den: nil),
            surface("status", space: "a", order: 5, placement: "details", den: nil, ui: .init(extension: "dowt")),
            surface("log", space: "a", order: 1, placement: "details"),
            surface("scratch", space: "a", order: 2, placement: "notes"),
            surface("empty", space: "a", order: 6, placement: ""),
            surface("panel", space: "a", order: 4, den: nil, ui: .init(extension: "dowt")),
        ]
        #expect(space("a").tabs(surfaces).map(\.metadata.name) == ["first", "second", "page", "panel", "empty"])
        #expect(space("a").surfaces(surfaces, in: "details").map(\.metadata.name) == ["log", "status"])
        #expect(space("b").surfaces(surfaces, in: "details").isEmpty)
        #expect(surfaces.last?.uiExtension == "default/dowt")
    }

    @Test func boxesAreEveryNameInUseListedOnesFirst() {
        // The same boxes whichever Space is selected: "notes" is only b's, "details" only a's.
        let surfaces = [
            surface("panel", space: "a", placement: "details", den: nil, ui: .init(extension: "dowt")),
            surface("scratch", space: "b", placement: "notes"),
            surface("log", space: "b", placement: "logs"),
            surface("tab", space: "a"),
            // Of no kind dense shows: no box for it.
            surface("odd", space: "a", placement: "odd", den: nil),
        ]
        let listed = [SidebarBox(name: "notes", lines: 4), SidebarBox(name: "unused", lines: 3),
                      SidebarBox(name: "details", lines: 12)]
        let boxes = SidebarBox.shown(surfaces, listed: listed)
        #expect(boxes == [SidebarBox(name: "notes", lines: 4), SidebarBox(name: "details", lines: 12),
                          SidebarBox(name: "logs", lines: SidebarBox.defaultLines)])
        #expect(SidebarBox.shown([surface("tab", space: "a")], listed: listed).isEmpty)
        #expect(SidebarBox.choices(shown: boxes, listed: listed) == ["notes", "details", "logs", "unused"])
    }

    @Test func aBoxNameMeansTheSameBoxOnEveryMachine() {
        // A Host's Spaces are in the Host's namespace; its "details" is this machine's.
        var remote = surface("panel", space: "a", placement: "details", den: nil, ui: .init(extension: "dowt"))
        remote.metadata.namespace = "devbox"
        let boxes = SidebarBox.shown([surface("log", space: "a", placement: "details"), remote], listed: [])
        #expect(boxes == [SidebarBox(name: "details", lines: SidebarBox.defaultLines)])
    }

    @Test func aTypedBoxNameIsLowercasedWithDashesForSpaces() {
        #expect(SidebarBox.name(typed: "Details") == "details")
        #expect(SidebarBox.name(typed: "  Review  Status ") == "review-status")
        #expect(SidebarBox.name(typed: "   ").isEmpty)
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
