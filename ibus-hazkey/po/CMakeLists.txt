# 言語ごとの.poファイルを"ibus-hazkey-community" GetTextドメイン向けにコンパイルする
#
# IBusパネルはエンジンの<longname>をdgettext(engine_textdomain, longname)で翻訳する
# engine_textdomainは、"ibus-engine-hazkey-community --xml"が出力する<textdomain>要素である (src/main.cpp参照)
# 明示的なbindtextdomain()が無いドメインは、glibc/GLibが既定のロケールディレクトリを探索するため、
# .moを ${CMAKE_INSTALL_DATADIR}/locale/<lang>/LC_MESSAGES/ibus-hazkey-community.mo としてインストールするだけで足りる
#
# 言語一覧は、LINGUASに記載する (スペース区切りコードを1行以上、#以降はコメント)
# .poファイルは、LINGUASと同じディレクトリに配置する

include(GNUInstallDirs)
find_package(Gettext REQUIRED)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/LINGUAS" _ibus_hazkey_lingua_lines
     REGEX "^[^#]")
set(_ibus_hazkey_languages)
foreach(_line IN LISTS _ibus_hazkey_lingua_lines)
    string(STRIP "${_line}" _line)
    if(_line)
        separate_arguments(_langs UNIX_COMMAND "${_line}")
        list(APPEND _ibus_hazkey_languages ${_langs})
    endif()
endforeach()

set(_ibus_hazkey_mo_files)
foreach(_lang IN LISTS _ibus_hazkey_languages)
    set(_po "${CMAKE_CURRENT_SOURCE_DIR}/${_lang}.po")
    if(NOT EXISTS "${_po}")
        message(FATAL_ERROR "Missing translation file: ${_po}")
    endif()

    # コンパイル済み.moファイルは、ロケール名ではなくTextDomain (ibus-hazkey-community) 名にする必要があるため、
    # msgfmtの出力はインストール時にリネームする
    set(_gmo "${CMAKE_CURRENT_BINARY_DIR}/${_lang}.gmo")
    add_custom_command(
        OUTPUT "${_gmo}"
        COMMAND "${GETTEXT_MSGFMT_EXECUTABLE}" -o "${_gmo}" "${_po}"
        DEPENDS "${_po}"
        COMMENT "Compiling ${_lang}.po -> ibus-hazkey-community.mo"
        VERBATIM)
    install(FILES "${_gmo}"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/locale/${_lang}/LC_MESSAGES"
        RENAME "ibus-hazkey-community.mo")
    list(APPEND _ibus_hazkey_mo_files "${_gmo}")
endforeach()

# 通常ビルドでカタログもコンパイルされるようALLを付ける
# 上記のinstall()規則が生成直後の.gmoファイルを取り込む
add_custom_target(ibus-hazkey-translations ALL
    DEPENDS ${_ibus_hazkey_mo_files})
