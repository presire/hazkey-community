# IBusエンジンバイナリとフロントエンドロジックのテスト
# fcitx5-hazkey/src/CMakeLists.txtと対応する構成で、このディレクトリが自ターゲットを持ち、
# 親がプロジェクト設定・共有トランスポート・component XML・GetTextカタログを持つ

# エンジン記述 (<icon>/<setup>)。設定コマンドは絶対パスにすること
# ibus-setupがos.spawnl()で起動し、PATH探索を行わないためである (絶対パスは、PATH探索ではなく、execv経由で直接解決される)
set(HAZKEY_ENGINE_ICON "hazkey-community")
set(HAZKEY_ENGINE_SETUP "${CMAKE_INSTALL_FULL_BINDIR}/hazkey-community-settings")
configure_file(engine_description.h.in
    ${CMAKE_CURRENT_BINARY_DIR}/engine_description.h
    @ONLY)

add_executable(ibus-engine-hazkey
    main.cpp
    hazkey_engine.cpp
    hazkey_state.cpp
    hazkey_ui.cpp
    hazkey_frontend.cpp
    live_convert_mode.cpp
    hazkey_frontend_glib.cpp
)
add_dependencies(ibus-engine-hazkey hazkey-proto-headers)

target_include_directories(ibus-engine-hazkey PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}
    ${IBUS_INCLUDE_DIRS}
)
target_link_libraries(ibus-engine-hazkey PRIVATE
    PkgConfig::IBUS
    hazkey-frontend-common
)

# libexec/ibus-hazkey-community配下にibus-engine-hazkey-communityとしてインストール
set_target_properties(ibus-engine-hazkey PROPERTIES
    OUTPUT_NAME ibus-engine-hazkey-community)
install(TARGETS ibus-engine-hazkey
    RUNTIME DESTINATION ${CMAKE_INSTALL_LIBEXECDIR}/ibus-hazkey-community)

# フロントエンドロジックのテスト
# IBusの候補インデックス対応付けについて、fcitx5-hazkey側のhazkey_candidate_selection_testと対応する
# hazkey_state.cppを直接リンクし (純粋なstaticマッパーのみを検証するため、エンジン生成もhazkey-serverへの接続も行わない)、
# 結合ビルドでfcitx5-hazkey-community側テストと衝突しないよう、ibus_接頭辞のCTest名を使用する
if(BUILD_TESTING)
    add_executable(ibus_hazkey_state_test
        hazkey_state_test.cpp
        hazkey_state.cpp
        hazkey_ui.cpp
        hazkey_frontend.cpp
        live_convert_mode.cpp
    )
    target_include_directories(ibus_hazkey_state_test PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${IBUS_INCLUDE_DIRS}
    )
    target_link_libraries(ibus_hazkey_state_test PRIVATE
        PkgConfig::IBUS
        hazkey-frontend-common
    )

    # テストは標準のassert()マクロで検証するため、このターゲットではNDEBUG (Release)を無効化しないと、全チェックがコンパイル時に除去されてしまう
    # fcitx5-hazkey側のテストターゲットと同様の措置
    target_compile_options(ibus_hazkey_state_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(ibus_hazkey_state_test hazkey-proto-headers)
    add_test(NAME ibus_hazkey_state_test COMMAND ibus_hazkey_state_test)
endif()
