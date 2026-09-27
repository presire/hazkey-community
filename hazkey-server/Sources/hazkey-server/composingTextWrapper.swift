import KanaKanjiConverterModule

/// 変換中のテキストを参照型ボックスで保持する
///
/// KanaKanjiConverterModuleのComposingTextは値型のため、接続ごとの入力状態を参照共有できるよう包んで保持する
///
/// 接続ごとに1つ用意しHazkeyServerStateの入力状態として直接差し替える
final class ComposingTextBox {
    /// 保持している変換中のテキスト本体
    ///
    /// 空で初期化され、入力の進行に合わせて差し替えられる
    public var value: ComposingText
    /// 空の変換テキストで箱を初期化する
    init() {
        self.value = ComposingText()
    }
}
