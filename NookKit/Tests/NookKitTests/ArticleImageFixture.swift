import Foundation
import CoreGraphics
import ImageIO

/// Offline metadata/DOM and real raster fixtures; no publisher/API traffic.
enum ArticleImageFixture {
    static let page = """
    <html><head>
      <meta property="og:image" content="/og.jpg">
      <meta property="og:image:secure_url" content="https://cdn.example.com/og.jpg">
      <meta property="og:image:width" content="1600">
      <meta property="og:image:height" content="900">
      <meta name="twitter:image" content="/twitter.jpg">
    </head><body>
      <header><img src="/logo.png" width="180" height="180"></header>
      <article>
        <div class="author-avatar"><img src="/portrait.jpg" width="800" height="800"></div>
        <figure><img src="/lead.jpg" width="600" height="400"
          srcset="/lead.jpg 600w, /lead-1200.jpg 1200w, /lead-1800.jpg 1800w" sizes="100vw"></figure>
        <p>Actual reporting.</p><img src="/second.jpg" width="1000" height="750">
        <aside><img src="/promo.jpg" width="2000" height="1200"></aside>
      </article>
    </body></html>
    """
    static let rss = """
    <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><title>News</title><item>
      <title>News story</title><link>https://example.com/story</link>
      <media:thumbnail url="https://example.com/thumb.jpg" width="240" height="135"/>
      <media:content url="https://example.com/large.jpg" type="image/jpeg" width="1600" height="900"/>
    </item></channel></rss>
    """
    static func raster(_ width: Int = 1600, _ height: Int = 900) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
