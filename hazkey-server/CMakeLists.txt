cmake_minimum_required(VERSION 3.21)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. "
        "Please create a separate build directory and run cmake from there.\n"
        "To clean up, remove CMakeCache.txt and CMakeFiles/ directory.")
endif()

project(hazkey-server VERSION 0.2.31)
include(GNUInstallDirs)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
# Swiftの権限問題を避けるため、インストール時にALLターゲットをスキップする
set(CMAKE_SKIP_INSTALL_ALL_DEPENDENCY TRUE)

find_program(SWIFT_EXECUTABLE swift REQUIRED)

option(HAZKEY_SERVER_STATIC_SWIFT_STDLIB "Statically link swift standard libraries" ON)

option(HAZKEY_SERVER_ENABLE_ZENZAI "Enable Zenzai AI features" ON)
option(HAZKEY_SERVER_BUILD_LLAMA_LIBS "Build llama.cpp libraries" ${HAZKEY_SERVER_ENABLE_ZENZAI})
option(HAZKEY_SERVER_INSTALL_LLAMA_LIBS "Install llama.cpp libraries" ${HAZKEY_SERVER_BUILD_LLAMA_LIBS})
option(HAZKEY_SERVER_ZENZAI_TRAIT "Enable Zenzai trait in AzooKeyKanaKanjiConverter" ${HAZKEY_SERVER_ENABLE_ZENZAI})

set(HAZKEY_SERVER_SYSTEM_RESOURCE_PATH "${CMAKE_INSTALL_FULL_DATADIR}" CACHE PATH "System Resource path")
set(HAZKEY_SERVER_SYSTEM_LIBRARY_PATH "${CMAKE_INSTALL_FULL_LIBDIR}" CACHE PATH "System Resource path")
option(HAZKEY_SERVER_INSTALL_DICTIONARY "Install dictionary" ON)

# TODO: パスの信頼性を確認する
set(HAZKEY_SERVER_LIBLLAMA_BINDIR "${CMAKE_BINARY_DIR}/bin" CACHE PATH "Llama.cpp library directory" )

# --- hazkey-server --- #

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(_DEFAULT_SWIFT_TYPE "debug")
else()
    set(_DEFAULT_SWIFT_TYPE "release")
endif()
set(SWIFT_BUILD_TYPE "${_DEFAULT_SWIFT_TYPE}" CACHE STRING "Swift build type (debug/release)")

message(STATUS "Configuring constants.swift")
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/Sources/hazkey-server/constants.swift.in
    ${CMAKE_CURRENT_SOURCE_DIR}/Sources/hazkey-server/constants.swift
    @ONLY
)

# Swiftライブラリのパスを自動検出する
# "swiftlang/swift#78003"を回避するため
if(HAZKEY_SERVER_STATIC_SWIFT_STDLIB AND NOT SWIFT_DYNAMIC_LIB_PATH)
    if(SWIFT_EXECUTABLE)
        get_filename_component(SWIFT_REAL_PATH "${SWIFT_EXECUTABLE}" REALPATH)

        if("${SWIFT_REAL_PATH}" MATCHES "/bin/swift[^/]*$")
            get_filename_component(SWIFT_BIN_DIR "${SWIFT_REAL_PATH}" DIRECTORY)
            get_filename_component(SWIFT_BASE_DIR "${SWIFT_BIN_DIR}" DIRECTORY)

            set(SWIFT_DYNAMIC_LIB_PATH "${SWIFT_BASE_DIR}/lib/swift/linux")
            message(STATUS "Detected Swift dynamic library path: ${SWIFT_DYNAMIC_LIB_PATH}")
        else()
            message(WARNING "Unexpected swift path structure: ${SWIFT_REAL_PATH}")
        endif()
    else()
        message(WARNING "Swift executable not found in PATH.")
    endif()
endif()

add_custom_target(build_hazkey_server ALL
    COMMAND ${CMAKE_COMMAND}
        "-DSWIFT_BUILD_TYPE=${SWIFT_BUILD_TYPE}"
        "-DSWIFT_EXECUTABLE=${SWIFT_EXECUTABLE}"
        "-DSWIFT_STATIC_STDLIB=${HAZKEY_SERVER_STATIC_SWIFT_STDLIB}"
        "-DSWIFT_DISABLE_DEPENDENCY_CACHE=${SWIFT_DISABLE_DEPENDENCY_CACHE}"
        "-DSWIFT_DYNAMIC_LIB_PATH=${SWIFT_DYNAMIC_LIB_PATH}"
        "-DSWIFT_LINK_PATH=${SWIFT_LINK_PATH}"
        "-DSWIFT_WORK_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
        "-DHAZKEY_SERVER_ZENZAI_TRAIT=${HAZKEY_SERVER_ZENZAI_TRAIT}"
        "-DLIBLLAMA_DIR=${HAZKEY_SERVER_LIBLLAMA_BINDIR}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/build_swift.cmake"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    COMMENT "Building hazkey-server"
    VERBATIM
)


# ----- llama.cpp ----- #
if(HAZKEY_SERVER_BUILD_LLAMA_LIBS)
    if(CMAKE_BUILD_TYPE STREQUAL "Release")
        set(GGML_LTO ON CACHE BOOL "")
    endif()

    # バックエンドDSOは、主要なllama.cppライブラリの1つ下のディレクトリにインストールする
    set(CMAKE_INSTALL_RPATH "$ORIGIN;$ORIGIN/..")
    set(CMAKE_BUILD_WITH_INSTALL_RPATH ON)
    set(CMAKE_SKIP_BUILD_RPATH OFF)

    set(BUILD_SHARED_LIBS ON CACHE BOOL "")
    set(LLAMA_STANDALONE OFF CACHE BOOL "")
    set(GGML_NATIVE OFF CACHE BOOL "")
    set(GGML_BACKEND_DL ON CACHE BOOL "")
    set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "")
    set(GGML_CPU ON CACHE BOOL "")

    # GGML_VULKAN: Zenzaiニューラル変換用のVulkanバックエンド
    # 既定は有効 (LinuxでGPUアクセラレーションを使用する場合に必要)
    # CPU専用ビルドを希望する場合 (例: ハイブリッドGPUシステムでの複数ICDによるSIGILL問題を避ける場合) は、
    # 設定時に"-DGGML_VULKAN=OFF"オプションを指定できる
    option(GGML_VULKAN "Build llama.cpp with Vulkan backend (CPU-only build: -DGGML_VULKAN=OFF)" ON)
    set(GGML_CUDA OFF CACHE BOOL "")
    set(GGML_HIP OFF CACHE BOOL "")
    set(CMAKE_SKIP_BUILD_RPATH ON CACHE BOOL "")

    add_subdirectory(llama.cpp EXCLUDE_FROM_ALL)

    add_dependencies(build_hazkey_server llama)
endif()

# ---- インストール ---- #

# hazkey-serverをインストールする
# Hazkey Communityは上流版と共存できるように、独自の名前 ("${LIBDIR}/hazkey-community"のhazkey-community-server) でインストールする
# SwiftPM productは、"hazkey-server"の名前を維持し、インストールされるファイルだけをリネームする
install(PROGRAMS ${CMAKE_CURRENT_BINARY_DIR}/swift-build/${SWIFT_BUILD_TYPE}/hazkey-server
        DESTINATION ${CMAKE_INSTALL_FULL_LIBDIR}/hazkey-community
        RENAME hazkey-community-server)

# hazkey-community-serverのラッパースクリプトを設定してインストールする
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/hazkey-server.sh.in
    ${CMAKE_CURRENT_BINARY_DIR}/hazkey-community-server
    @ONLY
)

install(PROGRAMS ${CMAKE_CURRENT_BINARY_DIR}/hazkey-community-server
        DESTINATION ${CMAKE_INSTALL_FULL_BINDIR})

# 手動データ移行スクリプトをインストールする
install(PROGRAMS ${CMAKE_CURRENT_SOURCE_DIR}/hazkey-community-migrate.sh
        DESTINATION ${CMAKE_INSTALL_FULL_DATADIR}/hazkey-community)

# llama.cppライブラリをインストールする
if(HAZKEY_SERVER_INSTALL_LLAMA_LIBS)
    # llama.cppライブラリのビルドは、これらのライブラリにSOVERSIONを設定するため、
    # HAZKEY_SERVER_LIBLLAMA_BINDIR内の各*.soファイル名はシンボリックリンクの連鎖になる
    # (例: libllama.so -> libllama.so.0 -> libllama.so.0.0.7771)
    #
    # install(FILES)には連鎖をたどるオプションがないため、最上位のシンボリックリンクだけをコピーする
    # 結果として、インストールしたリンクは宙に浮き (.so.Nの対象がインストールされない)、
    # hazkey-serverは、"error while loading shared libraries: libllama.so.0: cannot open shared object file"で起動に失敗する
    # インストール時に、"install(CODE ...)"経由で実行する"file(COPY ... FOLLOW_SYMLINK_CHAIN)"は、連鎖全体 (全ての中間リンクと最終的な実ファイル) をインストールする
    #
    # また、これらのパスがリンクではなく通常ファイルである場合は何もしない
    #
    # 注記:
    # install(CODE ...) は、インストール時に生のCMakeスクリプトを実行するため、$ENV{DESTDIR} は設定時ではなくインストール時に展開されるよう、
    # \$ENV{DESTDIR} (エスケープ付き) として参照する必要がある
    # DESTDIR接頭辞が無いと、file(COPY ... DESTINATION "/usr/...") はステージングツリーではなく、ビルドホストの/usrへ書き込む
    # その結果、ステージング済みパッケージには主要な3ライブラリが含まれずに欠落する (leap16 RPM の自己依存関係エラー: 'libggml-base.so.0()(64bit)' unmet)
    # 下記の install(DIRECTORY ...) は、自動的にDESTDIRを認識するため、この処理は不要である
    install(CODE "
        foreach(_llama_lib libggml-base.so libggml.so libllama.so)
            if(NOT EXISTS \"${HAZKEY_SERVER_LIBLLAMA_BINDIR}/\${_llama_lib}\")
                message(FATAL_ERROR \"Missing llama library: ${HAZKEY_SERVER_LIBLLAMA_BINDIR}/\${_llama_lib} (HAZKEY_SERVER_LIBLLAMA_BINDIR wrong or llama build failed)\")
            endif()
        endforeach()
        file(MAKE_DIRECTORY \"\$ENV{DESTDIR}${CMAKE_INSTALL_FULL_LIBDIR}/hazkey-community/libllama\")
        file(COPY
            \"${HAZKEY_SERVER_LIBLLAMA_BINDIR}/libggml-base.so\"
            \"${HAZKEY_SERVER_LIBLLAMA_BINDIR}/libggml.so\"
            \"${HAZKEY_SERVER_LIBLLAMA_BINDIR}/libllama.so\"
            DESTINATION \"\$ENV{DESTDIR}${CMAKE_INSTALL_FULL_LIBDIR}/hazkey-community/libllama\"
            FOLLOW_SYMLINK_CHAIN
        )
    ")

    install(DIRECTORY "${HAZKEY_SERVER_LIBLLAMA_BINDIR}/"
        DESTINATION "${CMAKE_INSTALL_FULL_LIBDIR}/hazkey-community/libllama/backends"
        FILES_MATCHING
        PATTERN "*.so"
        PATTERN "libggml-base.so" EXCLUDE
        PATTERN "libggml.so" EXCLUDE
        PATTERN "libllama.so" EXCLUDE
    )
endif()

# アイコンをインストールする
# Hazkey Communityは、上流版とは異なり、独自のアイコンテーマ名 (hazkey-community) を使用する
# これにより、古いアイコンキャッシュや上流パッケージがアイコンを上書きすることを防ぐ
# fcitx5-hazkey/src/hazkey-im.conf.in、fcitx5-hazkey/src/hazkey-addon.conf.in.in、hazkey-settings/hazkey-settings.desktopの"Icon="、
# "ibus-hazkey/src/CMakeLists.txt"の"HAZKEY_ENGINE_ICON"から参照される
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/icons/hazkey-community.svg
        DESTINATION ${CMAKE_INSTALL_FULL_DATADIR}/icons/hicolor/scalable/apps)
foreach(_icon_size 512 256 48 32 24)
    install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/icons/hazkey-community_${_icon_size}x${_icon_size}.png
            RENAME hazkey-community.png
            DESTINATION ${CMAKE_INSTALL_FULL_DATADIR}/icons/hicolor/${_icon_size}x${_icon_size}/apps)
endforeach()

# 辞書をインストールする
if(HAZKEY_SERVER_INSTALL_DICTIONARY)

    set(_OLD_INSTALL_MESSAGE ${CMAKE_INSTALL_MESSAGE})
    if(NOT CMAKE_INSTALL_MESSAGE)
        set(CMAKE_INSTALL_MESSAGE "LAZY")
    endif()

    install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/azooKey_dictionary_storage/Dictionary
        DESTINATION ${CMAKE_INSTALL_FULL_DATADIR}/hazkey-community)

    set(CMAKE_INSTALL_MESSAGE ${_OLD_INSTALL_MESSAGE})
endif()

# 絵文字辞書をインストールする
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/azooKey_emoji_dictionary_storage/EmojiDictionary/emoji_all_E17.0.txt
        DESTINATION ${CMAKE_INSTALL_FULL_DATADIR}/hazkey-community)

# 住所辞書をインストールする（補助LOUDS、コミュニティ拡張）
set(HAZKEY_ADDRESS_DICTIONARY_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}/../hazkey-address-dictionary/AddressDictionary)
if(EXISTS ${HAZKEY_ADDRESS_DICTIONARY_DIR}/louds/charID.chid)
    install(DIRECTORY ${HAZKEY_ADDRESS_DICTIONARY_DIR}
        DESTINATION ${CMAKE_INSTALL_FULL_DATADIR}/hazkey-community)
else()
    message(WARNING
        "hazkey-address-dictionary submodule is not checked out; "
        "the address dictionary will not be installed. "
        "Run: git submodule update --init hazkey-address-dictionary")
endif()

# 工学用語辞書をインストールする（補助LOUDS、コミュニティ拡張）
set(HAZKEY_ENGINEERING_DICTIONARY_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}/../hazkey-engineering-dictionary/EngineeringDictionary)
if(EXISTS ${HAZKEY_ENGINEERING_DICTIONARY_DIR}/louds/charID.chid)
    install(DIRECTORY ${HAZKEY_ENGINEERING_DICTIONARY_DIR}
        DESTINATION ${CMAKE_INSTALL_FULL_DATADIR}/hazkey-community)
else()
    message(WARNING
        "hazkey-engineering-dictionary submodule is not checked out; "
        "the engineering terms dictionary will not be installed. "
        "Run: git submodule update --init hazkey-engineering-dictionary")
endif()
