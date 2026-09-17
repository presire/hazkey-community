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

# Resolve the converter checkout before applying the standalone-unit
# Japanese-number conversion fix.
execute_process(
    COMMAND "${SWIFT_EXECUTABLE}" package resolve
            "--scratch-path=${CMAKE_CURRENT_BINARY_DIR}/swift-build"
    WORKING_DIRECTORY "${SWIFT_WORK_DIR}"
    RESULT_VARIABLE resolve_result
)
if(NOT resolve_result EQUAL 0)
    message(FATAL_ERROR "Swift package resolve failed; converter checkouts are required for patch application.")
endif()

# Apply the standalone-unit Japanese-number conversion fix to the
# AzooKeyKanaKanjiConverter fork.
# Upstream bug: getJapaneseNumberDicdata() early-returns an empty result for
# a bare unit reading with no preceding digit (e.g. "じゅう" alone, meaning
# 10; also affects "ひゃく"=100, "せん"=1000, ...), because
# `tokens.allSatisfy({$0.isNotNumber})` incorrectly classifies
# [.じゅう, .おわり] as "not a number" before parseTokens() ever runs -
# even though parseTokens() already handles this case correctly via
# `curnum ?? .One`. This is unconditional (not gated by
# HAZKEY_SERVER_ZENZAI_TRAIT) because JapaneseNumber.swift is part of the
# core KanaKanjiConverterModule, which is always compiled regardless of the
# Zenzai trait.
#
# Idempotent: skips when the patch is already applied (e.g. on rebuild).
# Non-fatal: warns and continues if git apply fails, so Swift build is not
# blocked when the upstream fork already ships the fix.
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

# Note: the former 0006-zenzai-preserve-user-dictionary.patch (Zenzai review
# retry preserving explicitly registered user-dictionary candidates) is baked
# into the converter fork's hazkey branch (presire/AzooKeyKanaKanjiConverter,
# commit 2cef753), so no apply step is needed here anymore.

# ----- jinen-v2 (Qwen3) support ----- #
# jinen-v2 (togatogah/jinen-v2-*.gguf, karukan) uses the Qwen3 architecture.
# The converter's Zenz path assumes zenz (v2/v3): GPT-2 style space/newline
# preprocessing, a leading BOS token, and U+EE03-EE06 condition tokens. For a
# qwen3 GGUF this patch switches to NFKC normalization, drops BOS, strips the
# condition/right-context/alignment-separator fields, and compares candidates
# in NFKC space. Detection is by GGUF `general.architecture` inside the
# converter, so the existing zenz (v3.1/v3.2) code paths are untouched.
# Idempotent: skips when the patch is already applied (marker: isJinenModel).
# Non-fatal: warns and continues if git apply fails.
set(JINEN_PATCH_FILE "${SWIFT_WORK_DIR}/patches/0007-jinen-qwen3-support.patch")
set(JINEN_CHECKOUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/swift-build/checkouts/AzooKeyKanaKanjiConverter")
set(JINEN_TARGET_FILE "${JINEN_CHECKOUT_DIR}/Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/Zenz/ZenzContext.swift")

if(EXISTS "${JINEN_PATCH_FILE}" AND EXISTS "${JINEN_TARGET_FILE}")
    execute_process(
        COMMAND grep -q "isJinenModel" "${JINEN_TARGET_FILE}"
        RESULT_VARIABLE jinen_patch_check_result
    )
    if(NOT jinen_patch_check_result EQUAL 0)
        message(STATUS "Applying jinen-v2 (Qwen3) support patch")
        execute_process(
            COMMAND git apply "${JINEN_PATCH_FILE}"
            WORKING_DIRECTORY "${JINEN_CHECKOUT_DIR}"
            RESULT_VARIABLE jinen_patch_result
            OUTPUT_VARIABLE jinen_patch_output
            ERROR_VARIABLE jinen_patch_error
        )
        if(NOT jinen_patch_result EQUAL 0)
            message(WARNING
                "Failed to apply jinen-v2 (Qwen3) support patch.\n"
                "git apply output: ${jinen_patch_output}\n"
                "git apply error:  ${jinen_patch_error}")
        else()
            message(STATUS "jinen-v2 (Qwen3) support patch applied successfully")
        endif()
    else()
        message(STATUS "jinen-v2 (Qwen3) support patch already applied (skipping)")
    endif()
endif()

execute_process(
    COMMAND ${SWIFT_COMMAND}
    WORKING_DIRECTORY "${SWIFT_WORK_DIR}"
    RESULT_VARIABLE result
)

# The first build fails for an unknown reason.
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
