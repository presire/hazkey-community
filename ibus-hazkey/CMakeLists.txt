cmake_minimum_required(VERSION 3.21)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. "
        "Please create a separate build directory and run cmake from there.\n"
        "To clean up, remove CMakeCache.txt and CMakeFiles/ directory.")
endif()

project(ibus-hazkey VERSION 0.2.25 LANGUAGES CXX)
include(GNUInstallDirs)
include(CTest)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(IBUS REQUIRED IMPORTED_TARGET ibus-1.0)

# When configured standalone (cmake -S ibus-hazkey), pull in the shared
# transport library. When configured from the repo root it is already there.
if(NOT TARGET hazkey-frontend-common)
    add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../hazkey-frontend-common"
        "${CMAKE_CURRENT_BINARY_DIR}/hazkey-frontend-common")
endif()

configure_file(ibus-hazkey.xml.in
    ${CMAKE_CURRENT_BINARY_DIR}/ibus-hazkey.xml
    @ONLY)

# gettext catalogs for the "ibus-hazkey" domain (engine <longname>/<description>).
add_subdirectory(po)
add_subdirectory(src)

install(FILES ${CMAKE_CURRENT_BINARY_DIR}/ibus-hazkey.xml
    DESTINATION ${CMAKE_INSTALL_DATADIR}/ibus/component)
