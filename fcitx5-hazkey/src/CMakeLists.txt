set(PROTO_FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/../../protocol/base.proto
    ${CMAKE_CURRENT_SOURCE_DIR}/../../protocol/commands.proto
    ${CMAKE_CURRENT_SOURCE_DIR}/../../protocol/config.proto
)

add_library(fcitx5-hazkey SHARED hazkey_state.cpp hazkey_engine.cpp hazkey_candidate.cpp hazkey_preedit.cpp hazkey_server_connector.cpp live_convert_mode.cpp)

if(Protobuf_VERSION VERSION_GREATER_EQUAL "3.15")
    # 3.15 ~：stable proto3 optional support
    message(STATUS "Using standard protobuf_generate (protobuf ${Protobuf_VERSION})")
    protobuf_generate(
        TARGET fcitx5-hazkey
        LANGUAGE cpp
        PROTOS ${PROTO_FILES}
        IMPORT_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/../../protocol
        PROTOC_OUT_DIR ${CMAKE_CURRENT_BINARY_DIR}
    )
elseif(Protobuf_VERSION VERSION_GREATER_EQUAL "3.12")
    # 3.12 ~ 3.14: build with flag. cannot use PROTOC_OPTIONS.
    # Ubuntu 22.04: v3.12.4 (2025/8/28)
    message(STATUS "Using manual protoc execution for proto3 optional (protobuf ${Protobuf_VERSION})")

    set(PROTO_SRCS)
    set(PROTO_HDRS)

    foreach(PROTO_FILE ${PROTO_FILES})
        get_filename_component(PROTO_NAME ${PROTO_FILE} NAME_WE)
        get_filename_component(PROTO_PATH ${PROTO_FILE} ABSOLUTE)
        set(PROTO_SRC "${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.cc")
        set(PROTO_HDR "${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.h")

        list(APPEND PROTO_SRCS ${PROTO_SRC})
        list(APPEND PROTO_HDRS ${PROTO_HDR})

        add_custom_command(
            OUTPUT ${PROTO_SRC} ${PROTO_HDR}
            COMMAND ${Protobuf_PROTOC_EXECUTABLE}
            ARGS --cpp_out=${CMAKE_CURRENT_BINARY_DIR}
                 --experimental_allow_proto3_optional
                 --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/../../protocol
                 ${CMAKE_CURRENT_SOURCE_DIR}/../../protocol/${PROTO_NAME}.proto
            DEPENDS ${PROTO_FILE}
            COMMENT "Generating C++ protobuf files from ${PROTO_FILE}"
            VERBATIM
        )
    endforeach()

    target_sources(fcitx5-hazkey PRIVATE ${PROTO_SRCS} ${PROTO_HDRS})
else()
    # ~ 3.12：no proto3 optional support
    message(FATAL_ERROR "protobuf 3.12+ required for proto3 optional support. Current version: ${Protobuf_VERSION}")
endif()

add_custom_target(hazkey-proto-headers
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/config.pb.h
            ${CMAKE_CURRENT_BINARY_DIR}/commands.pb.h
            ${CMAKE_CURRENT_BINARY_DIR}/base.pb.h
)

configure_file(hazkey_constants.h.in hazkey_constants.h @ONLY)

target_include_directories(fcitx5-hazkey PRIVATE ${CMAKE_CURRENT_BINARY_DIR} ${Protobuf_INCLUDE_DIRS})
target_link_libraries(fcitx5-hazkey PRIVATE Fcitx5::Core Fcitx5::Config ${Protobuf_LITE_LIBRARIES})

if(BUILD_TESTING)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(ProtobufLite REQUIRED IMPORTED_TARGET protobuf-lite)

    add_executable(live_convert_mode_test live_convert_mode_test.cpp live_convert_mode.cpp)
    target_include_directories(live_convert_mode_test PRIVATE ${CMAKE_CURRENT_BINARY_DIR} ${Protobuf_INCLUDE_DIRS})
    target_compile_options(live_convert_mode_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>
    )
    add_dependencies(live_convert_mode_test hazkey-proto-headers)
    add_test(NAME live_convert_mode_test COMMAND live_convert_mode_test)

    add_executable(hazkey_candidate_selection_test
        hazkey_candidate_selection_test.cpp hazkey_candidate.cpp)
    target_sources(hazkey_candidate_selection_test PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR}/base.pb.cc
        ${CMAKE_CURRENT_BINARY_DIR}/commands.pb.cc
        ${CMAKE_CURRENT_BINARY_DIR}/config.pb.cc)
    target_include_directories(hazkey_candidate_selection_test PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR} ${Protobuf_INCLUDE_DIRS})
    target_link_libraries(hazkey_candidate_selection_test PRIVATE
        Fcitx5::Core PkgConfig::ProtobufLite)
    target_compile_options(hazkey_candidate_selection_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_candidate_selection_test hazkey-proto-headers)
    add_test(NAME hazkey_candidate_selection_test
        COMMAND hazkey_candidate_selection_test)

    add_executable(hazkey_client_rpc_probe_test
        hazkey_client_rpc_probe_test.cpp hazkey_server_connector.cpp)
    target_sources(hazkey_client_rpc_probe_test PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR}/base.pb.cc
        ${CMAKE_CURRENT_BINARY_DIR}/commands.pb.cc
        ${CMAKE_CURRENT_BINARY_DIR}/config.pb.cc)
    target_include_directories(hazkey_client_rpc_probe_test PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR} ${Protobuf_INCLUDE_DIRS})
    target_link_libraries(hazkey_client_rpc_probe_test PRIVATE
        Fcitx5::Core PkgConfig::ProtobufLite)
    target_compile_options(hazkey_client_rpc_probe_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_client_rpc_probe_test hazkey-proto-headers)
    add_test(NAME hazkey_client_rpc_probe_test
        COMMAND hazkey_client_rpc_probe_test)

    add_executable(hazkey_client_cache_test
        hazkey_client_cache_test.cpp hazkey_server_connector.cpp)
    target_sources(hazkey_client_cache_test PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR}/base.pb.cc
        ${CMAKE_CURRENT_BINARY_DIR}/commands.pb.cc
        ${CMAKE_CURRENT_BINARY_DIR}/config.pb.cc)
    target_include_directories(hazkey_client_cache_test PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR} ${Protobuf_INCLUDE_DIRS})
    target_link_libraries(hazkey_client_cache_test PRIVATE
        Fcitx5::Core PkgConfig::ProtobufLite)
    target_compile_options(hazkey_client_cache_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_client_cache_test hazkey-proto-headers)
    add_test(NAME hazkey_client_cache_test
        COMMAND hazkey_client_cache_test)
endif()

set_target_properties(fcitx5-hazkey PROPERTIES PREFIX "")
install(TARGETS fcitx5-hazkey DESTINATION "${FCITX_INSTALL_LIBDIR}/fcitx5")

configure_file(hazkey-addon.conf.in.in hazkey-addon.conf.in @ONLY)
fcitx5_translate_desktop_file("${CMAKE_CURRENT_BINARY_DIR}/hazkey-addon.conf.in" "hazkey-addon.conf")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/hazkey-addon.conf" RENAME hazkey.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")

fcitx5_translate_desktop_file(hazkey-im.conf.in hazkey-im.conf)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/hazkey-im.conf" RENAME hazkey.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod")
