import Foundation
import Testing
import UniformTypeIdentifiers
@testable import NookKit

private let importOPMLFixture = """
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0"><head><title>Subscriptions</title></head><body>
<outline text="00 · Daily Core"><outline text="World">
<outline text="BBC" type="rss" xmlUrl="https://example.org/bbc/rss" htmlUrl="https://example.org/bbc"/>
<outline text="Guardian" xmlUrl="https://example.org/guardian/rss" htmlUrl="https://example.org/guardian"/>
<outline text="BBC duplicate" xmlUrl="https://example.org/bbc/rss"/>
</outline><outline text="NPR" xmlUrl="https://example.org/npr/rss" htmlUrl="https://example.org/npr"/></outline>
</body></opml>
"""

@Suite("OPML selected URL to import preview")
struct OPMLImportInteractionTests {
    @Test func validNestedFixturePreservesFeedsURLsAndNearestFolders() throws {
        let feeds = try OPMLService().importFeeds(data: Data(importOPMLFixture.utf8))
        #expect(feeds.count == 3)
        #expect(feeds.map(\.category) == ["World", "World", "00 · Daily Core"])
        #expect(feeds[0].title == "BBC")
        #expect(feeds[0].siteURL?.absoluteString == "https://example.org/bbc")
    }

    @Test func selectedFileLoadsIntoPreviewSelection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(importOPMLFixture.utf8).write(to: url)
        let feeds = try OPMLService().importFeeds(from: url)
        let existing = Set([feeds[0].feedURL.feedIdentityKey, feeds[1].siteURL!.feedIdentityKey])
        #expect(OPMLService.selectableIDs(feeds, existingKeys: existing) == [feeds[2].id])
    }

    @Test func malformedXMLIsRejected() {
        #expect(throws: (any Error).self) { try OPMLService().importFeeds(data: Data("<opml><body><outline></opml>".utf8)) }
    }

    @Test func validEmptyOPMLHasNoCandidates() throws {
        #expect(try OPMLService().importFeeds(data: Data("<opml version='2.0'><body/></opml>".utf8)).isEmpty)
    }

    @Test func nonOPMLXMLAndMissingBodyAreRejected() {
        for xml in ["<rss><outline xmlUrl='https://example.org/rss'/></rss>", "<opml><head/></opml>", ""] {
            #expect(throws: (any Error).self) { try OPMLService().importFeeds(data: Data(xml.utf8)) }
        }
    }

    @Test func duplicatesDoNotFailOrDuplicatePreviewRows() throws {
        let feeds = try OPMLService().importFeeds(data: Data(importOPMLFixture.utf8))
        #expect(Set(feeds.map(\.id)).count == feeds.count)
        #expect(OPMLService.selectableIDs(feeds, existingKeys: []).count == 3)
    }

    @Test func xmlFallbackStillRequiresOPMLContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(importOPMLFixture.utf8).write(to: url)
        #expect(try OPMLService().importFeeds(from: url).count == 3)
        try Data("<rss/>".utf8).write(to: url)
        #expect(throws: (any Error).self) { try OPMLService().importFeeds(from: url) }
    }

    @Test func arbitraryFileExtensionIsRejectedEvenWithOPMLBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(importOPMLFixture.utf8).write(to: url)
        #expect(throws: (any Error).self) { try OPMLService().importFeeds(from: url) }
    }

    @Test func pickerTypesAreOPMLAndXMLWithoutAllFilesFallback() {
        let types = OPMLImportTypes.allowed
        #expect(types.contains(OPMLImportTypes.declared))
        #expect(types.contains(.xml))
        #expect(!types.contains(.data) && !types.contains(.item) && !types.contains(.content))
        if let resolved = UTType(filenameExtension: "opml") { #expect(types.contains(resolved)) }
    }
}
