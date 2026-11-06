import Testing
@testable import Ghostty

struct SpaceTreeTests {
    private func space(_ name: String, parent: String? = nil, order: Int32? = nil, collapsed: Bool? = nil) -> Space {
        Space(metadata: .init(name: name, namespace: "default"),
              spec: .init(parent: parent, order: order, collapsed: collapsed))
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
}
