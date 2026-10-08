import Foundation
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
/// アセットが読み取り不能・不正・空のいずれかの場合は注入を無効化する
///
/// 構築時にNSLogで1度だけログを出力してnilを返し通常の変換は絵文字候補なしで継続する
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
    /// アセットが読み取り不能・不正・空のいずれかの場合はNSLogを1度出力した後に、nilを返す
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
        guard let contents = try? String(contentsOf: dictionaryURL, encoding: .utf8),
            Self.hasValidEntry(contents)
        else {
            hazkeyLog(
                "[hazkey] Emoji dictionary malformed or empty: \(dictionaryURL.path); emoji injection disabled"
            )
            return nil
        }
        let url = dictionaryURL
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

    /// 辞書内容に有効な行が少なくとも1つあるかを検証する
    ///
    /// TextReplacerのTSV形式 (base TAB queries TAB variations) に対応する
    ///
    /// 空でない各行はちょうど3列を持ちbaseとqueryの区画が空でないこと
    ///
    /// そうした行が少なくとも1つ存在すること
    ///
    /// - Parameter contents: 辞書ファイルの全文
    /// - Returns: 有効な行が1つ以上あれば真を返す
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
