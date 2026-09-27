import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// ユーザ定義の単語エントリ ([reading]から[word]への対応)
///
/// [reading]と[word]とコメントと[pos]を持つ
struct UserDictionaryEntry {
    /// 照合に使うひらがな読み
    let reading: String
    /// 表記
    let word: String
    /// 備考
    let comment: String
    /// 品詞トークン
    let pos: String

    /// エントリを生成する
    ///
    /// - Parameters:
    ///   - reading: 照合に使うひらがな読み
    ///   - word: 表記
    ///   - comment: 備考
    ///   - pos: 品詞トークンであり既定値は[noun]
    init(reading: String, word: String, comment: String, pos: String = "noun") {
        self.reading = reading
        self.word = word
        self.comment = comment
        self.pos = pos
    }

    /// 変換エンジン用のDicdataElementを1件組み立てる
    ///
    /// [pos]が[verb]の場合はVerbConjugator.detectBaseCidでCIDを決める
    ///
    /// 検出できない場合は、772へフォールバックする
    ///
    /// [verb]以外はcid(for:)でCIDを決める
    ///
    /// MIDはMIDData一般とし値は-5とする
    ///
    /// - Returns: 組み立てた単一要素
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

    /// エントリを1件以上のDicdataElementへ展開する
    ///
    /// [verb]エントリはVerbConjugator.dicdataElementsで全活用形を生成する
    ///
    /// それ以外の品詞は単一要素を生成する
    ///
    /// - Returns: 展開した要素列
    func expandedDicdataElements() -> [DicdataElement] {
        if pos == "verb" {
            return VerbConjugator.dicdataElements(word: word, hiraganaReading: reading)
        }
        return [toDicdataElement()]
    }

    // 動詞の品詞はVerbConjugator (末尾検出と活用展開) で別途処理する
    /// [pos]トークンをCIDへ変換する
    ///
    /// [noun]は固有名詞へ変換する
    ///
    /// [person]は人名一般へ変換する
    ///
    /// [place]は地名一般へ変換する
    ///
    /// 未知のトークンは警告を出して[noun]として扱う
    ///
    /// - Parameter pos: 品詞トークン
    /// - Returns: 対応するCID
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

/// ユーザ辞書TSVファイルを読み込み保持する
///
/// ファイル形式はTSV(UTF-8)とする
///
/// 形式は、[reading]TAB[word][TAB comment][TAB pos]とする
///
/// [#]で始まる行と空行は無視する
///
/// [reading]は照合のためひらがなへ正規化する
class UserDictionary {
    /// 保持中のエントリ一覧
    private var entries: [UserDictionaryEntry] = []
    /// 前回読込時の更新時刻
    private var lastModified: Date? = nil
    /// 前回読込時のファイルパス
    private var lastLoadedPath: String = ""
    /// 直近にファイルを確認した単調時刻 (ナノ秒)
    ///
    /// 未確認の場合はnilとする
    ///
    /// 実時刻(Date)は時計変更の影響を受けるため使わない
    private var lastCheckUptime: UInt64? = nil

    /// ファイル再確認の最短間隔 (秒)
    ///
    /// 打鍵ごとにstatしないための間引きとする
    static let reloadThrottleInterval: TimeInterval = 1.0

    /// 最短間隔のナノ秒換算値
    ///
    /// 比較のたびに変換しないため保持する
    private static let reloadThrottleIntervalNanoseconds: UInt64 =
        UInt64(reloadThrottleInterval * 1_000_000_000)

    /// 既定パスを返す
    ///
    /// [$XDG_CONFIG_HOME]/hazkey-community/[user_dictionary.tsv]を指す
    ///
    /// - Returns: 既定パスのURL
    static func defaultPath() -> URL {
        return HazkeyServerConfig.getConfigDirectory()
            .appendingPathComponent("user_dictionary.tsv", isDirectory: false)
    }

    /// TSVの1行をエントリへ変換する
    ///
    /// 形式は、[reading]TAB[word][TAB comment][TAB pos]とする
    ///
    /// コメント行と空行と不正な行はnilを返す
    ///
    /// [reading]は照合のためひらがなへ正規化する
    ///
    /// 未知の[pos]トークンは警告を出して[noun]として扱う
    ///
    /// - Parameter line: 変換対象の1行
    /// - Returns: 変換したエントリ、対象外の行ではnil
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

    /// 更新時刻変化や未読込時にファイルを読み込み直す
    ///
    /// forceがfalseの場合は前回確認から最短間隔未満ならstatも再読込も行わずfalseを返す
    ///
    /// 初回は未確認のため必ず確認する
    ///
    /// forceがtrueの場合は間引きせず必ず確認する
    ///
    /// - Parameter force: 間引きを迂回して必ず確認する場合はtrue
    /// - Returns: 読み込み直した場合やファイルが空や不在になった場合はtrue
    /// - Note: 設定適用時の強制再読込で使う
    @discardableResult
    func reloadIfNeeded(force: Bool = false) -> Bool {
        if !force, let lastCheck = lastCheckUptime {
            let elapsed = DispatchTime.now().uptimeNanoseconds - lastCheck
            if elapsed < Self.reloadThrottleIntervalNanoseconds {
                return false
            }
        }
        lastCheckUptime = DispatchTime.now().uptimeNanoseconds
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

    /// [reading]が[hiragana]と完全一致するエントリを返す
    ///
    /// - Parameter hiragana: 照合するひらがな読み
    /// - Returns: 完全一致したエントリ列
    func exactMatches(hiragana: String) -> [UserDictionaryEntry] {
        if hiragana.isEmpty { return [] }
        return entries.filter { $0.reading == hiragana }
    }

    /// 全エントリを展開して変換エンジン用の要素列を作る
    ///
    /// - Returns: 変換器へ注入する要素列
    func toDicdataElements() -> [DicdataElement] {
        return entries.flatMap { $0.expandedDicdataElements() }
    }

    /// エントリ件数(診断用)
    var count: Int { entries.count }
}
