import Foundation
import KanaKanjiConverterModule

/// [community] Cached immutable emoji candidate source for Emoji 17.0 direct
/// conversion.
///
/// Owns one `TextReplacer` built once from an injected dictionary URL. The
/// provider never reparses: `HazkeyServerState` constructs it at state
/// creation and reuses it for every `makeCandidatesResult` call (asset
/// refresh happens only when the server state itself is recreated).
///
/// Unreadable, malformed, or empty assets disable injection: construction
/// logs once via `NSLog` and returns `nil`, leaving normal conversion to
/// continue without emoji candidates.
final class EmojiCandidateProvider {
    /// Production asset installed at the shared data directory.
    /// Tests never read this path; they inject temporary fixture URLs.
    static var defaultDictionaryURL: URL {
        URL(fileURLWithPath: systemResourcePath)
            .appendingPathComponent("emoji_all_E17.0.txt", isDirectory: false)
    }

    private let replacer: TextReplacer

    /// Failable construction: returns `nil` (after one `NSLog`) when the
    /// asset is unreadable, malformed, or empty.
    init?(dictionaryURL: URL) {
        guard FileManager.default.isReadableFile(atPath: dictionaryURL.path) else {
            NSLog(
                "[hazkey] Emoji dictionary not readable: \(dictionaryURL.path); emoji injection disabled"
            )
            return nil
        }
        guard let contents = try? String(contentsOf: dictionaryURL, encoding: .utf8),
            Self.hasValidEntry(contents)
        else {
            NSLog(
                "[hazkey] Emoji dictionary malformed or empty: \(dictionaryURL.path); emoji injection disabled"
            )
            return nil
        }
        let url = dictionaryURL
        self.replacer = TextReplacer(emojiDataProvider: { url })
    }

    /// Direct search for `.emoji` targets. Returns the original
    /// `SearchResultItem`s unchanged: `text` is preserved byte-for-byte (no
    /// ZWJ/VS16/tag/skin-tone normalization or filtering) and `query` carries
    /// the matched normalized hiragana length used for prefix completion.
    /// No custom prefix scanning is performed; matching is entirely delegated
    /// to `TextReplacer`.
    func emojiCandidates(for reading: String) -> [TextReplacer.SearchResultItem] {
        replacer.getSearchResult(query: reading, target: [.emoji])
    }

    /// Asset validation mirroring `TextReplacer`'s TSV shape
    /// (`base TAB queries TAB variations`): every non-empty line must have
    /// exactly three columns with a non-empty base and query section, and at
    /// least one such line must exist.
    private static func hasValidEntry(_ contents: String) -> Bool {
        var found = false
        for line in contents.components(separatedBy: .newlines) {
            if line.isEmpty { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, !columns[0].isEmpty, !columns[1].isEmpty else {
                return false
            }
            found = true
        }
        return found
    }
}
