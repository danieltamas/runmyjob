import AppKit
import RMJCore
import SwiftUI

/// The log as one text view: SwiftUI rows of wrapped text re-measure on every scroll, a text view lays the whole log
/// out once and scrolls it on the GPU. Selection, find highlights and copy come with it.
struct ReportLogView: NSViewRepresentable {
    let lines: [LogLine]
    let query: String
    /// Changes when the filter or the search does: the view goes back to the top (or the end while following).
    let structure: String
    /// Changes when the log grew.
    let revision: Int64
    let follow: Bool
    let truncated: Bool
    /// Where a finished log opens: the first error, or nil for the top. A live log follows its end instead.
    let landOn: Int?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let text = BandedTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 14, height: 10)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.selectedTextAttributes = [.backgroundColor: NSColor(Theme.running).withAlphaComponent(0.28)]
        scroll.documentView = text
        context.coordinator.text = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let text = coordinator.text else { return }
        let key = "\(structure)|\(revision)|\(lines.count)"
        guard key != coordinator.key else { return }
        let restructured = structure != coordinator.structure
        let offset = scroll.contentView.bounds.origin
        coordinator.key = key
        coordinator.structure = structure
        let built = Self.build(lines, query: query, truncated: truncated)
        text.textStorage?.setAttributedString(built.text)
        text.bands = built.bands
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.needsDisplay = true
        if follow {
            text.scrollToEndOfDocument(nil)
        } else if restructured || !coordinator.placed {
            // Laid out above, so the offset is real: a scroll before layout lands wherever the text view ends up.
            var top: CGFloat = 0
            if !restructured, let landOn, let start = built.starts[landOn], let layout = text.layoutManager, let container = text.textContainer {
                let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: start, length: 0), actualCharacterRange: nil)
                top = max(0, layout.boundingRect(forGlyphRange: glyphs, in: container).minY - 60)
            }
            text.scroll(NSPoint(x: 0, y: top))
            if !coordinator.placed { scroll.flashScrollers() }
        } else {
            scroll.contentView.scroll(to: offset)
        }
        coordinator.placed = true
    }

    final class Coordinator {
        var text: BandedTextView?
        var key = ""
        var structure = ""
        var placed = false
    }

    // MARK: building

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    /// GitHub's `job<TAB>step<TAB>2026-10-29T08:32:43.0537729Z text` keeps only its time: the job and step repeat on every line.
    private static let stamp = try! NSRegularExpression(pattern: "^[^\\t]*\\t[^\\t]*\\t\\d{4}-\\d\\d-\\d\\dT(\\d\\d:\\d\\d:\\d\\d)\\.\\d+Z ?")

    private static func display(_ text: String) -> String {
        guard let match = stamp.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let time = Range(match.range(at: 1), in: text),
              let whole = Range(match.range, in: text) else { return text }
        return text[time] + "  " + text[whole.upperBound...]
    }

    @MainActor
    private static func build(_ lines: [LogLine], query: String, truncated: Bool) -> (text: NSAttributedString, bands: [(NSRange, NSColor)], starts: [Int: Int]) {
        let digits = max(3, String(lines.last?.number ?? 0).count)
        let gutter = NSString(string: String(repeating: "0", count: digits + 2)).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = gutter
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 1
        let numberColor = NSColor(Theme.textTertiary).withAlphaComponent(0.75)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let output = NSMutableAttributedString()
        var bands: [(NSRange, NSColor)] = []
        var starts: [Int: Int] = [:]
        if truncated {
            output.append(NSAttributedString(string: "Earlier output is not shown.\n", attributes: [.font: font, .foregroundColor: numberColor, .paragraphStyle: paragraph]))
        }
        for line in lines {
            let start = output.length
            starts[line.number] = start
            let number = String(line.number)
            output.append(NSAttributedString(string: String(repeating: " ", count: digits - number.count) + number + "  ",
                                             attributes: [.font: font, .foregroundColor: numberColor, .paragraphStyle: paragraph, .logNumber: true]))
            let shown = display(line.text)
            let body = NSMutableAttributedString(string: shown + "\n", attributes: [
                .font: line.kind == .command ? bold : font, .foregroundColor: color(line.kind), .paragraphStyle: paragraph,
            ])
            if !needle.isEmpty {
                let lower = shown.lowercased() as NSString
                var from = 0
                while from < lower.length {
                    let found = lower.range(of: needle, range: NSRange(location: from, length: lower.length - from))
                    if found.location == NSNotFound { break }
                    body.addAttribute(.backgroundColor, value: NSColor(Theme.warn).withAlphaComponent(0.4), range: found)
                    from = found.location + max(1, found.length)
                }
            }
            output.append(body)
            if let band = band(line.kind) { bands.append((NSRange(location: start, length: output.length - start), band)) }
        }
        return (output, bands, starts)
    }

    @MainActor
    private static func color(_ kind: LogLine.Kind) -> NSColor {
        switch kind {
        case .command: NSColor(Theme.running)
        case .error: NSColor(Theme.crit)
        case .warning: NSColor(Theme.warn)
        case .success: NSColor(Theme.ok)
        case .plain: NSColor(Theme.textPrimary).withAlphaComponent(0.88)
        }
    }

    @MainActor
    private static func band(_ kind: LogLine.Kind) -> NSColor? {
        switch kind {
        case .error: NSColor(Theme.crit).withAlphaComponent(0.10)
        case .warning: NSColor(Theme.warn).withAlphaComponent(0.07)
        default: nil
        }
    }
}

extension NSAttributedString.Key {
    /// Marks the line-number prefix, which a copy leaves out.
    static let logNumber = NSAttributedString.Key("rmj.logNumber")
}

/// A text view that tints whole lines (errors, warnings) edge to edge and copies without the line numbers.
final class BandedTextView: NSTextView {
    var bands: [(NSRange, NSColor)] = []

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer, !bands.isEmpty else { return }
        let origin = textContainerOrigin
        let shown = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = layout.characterRange(forGlyphRange: shown, actualGlyphRange: nil)
        for (range, color) in bands where NSIntersectionRange(range, visible).length > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            color.setFill()
            NSRect(x: 0, y: box.minY + origin.y, width: bounds.width, height: box.height).fill()
        }
    }

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0, let storage = textStorage else { return super.copy(sender) }
        var kept = ""
        storage.enumerateAttributes(in: selectedRange) { attributes, range, _ in
            if attributes[.logNumber] == nil { kept += (storage.string as NSString).substring(with: range) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(kept, forType: .string)
    }
}
