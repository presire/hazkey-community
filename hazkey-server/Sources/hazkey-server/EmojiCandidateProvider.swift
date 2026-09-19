import Foundation
import KanaKanjiConverterModule

/// Emoji 17.0直接変換用の、キャッシュされた不変の絵文字候補ソース
///
/// 注入された辞書URLから一度だけ構築したTextReplacerを1つ保持する
///
/// このプロバイダは再パースを行わない:
/// HazkeyServerStateが状態生成時に構築し、以降のmakeCandidatesResult呼び出しではそれを使い回す
/// (アセットの再読込はサーバ状態そのものが再生成されたときのみ発生する)
///
/// アセットが読み取り不能・不正・空のいずれかの場合は注入を無効化する:
/// 構築時にNSLogで1度だけログを出力してnilを返し、通常の変換は絵文字候補なしで継続する
final class EmojiCandidateProvider {
    /// 共有データディレクトリにインストールされる本番アセット
    /// テストではこのパスを読まず、一時的なフィクスチャURLを注入する
    static var defaultDictionaryURL: URL {
        URL(fileURLWithPath: systemResourcePath)
            .appendingPathComponent("emoji_all_E17.0.txt", isDirectory: false)
    }

    private let replacer: TextReplacer

    /// 失敗可能な初期化: アセットが読み取り不能・不正・空のいずれかの場合は、NSLogを1度出力した後にnilを返す
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

    /// .emojiターゲットに対する直接検索
    /// 元のSearchResultItemをそのまま返す:
    ///
    /// textは、バイト単位で保持され (ZWJ / VS16 / タグ / 肌色の正規化やフィルタリングは行わない)、
    /// queryには、プレフィックス変換で使用される一致した正規化済みひらがな長が入る
    ///
    /// 独自のプレフィックス走査は行わず、マッチングは全てTextReplacerに委譲する
    func emojiCandidates(for reading: String) -> [TextReplacer.SearchResultItem] {
        replacer.getSearchResult(query: reading, target: [.emoji])
    }

    /// TextReplacerのTSV形式 (base TAB queries TAB variations) に対応したアセット検証:
    /// 空でない各行はちょうど3列を持ち、baseとqueryの区画が空でないこと
    /// そうした行が少なくとも1つ存在すること
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
