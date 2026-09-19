import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// ユーザ定義の単語エントリ (読み -> 単語)
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

    /// かな漢字変換エンジンで使用できるDicdataElementを返す
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

    /// このエントリを1つ以上のDicdataElementへ展開する
    /// 動詞エントリは全活用形を生成し、それ以外の品詞は単一の要素を生成する
    func expandedDicdataElements() -> [DicdataElement] {
        if pos == "verb" {
            return VerbConjugator.dicdataElements(word: word, hiraganaReading: reading)
        }
        return [toDicdataElement()]
    }

    // 動詞の品詞は、VerbConjugator (末尾検出 + 活用展開) で別途処理する
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

/// ユーザ辞書ファイルを読み込み、キャッシュする
///
/// ファイル形式 (TSV, UTF-8):
///   reading<TAB>word[<TAB>comment][<TAB>pos]
/// '#' で始まる行と空行は無視される
/// 読みは照合のためにひらがなへ正規化される
class UserDictionary {
    private var entries: [UserDictionaryEntry] = []
    private var lastModified: Date? = nil
    private var lastLoadedPath: String = ""

    /// 既定パス: $XDG_CONFIG_HOME/hazkey/user_dictionary.tsv
    static func defaultPath() -> URL {
        return HazkeyServerConfig.getConfigDirectory()
            .appendingPathComponent("user_dictionary.tsv", isDirectory: false)
    }

    /// TSVの1行をエントリへパースする
    /// コメント行・空行・不正な行は、nilを返す
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

    /// ファイルのmtimeが変化していれば (または未ロードなら) ディスクから再読込する (頻繁に呼び出しても安全)
    /// エントリが (再) 読み込まれた場合、またはファイルが空 / 存在しなくなった場合にTrueを返す
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

    /// 読みがhiraganaと完全一致するエントリを返す
    func exactMatches(hiragana: String) -> [UserDictionaryEntry] {
        if hiragana.isEmpty { return [] }
        return entries.filter { $0.reading == hiragana }
    }

    /// 変換エンジンとの統合のため、全エントリをDicdataElementとして返す
    func toDicdataElements() -> [DicdataElement] {
        return entries.flatMap { $0.expandedDicdataElements() }
    }

    /// エントリの総数 (診断用)
    var count: Int { entries.count }
}
