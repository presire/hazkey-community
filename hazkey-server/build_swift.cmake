set(SWIFT_COMMAND
    "${SWIFT_EXECUTABLE}"
    "build" "-c" "${SWIFT_BUILD_TYPE}"
    "--scratch-path=${CMAKE_CURRENT_BINARY_DIR}/swift-build"
)

if(HAZKEY_SERVER_ZENZAI_TRAIT)
    list(APPEND SWIFT_COMMAND "--traits" "ZenzaiSupport")
    list(APPEND SWIFT_COMMAND "-Xlinker" "-L${LIBLLAMA_DIR}")
endif()

if(SWIFT_STATIC_STDLIB)
    list(APPEND SWIFT_COMMAND "-Xswiftc" "-static-stdlib")

    if(SWIFT_DYNAMIC_LIB_PATH)
        list(APPEND SWIFT_COMMAND "-Xlinker" "-L${SWIFT_DYNAMIC_LIB_PATH}")
    endif()
endif()

if(SWIFT_DISABLE_DEPENDENCY_CACHE)
    list(APPEND SWIFT_COMMAND "--disable-dependency-cache")
endif()

if(SWIFT_LINK_PATH)
    list(APPEND SWIFT_COMMAND "-Xlinker" "-L${SWIFT_LINK_PATH}")
endif()

# 単独の単位読みを日本語数詞へ変換する修正を適用する前に、コンバータのチェックアウトを解決する
execute_process(
    COMMAND "${SWIFT_EXECUTABLE}" package resolve
            "--scratch-path=${CMAKE_CURRENT_BINARY_DIR}/swift-build"
    WORKING_DIRECTORY "${SWIFT_WORK_DIR}"
    RESULT_VARIABLE resolve_result
)
if(NOT resolve_result EQUAL 0)
    message(FATAL_ERROR "Swift package resolve failed; converter checkouts are required for patch application.")
endif()

# 単独の単位読みを日本語数詞へ変換する修正をAzooKeyKanaKanjiConverterフォークに適用する
#
# 上流の不具合:
# getJapaneseNumberDicdata()は、先行する数字を持たない単位だけの読み (例: 単独の"じゅう"は10、"ひゃく"は100、"せん"は1000等も同様) に対して空の結果を早期に返す
# これは、"tokens.allSatisfy({$0.isNotNumber})"が"parseTokens()"の実行前に[.じゅう, .おわり]を誤って「数ではない」と判定するためである
# "parseTokens()"は、"curnum ?? .One"により、このケースをすでに正しく処理している
# この修正は、Zenzai traitの有無にかかわらず常にコンパイルされるコアKanaKanjiConverterModuleの一部であるJapaneseNumber.swiftを対象とするため、
# 無条件で適用する (HAZKEY_SERVER_ZENZAI_TRAITには依存しない)
#
# 冪等:
# パッチ適用済みの場合 (再ビルド時等) はスキップする
#
# 非致命的:
# git applyコマンドに失敗しても警告を出して続行する
# 上流フォークにすでに修正が含まれる場合も、Swiftビルドを妨げないためである
set(NUMBER_PATCH_FILE "${SWIFT_WORK_DIR}/patches/0003-fix-standalone-unit-japanese-number.patch")
set(NUMBER_CHECKOUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/swift-build/checkouts/AzooKeyKanaKanjiConverter")
set(NUMBER_TARGET_FILE "${NUMBER_CHECKOUT_DIR}/Sources/KanaKanjiConverterModule/DictionaryManagement/JapaneseNumber.swift")

if(EXISTS "${NUMBER_PATCH_FILE}" AND EXISTS "${NUMBER_TARGET_FILE}")
    execute_process(
        COMMAND grep -q "hazkey-community patch" "${NUMBER_TARGET_FILE}"
        RESULT_VARIABLE number_patch_check_result
    )
    if(NOT number_patch_check_result EQUAL 0)
        message(STATUS "Applying standalone-unit Japanese-number conversion fix")
        execute_process(
            COMMAND git apply "${NUMBER_PATCH_FILE}"
            WORKING_DIRECTORY "${NUMBER_CHECKOUT_DIR}"
            RESULT_VARIABLE number_patch_result
            OUTPUT_VARIABLE number_patch_output
            ERROR_VARIABLE number_patch_error
        )
        if(NOT number_patch_result EQUAL 0)
            message(WARNING
                "Failed to apply standalone-unit Japanese-number conversion fix.\n"
                "git apply output: ${number_patch_output}\n"
                "git apply error:  ${number_patch_error}")
        else()
            message(STATUS "Standalone-unit Japanese-number conversion fix applied successfully")
        endif()
    else()
        message(STATUS "Standalone-unit Japanese-number conversion fix already applied (skipping)")
    endif()
endif()

# 注記 1:
# 旧0006-zenzai-preserve-user-dictionary.patch (明示的に登録したユーザ辞書候補を保持するZenzaiレビューの再試行) は、
# AzooKeyKanaKanjiConverterフォークのhazkeyブランチ (コミット: 2cef753) に焼き込み済みのため、ここでの適用は不要である

# 注記 2:
# 旧0007-jinen-qwen3-support.patch (jinen-v2のQwen3対応: NFKC正規化、BOSなし、条件フィールドの抑止。GGUFのgeneral.architecture == "qwen3"で有効化) は、
# AzooKeyKanaKanjiConverterフォークのhazkeyブランチ (コミット: 2cb1bad) に焼き込み済みのため、ここでの適用は不要である

execute_process(
    COMMAND ${SWIFT_COMMAND}
    WORKING_DIRECTORY "${SWIFT_WORK_DIR}"
    RESULT_VARIABLE result
)

# 原因不明により、最初のビルドは失敗する
if(NOT result EQUAL 0)
    execute_process(
        COMMAND ${SWIFT_COMMAND}
        WORKING_DIRECTORY "${SWIFT_WORK_DIR}"
        RESULT_VARIABLE result2
    )
    if(NOT result2 EQUAL 0)
        message(FATAL_ERROR "Swift build failed after two attempts.")
    endif()
endif()
