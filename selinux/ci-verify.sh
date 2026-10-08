#!/bin/sh
########################################
# Hazkey CommunityのSELinuxポリシーモジュールの、CI用の検証スクリプト
#
# コンテナの中でrootとして実行する (GitHub Actionsのtest.ymlとbuild.ymlから呼び出す)
# コンテナ内ではSELinuxは動作しないが、ポリシーストアへの読み込みとファイルコンテキストの照会はできる
# このため、次の項目を検証する
#
#   1. 系統 (redhat / refpolicy) の自動判定
#   2. Makefileでの構文検査、ビルド、ポリシーストアへの読み込み
#   3. インストール先ごとのファイルコンテキスト (matchpathcon)
#   4. 許可規則と型遷移 (sesearch)。TCP通信を許可していないこと
#   5. .fcと.fc.inの内容の一致
#   6. CMakeでのビルドと、DESTDIR指定のインストール
#
# 使い方:
#   sh selinux/ci-verify.sh <出力する.ppのパス>
#
# 対応するイメージ: fedora、opensuse-leap、debian、ubuntu
########################################

set -eu

OUT="${1:?usage: ci-verify.sh <output .pp path>}"
SRC="$(cd "$(dirname "$0")" && pwd)"

. /etc/os-release
export DEBIAN_FRONTEND=noninteractive

########################################
# 依存パッケージ
########################################

case "$ID" in
    fedora)
        dnf install -y selinux-policy-targeted checkpolicy policycoreutils make gawk \
            libselinux-utils setools-console cmake ninja-build
        STORE=targeted
        EXPECTED_FLAVOR=redhat
        RUNTIME_TYPE=user_tmp_t
        ;;
    opensuse-leap)
        zypper -n install selinux-policy-targeted checkpolicy policycoreutils make gawk \
            selinux-tools setools-console cmake ninja
        STORE=targeted
        EXPECTED_FLAVOR=redhat
        RUNTIME_TYPE=user_tmp_t
        ;;
    debian|ubuntu)
        apt-get update
        apt-get install -y selinux-policy-default checkpolicy policycoreutils semodule-utils \
            selinux-utils make setools cmake ninja-build
        STORE=default
        EXPECTED_FLAVOR=refpolicy
        RUNTIME_TYPE=user_runtime_t
        ;;
    *)
        echo "unsupported distribution: $ID" >&2
        exit 1
        ;;
esac

# コンテナには/etc/selinux/configが無い場合があるため、ポリシーストアの名前を指定する
mkdir -p /etc/selinux
if [ ! -f /etc/selinux/config ]; then
    printf 'SELINUX=enforcing\nSELINUXTYPE=%s\n' "$STORE" > /etc/selinux/config
fi

echo "== $PRETTY_NAME: $(checkmodule -V 2>&1 | head -n 1)"

# ワークスペースを汚さないように、作業用のコピーでビルドする
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -a "$SRC/." "$WORK/"
rm -f "$WORK"/*.pp "$WORK"/*.mod
rm -rf "$WORK/.build" "$WORK/.check" "$WORK/.flavor"

FAILURES=0
fail() {
    echo "NG: $*" >&2
    FAILURES=$((FAILURES + 1))
}

########################################
# 1. 2. Makefileでのビルドと読み込み
########################################

cd "$WORK"
make check
make 2>&1 | tee make.log
if grep -q "(${EXPECTED_FLAVOR})" make.log; then
    echo "OK: flavor is ${EXPECTED_FLAVOR}"
else
    fail "expected flavor ${EXPECTED_FLAVOR} was not selected"
fi
test -f hazkey_community.pp || fail "hazkey_community.pp was not built"

semodule -i hazkey_community.pp
semodule -l | grep -x 'hazkey_community.*' || fail "module is not listed by semodule -l"

########################################
# 3. ファイルコンテキスト
########################################

expect_label() {
    path="$1"
    type="$2"
    got="$(matchpathcon -n "$path" 2>&1 || true)"
    case "$got" in
        *":object_r:${type}:"*) echo "OK: $path -> $type" ;;
        *) fail "$path: expected $type, got: $got" ;;
    esac
}

expect_label /usr/lib64/hazkey-community/hazkey-community-server hazkey_community_exec_t
expect_label /usr/lib/x86_64-linux-gnu/hazkey-community/hazkey-community-server hazkey_community_exec_t
expect_label /usr/lib/aarch64-linux-gnu/hazkey-community/hazkey-community-server hazkey_community_exec_t
expect_label /usr/local/lib64/hazkey-community/hazkey-community-server hazkey_community_exec_t
expect_label /opt/hazkey-community/lib64/hazkey-community/hazkey-community-server hazkey_community_exec_t
expect_label /home/user/.local/lib64/hazkey-community/hazkey-community-server hazkey_community_exec_t
expect_label /usr/lib64/hazkey-community/libllama/libllama.so lib_t
expect_label /usr/lib64/hazkey-community/hazkey-community-settings bin_t
expect_label /home/user/.config/hazkey-community/config.json hazkey_community_config_t
expect_label /home/user/.config/hazkey-community/config.json.tmp hazkey_community_config_t
expect_label /home/user/.config/hazkey-community/user_dictionary.tsv hazkey_community_conf_home_t
expect_label /home/user/.local/state/hazkey-community hazkey_community_state_home_t
expect_label /home/user/.cache/hazkey-community hazkey_community_cache_home_t

########################################
# 4. 許可規則と型遷移
########################################

# 変換サーバの起動 (非制限ユーザからの遷移)
sesearch -T -s unconfined_t -t hazkey_community_exec_t -c process | grep -q 'hazkey_community_server_t' \
    || fail "no domain transition from unconfined_t"

# ソケットとロックファイルの型遷移 (Debian / Ubuntuでは/run/user/<UID>がuser_runtime_t)
sesearch -T -s hazkey_community_server_t -t "$RUNTIME_TYPE" -c sock_file | grep -q 'hazkey_community_runtime_t' \
    || fail "no sock_file transition in $RUNTIME_TYPE"
sesearch -A -s hazkey_community_server_t -t "$RUNTIME_TYPE" -c dir | grep -q 'add_name' \
    || fail "no dir permission on $RUNTIME_TYPE"

# 以下の否定の検査が、sesearchの失敗で見かけ上通らないように、肯定の対照を先に確認する
sesearch -A -s hazkey_community_server_t -t hazkey_community_config_t -c file -p write | grep -q '^allow hazkey_community_server_t' \
    || fail "control check failed: config_t is not writable (sesearch may be broken)"
sesearch -A -s hazkey_community_server_t -t hazkey_community_conf_home_t -c file -p read | grep -q '^allow hazkey_community_server_t' \
    || fail "control check failed: conf_home_t is not readable (sesearch may be broken)"

# 変換サーバは全てのキー入力を受け取るため、TCP通信とポートへの束縛を許可しない
# (全てのドメインに共通の規則は、主体がdomain属性のため一致しない)
if sesearch -A -s hazkey_community_server_t -c tcp_socket | grep -q '^allow hazkey_community_server_t'; then
    fail "tcp_socket is allowed for hazkey_community_server_t"
else
    echo "OK: tcp_socket is not allowed"
fi

# 変換サーバは、起動元で読み込まれる設定 (env) を書き換えられない
if sesearch -A -s hazkey_community_server_t -t hazkey_community_conf_home_t -c file -p write | grep -q '^allow hazkey_community_server_t'; then
    fail "hazkey_community_server_t can write hazkey_community_conf_home_t files"
else
    echo "OK: conf_home_t files are not writable"
fi

# config.jsonの保存に使う一時ファイル (config.json.tmp) にも、書き込める型を付ける
sesearch -T -s hazkey_community_server_t -t hazkey_community_conf_home_t -c file | grep 'config.json.tmp' \
    | grep -q 'hazkey_community_config_t' \
    || fail "no file transition for config.json.tmp"

# envの作成・削除・置換の経路を許可しない
#   - 設定ディレクトリの通常のファイル: 作成、削除、名前の変更、リンク、属性の変更
#   - 書き込める設定ファイル: 名前の変更とリンク (config.jsonをenvへ改名できるため)
#   - 設定ディレクトリ: 属性の変更 (パーミッションを緩めて他のユーザに置き換えさせられるため)、削除、名前の変更
expect_not_allowed() {
    target="$1"
    class="$2"
    shift 2
    for perm in "$@"; do
        if sesearch -A -s hazkey_community_server_t -t "$target" -c "$class" -p "$perm" | grep -q '^allow hazkey_community_server_t'; then
            fail "hazkey_community_server_t has $perm on $target:$class"
        else
            echo "OK: no $perm on $target:$class"
        fi
    done
}
expect_not_allowed hazkey_community_conf_home_t file create append unlink rename link setattr
expect_not_allowed hazkey_community_conf_home_t lnk_file create unlink rename
expect_not_allowed hazkey_community_config_t file rename link
expect_not_allowed hazkey_community_conf_home_t dir setattr rmdir rename reparent

########################################
# 5. .fcと.fc.inの一致 (置換用の行を除く)
########################################

if diff -u hazkey_community.fc hazkey_community.fc.in | grep '^[-+][^-+]' \
    | grep -v '^+@HAZKEY_SELINUX_PREFIX_CONTEXTS@$' | grep -v '^+#' >/dev/null; then
    fail "hazkey_community.fc and hazkey_community.fc.in differ"
else
    echo "OK: .fc and .fc.in match"
fi

########################################
# 6. CMakeでのビルドとインストール
########################################

CMAKE_TEST="$WORK/cmake-test"
mkdir -p "$CMAKE_TEST/selinux"
cat > "$CMAKE_TEST/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(hazkey_selinux_test NONE)
include(GNUInstallDirs)
add_subdirectory(selinux)
CMAKE
# 元のソースだけをコピーする (上のMakefileでのビルド成果物は含めない)
cp -a "$SRC/." "$CMAKE_TEST/selinux/"
rm -f "$CMAKE_TEST"/selinux/*.pp "$CMAKE_TEST"/selinux/*.mod
rm -rf "$CMAKE_TEST/selinux/.build" "$CMAKE_TEST/selinux/.check" "$CMAKE_TEST/selinux/.flavor"

cmake -G Ninja -S "$CMAKE_TEST" -B "$WORK/cmake-build" -DCMAKE_INSTALL_PREFIX=/usr 2>&1 | tee cmake.log
grep -q "SELinux policy flavor: ${EXPECTED_FLAVOR}" cmake.log || fail "CMake did not select ${EXPECTED_FLAVOR}"
cmake --build "$WORK/cmake-build"
DESTDIR="$WORK/stage" cmake --install "$WORK/cmake-build" --component selinux
test -f "$WORK/stage/usr/share/selinux/packages/hazkey_community.pp" || fail "CMake did not install hazkey_community.pp"
test -f "$WORK/stage/usr/share/doc/hazkey_selinux_test/selinux/hazkey_community.te" || fail "CMake did not install hazkey_community.te"

# 変換済みのソースが、ビルドしたものと一致する (Debian / Ubuntuでは型名を置き換えたもの)
if [ "$EXPECTED_FLAVOR" = refpolicy ]; then
    grep -q 'xdg_config_t' "$WORK/stage/usr/share/doc/hazkey_selinux_test/selinux/hazkey_community.te" \
        || fail "installed hazkey_community.te was not converted"
fi

########################################
# 結果
########################################

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES check(s) failed" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
cp "$WORK/hazkey_community.pp" "$OUT"
chmod a+r "$OUT"
echo "All SELinux policy checks passed: $OUT"
