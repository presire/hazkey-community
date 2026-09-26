cmake_minimum_required(VERSION 3.21)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. "
        "Please create a separate build directory and run cmake from there.\n"
        "To clean up, remove CMakeCache.txt and CMakeFiles/ directory.")
endif()

project(ibus-hazkey VERSION 0.2.31 LANGUAGES CXX)
include(GNUInstallDirs)
include(CTest)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(IBUS REQUIRED IMPORTED_TARGET ibus-1.0)

# 単体でCMake Configureした場合 (cmake -S ibus-hazkeyコマンド) は共有トランスポートライブラリを取り込む
# リポジトリルートからCMake Configureした場合は既に存在する
if(NOT TARGET hazkey-frontend-common)
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../hazkey-frontend-common"
        "${CMAKE_CURRENT_BINARY_DIR}/hazkey-frontend-common")
endif()

configure_file(ibus-hazkey-community.xml.in
    ${CMAKE_CURRENT_BINARY_DIR}/ibus-hazkey-community.xml
    @ONLY)

# "ibus-hazkey-community"ドメインのGetTextカタログ (エンジンの <longname>/<description>向け)
add_subdirectory(po)
add_subdirectory(src)

install(FILES ${CMAKE_CURRENT_BINARY_DIR}/ibus-hazkey-community.xml
    DESTINATION ${CMAKE_INSTALL_DATADIR}/ibus/component)
