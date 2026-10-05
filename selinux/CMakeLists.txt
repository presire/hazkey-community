# Hazkey CommunityのSELinuxポリシーモジュールのビルド設定
#
# トップレベルのCMakeLists.txtで-DENABLE_SELINUX=ONを指定した場合だけ読み込まれる

########################################
# ツールの検出
########################################

find_program(CHECKMODULE checkmodule)
find_program(SEMODULE_PACKAGE semodule_package)
find_program(SEMODULE semodule PATHS /usr/sbin /sbin)
find_program(RESTORECON restorecon PATHS /usr/sbin /sbin)

if(NOT CHECKMODULE OR NOT SEMODULE_PACKAGE)
    message(WARNING "SELinux policy tools not found (checkmodule, semodule_package).")
    message(WARNING "SELinux policy module will not be built.")
    message(WARNING "To install tools on openSUSE: zypper install selinux-policy-devel")
    message(WARNING "To install tools on RHEL/Fedora: dnf install selinux-policy-devel checkpolicy")
    return()
endif()

########################################
# ポリシーモジュールの設定
########################################

set(POLICY_NAME hazkey_community)
set(POLICY_VERSION 1.0.0)

message(STATUS "Building SELinux policy module: ${POLICY_NAME} (version ${POLICY_VERSION})")

########################################
# ポリシーソースの型名の系統
#
# hazkey_community.teは、Fedora / RHEL / openSUSEのポリシーの型名 (config_home_t等) で書かれている
# Debian 13とUbuntu 26.04はupstream Reference Policyの型名 (xdg_config_t等) を使うため、
# hazkey_community_refpolicy.awkで型名を置き換えてからビルドする
#
#   auto      ビルド環境のポリシーから判定する (xdg_config_tがあればrefpolicy、それ以外はredhat)
#   redhat    Fedora / RHEL / openSUSE向け
#   refpolicy Debian / Ubuntu向け
#
# 別のディストリビューション向けに、ビルド環境と異なる系統の.ppを作る場合は明示的に指定する
########################################

set(HAZKEY_SELINUX_POLICY_FLAVOR "auto" CACHE STRING "Type name flavor of the SELinux policy: auto, redhat or refpolicy")
set_property(CACHE HAZKEY_SELINUX_POLICY_FLAVOR PROPERTY STRINGS auto redhat refpolicy)

set(_hz_flavor "${HAZKEY_SELINUX_POLICY_FLAVOR}")
if(_hz_flavor STREQUAL "auto")
    set(_hz_flavor "redhat")
    file(GLOB _hz_homedirs_files "/etc/selinux/*/contexts/files/file_contexts.homedirs")
    foreach(_hz_file IN LISTS _hz_homedirs_files)
        file(STRINGS "${_hz_file}" _hz_xdg_lines REGEX "xdg_config_t" LIMIT_COUNT 1)
        if(_hz_xdg_lines)
            set(_hz_flavor "refpolicy")
            break()
        endif()
    endforeach()
    # 判定には、ビルドを実行する環境の/etc/selinux配下を使う
    # パッケージ作成用のコンテナ (/etc/selinuxが無い環境) やクロスビルドでは判定できないため、系統を明示する
    if(NOT _hz_homedirs_files)
        message(WARNING "SELinux policy: no SELinux policy found under /etc/selinux, assuming the redhat flavor. "
                        "Specify -DHAZKEY_SELINUX_POLICY_FLAVOR=refpolicy for Debian / Ubuntu.")
    endif()
elseif(NOT _hz_flavor STREQUAL "redhat" AND NOT _hz_flavor STREQUAL "refpolicy")
    message(FATAL_ERROR "SELinux policy: HAZKEY_SELINUX_POLICY_FLAVOR must be auto, redhat or refpolicy: ${_hz_flavor}")
endif()
message(STATUS "SELinux policy flavor: ${_hz_flavor}")

# モジュールのソース (checkmoduleへ渡すファイル)
# refpolicyの場合は、型名を置き換えたファイルをビルド用ディレクトリへ生成する
# checkmoduleは、モジュール名と出力ファイル名の一致を要求するため、ファイル名はhazkey_community.teのままにする
set(HAZKEY_SELINUX_TE "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}.te")
set(HAZKEY_SELINUX_IF "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}.if")
if(_hz_flavor STREQUAL "refpolicy")
    find_program(AWK awk)
    if(NOT AWK)
        message(FATAL_ERROR "SELinux policy: awk is required for the refpolicy flavor.")
    endif()
    set(HAZKEY_SELINUX_TE "${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.te")
    execute_process(
        COMMAND ${AWK} -f "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}_refpolicy.awk"
        INPUT_FILE "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}.te"
        OUTPUT_FILE "${HAZKEY_SELINUX_TE}"
        RESULT_VARIABLE _hz_awk_result
    )
    if(NOT _hz_awk_result EQUAL 0)
        message(FATAL_ERROR "SELinux policy: failed to convert ${POLICY_NAME}.te for the refpolicy flavor.")
    endif()
    # インターフェースも同じ規則で変換する (他のポリシーモジュールから使う時に、型名が一致するようにする)
    set(HAZKEY_SELINUX_IF "${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.if")
    execute_process(
        COMMAND ${AWK} -f "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}_refpolicy.awk"
        INPUT_FILE "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}.if"
        OUTPUT_FILE "${HAZKEY_SELINUX_IF}"
        RESULT_VARIABLE _hz_awk_if_result
    )
    if(NOT _hz_awk_if_result EQUAL 0)
        message(FATAL_ERROR "SELinux policy: failed to convert ${POLICY_NAME}.if for the refpolicy flavor.")
    endif()
    # ソースの変更時にCMakeを再実行して、変換結果を更新する
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}.te"
        "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}.if"
        "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}_refpolicy.awk")
endif()

########################################
# インストール先のファイルコンテキストの生成
#
# .fcファイルには、/usr、/usr/local、/opt/hazkey-community、~/.localの規則が定義済み
# それ以外のインストール先 (例: /opt/hazkey、~/apps、Debian系のlib/x86_64-linux-gnu) の場合は、
# 実際のインストール先の規則を.fc.inの@HAZKEY_SELINUX_PREFIX_CONTEXTS@へ追加する
# 同じパスの規則が2つあるとモジュールの読み込みが失敗するため、定義済みのパスは追加しない
########################################

# 規則の項目は [|] で区切り、.fcファイルは行で区切るため、これらの文字を含むインストール先は扱えない
foreach(_hz_dir IN ITEMS CMAKE_INSTALL_PREFIX CMAKE_INSTALL_FULL_BINDIR CMAKE_INSTALL_FULL_LIBDIR
                         CMAKE_INSTALL_FULL_LIBEXECDIR CMAKE_INSTALL_FULL_DATADIR)
    if("${${_hz_dir}}" MATCHES "[|\t\n]")
        message(FATAL_ERROR "SELinux policy: ${_hz_dir} must not contain '|', tab or newline: ${${_hz_dir}}")
    endif()
endforeach()

# Fcitx 5のアドオンのインストール先
# Fcitx 5の設定によっては、Hazkey Communityのインストール先ではなくFcitx 5自体のライブラリディレクトリになる
set(HAZKEY_SELINUX_FCITX_LIBDIR "${CMAKE_INSTALL_FULL_LIBDIR}")
if(ENABLE_FCITX5)
    get_directory_property(_hz_fcitx_libdir
        DIRECTORY "${PROJECT_SOURCE_DIR}/fcitx5-hazkey"
        DEFINITION FCITX_INSTALL_LIBDIR)
    if(_hz_fcitx_libdir)
        set(HAZKEY_SELINUX_FCITX_LIBDIR "${_hz_fcitx_libdir}")
    endif()
endif()
if("${HAZKEY_SELINUX_FCITX_LIBDIR}" MATCHES "[|\t\n]")
    message(FATAL_ERROR "SELinux policy: Fcitx 5 library directory must not contain '|', tab or newline: ${HAZKEY_SELINUX_FCITX_LIBDIR}")
endif()

# パスを正規表現として扱えるように、特殊文字をエスケープする
# ホームディレクトリ配下のパスは、全てのユーザに適用するためにHOME_DIRへ置き換える
function(hazkey_selinux_path_regex out_var path)
    set(home "$ENV{HOME}")
    set(prefix "")
    if(home AND NOT home STREQUAL "/")
        string(LENGTH "${home}/" home_len)
        string(LENGTH "${path}" path_len)
        if(path_len GREATER home_len)
            string(SUBSTRING "${path}" 0 ${home_len} head)
            if(head STREQUAL "${home}/")
                math(EXPR home_len "${home_len} - 1")
                string(SUBSTRING "${path}" ${home_len} -1 path)
                set(prefix "HOME_DIR")
            endif()
        endif()
    endif()
    string(REGEX REPLACE "([][.+*?()^$|{}\\\\])" "\\\\\\1" escaped "${path}")
    # .fcファイルは空白で項目を区切るため、パス中の空白は16進のエスケープで表す
    string(REPLACE " " "\\x20" escaped "${escaped}")
    set(${out_var} "${prefix}${escaped}" PARENT_SCOPE)
endfunction()

hazkey_selinux_path_regex(_hz_bindir "${CMAKE_INSTALL_FULL_BINDIR}")
hazkey_selinux_path_regex(_hz_libdir "${CMAKE_INSTALL_FULL_LIBDIR}")
hazkey_selinux_path_regex(_hz_fcitx_libdir "${HAZKEY_SELINUX_FCITX_LIBDIR}")
hazkey_selinux_path_regex(_hz_libexecdir "${CMAKE_INSTALL_FULL_LIBEXECDIR}")
hazkey_selinux_path_regex(_hz_datadir "${CMAKE_INSTALL_FULL_DATADIR}")

# 規則の候補 (パス、ファイルの種類、型を [|] で区切る)
set(_hz_candidates
    "${_hz_libdir}/hazkey-community(/.*)?||lib_t"
    "${_hz_libdir}/hazkey-community/hazkey-community-server|--|hazkey_community_exec_t"
    "${_hz_libdir}/hazkey-community/hazkey-community-settings|--|bin_t"
    "${_hz_fcitx_libdir}/fcitx5/fcitx5-hazkey-community\\.so|--|lib_t"
    "${_hz_libexecdir}/ibus-hazkey-community(/.*)?||bin_t"
    "${_hz_datadir}/hazkey-community(/.*)?||usr_t"
)

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}.fc" _hz_fixed_fc)
set(HAZKEY_SELINUX_PREFIX_CONTEXTS "")
foreach(_hz_entry IN LISTS _hz_candidates)
    # 正規表現の [|] と区別するため、最初と最後の区切りの位置で分割する
    string(FIND "${_hz_entry}" "|" _hz_first)
    string(FIND "${_hz_entry}" "|" _hz_last REVERSE)
    string(SUBSTRING "${_hz_entry}" 0 ${_hz_first} _hz_path)
    math(EXPR _hz_kind_begin "${_hz_first} + 1")
    math(EXPR _hz_kind_len "${_hz_last} - ${_hz_first} - 1")
    string(SUBSTRING "${_hz_entry}" ${_hz_kind_begin} ${_hz_kind_len} _hz_kind)
    math(EXPR _hz_type_begin "${_hz_last} + 1")
    string(SUBSTRING "${_hz_entry}" ${_hz_type_begin} -1 _hz_type)
    # 定義済みのパス (行頭からタブまで) と一致する場合は追加しない
    string(FIND "${_hz_fixed_fc}" "\n${_hz_path}\t" _hz_found)
    if(_hz_found EQUAL -1)
        string(APPEND HAZKEY_SELINUX_PREFIX_CONTEXTS
               "${_hz_path}\t${_hz_kind}\tsystem_u:object_r:${_hz_type}:s0\n")
    endif()
endforeach()

# 標準以外のbinディレクトリに置いたラッパースクリプトには、制限ユーザも実行できるbin_tを付ける
# ホームディレクトリ配下の任意の場所 (~/apps/bin等) の既定のラベルはuser_home_tで、
# boolean [user_exec_content] を無効にした制限ユーザは実行できないため
# 変換サーバへの遷移の入口ではないため、専用の型 (hazkey_community_exec_t) は付けない
set(_hz_standard_bindirs "/usr/bin" "/bin" "/usr/local/bin" "/opt/hazkey-community/bin")
if(DEFINED ENV{HOME} AND NOT "$ENV{HOME}" STREQUAL "/")
    list(APPEND _hz_standard_bindirs "$ENV{HOME}/.local/bin" "$ENV{HOME}/bin")
endif()
list(FIND _hz_standard_bindirs "${CMAKE_INSTALL_FULL_BINDIR}" _hz_bindir_index)
if(_hz_bindir_index EQUAL -1)
    string(APPEND HAZKEY_SELINUX_PREFIX_CONTEXTS
           "${_hz_bindir}/hazkey-community-server\t--\tsystem_u:object_r:bin_t:s0\n")
endif()

if(HAZKEY_SELINUX_PREFIX_CONTEXTS)
    message(STATUS "SELinux file contexts added for the install prefix: ${CMAKE_INSTALL_PREFIX}")
endif()

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/${POLICY_NAME}.fc.in
    ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.fc
    @ONLY
)

########################################
# ビルド: .te -> .mod -> .pp
########################################

# .te (Type Enforcement) を.mod (モジュールのオブジェクト) へコンパイルする
add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.mod
    COMMAND ${CHECKMODULE} -M -m
            -o ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.mod
            ${HAZKEY_SELINUX_TE}
    DEPENDS
        ${HAZKEY_SELINUX_TE}
    COMMENT "Compiling SELinux Type Enforcement policy: ${POLICY_NAME}.te -> ${POLICY_NAME}.mod"
    VERBATIM
)

# .modと.fc (ファイルコンテキスト) を.pp (ポリシーパッケージ) にまとめる
add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.pp
    COMMAND ${SEMODULE_PACKAGE}
            -o ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.pp
            -m ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.mod
            -f ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.fc
    DEPENDS
        ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.mod
        ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.fc
    COMMENT "Packaging SELinux policy module: ${POLICY_NAME}.pp"
    VERBATIM
)

add_custom_target(selinux-policy ALL
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.pp
)

########################################
# インストール
########################################

# .ppを標準のSELinuxパッケージのディレクトリへインストールする
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.pp
        DESTINATION ${CMAKE_INSTALL_DATADIR}/selinux/packages
        COMPONENT selinux
        PERMISSIONS OWNER_READ OWNER_WRITE GROUP_READ WORLD_READ)

# 管理者がポリシーを確認・改変できるように、ソースとドキュメントもインストールする
# .teと.ifは、実際にビルドしたもの (refpolicyの場合は型名を置き換えたもの) をインストールする
install(FILES
        ${HAZKEY_SELINUX_TE}
        ${CMAKE_CURRENT_BINARY_DIR}/${POLICY_NAME}.fc
        ${HAZKEY_SELINUX_IF}
        ${CMAKE_CURRENT_SOURCE_DIR}/README.md
        ${CMAKE_CURRENT_SOURCE_DIR}/ADMIN.md
        DESTINATION ${CMAKE_INSTALL_DOCDIR}/selinux
        COMPONENT selinux)

########################################
# インストール後の処理: モジュールの読み込みとラベルの付け直し
#
# rootで実行した場合だけ、semoduleでモジュールを読み込み、restoreconでインストール済みのファイルと
# 既存ユーザのHazkey Community専用ディレクトリのラベルを付け直す (ソケットとロックファイルは、restoreconでは戻らないため、削除して作り直す)
# DESTDIRを指定したパッケージの作成時は、ビルド環境のポリシーを変更しないように読み込まない
# .ppに含まれるファイルコンテキストは設定時のインストール先から生成するため、
# cmake --install --prefixで別の場所へインストールした場合も読み込まない
# .ppのインストールと同じコンポーネント (selinux) に属するため、cmake --install --component selinuxでも実行される
########################################

# インストール先が /opt/<名前> のような専用のディレクトリの場合は、プレフィックス全体を対象にする
# bin、libexec、share/localeなど、個別のパスの一覧に含まれない場所にも、基本ポリシーの既定のラベルが付くため
# /usr や /usr/local は他のパッケージのファイルを多く含むため、個別のパスだけを対象にする
set(HAZKEY_SELINUX_PREFIX_RELABEL "")
if(CMAKE_INSTALL_PREFIX MATCHES "^/opt/.+")
    set(HAZKEY_SELINUX_PREFIX_RELABEL "${CMAKE_INSTALL_PREFIX}")
endif()

if(SEMODULE AND RESTORECON)
    install(CODE "
        set(CONFIGURED_PREFIX \"${CMAKE_INSTALL_PREFIX}\")
        set(POLICY_PP \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_DATADIR}/selinux/packages/${POLICY_NAME}.pp\")
        set(RELABEL_PATHS
            \"${CMAKE_INSTALL_FULL_BINDIR}/hazkey-community-server\"
            \"${CMAKE_INSTALL_FULL_BINDIR}/hazkey-community-settings\"
            \"${CMAKE_INSTALL_FULL_LIBDIR}/hazkey-community\"
            \"${HAZKEY_SELINUX_FCITX_LIBDIR}/fcitx5/fcitx5-hazkey-community.so\"
            \"${CMAKE_INSTALL_FULL_LIBEXECDIR}/ibus-hazkey-community\"
            \"${CMAKE_INSTALL_FULL_DATADIR}/hazkey-community\"
        )
        # プレフィックス全体を対象にする場合だけ、先頭に追加する (空の要素を作らない)
        if(NOT \"${HAZKEY_SELINUX_PREFIX_RELABEL}\" STREQUAL \"\")
            list(INSERT RELABEL_PATHS 0 \"${HAZKEY_SELINUX_PREFIX_RELABEL}\")
        endif()

        message(STATUS \"\")
        message(STATUS \"========================================\")
        message(STATUS \"SELinux Policy Module Installation\")
        message(STATUS \"========================================\")
        message(STATUS \"Module: ${POLICY_NAME}.pp\")
        message(STATUS \"Location: \${POLICY_PP}\")

        execute_process(
            COMMAND id -u
            OUTPUT_VARIABLE CURRENT_UID
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )

        if(NOT \"\$ENV{DESTDIR}\" STREQUAL \"\")
            message(STATUS \"DESTDIR is set. Skipping semodule and restorecon.\")
            message(STATUS \"Load the module on the target system:\")
            message(STATUS \"  sudo semodule -i \${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_DATADIR}/selinux/packages/${POLICY_NAME}.pp\")
        elseif(NOT \"\${CMAKE_INSTALL_PREFIX}\" STREQUAL \"\${CONFIGURED_PREFIX}\")
            message(WARNING \"\")
            message(WARNING \"!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\")
            message(WARNING \"  Install prefix (\${CMAKE_INSTALL_PREFIX}) differs from the configured prefix (\${CONFIGURED_PREFIX}).\")
            message(WARNING \"  The file contexts in ${POLICY_NAME}.pp were generated for the configured prefix.\")
            message(WARNING \"  SELinux module will NOT be loaded.\")
            message(WARNING \"  Reconfigure with -DCMAKE_INSTALL_PREFIX=\${CMAKE_INSTALL_PREFIX} and install again.\")
            message(WARNING \"!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\")
            message(WARNING \"\")
        elseif(NOT CURRENT_UID STREQUAL \"0\")
            message(WARNING \"\")
            message(WARNING \"!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\")
            message(WARNING \"  NOT running as root (uid=\${CURRENT_UID})\")
            message(WARNING \"  semodule requires root privileges.\")
            message(WARNING \"  SELinux module will NOT be loaded.\")
            message(WARNING \"  Please run manually:\")
            message(WARNING \"    sudo semodule -i \${POLICY_PP}\")
            message(WARNING \"    sudo restorecon -R -v \${RELABEL_PATHS}\")
            message(WARNING \"    restorecon -R -v ~/.config/hazkey-community ~/.local/share/hazkey-community ~/.local/state/hazkey-community ~/.cache/hazkey-community\")
            message(WARNING \"    pkill -u USER -f hazkey-community-server\")
            message(WARNING \"    rm -f \$ENV{XDG_RUNTIME_DIR}/hazkey-community-server.*\")
            message(WARNING \"!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\")
            message(WARNING \"\")
        else()
            message(STATUS \"Running: ${SEMODULE} -i \${POLICY_PP}\")
            execute_process(
                COMMAND ${SEMODULE} -i \${POLICY_PP}
                RESULT_VARIABLE SEMODULE_RESULT
                ERROR_VARIABLE SEMODULE_ERROR
                ERROR_STRIP_TRAILING_WHITESPACE
            )

            if(NOT SEMODULE_RESULT EQUAL 0)
                message(WARNING \"\")
                message(WARNING \"!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\")
                message(WARNING \"  FAILED to install SELinux module: ${POLICY_NAME}\")
                message(WARNING \"  Exit code: \${SEMODULE_RESULT}\")
                message(WARNING \"  Error: \${SEMODULE_ERROR}\")
                message(WARNING \"  Please run manually:\")
                message(WARNING \"    sudo semodule -i \${POLICY_PP}\")
                message(WARNING \"!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\")
                message(WARNING \"\")
            else()
                message(STATUS \"SELinux module '${POLICY_NAME}' installed successfully\")

                file(GLOB _user_paths
                    /home/*/.config/hazkey-community
                    /home/*/.local/share/hazkey-community
                    /home/*/.local/state/hazkey-community
                    /home/*/.cache/hazkey-community
                    /root/.config/hazkey-community
                    /root/.local/share/hazkey-community
                    /root/.local/state/hazkey-community
                    /root/.cache/hazkey-community
                )

                set(_failed_paths \"\")
                foreach(_path IN LISTS RELABEL_PATHS _user_paths)
                    if(EXISTS \"\${_path}\")
                        message(STATUS \"Running: ${RESTORECON} -R \${_path}\")
                        execute_process(
                            COMMAND ${RESTORECON} -R \${_path}
                            RESULT_VARIABLE _rc
                            ERROR_VARIABLE _err
                            ERROR_STRIP_TRAILING_WHITESPACE
                        )
                        if(NOT _rc EQUAL 0)
                            message(WARNING \"  restorecon failed for \${_path}: \${_err}\")
                            list(APPEND _failed_paths \"\${_path}\")
                        endif()
                    endif()
                endforeach()

                message(STATUS \"\")
                if(_failed_paths)
                    message(WARNING \"SELinux module was loaded, but relabeling is incomplete.\")
                    message(WARNING \"Run restorecon -R -v manually for: \${_failed_paths}\")
                else()
                    message(STATUS \"SELinux setup completed successfully\")
                endif()
                message(STATUS \"Restart the conversion server to apply the new domain:\")
                message(STATUS \"  pkill -u USER -f hazkey-community-server\")
                message(STATUS \"If the server cannot start, delete the old socket and lock file (restorecon does not relabel them):\")
                message(STATUS \"  rm -f \\\$XDG_RUNTIME_DIR/hazkey-community-server.*\")
                message(STATUS \"To verify: ps -eZ | grep hazkey-community-server\")
            endif()
        endif()
        message(STATUS \"========================================\")
        message(STATUS \"\")
    " COMPONENT selinux)
else()
    message(STATUS "SELinux tools (semodule, restorecon) not found at build time.")
    message(STATUS "Policy module will be installed but not automatically loaded.")
    message(STATUS "After installation, manually run:")
    message(STATUS "  sudo semodule -i ${CMAKE_INSTALL_FULL_DATADIR}/selinux/packages/${POLICY_NAME}.pp")
    message(STATUS "  restorecon -R -v ${CMAKE_INSTALL_FULL_LIBDIR}/hazkey-community")
endif()

message(STATUS "To uninstall SELinux policy module later:")
message(STATUS "  sudo semodule -r ${POLICY_NAME}")
