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

    @Test func linksToThisMacPointAtTheHost() {
        func onHost(_ url: String) -> String? { HostProxies.onHost(URL(string: url)!, host: "gpu1")?.absoluteString }
        #expect(onHost("http://localhost:8080/a?b#c") == "http://gpu1.localhost:8080/a?b#c")
        #expect(onHost("http://127.0.0.1:3000") == "http://gpu1.localhost:3000")
        #expect(onHost("http://[::1]:5173/") == "http://gpu1.localhost:5173/")
        #expect(onHost("https://LOCALHOST/") == "https://gpu1.localhost/")
        #expect(onHost("http://example.com:8080") == nil)
        #expect(onHost("http://gpu1.localhost:8080") == nil)
        #expect(onHost("file:///tmp/a.html") == nil)
    }
}
