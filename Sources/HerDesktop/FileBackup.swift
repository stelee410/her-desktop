import Foundation

extension FileManager {
    /// Copy `url` to a suffixed sibling (`name.<suffix>.<ext>`) before
    /// anything can overwrite it — the shared defensive move for corrupt or
    /// future-versioned files. Returns the backup URL, or nil when the copy
    /// failed; an existing backup with the same name is kept as-is.
    @discardableResult
    func backUpSiblingFile(at url: URL, suffix: String) -> URL? {
        let backup = url.deletingPathExtension()
            .appendingPathExtension(suffix)
            .appendingPathExtension(url.pathExtension.isEmpty ? "bak" : url.pathExtension)
        if fileExists(atPath: backup.path) {
            return backup
        }
        do {
            try copyItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }
}
