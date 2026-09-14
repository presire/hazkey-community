add_library(fcitx5-hazkey SHARED hazkey_state.cpp hazkey_engine.cpp hazkey_candidate.cpp hazkey_preedit.cpp hazkey_frontend_adapter.cpp live_convert_mode.cpp)

# protobuf generation now lives in hazkey-frontend-common (generated exactly
# once for both frontends); fcitx5-hazkey links it. hazkey_constants.h is
# still configured here because it embeds this addon's PROJECT_VERSION.
configure_file(hazkey_constants.h.in hazkey_constants.h @ONLY)

target_include_directories(fcitx5-hazkey PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(fcitx5-hazkey PRIVATE hazkey-frontend-common Fcitx5::Core Fcitx5::Config)

# Instance::showCustomInputMethodInformation() exists since fcitx5 5.1.11.
# Distributions with older fcitx5 (e.g. Ubuntu 24.04 ships 5.1.7) must still
# build, so the Zenzai toggle notification is compiled only when available.
if(Fcitx5Core_VERSION VERSION_GREATER_EQUAL "5.1.11")
    target_compile_definitions(fcitx5-hazkey PRIVATE
        HAZKEY_HAS_SHOW_CUSTOM_IM_INFO=1)
endif()

if(BUILD_TESTING)
    add_executable(live_convert_mode_test live_convert_mode_test.cpp live_convert_mode.cpp)
    target_link_libraries(live_convert_mode_test PRIVATE hazkey-frontend-common)
    target_compile_options(live_convert_mode_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>
    )
    add_dependencies(live_convert_mode_test hazkey-proto-headers)
    add_test(NAME live_convert_mode_test COMMAND live_convert_mode_test)

    add_executable(candidate_refresh_coalescer_test
        candidate_refresh_coalescer_test.cpp)
    # The policy header now lives in hazkey-frontend-common (shared with the
    # IBus frontend); linking it supplies the include directory.
    target_link_libraries(candidate_refresh_coalescer_test PRIVATE
        hazkey-frontend-common)
    target_compile_options(candidate_refresh_coalescer_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>
    )
    add_test(NAME candidate_refresh_coalescer_test
        COMMAND candidate_refresh_coalescer_test)

    add_executable(hazkey_candidate_selection_test
        hazkey_candidate_selection_test.cpp hazkey_candidate.cpp)
    target_link_libraries(hazkey_candidate_selection_test PRIVATE
        Fcitx5::Core hazkey-frontend-common)
    target_compile_options(hazkey_candidate_selection_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_candidate_selection_test hazkey-proto-headers)
    add_test(NAME hazkey_candidate_selection_test
        COMMAND hazkey_candidate_selection_test)

    # The shared-transport tests (hazkey_client_rpc_probe_test,
    # hazkey_client_cache_test, hazkey_client_transact_safety_test) are
    # registered in hazkey-frontend-common/CMakeLists.txt so they also run in
    # an IBus-only build (-DENABLE_FCITX5=OFF), where this directory is not
    # added at all.
endif()

set_target_properties(fcitx5-hazkey PROPERTIES PREFIX "")
install(TARGETS fcitx5-hazkey DESTINATION "${FCITX_INSTALL_LIBDIR}/fcitx5")

configure_file(hazkey-addon.conf.in.in hazkey-addon.conf.in @ONLY)
fcitx5_translate_desktop_file("${CMAKE_CURRENT_BINARY_DIR}/hazkey-addon.conf.in" "hazkey-addon.conf")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/hazkey-addon.conf" RENAME hazkey.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")

fcitx5_translate_desktop_file(hazkey-im.conf.in hazkey-im.conf)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/hazkey-im.conf" RENAME hazkey.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod")
