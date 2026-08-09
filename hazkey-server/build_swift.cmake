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

# Apply Vulkan ICD mitigation patch to the AzooKeyKanaKanjiConverter fork.
# Workaround for https://github.com/7ka-Hiira/hazkey/issues/29: on multi-GPU
# Linux systems (NVIDIA dGPU + AMD/Intel iGPU with both nvidia_icd.json and
# radeon_icd.json installed), Zenzai/Vulkan init crashes hazkey-server with
# SIGILL. The patch pins the Vulkan loader to a single ICD before
# ggml_backend_load_all() runs.
#
# Idempotent: skips when the patch is already applied (e.g. on rebuild).
# Non-fatal: warns and continues if git apply fails, so Swift build is not
# blocked when the upstream fork already ships the mitigation.
if(HAZKEY_SERVER_ZENZAI_TRAIT)
    set(PATCH_FILE "${SWIFT_WORK_DIR}/patches/0001-zenzai-pin-vulkan-icd.patch")
    set(CHECKOUT_DIR "${SWIFT_WORK_DIR}/.build/checkouts/AzooKeyKanaKanjiConverter")
    set(TARGET_FILE "${CHECKOUT_DIR}/Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/Zenz/ZenzContext.swift")

    if(EXISTS "${PATCH_FILE}" AND EXISTS "${TARGET_FILE}")
        execute_process(
            COMMAND grep -q "pinVulkanICDIfNeeded" "${TARGET_FILE}"
            RESULT_VARIABLE patch_check_result
        )
        if(NOT patch_check_result EQUAL 0)
            message(STATUS "Applying Vulkan ICD mitigation patch (Issue #29)")
            execute_process(
                COMMAND git apply "${PATCH_FILE}"
                WORKING_DIRECTORY "${CHECKOUT_DIR}"
                RESULT_VARIABLE patch_result
                OUTPUT_VARIABLE patch_output
                ERROR_VARIABLE patch_error
            )
            if(NOT patch_result EQUAL 0)
                message(WARNING
                    "Failed to apply Vulkan ICD patch (Issue #29 mitigation inactive).\n"
                    "git apply output: ${patch_output}\n"
                    "git apply error:  ${patch_error}")
            else()
                message(STATUS "Vulkan ICD mitigation patch applied successfully")
            endif()
        else()
            message(STATUS "Vulkan ICD mitigation patch already applied (skipping)")
        endif()
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
