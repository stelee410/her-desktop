import Foundation

/// One append-only JSONL log file: encoder/decoder configuration, append
/// (atomic first write, seek-to-end after), whole-file load with corrupt
/// lines skipped, and a bounded tail read for unbounded logs.
///
/// AuditEventStore / InboxEventStore / PluginEventStore each had a
/// byte-identical copy of this logic; they now compose one of these.
final class JSONLStore<Event: Codable>: @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func append(_ event: Event) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = try Self.encoder.encode(event)
        data.append(0x0A)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    /// Whole-file load. Malformed lines are skipped, not fatal: append is
    /// not atomic, so one truncated line (crash mid-write) must not make
    /// the entire history unreadable.
    func loadAll() throws -> [Event] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return Self.decode(text)
    }

    /// Reads only the tail of the (unbounded, append-only) log — enough for
    /// a recent-events feed without decoding years of history at startup.
    func loadRecent(maxBytes: Int = 131_072) throws -> [Event] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(data: data, encoding: .utf8) ?? ""
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            // Drop the first (probably partial) line of a mid-file read.
            text = String(text[text.index(after: firstNewline)...])
        }
        return Self.decode(text)
    }

    private static func decode(_ text: String) -> [Event] {
        text.split(separator: "\n")
            .compactMap { try? decoder.decode(Event.self, from: Data(String($0).utf8)) }
    }

    // Configuration is immutable after init; sharing across threads is safe.
    nonisolated(unsafe) private static var encoder: JSONEncoder {
        sharedEncoder
    }

    nonisolated(unsafe) private static var decoder: JSONDecoder {
        sharedDecoder
    }
}

// Non-generic shared codecs (a generic type would mint one static pair per
// specialization; these are identical for every Event type).
nonisolated(unsafe) private let sharedEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

nonisolated(unsafe) private let sharedDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()
