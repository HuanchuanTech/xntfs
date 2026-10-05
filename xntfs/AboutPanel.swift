import AppKit

@MainActor
enum AboutPanel {
    static func show() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
        let credits = NSMutableAttributedString(
            string: String(localized: "Read and write NTFS drives on your Mac with Apple FSKit and ntfs-3g. No macFUSE or kernel extension required."),
            attributes: attributes
        )
        credits.append(NSAttributedString(string: "\n\n", attributes: attributes))

        var linkAttributes = attributes
        linkAttributes[.link] = "https://github.com/HuanchuanTech/xntfs"
        credits.append(NSAttributedString(
            string: "GitHub: HuanchuanTech/xntfs",
            attributes: linkAttributes
        ))

        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
