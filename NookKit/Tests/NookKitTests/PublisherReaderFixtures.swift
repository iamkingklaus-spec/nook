/// Structural excerpts captured with bundled Legibility 5f4a783 / 6ca2806d,
/// 2026-09-27. Article prose and media URLs replaced with test text; publisher
/// nesting, missing class/id, metadata and inline layout intentionally retained.
enum PublisherReaderFixtures {
    // https://www.bbc.co.uk/news/articles/cw62jje658dlo (live article has since been updated)
    static let bbc = """
    <article><div><div><h1><span>A news headline</span></h1></div></div>
    <div><figure><div><span><img src="https://example.org/photo.jpg"></span><span>Reuters</span></div><figcaption><div><p>A scene at a meeting.</p></div></figcaption></figure></div>
    <div><div><div><span><span>Kali Hays</span><span>Technology reporter</span></span><span><span> and </span><span>Lily Jamali</span><span>North America Technology correspondent</span></span></div></div></div>
    <div><div><ul><div><li><div><span><time datetime="2026-09-26T01:25:00Z">26 September 2026</time></span></div></li></div></ul><div><span><time datetime="2026-09-26T02:00:00Z">Updated 19 minutes ago</time></span></div></div></div>
    <div><div><div><p><b>The first body paragraph.</b></p><p>Read <a href="https://example.org/report?a=1&amp;b=2">the report</a>, then <em>consider</em> it.</p></div></div></div>
    </article>
    """

    // https://www.npr.org/2026/09/26/g-s1-144667/hiv-crystal-meth-epidemic-fiji
    static let npr = """
    <article><div><div><time datetime="2026-09-26T07:31:18-04:00"><span>September 26, 2026</span><span>7:31 AM ET</span></time></div></div>
    <div><div><p>By </p><div><p><a href="https://example.org/author" rel="author">David Cox</a></p></div></div></div>
    <div><div><img src="https://example.org/picture.jpg"></div><div><div><p>A person at a conference.<b>Ian Cheibub for NPR</b><b><b>hide caption</b></b></p></div><b><b>toggle caption</b></b><span>Ian Cheibub for NPR</span></div></div>
    <p>A short opening paragraph.</p><p>Cases rose by <a href="https://example.org/study">12-fold</a> in the study.</p>
    <aside><div><span>Sponsor Message</span></div></aside>
    <h3><strong>A section heading</strong></h3><p>The next paragraph contains <em>emphasis</em>.</p></article>
    """

    // https://www.theguardian.com/world/2026/sep/26/british-climber-28-dies-fall-spain-torrecerredo-mountain
    static let guardian = """
    <article><div><div><figure><div><img src="https://example.org/mountain.jpg"><span><div><figcaption><span>A mountain scene.</span> Photograph: A Photographer/AP</figcaption></div></span></div><span><figcaption><span>A mountain scene.</span> Photograph: A Photographer/AP</figcaption></span></figure></div></div>
    <aside><div><div><span>Press Association</span></div><div>Sat 26 Sep 2026 03.02 BST</div><a href="mailto:?subject=Story">Share</a><a href="https://www.google.com/preferences/source?q=theguardian.com">Prefer the Guardian on Google</a></div></aside>
    <div><div><div><div><p>Paragraph A with <a href="https://example.org/place">a place</a>.</p><p>Paragraph B.</p><p>Paragraph C.</p></div></div>
    <div><span>Explore more on these topics</span><div><ul><li><a href="/world/spain">Spain</a></li><li><a href="/tone/news">news</a></li></ul></div><div><a href="mailto:?subject=Story">Share</a><a href="https://syndication.theguardian.com/?url=story">Reuse this content</a></div></div></div></div></article>
    """
}
