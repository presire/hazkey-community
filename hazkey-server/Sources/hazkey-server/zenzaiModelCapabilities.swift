import Foundation

/// モデルファイル名からZenzaiの機能対応を判定する純関数群。
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
    static func supportsRightContext(modelURL: URL?) -> Bool {
        guard let modelURL else {
            return false
        }
        var name = modelURL.lastPathComponent.lowercased()
        if name.hasSuffix(".gguf") {
            name.removeLast(".gguf".count)
        }
        if name.contains("jinen") {
            return false
        }
        guard let match = name.firstMatch(of: /zenz-v(\d+)(?:\.(\d+))?/) else {
            return true
        }
        let major = Int(match.1) ?? 0
        let minor = match.2.flatMap { Int($0) } ?? 0
        return (major, minor) >= (3, 2)
    }
}
