#!/usr/bin/env sh
#
# hazkey-community-migrate.sh
#
# 上流版Hazkeyのユーザデータを、hazkey-communityのディレクトリへ手動でコピーする移行スクリプト
#
# hazkey-communityは、上流版Hazkeyと併存できるように、ユーザデータを別ディレクトリに保存する
#   $XDG_CONFIG_HOME/hazkey   -> $XDG_CONFIG_HOME/hazkey-community   (config.json / env / user_dictionary.tsv / keymap / table)
#   $XDG_DATA_HOME/hazkey     -> $XDG_DATA_HOME/hazkey-community     (Zenzaiモデル)
#   $XDG_STATE_HOME/hazkey    -> $XDG_STATE_HOME/hazkey-community    (学習データ)
#   $XDG_CONFIG_HOME/fcitx5/conf/hazkey.conf -> $XDG_CONFIG_HOME/fcitx5/conf/hazkey-community.conf
#
# 旧ディレクトリは上流版Hazkeyが引き続き使用するため、移動ではなくコピーする (旧ディレクトリは変更しない)
# $XDG_CACHE_HOME/hazkey は再生成されるため移行しない
#
# コピー後、旧ディレクトリを指す絶対パスを新ディレクトリへ書き換える
#   - シンボリックリンク (例: zenzai/zenzai.gguf -> .../hazkey/zenzai/models/*.gguf)
#   - config.json (例: zenzaiWeightPath) と envファイル内のパス
#
# hazkey-community-serverが起動中の場合は、コピー前にこのスクリプトが終了させる (SIGTERM: サーバは終了時に学習データを保存する)
# Fcitx 5 / IBusは、キー入力のたびにサーバが無ければ再起動するため、利用者が事前にpkillしても、
# このスクリプトを実行する[Enter]キーの押下でサーバが再起動してしまう
# 移行後にもう1度終了させ、次のキー入力で再起動したサーバが移行済みのデータを読み込むようにする
#
# 起動済みのサーバは、コピー先に空のディレクトリ (keymap/、table/、memory/ 等) を自動作成する
# ファイルを1つも含まないコピー先は未使用とみなし、--forceなしでコピーする
#
# Fcitx 5の入力メソッド一覧 (profile) やIBusのpreload-enginesは書き換えない
# 移行後、入力メソッド"Hazkey-Community"を手動で追加すること

set -eu

PROGRAM_NAME=$(basename "$0")

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [--dry-run] [--force] [--help]

上流版Hazkeyのユーザデータ (設定・ユーザ辞書・Zenzaiモデル・学習データ) をhazkey-communityのディレクトリへコピーします
旧ディレクトリは変更しません

Options:
  -n, --dry-run   実際にはコピーせず、実行内容のみを表示する
  -f, --force     コピー先にファイルが既に存在する場合、コピー先を <コピー先>.bak-<日時> へ退避してからコピーする
  -h, --help      このヘルプを表示する

起動中のhazkey-community-serverは、このスクリプトが自動的に終了させます
移行中は、Hazkey-Communityで文字を入力しないでください
EOF
}

DRY_RUN=0
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -f|--force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf '%s: unknown option: %s\n\n' "$PROGRAM_NAME" "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ -z "${HOME:-}" ]; then
    printf '%s: HOME is not set\n' "$PROGRAM_NAME" >&2
    exit 1
fi

# XDG Base Directory (未設定・空・相対パスの場合は仕様どおりの既定値)
# 相対パスはサーバ・設定GUIも無視するため、ここで受け入れると移行先とサーバの参照先が食い違う
xdg_base_dir() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$2" ;;
    esac
}
CONFIG_HOME=$(xdg_base_dir "${XDG_CONFIG_HOME:-}" "$HOME/.config")
DATA_HOME=$(xdg_base_dir "${XDG_DATA_HOME:-}" "$HOME/.local/share")
STATE_HOME=$(xdg_base_dir "${XDG_STATE_HOME:-}" "$HOME/.local/state")

UID_NUM=$(id -u)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        info "  [dry-run] $*"
    else
        "$@"
    fi
}

# 指定したPIDが、自UIDのhazkey-community-serverであるかを/procで確認する
# pgrepの列挙からシグナル送信までの間にサーバが終了してPIDが別プロセスへ再利用された場合に、
# 無関係なプロセスへシグナルを送らないよう、送信の直前に照合する (argv[0]の照合はpgrepのパターンと同じ)
is_community_server() {
    status_file="/proc/$1/status"
    [ -r "$status_file" ] || return 1
    proc_uid=$(awk '/^Uid:/ { print $2; exit }' "$status_file" 2>/dev/null) || return 1
    [ "$proc_uid" = "$UID_NUM" ] || return 1
    proc_argv0=$(tr '\000' '\n' < "/proc/$1/cmdline" 2>/dev/null | head -n 1) || return 1
    case "$proc_argv0" in
        hazkey-community-server | */hazkey-community-server) return 0 ;;
    esac
    return 1
}

stop_community_servers() {
    pgrep -u "$UID_NUM" -f '^([^ ]*/)?hazkey-community-server( |$)' | while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        # pgrepの列挙後に終了したサーバ (PIDが再利用された場合を含む) は停止済みとして扱う
        is_community_server "$pid" || continue
        info "Stopping hazkey-community-server (PID $pid)"
        kill -TERM "$pid" 2>/dev/null || continue
        attempts=0
        # 終了後にPIDが別プロセスへ再利用されても待ち続けないよう、生存確認にも同じ照合を使う
        while is_community_server "$pid"; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 100 ]; then
                die "hazkey-community-server (PID $pid) did not stop after SIGTERM"
            fi
            sleep 0.1
        done
    done
}

if ! command -v pgrep >/dev/null 2>&1; then
    die "pgrep is required to ensure hazkey-community-server is stopped during migration"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    pgrep -u "$UID_NUM" -af '^([^ ]*/)?hazkey-community-server( |$)' || true
    info "[dry-run] would stop hazkey-community-server before migration and after copying"
else
    stop_community_servers
fi

# 実行中のサーバを確認する
# hazkey-community-serverは15文字を超えるため、comm照合 (-x) ではなく、argv[0]照合 (-f) を使用する
if false; then
    if pgrep -u "$UID_NUM" -f '^([^ ]*/)?hazkey-community-server( |$)' >/dev/null 2>&1; then
        die "hazkey-community-server is running. Stop it first:
  pkill -u \"\$(id -u)\" -f '^([^ ]*/)?hazkey-community-server( |\$)'
(The input method may restart it on the next key press; do not type into a Hazkey-Community input field while migrating.)"
    fi
    if pgrep -u "$UID_NUM" -x hazkey-server >/dev/null 2>&1; then
        warn "upstream hazkey-server is running. Learning data written after this copy will not be migrated."
    fi
elif false; then
    warn "pgrep not found; cannot check whether hazkey-community-server is running."
fi

# sed (ERE) のパターン用にメタ文字をエスケープする
sed_escape_pattern() {
    printf '%s' "$1" | sed -e 's/[][\\.*^$+?(){}|/]/\\&/g'
}

# sed の置換文字列用に \ & / をエスケープする
sed_escape_replacement() {
    printf '%s' "$1" | sed -e 's/[\\&/]/\\&/g'
}

# テキストファイル内の旧パス (境界: 直後が "/" 、 "\"" 、空白、行末) を新パスへ書き換える
rewrite_paths_in_file() {
    file=$1
    [ -f "$file" ] || return 0
    [ -L "$file" ] && return 0
    # 一時ファイルは推測できない名前でmktempが排他的に作成する (固定名の既存ファイルやシンボリックリンクへの書き込みを避ける)
    tmp=$(mktemp "${file}.migrate-tmp.XXXXXX")
    tmp_sed=$(mktemp "${file}.migrate-tmp.XXXXXX")
    cp -p "$file" "$tmp"
    set -- \
        "$CONFIG_HOME/hazkey" "$CONFIG_HOME/hazkey-community" \
        "$DATA_HOME/hazkey" "$DATA_HOME/hazkey-community" \
        "$STATE_HOME/hazkey" "$STATE_HOME/hazkey-community"
    while [ $# -ge 2 ]; do
        old=$(sed_escape_pattern "$1")
        new=$(sed_escape_replacement "$2")
        sed -E -e "s/${old}(\/|\"|'|[[:space:]]|$)/${new}\1/g" "$tmp" > "$tmp_sed"
        # cp -pで引き継いだ元ファイルの権限を保つため、置き換えではなく内容を書き戻す
        cat "$tmp_sed" > "$tmp"
        shift 2
    done
    rm -f "$tmp_sed"
    if cmp -s "$file" "$tmp"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$file"
        info "  rewrote paths: $file"
    fi
}

# コピー先ツリー内で、旧ディレクトリ配下を指す絶対パスのシンボリックリンクを新ディレクトリへ張り替える
repoint_symlinks() {
    # 改行を含むファイル名でも1リンクずつ扱えるよう、行単位の読み取りではなく -exec で引数として渡す
    find "$1" -type l -exec sh -c '
        set -eu
        old_root=$1
        new_root=$2
        shift 2
        for link do
            # $(...) は末尾の改行を全て削るため、番兵xを付けて読み、readlinkが付けた改行1つだけを除く
            target=$(readlink "$link" && printf x)
            target=${target%x}
            target=${target%?}
            case "$target" in
                "$old_root"/*)
                    new_target="${new_root}${target#"$old_root"}"
                    ln -sfn "$new_target" "$link"
                    printf "%s\n" "  relinked: $link -> $new_target"
                    ;;
            esac
        done
    ' sh "$2" "$3" {} +
}

MIGRATED=0

# 1ディレクトリ (またはファイル) をコピーする
# 戻り値 0: コピーした / 1: スキップした
copy_entry() {
    src=$1
    dst=$2
    label=$3
    copy_contents=0

    if [ ! -e "$src" ] && [ ! -L "$src" ]; then
        info "- ${label}: ${src} not found, skipped"
        return 1
    fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        if [ -d "$src" ] && [ -d "$dst" ] && [ -z "$(find "$dst" \( -type f -o -type l \) -print -quit)" ]; then
            copy_contents=1
        fi
    fi
    if { [ -e "$dst" ] || [ -L "$dst" ]; } && [ "$copy_contents" -eq 0 ]; then
        if [ "$FORCE" -ne 1 ]; then
            warn "${label}: ${dst} already exists, skipped (use --force to back it up and replace it)"
            return 1
        fi
        # 同じ秒に再実行した場合も既存の退避先を上書き・入れ子にしないよう、未使用の名前を選ぶ
        backup="${dst}.bak-${TIMESTAMP}"
        backup_index=1
        while [ -e "$backup" ] || [ -L "$backup" ]; do
            backup="${dst}.bak-${TIMESTAMP}-${backup_index}"
            backup_index=$((backup_index + 1))
        done
        info "- ${label}: backing up existing ${dst} -> ${backup}"
        # -T: 退避先がディレクトリとして存在していても、その中へ移動しない
        run mv -T "$dst" "$backup"
    fi

    info "- ${label}: ${src} -> ${dst}"
    if [ -d "$src" ]; then
        run mkdir -p "$(dirname "$dst")"
        run mkdir -p "$dst"
        run cp -a "$src"/. "$dst"/
    else
        run mkdir -p "$(dirname "$dst")"
        run cp -a "$src" "$dst"
    fi
    MIGRATED=$((MIGRATED + 1))
    return 0
}

info "Migrating upstream Hazkey user data to hazkey-community"
[ "$DRY_RUN" -eq 1 ] && info "(dry run: nothing will be changed)"
info ""

if copy_entry "$CONFIG_HOME/hazkey" "$CONFIG_HOME/hazkey-community" "config"; then
    if [ "$DRY_RUN" -ne 1 ]; then
        rewrite_paths_in_file "$CONFIG_HOME/hazkey-community/config.json"
        rewrite_paths_in_file "$CONFIG_HOME/hazkey-community/env"
        repoint_symlinks "$CONFIG_HOME/hazkey-community" "$CONFIG_HOME/hazkey" "$CONFIG_HOME/hazkey-community"
    fi
fi

if copy_entry "$DATA_HOME/hazkey" "$DATA_HOME/hazkey-community" "data (Zenzai models)"; then
    if [ "$DRY_RUN" -ne 1 ]; then
        repoint_symlinks "$DATA_HOME/hazkey-community" "$DATA_HOME/hazkey" "$DATA_HOME/hazkey-community"
    fi
fi

if copy_entry "$STATE_HOME/hazkey" "$STATE_HOME/hazkey-community" "state (learning data)"; then
    if [ "$DRY_RUN" -ne 1 ]; then
        repoint_symlinks "$STATE_HOME/hazkey-community" "$STATE_HOME/hazkey" "$STATE_HOME/hazkey-community"
    fi
fi

copy_entry "$CONFIG_HOME/fcitx5/conf/hazkey.conf" "$CONFIG_HOME/fcitx5/conf/hazkey-community.conf" \
    "Fcitx 5 addon config" || true

if [ "$DRY_RUN" -ne 1 ]; then
    stop_community_servers
fi

info ""
if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run finished."
    exit 0
fi

info "Done (${MIGRATED} item(s) copied). The original upstream directories were left unchanged."
cat <<'EOF'

Next steps:
  * Fcitx 5: restart Fcitx 5 (systemctl --user restart fcitx5.service), then add
    "Hazkey-Community" in fcitx5-configtool (the upstream "Hazkey" entry is separate).
  * IBus: run "ibus restart", then add "Hazkey-Community" in your input source settings.
EOF
