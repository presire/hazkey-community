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

# 共有トランスポート + protobuf生成: 両フロントエンドで必須
add_subdirectory(hazkey-frontend-common)
add_subdirectory(hazkey-server)

if(ENABLE_FCITX5)
    add_subdirectory(fcitx5-hazkey)
endif()

if(ENABLE_IBUS)
    add_subdirectory(ibus-hazkey)
endif()

add_subdirectory(hazkey-settings)

# --- ライセンス表示 ---
# プロジェクトのLICENSEとサードパーティのライセンス表示を、全てのパッケージに同梱する
# 頒布されるパッケージは、MIT / Apache-2.0 / BSDのSwiftパッケージを静的にリンクし、llama.cppランタイムを同梱し、
# 辞書データ (Apache-2.0 / Unicode / CC BY-SA 4.0) を頒布するため、いずれもバイナリ再頒布に著作権表示とライセンス全文の添付が必要となる
# share/hazkey-community/配下にインストールすることにより、そのディレクトリを丸ごとコピーするIBusパッケージング工程でも、両フロントエンドのパッケージに含まれる
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/LICENSE
        DESTINATION ${CMAKE_INSTALL_DATADIR}/hazkey-community)
install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/ThirdPartyLicenses/
        DESTINATION ${CMAKE_INSTALL_DATADIR}/hazkey-community/ThirdPartyLicenses)
