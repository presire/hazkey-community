import Foundation
import Glibc
import XCTest

/// ラッパー (`hazkey-server.sh.in`) の env ファイル解析を、実際のシェルで検証する
///
/// ラッパーは env ファイルを1行ずつデータとして解釈し、読み込んだ変数を解析中のシェルへ代入せずに
/// env(1) の引数として変換サーバへ渡す
/// bash では RANDOM や OPTIND 等の特殊変数への代入が値を算術式として評価するため、
/// シェルへ代入すると、単一引用符で囲んだ値の配列添字に書いたコマンド置換が実行されてしまう
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

    /// 検証に使うシェル (`/bin/sh` は必須、bash と busybox は存在する場合のみ)
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

    /// 偽の変換サーバのインタプリタ
    /// dash (Debian / Ubuntu の /bin/sh) は、受け継いだ OPTIND が数値でないと起動時に "Illegal number" で終了するため、
    /// bash があれば bash で動かす (ラッパー自体は shells の全シェルで検証する)
    private var fakeServerInterpreter: String {
        for bash in ["/usr/bin/bash", "/bin/bash"] where access(bash, X_OK) == 0 {
            return bash
        }
        return "/bin/sh"
    }

    /// テンプレートの LIBDIR を一時ディレクトリへ差し替え、引数と環境を書き出す偽の変換サーバを置く
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
        currentDirectory: URL? = nil
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
        ]
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

    /// 特殊変数・読み取り専用変数・解析器自身の変数の名前を使った行でも、コマンドが実行されない
    /// 正当な行は、従来どおり変換サーバの環境へ渡る
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

    /// env ファイルが無い場合と、XDG_CONFIG_HOME が相対パスの場合
    /// 相対パスは無効として $HOME/.config を使い、作業ディレクトリ配下の env を読まない
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
}
