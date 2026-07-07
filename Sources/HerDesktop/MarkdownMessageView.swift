import SwiftUI

enum MarkdownBlock: Equatable, Identifiable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bulletList(items: [String])
    case orderedList(items: [String])
    case codeBlock(text: String)
    case quote(String)
    case rule

    var id: String {
        switch self {
        case .paragraph(let text): return "p:\(text)"
        case .heading(let level, let text): return "h\(level):\(text)"
        case .bulletList(let items): return "ul:\(items.joined(separator: "\u{1}"))"
        case .orderedList(let items): return "ol:\(items.joined(separator: "\u{1}"))"
        case .codeBlock(let text): return "code:\(text)"
        case .quote(let text): return "q:\(text)"
        case .rule: return "rule"
        }
    }
}

enum MarkdownMessageParser {
    private final class BlockBox { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }
    // Parsing is pure and message content is immutable, so cache by content.
    // Without this, every SwiftUI re-render re-parsed every visible message —
    // O(messages × size) work per frame that made the whole UI lag.
    nonisolated(unsafe) private static let cache = NSCache<NSString, BlockBox>()

    static func blocks(from content: String) -> [MarkdownBlock] {
        let key = content as NSString
        if let box = cache.object(forKey: key) { return box.blocks }
        let parsed = parseBlocks(content)
        cache.setObject(BlockBox(parsed), forKey: key)
        return parsed
    }

    private static func parseBlocks(_ content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var codeLines: [String] = []
        var quoteLines: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        func flushLists() {
            if !bullets.isEmpty {
                blocks.append(.bulletList(items: bullets))
                bullets = []
            }
            if !ordered.isEmpty {
                blocks.append(.orderedList(items: ordered))
                ordered = []
            }
        }

        func flushQuote() {
            if !quoteLines.isEmpty {
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                quoteLines = []
            }
        }

        func flushAll() {
            flushParagraph()
            flushLists()
            flushQuote()
        }

        for rawLine in content.components(separatedBy: "\n") {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCodeFence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCodeFence = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushAll()
                inCodeFence = true
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if let heading = headingBlock(from: trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }

            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushLists()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if let item = bulletItem(from: trimmed) {
                flushParagraph()
                flushQuote()
                if !ordered.isEmpty {
                    blocks.append(.orderedList(items: ordered))
                    ordered = []
                }
                bullets.append(item)
                continue
            }

            if let item = orderedItem(from: trimmed) {
                flushParagraph()
                flushQuote()
                if !bullets.isEmpty {
                    blocks.append(.bulletList(items: bullets))
                    bullets = []
                }
                ordered.append(item)
                continue
            }

            flushLists()
            flushQuote()
            paragraph.append(line)
        }

        // A fence left open (e.g. mid-stream) still renders as code.
        if inCodeFence, !codeLines.isEmpty {
            blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private final class AttrBox { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let inlineCache = NSCache<NSString, AttrBox>()

    static func inlineAttributed(_ text: String) -> AttributedString {
        let key = text as NSString
        if let box = inlineCache.object(forKey: key) { return box.value }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let value = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        inlineCache.setObject(AttrBox(value), forKey: key)
        return value
    }

    private static func headingBlock(from line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "-" } || line.allSatisfy { $0 == "*" } || line.allSatisfy { $0 == "_" }
    }

    private static func bulletItem(from line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func orderedItem(from line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
}

struct MarkdownMessageView: View {
    var content: String
    var baseSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(MarkdownMessageParser.blocks(from: content)) { block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownMessageParser.inlineAttributed(text))
                .font(.system(size: baseSize))
                .foregroundStyle(AppTheme.ink)
        case .heading(let level, let text):
            Text(MarkdownMessageParser.inlineAttributed(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(AppTheme.ink)
                .padding(.top, level <= 2 ? 3 : 1)
        case .bulletList(let items):
            listView(items: items) { _ in "•" }
        case .orderedList(let items):
            listView(items: items) { index in "\(index + 1)." }
        case .codeBlock(let text):
            Text(text)
                .font(.system(size: baseSize - 1.5, design: .monospaced))
                .foregroundStyle(AppTheme.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(AppTheme.coral.opacity(0.45))
                    .frame(width: 3)
                Text(MarkdownMessageParser.inlineAttributed(text))
                    .font(.system(size: baseSize))
                    .foregroundStyle(AppTheme.muted)
            }
        case .rule:
            Divider()
        }
    }

    private func listView(items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 7) {
                    Text(marker(index))
                        .font(.system(size: baseSize))
                        .foregroundStyle(AppTheme.muted)
                    Text(MarkdownMessageParser.inlineAttributed(item))
                        .font(.system(size: baseSize))
                        .foregroundStyle(AppTheme.ink)
                }
            }
        }
        .padding(.leading, 2)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 6
        case 2: return baseSize + 4
        case 3: return baseSize + 2
        default: return baseSize + 1
        }
    }
}
