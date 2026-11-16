import Foundation
import Testing
@testable import Ghostty

struct WebPageTests {
    @Test func typedAddressesAreWebPagesOrFiles() {
        #expect(WebPage.url("example.com/a")?.absoluteString == "https://example.com/a")
        #expect(WebPage.url(" http://x.test ")?.absoluteString == "http://x.test")
        #expect(WebPage.url("/tmp/a b.html")?.absoluteString == "file:///tmp/a%20b.html")
        #expect(WebPage.url("~/a.html")?.path == NSHomeDirectory() + "/a.html")
        #expect(WebPage.url("  ") == nil)
    }

    @Test func aLinkToAnotherSectionIsTheSamePage() {
        let page = URL(string: "https://x.test/a#top")
        #expect(WebPage.samePage(URL(string: "https://x.test/a#end")!, page))
        #expect(!WebPage.samePage(URL(string: "https://x.test/b")!, page))
        #expect(!WebPage.samePage(URL(string: "https://x.test/a")!, nil))
    }
}
