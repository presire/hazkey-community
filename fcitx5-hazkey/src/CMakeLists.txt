add_library(fcitx5-hazkey SHARED
    hazkey_state.cpp
    hazkey_engine.cpp
    hazkey_candidate.cpp
    hazkey_preedit.cpp
    hazkey_frontend_adapter.cpp
    live_convert_mode.cpp
)

# protobuf生成はhazkey-frontend-commonへ移して、両フロントエンドで1度だけ行う
# fcitx5-hazkey-communityは、そのライブラリをリンクする
# hazkey_constants.hには、アドオンのPROJECT_VERSIONを埋め込むため、ここで生成する
configure_file(hazkey_constants.h.in hazkey_constants.h @ONLY)

target_include_directories(fcitx5-hazkey PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(fcitx5-hazkey PRIVATE hazkey-frontend-common Fcitx5::Core Fcitx5::Config)

# Instance::showCustomInputMethodInformation()は、Fcitx 5.1.11以降で利用できる
# 古いバージョン (Ubuntu 24.04は5.1.7) でもビルドできるよう、Zenzai切替通知はAPIが利用可能な場合だけコンパイルする
if(Fcitx5Core_VERSION VERSION_GREATER_EQUAL "5.1.11")
    target_compile_definitions(fcitx5-hazkey PRIVATE
        HAZKEY_HAS_SHOW_CUSTOM_IM_INFO=1)
endif()

if(BUILD_TESTING)
    add_executable(live_convert_mode_test live_convert_mode_test.cpp live_convert_mode.cpp)
    target_link_libraries(live_convert_mode_test PRIVATE hazkey-frontend-common)
    target_compile_options(live_convert_mode_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>
    )
    add_dependencies(live_convert_mode_test hazkey-proto-headers)
    add_test(NAME live_convert_mode_test COMMAND live_convert_mode_test)

    add_executable(candidate_refresh_coalescer_test
        candidate_refresh_coalescer_test.cpp)
    # 間引きポリシーのヘッダーはIBus版と共通のhazkey-frontend-commonに配置する
    # リンク時にインクルードディレクトリも追加される
    target_link_libraries(candidate_refresh_coalescer_test PRIVATE
        hazkey-frontend-common)
    target_compile_options(candidate_refresh_coalescer_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>
    )
    add_test(NAME candidate_refresh_coalescer_test
        COMMAND candidate_refresh_coalescer_test)

    add_executable(hazkey_candidate_selection_test
        hazkey_candidate_selection_test.cpp hazkey_candidate.cpp)
    target_link_libraries(hazkey_candidate_selection_test PRIVATE
        Fcitx5::Core hazkey-frontend-common)
    target_compile_options(hazkey_candidate_selection_test PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-UNDEBUG>
        $<$<CXX_COMPILER_ID:MSVC>:/UNDEBUG>)
    add_dependencies(hazkey_candidate_selection_test hazkey-proto-headers)
    add_test(NAME hazkey_candidate_selection_test
        COMMAND hazkey_candidate_selection_test)

    # 共通トランスポートのテストはhazkey-frontend-common/CMakeLists.txtで登録する
    # fcitx5-hazkey-communityを無効にしてこのディレクトリを追加しないIBus単独ビルドでも実行する
endif()

# fcitx5-hazkey-community.soとしてインストールして、アドオン名をhazkey-communityとする
# 上流版のfcitx5-hazkeyパッケージと共存できるようにする
set_target_properties(fcitx5-hazkey PROPERTIES PREFIX "" OUTPUT_NAME fcitx5-hazkey-community)
install(TARGETS fcitx5-hazkey DESTINATION "${FCITX_INSTALL_LIBDIR}/fcitx5")

configure_file(hazkey-addon.conf.in.in hazkey-addon.conf.in @ONLY)
fcitx5_translate_desktop_file("${CMAKE_CURRENT_BINARY_DIR}/hazkey-addon.conf.in" "hazkey-addon.conf")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/hazkey-addon.conf" RENAME hazkey-community.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon")

fcitx5_translate_desktop_file(hazkey-im.conf.in hazkey-im.conf)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/hazkey-im.conf" RENAME hazkey-community.conf DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod")
