cmake_minimum_required(VERSION 3.21)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. "
        "Please create a separate build directory and run cmake from there.\n"
        "To clean up, remove CMakeCache.txt and CMakeFiles/ directory.")
endif()

project(hazkey VERSION 0.2.18)
include(GNUInstallDirs)
enable_testing()

set(CMAKE_SKIP_INSTALL_ALL_DEPENDENCY TRUE)

add_subdirectory(fcitx5-hazkey)
add_subdirectory(hazkey-server)
add_subdirectory(hazkey-settings)
