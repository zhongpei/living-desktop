import AppKit

/// Last-resort artwork for a prop with no installed sprite frames.
public enum PropEmojiImage {
    public static func make(_ emoji: String, size: CGFloat) -> CGImage? {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let font = NSFont.systemFont(ofSize: size * 0.72)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let str = NSAttributedString(string: emoji, attributes: attrs)
        let bounds = str.size()
        str.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
