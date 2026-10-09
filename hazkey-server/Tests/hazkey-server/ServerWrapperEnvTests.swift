import Foundation
import Glibc
import XCTest

// ラッパーhazkey-server.sh.inのenvファイル解析を、実際のシェルで検証する
// ラッパーはenvファイルを1行ずつデータとして解釈し、読み込んだ変数を解析中のシェルへ代入せずに
// env(1)の引数として変換サーバへ渡す
// bashでは[RANDOM]や[OPTIND]等の特殊変数への代入が値を算術式として評価するため、
// シェルへ代入すると、単一引用符で囲んだ値の配列添字に書いたコマンド置換が実行されてしまう
final class ServerWrapperEnvTests: XCTestCase {
    private struct Invocation {
        let status: Int32
        let arguments: [String]
        let environment: [String: String]
        let standardError: String
    }

    private var wrapperTemplate: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hazkey-server.sh.in")
    }

    // 検証に使うシェル(/bin/shは必須、bashとbusyboxは存在する場合のみ)
    private var shells: [[String]] {
        var result: [[String]] = [["/bin/sh"]]
        for bash in ["/usr/bin/bash", "/bin/bash"] where access(bash, X_OK) == 0 {
            result.append([bash])
            result.append([bash, "--posix"])
            break
        }
        for busybox in ["/usr/bin/busybox", "/bin/busybox"] where access(busybox, X_OK) == 0 {
            result.append([busybox, "sh"])
            break
        }
        return result
    }

    // 偽の変換サーバのインタプリタ
    // dash(Debian/Ubuntuの/bin/sh)は、受け継いだ[OPTIND]が数値でないと起動時に「Illegal number」で終了するため、
    // bashがあればbashで動かす(ラッパー自体は[shells]の全シェルで検証する)
    private var fakeServerInterpreter: String {
        for bash in ["/usr/bin/bash", "/bin/bash"] where access(bash, X_OK) == 0 {
            return bash
        }
        return "/bin/sh"
    }

    // テンプレートの[CMAKE_INSTALL_FULL_LIBDIR]を一時ディレクトリへ差し替え、引数と環境を書き出す偽の変換サーバを置く
    private func makeWrapper(in root: URL) throws -> URL {
        let serverDirectory = root.appendingPathComponent("lib/hazkey-community", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        let fakeServer = serverDirectory.appendingPathComponent("hazkey-community-server")
        try """
            #!\(fakeServerInterpreter)
            {
                for a in "$@"; do printf 'ARG\\t%s\\n' "$a"; done
                /usr/bin/env | while IFS= read -r line; do printf 'ENV\\t%s\\n' "$line"; done
            } > "$HAZKEY_TEST_OUT"

            """.write(to: fakeServer, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(fakeServer.path, 0o700), 0)

        let template = try String(contentsOf: wrapperTemplate, encoding: .utf8)
        XCTAssertTrue(template.contains("@CMAKE_INSTALL_FULL_LIBDIR@"))
        let wrapper = root.appendingPathComponent("wrapper.sh")
        try template.replacingOccurrences(
            of: "@CMAKE_INSTALL_FULL_LIBDIR@", with: root.appendingPathComponent("lib").path
        ).write(to: wrapper, atomically: true, encoding: .utf8)
        return wrapper
    }

    private func run(
        shell: [String], wrapper: URL, root: URL, configHome: String, arguments: [String],
        currentDirectory: URL? = nil, extraEnvironment: [String: String] = [:]
    ) throws -> Invocation {
        let output = root.appendingPathComponent("out-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell[0])
        process.arguments = Array(shell.dropFirst()) + [wrapper.path] + arguments
        process.environment = [
            "HOME": root.appendingPathComponent("home").path,
            "PATH": "/usr/bin:/bin",
            "XDG_CONFIG_HOME": configHome,
            "HAZKEY_TEST_OUT": output.path,
        ].merging(extraEnvironment) { _, extra in extra }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var parsedArguments: [String] = []
        var environment: [String: String] = [:]
        if let text = try? String(contentsOf: output, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("ARG\t") {
                    parsedArguments.append(String(line.dropFirst(4)))
                } else if line.hasPrefix("ENV\t"), let equal = line.firstIndex(of: "=") {
                    let key = String(line[line.index(line.startIndex, offsetBy: 4)..<equal])
                    environment[key] = String(line[line.index(after: equal)...])
                }
            }
        }
        return Invocation(
            status: process.terminationStatus, arguments: parsedArguments, environment: environment,
            standardError: String(decoding: errorData, as: UTF8.self))
    }

    private func writeEnvFile(_ contents: String, configHome: URL) throws {
        let directory = configHome.appendingPathComponent("hazkey-community", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appendingPathComponent("env"), atomically: true, encoding: .utf8)
    }

    private func markers(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("PWNED_") }
    }

    // 特殊変数・読み取り専用変数・解析器自身の変数の名前を使った行でも、コマンドが実行されない
    // 正当な行は、従来どおり変換サーバの環境へ渡る
    func testEnvFileNamesNeverExecuteCodeAndValidEntriesReachTheServer() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = try makeWrapper(in: root)
        let configHome = root.appendingPathComponent("config", isDirectory: true)
        let marker = { (name: String) in root.appendingPathComponent("PWNED_\(name)").path }
        let hostileNames = [
            "RANDOM", "OPTIND", "SECONDS", "LINENO", "SRANDOM", "hazkey_env_lineno",
            "hazkey_env_argc", "hazkey_env_value", "hazkey_env_names",
        ]
        var lines = hostileNames.map { "\($0)='a[$(touch \(marker($0)))0]'" }
        lines += [
            "UID=5",
            "IFS='x'",
            "VK_DRIVER_FILES=/usr/share/vulkan/icd.d/x.json",
            "export HAZKEY_A=1",
            "HAZKEY_B=\"$HAZKEY_A/x\"",
            "HAZKEY_C=${HOME}/c",
            "HAZKEY_D='lit$(x)`y`\\z'",
            "HAZKEY_E=~/e",
            "HAZKEY_F=abc#def",
            "HAZKEY_G=1 # comment",
            "HAZKEY_A=2",
            "LD_PRELOAD=/nonexistent.so",
            "HAZKEY_BAD=$(touch \(marker("CMD")))",
            "HAZKEY_BAD2=\"`touch \(marker("BACKTICK"))`\"",
            "touch \(marker("BARE"))",
        ]
        try writeEnvFile(lines.joined(separator: "\n") + "\n", configHome: configHome)
        let home = root.appendingPathComponent("home").path

        for shell in shells {
            let label = shell.joined(separator: " ")
            let result = try run(
                shell: shell, wrapper: wrapper, root: root, configHome: configHome.path,
                arguments: ["-r", "arg with space"])
            XCTAssertEqual(result.status, 0, "\(label): \(result.standardError)")
            XCTAssertEqual(markers(in: root), [], "\(label) executed code from the env file")
            XCTAssertEqual(result.arguments, ["-r", "arg with space"], label)
            let env = result.environment
            XCTAssertEqual(env["VK_DRIVER_FILES"], "/usr/share/vulkan/icd.d/x.json", label)
            XCTAssertEqual(env["HAZKEY_A"], "2", label)
            XCTAssertEqual(env["HAZKEY_B"], "1/x", label)
            XCTAssertEqual(env["HAZKEY_C"], "\(home)/c", label)
            XCTAssertEqual(env["HAZKEY_D"], "lit$(x)`y`\\z", label)
            XCTAssertEqual(env["HAZKEY_E"], "\(home)/e", label)
            XCTAssertEqual(env["HAZKEY_F"], "abc#def", label)
            XCTAssertEqual(env["HAZKEY_G"], "1", label)
            XCTAssertEqual(env["UID"], "5", label)
            XCTAssertNil(env["LD_PRELOAD"], label)
            XCTAssertNil(env["HAZKEY_BAD"], label)
            XCTAssertNil(env["HAZKEY_BAD2"], label)
            for name in ["hazkey_env_lineno", "hazkey_env_argc", "hazkey_env_value"] {
                XCTAssertEqual(env[name], "a[$(touch \(marker(name)))0]", "\(label): \(name)")
            }
            XCTAssertTrue(result.standardError.contains("LD_PRELOAD is not allowed"), label)
        }
    }

    // 展開後の値が上限(値1つあたり64KiB、合計256KiB)を超える行は棄却する
    // いずれの上限もバイト単位で判定する
    // [A=x]に続けて[A="$A$A"]を繰り返す小さなファイルが値を指数関数的に膨らませても、
    // ラッパーは変換サーバを起動し、正当な短い値は従来どおり渡り、変数は変更前の値のまま残る
    // 文字数だけで判定すれば上限内に見える65_536文字の「あ」(196_608バイト)は棄却され、
    // 短い多バイト値は通る
    func testOversizedExpansionsAreRejectedAndSmallValuesStillPass() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = try makeWrapper(in: root)
        let configHome = root.appendingPathComponent("config", isDirectory: true)
        var lines = ["A=x", "HAZKEY_OK=hello"]
        for _ in 0..<20 { lines.append("A=\"$A$A\"") }
        // 多バイト文字の倍増攻撃: [M=あ]に続けて[M="$M$M"]を繰り返すとバイト数で頭打ちになる
        // 合計上限用の値より前に置く(合計予算を先に確保し、値上限での打ち切りを純粋に検証する)
        lines.append("M=あ")
        for _ in 0..<20 { lines.append("M=\"$M$M\"") }
        // 合計上限用: 60_000バイトの値を5つ(300_000バイトで上限の262_144バイトを超える)
        let chunk = String(repeating: "y", count: 60_000)
        for index in 0..<5 { lines.append("HAZKEY_BIG\(index)='\(chunk)'") }
        // バイト単位の検証用: 短い多バイト値は通り、文字数では上限内だが
        // バイト数では上限超えの値は棄却される
        // 単一引用符の行は展開を経ないため、
        // 代入ゲートのバイト判定を直接検証する
        let smallMulti = "あいうえお" // 5文字・15バイトの値は受け入れる
        lines.append("HAZKEY_SMALL_MULTI='\(smallMulti)'")
        let bigMulti = String(repeating: "あ", count: 65_536) // 65_536文字だが196_608バイトの値は棄却する
        lines.append("HAZKEY_BIG_MULTI='\(bigMulti)'")
        try writeEnvFile(lines.joined(separator: "\n") + "\n", configHome: configHome)

        for shell in shells {
            let label = shell.joined(separator: " ")
            let result = try run(
                shell: shell, wrapper: wrapper, root: root, configHome: configHome.path,
                arguments: [])
            XCTAssertEqual(result.status, 0, "\(label): \(result.standardError)")
            XCTAssertEqual(result.environment["HAZKEY_OK"], "hello", label)
            // 値上限: 65_536バイトで頭打ちになり、それ以降の倍増は棄却される
            XCTAssertEqual(result.environment["A"]?.count, 65_536, label)
            XCTAssertEqual(result.environment["A"]?.utf8.count, 65_536, label)
            XCTAssertTrue(result.standardError.contains("value too large"), label)
            // バイト単位の検証: 短い多バイト値は通り、65_536文字でも196_608バイトの値は棄却される
            XCTAssertEqual(result.environment["HAZKEY_SMALL_MULTI"], smallMulti, label)
            XCTAssertEqual(result.environment["HAZKEY_SMALL_MULTI"]?.utf8.count, 15, label)
            XCTAssertNil(result.environment["HAZKEY_BIG_MULTI"], "\(label): byte cap did not reject 65536 chars / 196608 bytes")
            // 多バイト倍増の打ち切り: バイト数で上限内に収まり、部分的な代入は行わない
            // 「あ」(3バイト)の倍増は3×2^14 = 49_152バイト(16_384文字)で頭打ちになる
            let multiDoubled = result.environment["M"]
            XCTAssertNotNil(multiDoubled, "\(label): multibyte doubling left M unset")
            if let multiDoubled {
                XCTAssertEqual(multiDoubled.utf8.count, 49_152, label)
                XCTAssertEqual(multiDoubled.count, 16_384, label)
                XCTAssertEqual(multiDoubled.utf8.count, multiDoubled.count * 3, label)
            }
            // 合計上限: 先の変数で予算を使い切るため、後の大きな変数は一部だけが残る
            let bigAccepted = (0..<5).compactMap { result.environment["HAZKEY_BIG\($0)"] }
            XCTAssertTrue(bigAccepted.count < 5, "\(label): total cap did not reject anything")
            XCTAssertTrue(bigAccepted.count >= 1, "\(label): total cap rejected everything")
            for value in bigAccepted { XCTAssertEqual(value.count, 60_000, label) }
        }
    }

    // envファイルが無い場合と、[XDG_CONFIG_HOME]が相対パスの場合
    // 相対パスは無効として$HOME/.configを使い、作業ディレクトリ配下のenvを読まない
    func testMissingEnvFileExecsDirectlyAndRelativeConfigHomeIsIgnored() throws {
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = try makeWrapper(in: root)

        for shell in shells {
            let label = shell.joined(separator: " ")
            let result = try run(
                shell: shell, wrapper: wrapper, root: root,
                configHome: root.appendingPathComponent("missing").path, arguments: ["--probe"])
            XCTAssertEqual(result.status, 0, "\(label): \(result.standardError)")
            XCTAssertEqual(result.arguments, ["--probe"], label)
            XCTAssertEqual(result.standardError, "", label)
        }

        try writeEnvFile(
            "HAZKEY_FROM_CWD=1\n", configHome: root.appendingPathComponent("relative"))
        try writeEnvFile(
            "HAZKEY_FROM_HOME=1\n",
            configHome: root.appendingPathComponent("home/.config", isDirectory: true))
        for shell in shells {
            let label = shell.joined(separator: " ")
            let result = try run(
                shell: shell, wrapper: wrapper, root: root, configHome: "relative", arguments: [],
                currentDirectory: root)
            XCTAssertEqual(result.status, 0, "\(label): \(result.standardError)")
            XCTAssertNil(result.environment["HAZKEY_FROM_CWD"], label)
            XCTAssertEqual(result.environment["HAZKEY_FROM_HOME"], "1", label)
        }
    }

    // SELinuxのラベルのない古いソケットとロックファイルを、使用中でない場合だけ片付けてから変換サーバを起動する
    // ラベルはstatの[%C]を差し替えて与える (実際のラベルの付け替えにはroot権限とポリシーが必要なため)
    // 使用中のロックファイル、正しいラベルのファイル、SELinuxで制限されない変換サーバの場合は削除しない
    func testUnlabeledRuntimeFilesAreRemovedOnlyWhenUnusedAndServerIsConfined() throws {
        let flockPaths: [String] = ["/usr/bin/flock", "/bin/flock"]
        guard flockPaths.contains(where: { access($0, X_OK) == 0 }) else {
            throw XCTSkip("flock is not available")
        }
        let root = try TestTempRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = try makeWrapper(in: root)
        let configHome = root.appendingPathComponent("config", isDirectory: true)

        // [stat -c %C -- <パス>]だけを差し替える偽のstat
        // 変換サーバには[HAZKEY_TEST_SERVER_CONTEXT]のラベルを返し、
        // その他のファイルには<パス>.contextの内容を返す (無ければuser_tmp_t)
        let stubDirectory = root.appendingPathComponent("stub", isDirectory: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        let stubStat = stubDirectory.appendingPathComponent("stat")
        try """
            #!/bin/sh
            if [ "$1" = -c ] && [ "$2" = %C ] && [ "$3" = -- ]; then
                case $4 in
                    */hazkey-community-server) printf '%s\\n' "$HAZKEY_TEST_SERVER_CONTEXT" ;;
                    *)
                        if [ -f "$4.context" ]; then cat "$4.context"
                        else printf '%s\\n' 'unconfined_u:object_r:user_tmp_t:s0'; fi
                        ;;
                esac
                exit 0
            fi
            for real in /usr/bin/stat /bin/stat; do
                if [ -x "$real" ]; then exec "$real" "$@"; fi
            done
            exit 1

            """.write(to: stubStat, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(stubStat.path, 0o700), 0)

        let runtimeDirectory = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(runtimeDirectory.path, 0o700), 0)
        let uid = getuid()
        let lock = runtimeDirectory.appendingPathComponent("hazkey-community-server.\(uid).lock")
        let socket = runtimeDirectory.appendingPathComponent("hazkey-community-server.\(uid).sock")
        let confined = "system_u:object_r:hazkey_community_exec_t:s0"
        let runtimeLabel = "unconfined_u:object_r:hazkey_community_runtime_t:s0"

        func prepare(lockLabel: String?, socketLabel: String?) throws {
            for (file, label) in [(lock, lockLabel), (socket, socketLabel)] {
                try "".write(to: file, atomically: false, encoding: .utf8)
                let contextFile = URL(fileURLWithPath: file.path + ".context")
                if let label {
                    try label.write(to: contextFile, atomically: false, encoding: .utf8)
                } else {
                    try? FileManager.default.removeItem(at: contextFile)
                }
            }
        }
        func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

        for shell in shells {
            let label = shell.joined(separator: " ")
            func launch(serverContext: String) throws -> Invocation {
                try run(
                    shell: shell, wrapper: wrapper, root: root, configHome: configHome.path,
                    arguments: ["--probe"],
                    extraEnvironment: [
                        "PATH": "\(stubDirectory.path):/usr/bin:/bin",
                        "XDG_RUNTIME_DIR": runtimeDirectory.path,
                        "HAZKEY_TEST_SERVER_CONTEXT": serverContext,
                    ])
            }

            // 使用中でないuser_tmp_tのロックファイルとソケットは削除してから変換サーバを起動する
            try prepare(lockLabel: nil, socketLabel: nil)
            var result = try launch(serverContext: confined)
            XCTAssertEqual(result.status, 0, "\(label): \(result.standardError)")
            XCTAssertEqual(result.arguments, ["--probe"], label)
            XCTAssertFalse(exists(lock), "\(label): unlabeled lock was not removed")
            XCTAssertFalse(exists(socket), "\(label): unlabeled socket was not removed")
            XCTAssertTrue(result.standardError.contains("without the SELinux label"), label)

            // ソケットだけが古い場合も、両方を削除する
            try prepare(lockLabel: runtimeLabel, socketLabel: nil)
            result = try launch(serverContext: confined)
            XCTAssertEqual(result.status, 0, "\(label): \(result.standardError)")
            XCTAssertFalse(exists(lock), label)
            XCTAssertFalse(exists(socket), label)

            // ロックファイルを誰かがロックしている (動作中の変換サーバがある) 場合は削除しない
            try prepare(lockLabel: nil, socketLabel: nil)
            let holder = open(lock.path, O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(holder, 0)
            XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
            result = try launch(serverContext: confined)
            close(holder)
            XCTAssertEqual(result.status, 0, "\(label): \(result.standardError)")
            XCTAssertTrue(exists(lock), "\(label): locked file was removed")
            XCTAssertTrue(exists(socket), "\(label): socket of the running server was removed")
            XCTAssertEqual(result.standardError, "", label)

            // 正しいラベルのファイルは削除しない
            try prepare(lockLabel: runtimeLabel, socketLabel: runtimeLabel)
            result = try launch(serverContext: confined)
            XCTAssertTrue(exists(lock), label)
            XCTAssertTrue(exists(socket), label)
            XCTAssertEqual(result.standardError, "", label)

            // SELinuxで制限されない変換サーバ (ラベルなしやSELinuxの無効な環境) の場合は削除しない
            for serverContext in ["unconfined_u:object_r:lib_t:s0", "?", ""] {
                try prepare(lockLabel: nil, socketLabel: nil)
                result = try launch(serverContext: serverContext)
                XCTAssertEqual(result.status, 0, "\(label): \(result.standardError)")
                XCTAssertTrue(exists(lock), "\(label): \(serverContext)")
                XCTAssertTrue(exists(socket), "\(label): \(serverContext)")
            }
        }
    }
}
