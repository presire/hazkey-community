import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// User-defined word entry (reading -> word).
struct UserDictionaryEntry {
    let reading: String
    let word: String
    let comment: String
    let pos: String

    init(reading: String, word: String, comment: String, pos: String = "noun") {
        self.reading = reading
        self.word = word
        self.comment = comment
        self.pos = pos
    }

    /// Returns a `DicdataElement` usable by the kana-kanji converter.
    func toDicdataElement() -> DicdataElement {
        let cid: Int
        if pos == "verb" {
            cid = VerbConjugator.detectBaseCid(hiraganaReading: reading) ?? 772
        } else {
            cid = Self.cid(for: pos)
        }
        return DicdataElement(
            word: word,
            ruby: reading.toKatakana(),
            cid: cid,
            mid: MIDData.一般.mid,
            value: -5
        )
    }

    /// Expands this entry into one or more `DicdataElement` values.
    /// Verb entries produce all conjugated forms; other POS produce a single element.
    func expandedDicdataElements() -> [DicdataElement] {
        if pos == "verb" {
            return VerbConjugator.dicdataElements(word: word, hiraganaReading: reading)
        }
        return [toDicdataElement()]
    }

    // Verb POS is handled separately via VerbConjugator (tail-detection + conjugation).
    private static func cid(for pos: String) -> Int {
        switch pos {
        case "noun":
            return CIDData.固有名詞.cid
        case "person":
            return CIDData.人名一般.cid
        case "place":
            return CIDData.地名一般.cid
        default:
            NSLog("[hazkey] Unknown user dictionary POS token '\(pos)', defaulting to noun")
            return CIDData.固有名詞.cid
        }
    }
}

/// Loads and caches the user dictionary file.
///
/// File format (TSV, UTF-8):
///   reading<TAB>word[<TAB>comment][<TAB>pos]
/// Lines starting with '#' and empty lines are ignored.
/// Reading is normalized to hiragana for matching.
class UserDictionary {
    private var entries: [UserDictionaryEntry] = []
    private var lastModified: Date? = nil
    private var lastLoadedPath: String = ""

    /// Default path: $XDG_CONFIG_HOME/hazkey/user_dictionary.tsv
    static func defaultPath() -> URL {
        return HazkeyServerConfig.getConfigDirectory()
            .appendingPathComponent("user_dictionary.tsv", isDirectory: false)
    }

    /// Parse a single TSV line into an entry, or nil for comments/empty/invalid lines.
    static func parseLine(_ line: String) -> UserDictionaryEntry? {
        if line.isEmpty || line.hasPrefix("#") { return nil }
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 2 else { return nil }
        let reading = cols[0].trimmingCharacters(in: .whitespaces)
            .precomposedStringWithCanonicalMapping
        let word = cols[1]
        let comment = cols.count >= 3 ? cols[2] : ""
        let rawPos = cols.count >= 4 ? cols[3].trimmingCharacters(in: .whitespaces).lowercased() : "noun"
        let knownPosTokens: Set<String> = ["noun", "person", "place", "verb"]
        let pos: String
        if knownPosTokens.contains(rawPos) {
            pos = rawPos
        } else {
            NSLog("[hazkey] Unknown user dictionary POS token '\(rawPos)', defaulting to noun")
            pos = "noun"
        }
        if reading.isEmpty || word.isEmpty { return nil }
        return UserDictionaryEntry(reading: reading, word: word, comment: comment, pos: pos)
    }

    /// Reload from disk if the file's mtime changed (or never loaded).
    /// Safe to call frequently.
    /// Returns `true` when entries were (re)loaded or the file became empty/absent.
    @discardableResult
    func reloadIfNeeded() -> Bool {
        let url = Self.defaultPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            let stateChanged = !entries.isEmpty || lastModified != nil || lastLoadedPath != url.path
            if !entries.isEmpty || lastModified != nil {
                entries = []
                lastModified = nil
            }
            lastLoadedPath = url.path
            return stateChanged
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let mtime = attrs[.modificationDate] as? Date
            if lastLoadedPath == url.path, let last = lastModified, let cur = mtime, last == cur {
                return false
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            var newEntries: [UserDictionaryEntry] = []
            for rawLine in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                if let entry = Self.parseLine(String(rawLine)) {
                    newEntries.append(entry)
                }
            }
            entries = newEntries
            lastModified = mtime
            lastLoadedPath = url.path
            NSLog("[hazkey] Loaded \(entries.count) user dictionary entries from \(url.path)")
            return true
        } catch {
            NSLog("[hazkey] Failed to load user dictionary: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns entries whose reading exactly equals `hiragana`.
    func exactMatches(hiragana: String) -> [UserDictionaryEntry] {
        if hiragana.isEmpty { return [] }
        return entries.filter { $0.reading == hiragana }
    }

    /// Returns all entries as `DicdataElement` values for converter integration.
    func toDicdataElements() -> [DicdataElement] {
        return entries.flatMap { $0.expandedDicdataElements() }
    }

    /// Total entry count (for diagnostics).
    var count: Int { entries.count }
}
