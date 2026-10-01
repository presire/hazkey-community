import Foundation
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// HazkeyServerConfig.makeZenzaiV3DependentModeの振る舞いを固定する
///
/// 右文脈フラグがOFFのままなら今日の生成式と等しく、ONでも対応モデル・文脈モード・非空の条件がそろったときだけ右文脈が渡る
final class ZenzaiRightContextModeTests: XCTestCase {
    private static func profile(
        rightContext: Bool = false,
        contextualMode: Bool = true,
        alignmentSeparator: Bool = false
    ) -> Hazkey_Config_Profile {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.zenzaiRightContext = rightContext
        profile.zenzaiContextualMode = contextualMode
        profile.zenzaiAlignmentSeparator = alignmentSeparator
        profile.zenzaiProfile = "かいはつしゃ"
        profile.zenzaiTopic = "ぎじゅつぶんしょ"
        profile.zenzaiStyle = "であるちょう"
        profile.zenzaiPreference = "みじかく"
        return profile
    }

    private static func modelURL(named fileName: String) -> URL {
        URL(fileURLWithPath: "/models/\(fileName)")
    }

    private static let alignmentModelTable: [(name: String?, supported: Bool)] = [
        ("zenz-v3.2-small.gguf", true),
        ("zenz-v3.2-xsmall.gguf", true),
        ("zenz-v3.2-small", true),
        ("zenz-v4.0-small.gguf", true),
        ("zenz-v3.1-small.gguf", false),
        ("zenz-v3-small.gguf", false),
        ("zenz-v2-small.gguf", false),
        ("jinen-v2-small-Q5_K_M.gguf", false),
        ("my-custom.gguf", false),
        ("zenzai.gguf", false),
        (nil, false),
    ]

    private static func preFeatureModeBaseline(
        profile: Hazkey_Config_Profile, leftContext: String
    ) -> ConvertRequestOptions.ZenzaiV3DependentMode {
        ConvertRequestOptions.ZenzaiV3DependentMode(
            profile: profile.zenzaiProfile,
            topic: profile.zenzaiTopic,
            style: profile.zenzaiStyle,
            preference: profile.zenzaiPreference,
            leftSideContext: profile.zenzaiContextualMode ? leftContext : nil
        )
    }

    func testOffFlagsMatchLegacyExpressionForAnyRightContext() {
        for contextualMode in [true, false] {
            let profile = Self.profile(contextualMode: contextualMode)
            for rightContext in ["", "みぎぶんみゃく", "文の途中にある長い右側の文脈"] {
                XCTAssertEqual(
                    HazkeyServerConfig.makeZenzaiV3DependentMode(
                        profile: profile,
                        leftContext: "ひだりぶんみゃく",
                        rightContext: rightContext,
                        modelURL: Self.modelURL(named: "zenz-v3.2-small.gguf")
                    ),
                    Self.preFeatureModeBaseline(profile: profile, leftContext: "ひだりぶんみゃく")
                )
            }
        }

        // 区切りフラグ {OFF, ON} × カーソル {末尾, 途中} でも、
        // 区切りOFFまたはカーソル末尾では生成されるモードが従来式と一致する
        for alignmentSeparator in [false, true] {
            let profile = Self.profile(alignmentSeparator: alignmentSeparator)
            for sendsFullReading in [false, true] where !alignmentSeparator || !sendsFullReading {
                XCTAssertEqual(
                    HazkeyServerConfig.makeZenzaiV3DependentMode(
                        profile: profile,
                        leftContext: "ひだりぶんみゃく",
                        rightContext: "",
                        modelURL: Self.modelURL(named: "zenz-v3.2-small.gguf"),
                        sendsFullReadingForAlignment: sendsFullReading
                    ),
                    Self.preFeatureModeBaseline(profile: profile, leftContext: "ひだりぶんみゃく")
                )
            }
        }
    }

    func testAlignmentSeparatorOnlyWhenFlagAndSupportedModel() {
        for flag in [false, true] {
            let profile = Self.profile(alignmentSeparator: flag)
            for testCase in Self.alignmentModelTable {
                let url: URL? = testCase.name.map { Self.modelURL(named: $0) }
                let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
                    profile: profile,
                    leftContext: "ひだり",
                    rightContext: "",
                    modelURL: url,
                    sendsFullReadingForAlignment: true
                )
                XCTAssertEqual(
                    mode.enableAlignmentSeparator,
                    flag && testCase.supported,
                    "flag=\(flag) model=\(testCase.name ?? "nil")"
                )
            }
        }
    }

    func testAlignmentSeparatorIsIndependentOfContextualMode() {
        let profile = Self.profile(contextualMode: false, alignmentSeparator: true)
        let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
            profile: profile,
            leftContext: "ひだり",
            rightContext: "",
            modelURL: Self.modelURL(named: "zenz-v3.2-small.gguf"),
            sendsFullReadingForAlignment: true
        )
        XCTAssertTrue(mode.enableAlignmentSeparator)
    }

    func testAlignmentSeparatorAppliesMatchesModeDecision() {
        for flag in [false, true] {
            let profile = Self.profile(alignmentSeparator: flag)
            for testCase in Self.alignmentModelTable {
                let url: URL? = testCase.name.map { Self.modelURL(named: $0) }
                let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
                    profile: profile,
                    leftContext: "ひだり",
                    rightContext: "",
                    modelURL: url,
                    sendsFullReadingForAlignment: true
                )
                XCTAssertEqual(
                    mode.enableAlignmentSeparator,
                    HazkeyServerConfig.alignmentSeparatorApplies(
                        profile: profile, modelURL: url
                    ),
                    "flag=\(flag) model=\(testCase.name ?? "nil")"
                )
            }
        }
    }

    func testRightContextFlowsWhenAllConditionsHold() {
        let profile = Self.profile(rightContext: true)
        let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
            profile: profile,
            leftContext: "ひだり",
            rightContext: "みぎ",
            modelURL: Self.modelURL(named: "zenz-v3.2-small.gguf")
        )
        XCTAssertEqual(mode.rightSideContext, "みぎ")
    }

    func testRightContextNilWhenContextualModeOff() {
        let profile = Self.profile(rightContext: true, contextualMode: false)
        let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
            profile: profile,
            leftContext: "ひだり",
            rightContext: "みぎ",
            modelURL: Self.modelURL(named: "zenz-v3.2-small.gguf")
        )
        XCTAssertNil(mode.rightSideContext)
    }

    func testRightContextNilForUnsupportedModels() {
        let profile = Self.profile(rightContext: true)
        for fileName in ["zenz-v3.1-small.gguf", "jinen-v2-small-Q5_K_M.gguf"] {
            let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
                profile: profile,
                leftContext: "ひだり",
                rightContext: "みぎ",
                modelURL: Self.modelURL(named: fileName)
            )
            XCTAssertNil(mode.rightSideContext, fileName)
        }
    }

    func testRightContextNilWhenEmpty() {
        let profile = Self.profile(rightContext: true)
        let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
            profile: profile,
            leftContext: "ひだり",
            rightContext: "",
            modelURL: Self.modelURL(named: "zenz-v3.2-small.gguf")
        )
        XCTAssertNil(mode.rightSideContext)
    }

    func testCustomModelFollowsSettings() {
        let profile = Self.profile(rightContext: true)
        let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
            profile: profile,
            leftContext: "ひだり",
            rightContext: "みぎ",
            modelURL: Self.modelURL(named: "my-custom.gguf")
        )
        XCTAssertEqual(mode.rightSideContext, "みぎ")
    }

    func testNilModelURLSendsNothing() {
        let profile = Self.profile(rightContext: true)
        let mode = HazkeyServerConfig.makeZenzaiV3DependentMode(
            profile: profile,
            leftContext: "ひだり",
            rightContext: "みぎ",
            modelURL: nil
        )
        XCTAssertNil(mode.rightSideContext)
    }
}
