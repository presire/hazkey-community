# IBus engine binary and its frontend-logic test. Mirrors
# fcitx5-hazkey/src/CMakeLists.txt: this directory owns its targets while the
# parent owns project setup, the shared transport, the component XML and the
# gettext catalogs.

# Engine description (<icon>/<setup>) embedded into the engine binary and
# emitted by `ibus-engine-hazkey --xml`. The setup command must be an absolute
# path because ibus-setup launches it with os.spawnl(), which does not search
# PATH (an absolute path would otherwise resolve via execv, not PATH lookup).
set(HAZKEY_ENGINE_ICON "hazkey")
set(HAZKEY_ENGINE_SETUP "${CMAKE_INSTALL_FULL_BINDIR}/hazkey-settings")
configure_file(engine_description.h.in
    ${CMAKE_CURRENT_BINARY_DIR}/engine_description.h
    @ONLY)

add_executable(ibus-engine-hazkey
    main.cpp
    hazkey_engine.cpp
    hazkey_state.cpp
    live_convert_mode.cpp
    hazkey_frontend_glib.cpp
)
add_dependencies(ibus-engine-hazkey hazkey-proto-headers)

target_include_directories(ibus-engine-hazkey PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}
    ${IBUS_INCLUDE_DIRS}
)
target_link_libraries(ibus-engine-hazkey PRIVATE
    PkgConfig::IBUS
    hazkey-frontend-common
)

install(TARGETS ibus-engine-hazkey
    RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/ibus-hazkey)

# Frontend-logic test. Mirrors fcitx5-hazkey's hazkey_candidate_selection_test
# for the IBus candidate index mapping. It links hazkey_state.cpp directly
# (the pure static mapper is exercised without constructing an engine or
# contacting hazkey-server) and uses an ibus_-prefixed CTest name so it does
# not collide with the fcitx5-hazkey tests in a combined build.
if(BUILD_TESTING)
    add_executable(ibus_hazkey_state_test
        hazkey_state_test.cpp
        hazkey_state.cpp
        live_convert_mode.cpp
    )
    target_include_directories(ibus_hazkey_state_test PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${IBUS_INCLUDE_DIRS}
    )
    target_link_libraries(ibus_hazkey_state_test PRIVATE
        PkgConfig::IBUS
        hazkey-frontend-common
    )
    # The test asserts with the standard assert() macro, so NDEBUG (Release)
    # must be disabled for this target or every check would be compiled out.
    # Mirrors the fcitx5-hazkey test targets.
    target_compile_options(ibus_hazkey_state_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(ibus_hazkey_state_test hazkey-proto-headers)
    add_test(NAME ibus_hazkey_state_test COMMAND ibus_hazkey_state_test)
endif()
