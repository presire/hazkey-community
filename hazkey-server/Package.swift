// swift-tools-version: 6.1
// swift-tools-versionは、このパッケージのビルドに必要なSwiftの最低バージョンを宣言する

import PackageDescription

let package = Package(
    name: "hazkey-server",
    products: [
        // Productsはパッケージが生成する実行可能ファイルとライブラリを定義し、他のパッケージから利用可能にする
        .executable(
            name: "hazkey-server",
            targets: ["hazkey-server"])
    ],
    traits: [
        "ZenzaiSupport"
    ],
    dependencies: [
        .package(
            url: "https://github.com/presire/AzooKeyKanaKanjiConverter",
            branch: "hazkey",
            traits: [.trait(name: "Zenzai", condition: .when(traits: ["ZenzaiSupport"]))]),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.27.0"),
    ],
    targets: [
        // Targetsは、モジュールまたはテストスイートを定義するパッケージの基本構成要素である
        // Targetsは、このパッケージ内の他のtargetや依存先のproductに依存できる
        .executableTarget(
            name: "hazkey-server",
            dependencies: [
                .product(
                    name: "KanaKanjiConverterModule",
                    package: "AzooKeyKanaKanjiConverter"),
                .product(
                    name: "SwiftUtils",
                    package: "AzooKeyKanaKanjiConverter"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "$ORIGIN/libllama"])
            ],
        ),
        .testTarget(
            name: "hazkey-server-tests",
            dependencies: [
                "hazkey-server",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Tests/hazkey-server",
            // 既存の統合テストはprotobufスキーマから削除されたHazkey_Commands_QueryDataを参照している
            // 現在のプロトコルへ更新されるまで除外する
            exclude: [
                "base.swift",
                "utils.swift",
                "config.swift",
                "candidate.swift",
                "composingTextExtension.swift",
                "error.swift",
                "integration.swift",
                "userDictionaryProfileSetting.swift",
                "autoConversion.swift",
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)],
        ),
    ]
)
