import Foundation
import Testing
@testable import SpotliteCore

@Suite("Links")
struct LinkTests {
    private func resolve(_ target: String) -> String? {
        Link.resolve(target, home: "/Users/ann").map { $0.isFileURL ? $0.path : $0.absoluteString }
    }

    @Test func pathsBecomeFileURLs() {
        #expect(resolve("~/Downloads") == "/Users/ann/Downloads")
        #expect(resolve("~") == "/Users/ann")
        #expect(resolve(" /Volumes/Work ") == "/Volumes/Work")
        #expect(Link.resolve("/tmp")?.isFileURL == true)
    }

    @Test func addressesKeepTheirSchemeOrGainHTTPS() {
        #expect(resolve("https://example.com/a?b=c") == "https://example.com/a?b=c")
        #expect(resolve("github.com/ivalkenburg") == "https://github.com/ivalkenburg")
        #expect(resolve("mailto:ann@example.com") == "mailto:ann@example.com")
        #expect(resolve("tel:0612345678") == "tel:0612345678")
        #expect(resolve("sms:12345") == "sms:12345")
        #expect(resolve("x-apple.systempreferences:com.apple.Bluetooth")
                == "x-apple.systempreferences:com.apple.Bluetooth")
    }

    /// The colon of a port is not a scheme, and local servers get plain http.
    @Test func localServersAreHTTP() {
        #expect(resolve("localhost:3000") == "http://localhost:3000")
        #expect(resolve("192.168.1.1:8080/admin") == "http://192.168.1.1:8080/admin")
        #expect(resolve("127.0.0.1") == "http://127.0.0.1")
        #expect(resolve("localhostish.com") == "https://localhostish.com")
        #expect(resolve("localhost.example.com") == "https://localhost.example.com")
        #expect(resolve("github.com:443") == "https://github.com:443")
    }

    @Test func rejectsWhatIsNeitherPathNorAddress() {
        #expect(resolve("") == nil)
        #expect(resolve("downloads") == nil)
        #expect(resolve("two words.com") == nil)
        #expect(resolve("~ann/Downloads") == nil)
        #expect(resolve("./Downloads") == nil)
        #expect(resolve("../x.txt") == nil)
    }

    @Test func entryKeepsItsIdentityThroughEdits() throws {
        var link = Link(name: "Downloads", target: "~/Downloads")
        let before = try #require(link.entry)
        link.name = "DL"
        link.target = "/tmp"
        let after = try #require(link.entry)
        #expect(before.id == after.id)
        #expect(after.kind == .link)
        #expect(after.name == "DL")
    }

    @Test func blankNameOrBadTargetHasNoEntry() {
        #expect(Link(name: "  ", target: "/tmp").entry == nil)
        #expect(Link(name: "X", target: "nope").entry == nil)
    }

    /// Identity is the link's own, not its target's: a link to Safari.app is not the
    /// app, and two links to one folder stay two rows.
    @Test func linksNeverShareIdentityWithTheirTarget() throws {
        let app = AppEntry(url: URL(fileURLWithPath: "/Applications/Safari.app"), name: "Safari",
                           bundleID: "com.apple.Safari")
        let toApp = try #require(Link(name: "Safari", target: "/Applications/Safari.app").entry)
        let a = try #require(Link(name: "A", target: "~/Downloads").entry)
        let b = try #require(Link(name: "B", target: "~/Downloads").entry)
        #expect(toApp != app)
        #expect(a != b)
        #expect(a.instanceID == a.id)
    }

    private func fill(_ target: String, _ argument: String) -> String? {
        Link.resolve(target, argument: argument, home: "/Users/ann")
            .map { $0.isFileURL ? $0.path : $0.absoluteString }
    }

    /// An address takes the argument as one query value; a path takes it as typed.
    @Test func templatesEncodeForAddressesOnly() {
        #expect(fill("github.com/search?q={query}", " a&b #1 ") == "https://github.com/search?q=a%26b%20%231")
        #expect(fill("shortcuts://run-shortcut?name=Note&input=text&text={query}", "buy milk")
                == "shortcuts://run-shortcut?name=Note&input=text&text=buy%20milk")
        #expect(fill("~/Projects/{query}", "my app") == "/Users/ann/Projects/my app")
        #expect(fill("example.com/{query}/{query}", "x") == "https://example.com/x/x")
    }

    /// The target's shape is judged before filling: digits after `tel:` are no port.
    @Test func templateShapeIgnoresTheArgument() {
        #expect(fill("tel:{query}", "0612345678") == "tel:0612345678")
        #expect(fill("localhost:{query}", "3000") == "http://localhost:3000")
        #expect(fill("github.com/search?q={query}", "") == "https://github.com/search?q=")
        #expect(fill("{query}", "github.com") == nil)
    }

    @Test func templateEntryCarriesItsTarget() throws {
        let template = try #require(Link(name: "GitHub", target: "github.com/search?q={query}").entry)
        #expect(template.template == "github.com/search?q={query}")
        #expect(template.url.absoluteString == "https://github.com/search?q=")
        #expect(try #require(Link(name: "DL", target: "~/Downloads").entry).template == nil)
    }
}

@Suite("System commands")
struct SystemCommandTests {
    @Test func idsRoundTripAndDoNotCollide() {
        for command in SystemCommand.allCases {
            #expect(SystemCommand(id: command.id) == command)
            #expect(command.entry.kind == .command)
        }
        #expect(Set(SystemCommand.entries.map(\.instanceID)).count == SystemCommand.allCases.count)
        #expect(SystemCommand(id: "com.apple.Safari") == nil)
    }

    @Test func areMatchedByName() {
        let hits = Matcher().search("lock", in: SystemCommand.entries)
        #expect(hits.first?.entry.name == "Lock Screen")
    }
}

@Suite("Web search")
struct WebSearchEngineTests {
    @Test func encodesTheQueryAsOneValue() {
        #expect(WebSearchEngine.google.url(for: " a&b=c #1 ")?.absoluteString
                == "https://www.google.com/search?q=a%26b%3Dc%20%231")
        #expect(WebSearchEngine.duckDuckGo.url(for: "c++")?.absoluteString == "https://duckduckgo.com/?q=c%2B%2B")
        #expect(WebSearchEngine.kagi.url(for: "   ") == nil)
    }
}
