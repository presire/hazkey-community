import XCTest

@testable import hazkey_server

final class ZenzaiModelCapabilitiesTests: XCTestCase {
    private struct Case {
        let name: String?
        let expected: Bool
    }

    private let cases: [Case] = [
        Case(name: "zenz-v3.2-small.gguf", expected: true),
        Case(name: "zenz-v3.2-xsmall.gguf", expected: true),
        Case(name: "zenz-v3.1-small.gguf", expected: false),
        Case(name: "zenz-v3-small.gguf", expected: false),
        Case(name: "zenz-v2-small.gguf", expected: false),
        Case(name: "zenz-v4.0-small.gguf", expected: true),
        Case(name: "jinen-v2-small-Q5_K_M.gguf", expected: false),
        Case(name: "my-custom-model.gguf", expected: true),
        Case(name: "zenzai.gguf", expected: true),
        Case(name: nil, expected: false),
        Case(name: "ZENZ-V3.2-SMALL.GGUF", expected: true),
    ]

    func testSupportsRightContextTable() {
        for testCase in cases {
            let url: URL? = testCase.name.map { URL(fileURLWithPath: "/x/y/\($0)") }
            let actual = ZenzaiModelCapabilities.supportsRightContext(modelURL: url)
            XCTAssertEqual(
                actual,
                testCase.expected,
                "supportsRightContext(\(testCase.name ?? "nil")) should be \(testCase.expected)"
            )
        }
    }

    func testJinenAndV31AreNotSupported() {
        // 明示的に非対応モデルがfalseになることを個別に固定する
        let jinen = ZenzaiModelCapabilities.supportsRightContext(
            modelURL: URL(fileURLWithPath: "/x/y/jinen-v2-small-Q5_K_M.gguf")
        )
        let v31 = ZenzaiModelCapabilities.supportsRightContext(
            modelURL: URL(fileURLWithPath: "/x/y/zenz-v3.1-small.gguf")
        )
        print("jinen-v2-small-Q5_K_M.gguf supportsRightContext = \(jinen) (expected false)")
        print("zenz-v3.1-small.gguf supportsRightContext = \(v31) (expected false)")
        XCTAssertFalse(jinen)
        XCTAssertFalse(v31)
    }

    func testNilModelIsNotSupported() {
        XCTAssertFalse(ZenzaiModelCapabilities.supportsRightContext(modelURL: nil))
    }
}
