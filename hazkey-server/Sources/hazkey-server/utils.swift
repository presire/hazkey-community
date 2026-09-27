import Foundation

/// デバッグ用ログを出力する
///
/// DEBUGビルドでのみNSLogを呼び出す
///
/// リリースビルドでは何も実行されない
///
/// - Parameters:
///   - items: 出力する内容(nilの場合は呼び出し元名だけを出す)
///   - function: 呼び出し元名(既定は呼び出し側の関数名)
public func debugLog(
    _ items: Any?, function: String = #function
) {
    #if DEBUG
        if let items = items {
            NSLog("\(function) : \(items)")
        } else {
            NSLog("\(function)")
        }
    #endif
}
