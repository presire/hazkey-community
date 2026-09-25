cmake_minimum_required(VERSION 3.21)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. "
        "Please create a separate build directory and run cmake from there.\n"
        "To clean up, remove CMakeCache.txt and CMakeFiles/ directory.")
endif()

project(hazkey VERSION 0.2.31)
include(GNUInstallDirs)
enable_testing()

set(CMAKE_SKIP_INSTALL_ALL_DEPENDENCY TRUE)

option(ENABLE_FCITX5 "Build Fcitx5 frontend" ON)
option(ENABLE_IBUS "Build IBus frontend" OFF)

# Shared transport + protobuf generation: required by both frontends.
add_subdirectory(hazkey-frontend-common)
add_subdirectory(hazkey-server)

if(ENABLE_FCITX5)
    add_subdirectory(fcitx5-hazkey)
endif()

if(ENABLE_IBUS)
    add_subdirectory(ibus-hazkey)
endif()

add_subdirectory(hazkey-settings)
