> Hazkey Communityの設定・環境のリファレンスです。  

# 設定・環境のリファレンス

Hazkey Communityが使用するファイルの場所と、サーバ起動時に効く環境変数を記載します。  

## ファイルの場所 (XDGベースディレクトリ準拠)

| 用途 | パス |
|:---|:---|
| **設定本体** | `$XDG_CONFIG_HOME/hazkey-community/config.json`<br>(通常は `~/.config/hazkey-community/config.json`) |
| **環境変数ファイル** | `$XDG_CONFIG_HOME/hazkey-community/env`<br>(通常は `~/.config/hazkey-community/env`) |
| **ユーザ辞書** | `$XDG_CONFIG_HOME/hazkey-community/user_dictionary.tsv` |
| **Zenzaiモデル** | `$XDG_DATA_HOME/hazkey-community/zenzai/`<br>(通常は `~/.local/share/hazkey-community/zenzai/`) |
| **学習データ (入力履歴)** | `$XDG_STATE_HOME/hazkey-community/` 配下<br>(通常は `~/.local/state/hazkey-community/`) |
| **サーバソケット** | `$XDG_RUNTIME_DIR/hazkey-community-server.<uid>.sock` |

## 環境変数ファイル `~/.config/hazkey-community/env`

hazkey-community-serverの起動時、ラッパースクリプトがこのファイルを読み込んでサーバプロセスに引き継ぎます。  
1行1変数の`KEY=value`形式 (`export`不要)  

このファイルはシェルスクリプトとして実行せず、データとして読み込みます。  
読み込んだ変数はラッパースクリプト自身のシェルには代入せず、サーバプロセスの環境にだけ設定します。  
そのため、シェルの特殊変数 (`RANDOM`、`OPTIND`等) と同じ名前を書いても、ラッパースクリプトの動作は変わりません。  
- 空行と、`#`で始まる行は無視します。値の後ろには、空白を挟んで`#`で始まるコメントを書けます  
  空白を挟まない`#`は値の一部です (例: `KEY=abc#def`の値は`abc#def`)  
- 引用符なしの値と`"..."`で囲んだ値は、`$NAME`と`${NAME}`を展開します (例: `$HOME/.cache/...`)。このファイルの前の行で設定した変数も展開できます。引用符なしの値の先頭の`~/`は`$HOME`に展開します  
- `'...'`で囲んだ値は展開せず、`$`、`` ` ``、`\`も含めて文字どおりに使います。空白を含む値は`"..."`か`'...'`で囲みます  
- 引用符なしの値と`"..."`で囲んだ値で、コマンド置換 (`$(...)`、`` `...` ``)、`${NAME:-x}`等の展開、バックスラッシュを含む行は、警告を出して読み飛ばします  
- 同じ変数を複数回設定した場合は、最後の行の値を使います  
- `LD_PRELOAD`等の`LD_*`と、glibcがsetuidプログラムで取り除く変数 (`GCONV_PATH`、`GLIBC_TUNABLES`、`TMPDIR`等) は設定できません  

ファイルが存在しない場合は何も行われません。  

| 変数名 | 用途 | 設定値 |
|:---|:---|:---|
| **`VK_DRIVER_FILES`** | 使用するVulkan ICDの明示指定<br>(設定するとhazkey-community-serverはバックエンド安全確認プローブを省略してこの指定をそのまま使用する。<br>マルチGPU環境のSIGILL回避にもなる) | ICDのJSONパス<br>(例: `/usr/share/vulkan/icd.d/nvidia_icd.json`)<br><br>実在名は、`ls /usr/share/vulkan/icd.d/`コマンドで確認 |
| **`VK_ICD_FILENAMES`** | 同上 (Vulkan loader向けの別名)<br>`VK_DRIVER_FILES`と同じ値を指定する | 同上 |
| **`HAZKEY_ZENZAI_CPU_THREADS`** | Zenzai CPU推論のスレッド数 | `1`〜`8`<br>未設定・無効値時は既定動作 |
| **`HAZKEY_ZENZAI_DEADLINE_MS`** | Zenzai CPU推論1回の上限時間 (ミリ秒) | `0`〜`2000`<br>`0`は期限なし<br><br>超過時はニューラル変換なしにフォールバック |
| **`HAZKEY_ZENZAI_MODEL`** | Zenzai モデルファイル (`zenzai.gguf`) の明示指定 (上級者向け) | 実在する通常ファイルのパス |
| **`HAZKEY_DICTIONARY`** | 辞書ディレクトリの明示指定 (上級者向け) | 実在するディレクトリのパス |
| **`HAZKEY_ADDRESS_DICTIONARY`** | 住所辞書 (`AddressDictionary`) ディレクトリの明示指定 (上級者向け)<br>設定するとその値のみを用いて、実在するディレクトリでなければ住所辞書を無効にする (システム配備へは切り替えない)<br>未設定時は、`/usr/share/hazkey-community/AddressDictionary`を使用 | ディレクトリのパス |
| **`HAZKEY_ENGINEERING_DICTIONARY`** | 工学用語辞書 (`EngineeringDictionary`) ディレクトリの明示指定 (上級者向け)<br>`HAZKEY_ADDRESS_DICTIONARY`と同じ規則<br>未設定時は、`/usr/share/hazkey-community/EngineeringDictionary`を使用 | ディレクトリのパス |
| **`GGML_BACKEND_DIR`** | llama.cppバックエンド (`.so`) の探索ディレクトリ (上級者向け) | ディレクトリのパス (末尾`/`は自動補完) |

**設定例**:  

```sh
mkdir -p ~/.config/hazkey-community
cat > ~/.config/hazkey-community/env <<'EOF'
# NVIDIA GPUのみに固定する例
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
HAZKEY_ZENZAI_CPU_THREADS=4
HAZKEY_ZENZAI_DEADLINE_MS=0
EOF

# 次回サーバ起動時に反映 (即時反映したい場合はサーバを終了)
pkill -u $USER -f '^([^ ]*/)?hazkey-community-server( |$)'
```

> Systemdのドロップイン (`fcitx5.service.d/*.conf`の`Environment=`) でも環境変数は設定できますが、  
> ラッパースクリプトがenvファイルを読み込んでからサーバを起動するため、両方に同じ変数を指定した場合は**`~/.config/hazkey-community/env`側が優先**されます。  
> そのため、混在させずにどちらか一方を使用してください。  
