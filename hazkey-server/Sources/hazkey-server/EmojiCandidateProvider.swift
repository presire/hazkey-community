import CHazkeyLinux
import Foundation
import Glibc
import KanaKanjiConverterModule

/// Emoji 17.0直接変換用のキャッシュされた不変の絵文字候補ソース
///
/// 注入された辞書URLから一度だけ構築したTextReplacerを1つ保持する
///
/// このプロバイダは再パースを行わない
///
/// HazkeyServerStateが状態生成時に構築し以降のmakeCandidatesResult呼び出しでは、それを使い回す
///
/// アセットの再読込はサーバ状態そのものが再生成されたときのみ発生する
///
/// アセットが読み取り不能・UTF-8として不正・有効な行なしのいずれかの場合は注入を無効化する
///
/// 構築時にNSLogで1度だけログを出力してnilを返し通常の変換は絵文字候補なしで継続する
///
/// 一部の行だけが不正な場合は、その行を読み飛ばして残りの行で注入を続け、読み飛ばした行数をログに1度出力する
final class EmojiCandidateProvider {
    /// 共有データディレクトリにインストールされる本番アセット
    ///
    /// テストではこのパスを読まず一時的なフィクスチャURLを注入する
    static var defaultDictionaryURL: URL {
        URL(fileURLWithPath: systemResourcePath)
            .appendingPathComponent("emoji_all_E17.0.txt", isDirectory: false)
    }

    /// 辞書URLから一度だけ構築した検索器
    ///
    /// 初期化後は再構築せず全ての検索で使い回す
    private let replacer: TextReplacer

    /// 辞書URLからプロバイダを構築する
    ///
    /// アセットが読み取り不能・UTF-8として不正・有効な行なしのいずれかの場合はNSLogを1度出力した後に、nilを返す
    ///
    /// 不正な行は読み飛ばし、有効な行だけで検索器を構築する
    ///
    /// - Parameter dictionaryURL: 絵文字辞書TSVのファイルURL
    /// - Note: 失敗しても通常の変換は絵文字候補なしで継続する
    init?(dictionaryURL: URL) {
        guard FileManager.default.isReadableFile(atPath: dictionaryURL.path) else {
            hazkeyLog(
                "[hazkey] Emoji dictionary not readable: \(dictionaryURL.path); emoji injection disabled"
            )
            return nil
        }
        guard let contents = try? String(contentsOf: dictionaryURL, encoding: .utf8) else {
            hazkeyLog(
                "[hazkey] Emoji dictionary malformed or empty: \(dictionaryURL.path); emoji injection disabled"
            )
            return nil
        }
        let entries = Self.validEntries(contents)
        guard !entries.validLines.isEmpty else {
            hazkeyLog(
                "[hazkey] Emoji dictionary malformed or empty: \(dictionaryURL.path); emoji injection disabled"
            )
            return nil
        }
        guard let firstInvalidLineNumber = entries.firstInvalidLineNumber else {
            let url = dictionaryURL
            self.replacer = TextReplacer(emojiDataProvider: { url })
            return
        }
        hazkeyLog(
            "[hazkey] Emoji dictionary has \(entries.invalidLineCount) malformed line(s) "
                + "(first at line \(firstInvalidLineNumber)): \(dictionaryURL.path); skipped them"
        )
        // TextReplacerは不正な行に達すると以降の行を読まずに打ち切るため、有効な行だけを封印したmemfdへ書き出して読ませる
        // TextReplacerは初期化中に内容を読み終えるので、初期化の直後にfdを閉じてよい
        let sanitized = entries.validLines.joined(separator: "\n")
        let fd = Array(sanitized.utf8).withUnsafeBytes {
            hazkey_sealed_memfd("hazkey-emoji-dictionary", $0.baseAddress, $0.count)
        }
        guard fd >= 0 else {
            hazkeyLog(
                "[hazkey] Emoji dictionary could not be staged: \(dictionaryURL.path); emoji injection disabled"
            )
            return nil
        }
        defer { close(fd) }
        let url = URL(fileURLWithPath: "/proc/self/fd/\(fd)")
        self.replacer = TextReplacer(emojiDataProvider: { url })
    }

    /// [emoji]ターゲットに対する直接検索
    ///
    /// 元のSearchResultItemをそのまま返す
    ///
    /// textはバイト単位で保持する (ZWJ/VS16/タグ/肌色の正規化やフィルタリングは行わない)
    ///
    /// queryにはプレフィックス変換で使用する一致した正規化済みひらがな長が入る
    ///
    /// 独自のプレフィックス走査は行わずマッチングは全てTextReplacerに委譲する
    ///
    /// - Parameter reading: 検索するひらがな読み
    /// - Returns: 一致した検索結果の列を返す
    func emojiCandidates(for reading: String) -> [TextReplacer.SearchResultItem] {
        replacer.getSearchResult(query: reading, target: [.emoji])
    }

    /// 辞書内容を有効な行と不正な行に分ける
    ///
    /// TextReplacerのTSV形式 (base TAB queries TAB variations) に対応する
    ///
    /// 空でない各行は、ちょうど3列を持ちbaseとqueryの区画が空でないときに有効とする
    ///
    /// 空行は数えない
    ///
    /// - Parameter contents: 辞書ファイルの全文
    /// - Returns: 有効な行 (元の順序)、不正な行の数、最初の不正な行の行番号 (1始まり、不正な行が無ければnil)
    static func validEntries(
        _ contents: String
    ) -> (validLines: [String], invalidLineCount: Int, firstInvalidLineNumber: Int?) {
        var validLines: [String] = []
        var invalidLineCount = 0
        var firstInvalidLineNumber: Int?
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            if line.isEmpty { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, !columns[0].isEmpty, !columns[1].isEmpty else {
                invalidLineCount += 1
                if firstInvalidLineNumber == nil {
                    firstInvalidLineNumber = index + 1
                }
                continue
            }
            validLines.append(line)
        }
        return (validLines, invalidLineCount, firstInvalidLineNumber)
    }
}
