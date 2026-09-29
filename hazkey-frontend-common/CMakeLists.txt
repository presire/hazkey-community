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

# 非同期通信基盤で使うstd::threadを検出する
find_package(Threads REQUIRED)

# protobuf-liteの依存ライブラリをpkg-config経由で取得する
find_package(PkgConfig REQUIRED)
pkg_check_modules(ProtobufLite REQUIRED IMPORTED_TARGET protobuf-lite)

set(PROTO_FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/base.proto
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/commands.proto
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/config.proto
)

# Fcitx 5とIBusで共有する通信ライブラリとフック実装
# protobuf生成は、このターゲットで1回のみ行う
add_library(hazkey-frontend-common STATIC
    hazkey_server_connector.cpp
    hazkey_frontend_hooks.cpp
    serial_task_executor.cpp
    composing_cursor_view.cpp
    candidate_annotation.cpp
)

if(Protobuf_VERSION VERSION_GREATER_EQUAL "3.15")
    # protobuf 3.15以降は標準のproto3 optional生成を使用する
    message(STATUS "Using standard protobuf_generate (protobuf ${Protobuf_VERSION})")
    protobuf_generate(
        TARGET hazkey-frontend-common
        LANGUAGE cpp
        PROTOS ${PROTO_FILES}
        IMPORT_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/../protocol
        PROTOC_OUT_DIR ${CMAKE_CURRENT_BINARY_DIR}
    )
elseif(Protobuf_VERSION VERSION_GREATER_EQUAL "3.12")
    # protobuf 3.12〜3.14はフラグ付きでprotocを直接実行する
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

# Fcitx 5の共有ライブラリへリンクするため、位置独立コードを有効にする
set_target_properties(hazkey-frontend-common PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# フロントエンドとC++テストへ生成ヘッダとprotobuf-liteを公開する
target_include_directories(hazkey-frontend-common PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}
    ${Protobuf_INCLUDE_DIRS}
)
target_link_libraries(hazkey-frontend-common PUBLIC PkgConfig::ProtobufLite)
# 静的ライブラリの利用側にもスレッドライブラリをリンクする
target_link_libraries(hazkey-frontend-common PUBLIC Threads::Threads)

# 共通通信層のテスト
# IBus単独ビルドでも実行できるよう、このディレクトリで登録する
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

    add_executable(hazkey_client_config_revision_test
        hazkey_client_config_revision_test.cpp)
    target_link_libraries(hazkey_client_config_revision_test PRIVATE
        hazkey-frontend-common)
    target_compile_options(hazkey_client_config_revision_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_client_config_revision_test hazkey-proto-headers)
    add_test(NAME hazkey_client_config_revision_test
        COMMAND hazkey_client_config_revision_test)

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

    # 両フロントエンドが共有する組成カーソル表示規則のテスト
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

    # IBusのキー処理をブロックさせない非同期通信基盤のテスト
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
