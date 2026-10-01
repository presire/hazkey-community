import Foundation

/// モデルファイル名からZenzaiの機能対応を判定する純関数群
///
/// 呼び出し側は、resolvingSymlinksInPath()済みのURLを渡すこと
/// シンボリックリンク越しの実体ファイル名で判定する必要があるため
enum ZenzaiModelCapabilities {
    /// 右側文脈 (カーソルの右側にある文章) を変換器へ渡せるモデルかを判定する
    ///
    /// 判定は、lastPathComponentを小文字化して、".gguf"を除いた語に対して行う
    /// - nilは、false
    /// - jinenを含むモデルは、false
    /// - "zenz-v<major>.<minor>"に一致して "(major, minor) >= (3, 2)"の場合はtrue、未満はfalse
    ///   (zenz-v3のようにminorが無い場合は、0とみなす)
    /// - いずれの名前規則にも当てはまらない場合は、true
    ///   (名前から判別できないモデルは設定に従う)
    /// - Note: 判別不能なモデルを許容するのは、右文脈がプロンプトの補助情報であり、候補との対応を変えない
    ///   アラインメント区切り (U+EE08) は全文プロンプトとカーソルまでの候補の対応を壊し得るため、別の厳格判定を使用する
    static func supportsRightContext(modelURL: URL?) -> Bool {
        guard let modelURL else {
            return false
        }
        if modelURL.lastPathComponent.lowercased().contains("jinen") {
            return false
        }
        guard let version = Self.zenzVersion(from: modelURL) else {
            return true
        }
        return version >= (3, 2)
    }

    /// U+EE08アラインメント区切りを理解するモデルかを厳格に判定する
    ///
    /// 名前で判別できないモデルは非対応とする
    /// (対応しないモデルへ全文を渡すと、プロンプトとカーソルまでの候補の対応が壊れるため)
    static func supportsAlignmentSeparator(modelURL: URL?) -> Bool {
        guard let modelURL,
            !modelURL.lastPathComponent.lowercased().contains("jinen"),
            let version = Self.zenzVersion(from: modelURL)
        else {
            return false
        }
        return version >= (3, 2)
    }

    private static func zenzVersion(from modelURL: URL?) -> (major: Int, minor: Int)? {
        guard let modelURL else {
            return nil
        }
        var name = modelURL.lastPathComponent.lowercased()
        if name.hasSuffix(".gguf") {
            name.removeLast(".gguf".count)
        }
        guard let match = name.firstMatch(of: /zenz-v(\d+)(?:\.(\d+))?/) else {
            return nil
        }
        let major = Int(match.1) ?? 0
        let minor = match.2.flatMap { Int($0) } ?? 0
        return (major, minor)
    }
}
