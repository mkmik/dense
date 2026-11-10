import Foundation
import Testing
@testable import Ghostty

struct ShowRequestTests {
    private func asking(_ annotation: String?) -> Surface {
        Surface(metadata: .init(name: "ccwt", namespace: "far",
                                annotations: annotation.map { [ShowRequest.annotation: $0] }),
                spec: .init(space: "repo"))
    }

    @Test func readsTheNamesInTheAskingSurfacesNamespace() {
        let tab = ShowRequest(asking(#"{"surface":"wt-2","at":"2026-11-10T12:00:00Z"}"#))
        #expect(tab?.from == "far/ccwt")
        #expect(tab?.surface == "far/wt-2")
        #expect(tab?.space == nil)
        #expect(ShowRequest(asking(#"{"space":"wt","at":"x"}"#))?.space == "far/wt")
        #expect(ShowRequest(asking(#"{"at":"x"}"#)) == nil)
        #expect(ShowRequest(asking("not json")) == nil)
        #expect(ShowRequest(asking(nil)) == nil)
    }

    @Test func onlyTheWindowJustTypedIntoTheAskingTabObeys() throws {
        let request = try #require(ShowRequest(asking(#"{"space":"wt","at":"x"}"#)))
        let now = Date()
        #expect(SpaceTabs.obeys(request, active: "far/ccwt", lastKey: now - 1, now: now))
        // Another tab in front, or nothing typed here lately: the user asked elsewhere.
        #expect(!SpaceTabs.obeys(request, active: "far/other", lastKey: now - 1, now: now))
        #expect(!SpaceTabs.obeys(request, active: "far/ccwt", lastKey: now - 30, now: now))
        #expect(!SpaceTabs.obeys(request, active: nil, lastKey: now, now: now))
    }
}
