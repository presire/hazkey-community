########################################
# Hazkey Communityのポリシーソース (hazkey_community.teとhazkey_community.if) を、
# upstream Reference Policy向けに変換するawkスクリプト
#
# hazkey_community.teとhazkey_community.ifは、Fedora / RHEL / openSUSEのポリシーの型名で書かれている
# Debian 13とUbuntu 26.04のポリシーはupstream Reference Policyの型名を使い、
# 以下の型が存在しないため、そのままではモジュールを読み込めない
#
#   Fedora / RHEL / openSUSE    Debian / Ubuntu
#   config_home_t            -> xdg_config_t       (~/.config)
#   data_home_t              -> xdg_data_t         (~/.local/share)
#   gconf_home_t             -> xdg_data_t         (~/.local、~/.local/stateを含む)
#   cache_home_t             -> xdg_cache_t        (~/.cache)
#   home_bin_t               -> user_bin_t         (~/bin、~/.local/bin)
#   passwd_file_t            -> etc_t              (/etc/passwd)
#   user_tmp_t               -> user_runtime_t     (/run/user/<UID>、[XDG_RUNTIME_DIR])
#
# 使い方:
#   awk -f hazkey_community_refpolicy.awk hazkey_community.te > 出力先/hazkey_community.te
#   awk -f hazkey_community_refpolicy.awk hazkey_community.if > 出力先/hazkey_community.if
#
# 変換の規則:
#   1. コメント行は変更しない
#      行の途中のコメントは、コメントより前のコードだけを変換する
#   2. 型名は単語単位で置き換える
#      hazkey_community_data_home_tのような、別の型名の一部は置き換えない
#   3. Debian / Ubuntuでは~/.local/stateと~/.local/shareが同じ型 (xdg_data_t) になる
#      同じ親の型と名前 (hazkey-community) に対する遷移は結果が1つに決まらないため、
#      ~/.local/state用の遷移 (hazkey_community_state_home_tへの遷移) と、
#      ~/.local/share用のディレクトリの遷移 (gconf_home_tからdata_home_tへのshare) は削除する
#      (.ifのfiletrans_patternも同様に、~/.local/state用の遷移を削除する)
#      削除するかどうかは、コメントを除いたコード部分だけで判定する
#      ~/.local/stateのディレクトリは、遷移では~/.local/share用の型になる
#      どちらの型にも同じ権限を与えているため、動作は変わらず、
#      restoreconを実行すると本来の型 (hazkey_community_state_home_t) に付け直される
#   4. 置き換えで同じ宣言が重複する場合は、1つのrequireブロック (.ifではgen_require) の中の重複だけを削除する
#      requireブロックの外の宣言には触れない
########################################

BEGIN {
    # 置き換える型名の対応表
    map["config_home_t"] = "xdg_config_t"
    map["data_home_t"]   = "xdg_data_t"
    map["gconf_home_t"]  = "xdg_data_t"
    map["cache_home_t"]  = "xdg_cache_t"
    map["home_bin_t"]    = "user_bin_t"
    map["passwd_file_t"] = "etc_t"
    map["user_tmp_t"]    = "user_runtime_t"
    in_require = 0
}

# 識別子を単語単位で置き換える
function rename(text,    out, head, word) {
    out = ""
    while (match(text, /[A-Za-z0-9_]+/)) {
        head = substr(text, 1, RSTART - 1)
        word = substr(text, RSTART, RLENGTH)
        if (word in map) {
            word = map[word]
        }
        out = out head word
        text = substr(text, RSTART + RLENGTH)
    }
    return out text
}

# コメント行は変更しない
/^[ \t]*#/ {
    print
    next
}

{
    line = $0
    comment = ""
    pos = index(line, "#")
    if (pos > 0) {
        comment = substr(line, pos)
        line = substr(line, 1, pos - 1)
    }

    # ~/.local/stateとshareの遷移は削除する (コメントを除いたコード部分だけで判定する)
    if (line ~ /^[ \t]*type_transition[ \t].*[ \t]gconf_home_t:dir[ \t]+hazkey_community_state_home_t[ \t]/) { next }
    if (line ~ /^[ \t]*type_transition[ \t].*[ \t]gconf_home_t:dir[ \t]+data_home_t[ \t]+"share"/) { next }
    if (line ~ /^[ \t]*filetrans_pattern\(\$1,[ \t]*gconf_home_t,[ \t]*hazkey_community_state_home_t,/) { next }

    line = rename(line)

    # requireブロックの範囲を追跡して、同じブロック内の重複する宣言だけを削除する
    if (line ~ /^[ \t]*(gen_)?require[ \t]*(\{|\(`)/) {
        in_require = 1
        delete seen
    } else if (in_require && (line ~ /^[ \t]*\}[ \t]*$/ || line ~ /^[ \t]*'\)[ \t]*$/)) {
        in_require = 0
    }
    if (in_require && line ~ /^[ \t]+(type|attribute)[ \t]+[A-Za-z0-9_]+;/) {
        key = line
        sub(/;.*/, ";", key)
        gsub(/[ \t]+/, " ", key)
        if (key in seen) {
            next
        }
        seen[key] = 1
    }

    print line comment
}
