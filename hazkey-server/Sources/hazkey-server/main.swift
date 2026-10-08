import Foundation
import Glibc

// バックエンドプローブ用の隠し再実行モード
//
// [--probe-backends]付きで起動した隔離子プロセスでGGMLとVulkanバックエンドだけを読み込んで終了する
//
// 異なるベンダーのVulkan ICD競合等で落ちても親はシグナルとして観測できる
//
// 他の起動処理より先に判定する必要がある
if CommandLine.arguments.contains("--probe-backends") {
    runBackendProbeAndExit()
}

umask(0o077)
HazkeyServerConfig.tightenPrivateDirectories()

do {
    // サーバを起動する
    NSLog("Starting hazkey-community-server...")
    let server = HazkeyServer()

    try server.start()
} catch {
    // 起動失敗時は内容を記録して異常終了する
    hazkeyLog("Failed to start server: \(error)")
    exit(1)
}
