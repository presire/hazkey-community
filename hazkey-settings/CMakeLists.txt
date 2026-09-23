cmake_minimum_required(VERSION 3.21)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. "
        "Please create a separate build directory and run cmake from there.\n"
        "To clean up, remove CMakeCache.txt and CMakeFiles/ directory.")
endif()

project(hazkey-settings VERSION 0.2.29 LANGUAGES CXX)

set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets LinguistTools Network)
find_package(Protobuf REQUIRED)

# Link protobuf-lite through pkg-config (same as hazkey-frontend-common): the
# FindProtobuf imported target omits abseil, which protobuf >= 22 headers call
# directly in Debug builds (ABSL_DCHECK -> absl_log_internal_check_op).
find_package(PkgConfig REQUIRED)
pkg_check_modules(ProtobufLite REQUIRED IMPORTED_TARGET protobuf-lite)

set(TS_FILES hazkey-settings_ja_JP.ts)

configure_file(constants.h.in constants.h @ONLY)

# Proto files
set(PROTO_FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/base.proto
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/commands.proto
    ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/config.proto
)

set(PROJECT_SOURCES
    main.cpp
    mainwindow.cpp
    mainwindow.h
    mainwindow.ui
    serverconnector.cpp
    serverconnector.h
    learninghistorydialog.cpp
    learninghistorydialog.h
    config_definitions.h
    config_macros.h
    keysequence_util.cpp
    keysequence_util.h
    zenzai_models.cpp
    zenzai_models.h
    zenzai_dialog_selection.cpp
    zenzai_dialog_selection.h
    zenzai_download_validation.cpp
    zenzai_download_validation.h
    zenzai_family_row.cpp
    zenzai_family_row.h
    userdict_model.cpp
    userdict_model.h
)

qt_add_executable(hazkey-settings ${PROJECT_SOURCES}
    hazkey-icon.qrc)
qt_create_translation(QM_FILES ${PROJECT_SOURCES} ${TS_FILES})

foreach(_qm ${QM_FILES})
    get_filename_component(_qm_name ${_qm} NAME)
    set_source_files_properties(${_qm} PROPERTIES QT_RESOURCE_ALIAS ${_qm_name})
endforeach()

qt_add_resources(hazkey-settings "translations"
    PREFIX "/i18n"
    FILES ${QM_FILES}
)

if(Protobuf_VERSION VERSION_GREATER_EQUAL "3.15")
    # 3.15 ~：stable proto3 optional support
    message(STATUS "Using standard protobuf_generate (protobuf ${Protobuf_VERSION})")
    protobuf_generate(
        TARGET hazkey-settings
        LANGUAGE cpp
        PROTOS ${PROTO_FILES}
        IMPORT_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/../protocol
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
                 --proto_path=${CMAKE_CURRENT_SOURCE_DIR}/../protocol
                 ${CMAKE_CURRENT_SOURCE_DIR}/../protocol/${PROTO_NAME}.proto
            DEPENDS ${PROTO_FILE}
            COMMENT "Generating C++ protobuf files from ${PROTO_FILE}"
            VERBATIM
        )
    endforeach()

    target_sources(hazkey-settings PRIVATE ${PROTO_SRCS} ${PROTO_HDRS})
else()
    # ~ 3.12：no proto3 optional support
    message(FATAL_ERROR "protobuf 3.12+ required for proto3 optional support. Current version: ${Protobuf_VERSION}")
endif()

target_include_directories(hazkey-settings PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${Protobuf_INCLUDE_DIRS}
)

target_link_libraries(hazkey-settings PRIVATE
    Qt6::Widgets
    Qt6::Network
    PkgConfig::ProtobufLite
)

include(GNUInstallDirs)
# Installed as hazkey-community-settings under ${LIBDIR}/hazkey-community so it
# can coexist with an upstream hazkey package.
set_target_properties(hazkey-settings PROPERTIES OUTPUT_NAME hazkey-community-settings)
install(TARGETS hazkey-settings
    RUNTIME DESTINATION ${CMAKE_INSTALL_FULL_LIBDIR}/hazkey-community
)

# install desktop entry
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/hazkey-community-settings.desktop"
    DESTINATION ${CMAKE_INSTALL_FULL_DATADIR}/applications)

# create a symlink in the binary directory
install(CODE "
    file(MAKE_DIRECTORY \"\$ENV{DESTDIR}${CMAKE_INSTALL_FULL_BINDIR}\")
    file(CREATE_LINK
    \"${CMAKE_INSTALL_FULL_LIBDIR}/hazkey-community/hazkey-community-settings\"
    \"\$ENV{DESTDIR}${CMAKE_INSTALL_FULL_BINDIR}/hazkey-community-settings\"
    SYMBOLIC)
")

# Tests
find_package(Qt6 REQUIRED COMPONENTS Test)
enable_testing()
qt_add_executable(zenzai_model_management_test
    zenzai_model_management_test.cpp
    zenzai_models.cpp
)
target_link_libraries(zenzai_model_management_test PRIVATE Qt6::Test Qt6::Core)
add_test(NAME zenzai_model_management_test COMMAND zenzai_model_management_test)

qt_add_executable(zenzai_dialog_selection_test
    zenzai_dialog_selection_test.cpp
    zenzai_dialog_selection.cpp
)
target_link_libraries(zenzai_dialog_selection_test PRIVATE Qt6::Test Qt6::Core)
add_test(NAME zenzai_dialog_selection_test COMMAND zenzai_dialog_selection_test)

qt_add_executable(zenzai_download_validation_test
    zenzai_download_validation_test.cpp
    zenzai_download_validation.cpp
)
target_link_libraries(zenzai_download_validation_test PRIVATE Qt6::Test Qt6::Core)
add_test(NAME zenzai_download_validation_test COMMAND zenzai_download_validation_test)

qt_add_executable(zenzai_family_row_test
    zenzai_family_row_test.cpp
    zenzai_family_row.cpp
    zenzai_models.cpp
)
target_link_libraries(zenzai_family_row_test PRIVATE Qt6::Test Qt6::Widgets)
add_test(NAME zenzai_family_row_test COMMAND zenzai_family_row_test)
set_tests_properties(zenzai_family_row_test PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)

qt_add_executable(keysequence_util_test
    keysequence_util_test.cpp
    keysequence_util.cpp
)
target_link_libraries(keysequence_util_test PRIVATE Qt6::Test Qt6::Gui)
add_test(NAME keysequence_util_test COMMAND keysequence_util_test)

qt_add_executable(userdict_model_test
    userdict_model_test.cpp
    userdict_model.cpp
)
target_link_libraries(userdict_model_test PRIVATE Qt6::Test Qt6::Core)
add_test(NAME userdict_model_test COMMAND userdict_model_test)

qt_add_executable(learninghistorydialog_test
    learninghistorydialog_test.cpp
    learninghistorydialog.cpp
    serverconnector.cpp
)
if(Protobuf_VERSION VERSION_GREATER_EQUAL "3.15")
    protobuf_generate(
        TARGET learninghistorydialog_test
        LANGUAGE cpp
        PROTOS ${PROTO_FILES}
        IMPORT_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/../protocol
        PROTOC_OUT_DIR ${CMAKE_CURRENT_BINARY_DIR}
    )
else()
    target_sources(learninghistorydialog_test PRIVATE ${PROTO_SRCS} ${PROTO_HDRS})
endif()
target_include_directories(learninghistorydialog_test PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${Protobuf_INCLUDE_DIRS}
)
target_link_libraries(learninghistorydialog_test PRIVATE
    Qt6::Test
    Qt6::Widgets
    Qt6::Network
    PkgConfig::ProtobufLite
)
target_compile_definitions(learninghistorydialog_test PRIVATE
    HAZKEY_SERVER_BINARY="${CMAKE_BINARY_DIR}/hazkey-server/swift-build/release/hazkey-server"
    HAZKEY_LLAMA_LIBRARY_DIR="${CMAKE_BINARY_DIR}/bin"
    HAZKEY_SOURCE_DIR="${CMAKE_SOURCE_DIR}"
)
add_dependencies(learninghistorydialog_test build_hazkey_server)
add_test(NAME learninghistorydialog_test COMMAND learninghistorydialog_test)
set_tests_properties(learninghistorydialog_test PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
)
