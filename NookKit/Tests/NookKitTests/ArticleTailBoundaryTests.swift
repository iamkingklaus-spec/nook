import Foundation
import Testing
@testable import NookKit

private let bbcTailFixture = """
<article><div><p>First news paragraph.</p><p>Second news paragraph.</p></div>
<h2>Get in touch</h2><p>Tell us which stories we should cover in Birmingham and the Black Country.</p>
<p><a href="https://www.bbc.co.uk/contact">Contact form</a></p>
<p>Follow BBC Birmingham on <a href="https://www.bbc.co.uk/sounds">BBC Sounds</a>,
<a href="https://www.facebook.com/bbc">Facebook</a>, <a href="https://x.com/bbc">X</a> and <a href="https://instagram.com/bbc">Instagram</a>.</p>
<h2>Related internet links</h2><ul><li><a href="https://example.org/trust">Birmingham and Black Country Wildlife Trust</a></li>
<li><a href="https://example.org/group">West Midlands Fungus Group</a></li></ul></article>
"""

private func tailDocument(_ html: String, host: String = "www.bbc.co.uk") -> BlockReaderDocument {
    BlockReaderDocument(input: .init(articleID: "tail", url: URL(string: "https://\(host)/news/story")!,
        html: html, paragraphs: [], source: .extractedReaderContent))
}
private func contents(_ doc: BlockReaderDocument) -> [String] {
    doc.document.blocks.map { ReaderHTMLSignals.plain($0.sourceContent) }
}

@Suite("Article modules and terminal boundaries")
struct ArticleTailBoundaryTests {
    @Test func bbcContactAndRelatedTailIsRemovedAsOneBoundary() {
        let doc = tailDocument(bbcTailFixture)
        #expect(contents(doc) == ["First news paragraph.", "Second news paragraph."])
        #expect(doc.preparationReasons.contains(.tailBoundary))
    }

    @Test func tailNeverEntersTranslationInput() throws {
        let doc = tailDocument(bbcTailFixture)
        let prompt = try TextOnlyBlockTranslation.prompt(doc.texts)
        for noise in ["Get in touch", "Contact form", "Follow BBC", "Fungus Group", "Wildlife Trust", "stories we should cover"] {
            #expect(!prompt.contains(noise))
        }
        #expect(doc.texts.count == 2)
    }

    @Test func contactOnlyTailDoesNotLeaveAnOrphanHeading() {
        let html = "<p>News.</p><h2>Get in touch</h2><p>Tell us which stories we should cover using our <a href='/contact'>Contact form</a>.</p>"
        #expect(contents(tailDocument(html)) == ["News."])
    }

    @Test func guardianTailWithUpdatedMetadataIsRemoved() {
        let html = """
        <p>Actual news.</p><h2>Explore more on these topics</h2>
        <ul><li><a href='/world'>World</a></li></ul><p>Updated 19 minutes ago</p>
        <p><a href='mailto:?subject=article'>Share</a></p>
        <p><a href='https://www.google.com/preferences/source?q=theguardian.com'>Prefer to read the Guardian on Google</a></p>
        <h2>Related stories</h2><p><a href='/related'>Another story</a></p>
        """
        #expect(contents(tailDocument(html, host: "www.theguardian.com")) == ["Actual news."])
    }

    @Test func ordinaryContactShareFollowAndRelatedProseSurvives() {
        let paragraphs = ["Scientists contact colleagues and share their results.",
            "Readers follow the related evidence.", "They subscribe to a different view."]
        #expect(contents(tailDocument(paragraphs.map { "<p>\($0)</p>" }.joined())) == paragraphs)
    }

    @Test func headingWithRealFollowingProseDoesNotTruncate() {
        let doc = tailDocument("<p>Opening.</p><h2>Get in touch</h2><p>The scientist described how animals communicate.</p><p><a href='/study'>Study</a></p>")
        #expect(contents(doc).contains("The scientist described how animals communicate."))
        #expect(!doc.preparationReasons.contains(.tailBoundary))
    }

    @Test func explicitModulesAreRemovedAtStartAndMiddleToo() {
        let html = """
        <div class='contact-module'><p>Contact form</p></div><p>First.</p>
        <aside><h2>Related stories</h2><p><a href='/related'>Related report</a></p></aside>
        <p>Second.</p><div class='newsletter-signup'><p>Enter email</p></div><p>Third.</p>
        """
        #expect(contents(tailDocument(html)) == ["First.", "Second.", "Third."])
    }

    @Test func semanticNavigationAndFooterNeverBecomeBodyRegardlessOfPosition() {
        let html = "<nav><a href='/'>Home</a></nav><p>First.</p><footer><p>Site footer links</p></footer><p>Second.</p>"
        #expect(contents(tailDocument(html)) == ["First.", "Second."])
    }

    @Test func ordinaryAsideAndQuotedModuleWordsAreRetained() {
        let html = "<p>First.</p><aside><p>Supporting scientific evidence.</p></aside><blockquote><p>Get in touch</p><p><a href='/person'>Contact form</a></p></blockquote>"
        let doc = tailDocument(html)
        #expect(contents(doc).contains("Supporting scientific evidence."))
        #expect(doc.document.blocks.contains { $0.kind == .quote && $0.sourceContent.contains("Get in touch") })
    }

    @Test func publisherFallbackRequiresMatchingHost() {
        let html = "<p>News.</p><p>Follow BBC Birmingham on <a href='/sounds'>BBC Sounds</a>.</p><p>More news.</p>"
        #expect(tailDocument(html).texts.count == 2)
        #expect(tailDocument(html, host: "example.org").texts.count == 3)
    }

    @Test func genericReadMoreBoundaryRequiresLinkEvidence() {
        let doc = tailDocument("<p>News.</p><h2>Read more</h2><ul><li><a href='/one'>One</a></li><li><a href='/two'>Two</a></li></ul>", host: "example.org")
        #expect(contents(doc) == ["News."])
        #expect(contents(tailDocument("<p>News.</p><h2>Read more</h2><p>Genuine final paragraph.</p>")).contains("Genuine final paragraph."))
    }

    @Test func repeatedMetadataRemovedButCreditRemainsNontranslatable() {
        let doc = tailDocument("<p>News.</p><p>Photograph: A Person/AP</p><p>Updated 19 minutes ago</p><p>Updated 19 minutes ago</p>")
        #expect(contents(doc).filter { $0 == "Updated 19 minutes ago" }.count == 1)
        #expect(doc.texts.count == 1)
        #expect(doc.nodes.contains { if case .photoCredit = $0 { return true }; return false })
    }

    @Test func cleanBodyIdentityAndBilingualPairOrderArePreserved() throws {
        let dirty = tailDocument(bbcTailFixture)
        let clean = tailDocument("<p>First news paragraph.</p><p>Second news paragraph.</p>")
        #expect(dirty.document == clean.document)
        let translations = Dictionary(uniqueKeysWithValues: dirty.texts.map { ($0.blockID, "译文 " + $0.template) })
        let html = try Dictionary(uniqueKeysWithValues: dirty.texts.map { ($0.blockID, try $0.restore(translations[$0.blockID]!)) })
        let nodes = BlockReaderPresentation.nodes(dirty.nodes, translations: html.merging(["old-noise": "垃圾译文"]) { a, _ in a }, templates: translations)
        let lines = nodes.flatMap { node -> [String] in
            guard case .group(let group) = node else { return [] }
            return group.texts(in: .bilingual).map { ReaderHTMLSignals.plain($0.html) }
        }
        #expect(lines == ["First news paragraph.", "译文 First news paragraph.", "Second news paragraph.", "译文 Second news paragraph."])
    }
}
