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
