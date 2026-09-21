cmake_minimum_required(VERSION 3.21)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. "
        "Please create a separate build directory and run cmake from there.\n"
        "To clean up, remove CMakeCache.txt and CMakeFiles/ directory.")
endif()

project(hazkey-frontend-common LANGUAGES CXX)
include(GNUInstallDirs)
include(CTest)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Protobuf REQUIRED)

# std::thread-based async transport foundation (serial_task_executor.cpp).
find_package(Threads REQUIRED)

# protobuf-lite's real link closure (abseil, utf8_range, ...) comes from
# pkg-config; the bare Protobuf_LITE_LIBRARIES variable is not enough for
# executables that instantiate protobuf inline code.
find_package(PkgConfig REQUIRED)
pkg_check_modules(ProtobufLite REQUIRED IMPORTED_TARGET protobuf-lite)

set(PROTO_FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/base.proto
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/commands.proto
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/config.proto
)

# Shared, framework-independent transport (UNIX socket framing, timeout,
# reconnect, read-through cache, all RPC wrappers) plus the frontend hook
# injection points. Both the fcitx5 and the IBus frontends link this; protobuf
# generation lives here so it is produced exactly once.
add_library(hazkey-frontend-common STATIC
    hazkey_server_connector.cpp
    hazkey_frontend_hooks.cpp
    serial_task_executor.cpp
    composing_cursor_view.cpp
)

if(Protobuf_VERSION VERSION_GREATER_EQUAL "3.15")
    # 3.15 ~：stable proto3 optional support
    message(STATUS "Using standard protobuf_generate (protobuf ${Protobuf_VERSION})")
    protobuf_generate(
        TARGET hazkey-frontend-common
        LANGUAGE cpp
        PROTOS ${PROTO_FILES}
        IMPORT_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/../protocol
        PROTOC_OUT_DIR ${CMAKE_CURRENT_BINARY_DIR}
    )
elseif(Protobuf_VERSION VERSION_GREATER_EQUAL "3.12")
    # 3.12 ~ 3.14: build with flag. cannot use PROTOC_OPTIONS.
    message(STATUS "Using manual protoc execution for proto3 optional (protobuf ${Protobuf_VERSION})")

    set(PROTO_SRCS)
    set(PROTO_HDRS)

    foreach(PROTO_FILE ${PROTO_FILES})
        get_filename_component(PROTO_NAME ${PROTO_FILE} NAME_WE)
        set(PROTO_SRC "${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.cc")
        set(PROTO_HDR "${CMAKE_CURRENT_BINARY_DIR}/${PROTO_NAME}.pb.h")

        list(APPEND PROTO_SRCS ${PROTO_SRC})
        list(APPEND PROTO_HDRS ${PROTO_HDR})

        add_custom_command(
            OUTPUT ${PROTO_SRC} ${PROTO_HDR}
            COMMAND ${Protobuf_PROTOC_EXECUTABLE}
            ARGS --cpp_out=${CMAKE_CURRENT_BINARY_DIR}
                 --experimental_allow_proto3_optional
                 --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/../protocol
                 ${PROTO_FILE}
            DEPENDS ${PROTO_FILE}
            COMMENT "Generating C++ protobuf files from ${PROTO_FILE}"
            VERBATIM
        )
    endforeach()

    target_sources(hazkey-frontend-common PRIVATE ${PROTO_SRCS} ${PROTO_HDRS})
else()
    message(FATAL_ERROR "protobuf 3.12+ required for proto3 optional support. Current version: ${Protobuf_VERSION}")
endif()

add_custom_target(hazkey-proto-headers
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/config.pb.h
            ${CMAKE_CURRENT_BINARY_DIR}/commands.pb.h
            ${CMAKE_CURRENT_BINARY_DIR}/base.pb.h
)

# The fcitx5 frontend is a shared library, so this static library must be
# position independent.
set_target_properties(hazkey-frontend-common PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# PUBLIC: frontends and the C++ tests include the generated *.pb.h and
# hazkey_frontend_hooks.h, and need protobuf-lite at link time.
target_include_directories(hazkey-frontend-common PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}
    ${Protobuf_INCLUDE_DIRS}
)
target_link_libraries(hazkey-frontend-common PUBLIC PkgConfig::ProtobufLite)
# PUBLIC: the static library uses std::thread, so every consumer must link
# pthread too.
target_link_libraries(hazkey-frontend-common PUBLIC Threads::Threads)

# Shared-transport tests. These exercise only hazkey-frontend-common (UNIX
# socket framing, timeouts/reconnect, read-through cache, RPC round trips), so
# they are registered here rather than in a frontend. That way they run in
# every configuration -- including an IBus-only build with
# -DENABLE_FCITX5=OFF, where fcitx5-hazkey (and any tests registered there) is
# not built. The CTest names are preserved from their previous fcitx5-hazkey
# registration.
if(BUILD_TESTING)
    add_executable(hazkey_client_rpc_probe_test
        hazkey_client_rpc_probe_test.cpp)
    target_link_libraries(hazkey_client_rpc_probe_test PRIVATE
        hazkey-frontend-common)
    target_compile_options(hazkey_client_rpc_probe_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_client_rpc_probe_test hazkey-proto-headers)
    add_test(NAME hazkey_client_rpc_probe_test
        COMMAND hazkey_client_rpc_probe_test)

    add_executable(hazkey_client_cache_test
        hazkey_client_cache_test.cpp)
    target_link_libraries(hazkey_client_cache_test PRIVATE
        hazkey-frontend-common)
    target_compile_options(hazkey_client_cache_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_client_cache_test hazkey-proto-headers)
    add_test(NAME hazkey_client_cache_test
        COMMAND hazkey_client_cache_test)

    add_executable(hazkey_client_transact_safety_test
        hazkey_client_transact_safety_test.cpp)
    target_link_libraries(hazkey_client_transact_safety_test PRIVATE
        hazkey-frontend-common)
    target_compile_options(hazkey_client_transact_safety_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_client_transact_safety_test hazkey-proto-headers)
    add_test(NAME hazkey_client_transact_safety_test
        COMMAND hazkey_client_transact_safety_test)

    # Shared composition-cursor presentation rules (live-conversion pause mode
    # decision, caret byte/character offsets, aux-text gate). Both frontends
    # call these, so the test belongs here and must run in an IBus-only build
    # as well.
    add_executable(hazkey_composing_cursor_view_test
        composing_cursor_view_test.cpp)
    target_link_libraries(hazkey_composing_cursor_view_test PRIVATE
        hazkey-frontend-common)
    target_compile_options(hazkey_composing_cursor_view_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_composing_cursor_view_test hazkey-proto-headers)
    add_test(NAME hazkey_composing_cursor_view_test
        COMMAND hazkey_composing_cursor_view_test)

    # Async transport foundation: SerialTaskExecutor + the main-loop post hook
    # that the IBus frontend uses to keep process_key_event non-blocking.
    add_executable(hazkey_frontend_async_test
        hazkey_frontend_async_test.cpp)
    target_link_libraries(hazkey_frontend_async_test PRIVATE
        hazkey-frontend-common)
    target_compile_options(hazkey_frontend_async_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_frontend_async_test hazkey-proto-headers)
    add_test(NAME hazkey_frontend_async_test
        COMMAND hazkey_frontend_async_test)
endif()
