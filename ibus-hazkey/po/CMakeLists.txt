# Compiles the per-language .po files into the "ibus-hazkey" gettext domain.
#
# The IBus panel translates an engine's <longname> with
# dgettext(engine_textdomain, longname); engine_textdomain is the <textdomain>
# element that `ibus-engine-hazkey --xml` emits (see src/main.cpp). glibc/GLib
# search the default locale directory for a domain that has no explicit
# bindtextdomain(), so installing the .mo under
# ${CMAKE_INSTALL_DATADIR}/locale/<lang>/LC_MESSAGES/ibus-hazkey.mo is enough.
#
# Languages are listed in ./LINGUAS (one or more space-separated codes, '#' for
# comments); the .po files live next to it.

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

    # The compiled .mo must be named after the textdomain ("ibus-hazkey"), not
    # after the locale, so the msgfmt output is renamed at install time.
    set(_gmo "${CMAKE_CURRENT_BINARY_DIR}/${_lang}.gmo")
    add_custom_command(
        OUTPUT "${_gmo}"
        COMMAND "${GETTEXT_MSGFMT_EXECUTABLE}" -o "${_gmo}" "${_po}"
        DEPENDS "${_po}"
        COMMENT "Compiling ${_lang}.po -> ibus-hazkey.mo"
        VERBATIM)
    install(FILES "${_gmo}"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/locale/${_lang}/LC_MESSAGES"
        RENAME "ibus-hazkey.mo")
    list(APPEND _ibus_hazkey_mo_files "${_gmo}")
endforeach()

# ALL so a normal build compiles the catalogs; the install() rules above then
# pick up the freshly generated .gmo files.
add_custom_target(ibus-hazkey-translations ALL
    DEPENDS ${_ibus_hazkey_mo_files})
