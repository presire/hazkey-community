# fcitx5-hazkey-community

[![based on 7ka-Hiira/hazkey](https://img.shields.io/badge/based%20on-7ka--Hiira%2Fhazkey-blue)](https://github.com/7ka-Hiira/hazkey)

Hazkeyは、Linux向けデスクトップ環境 [Fcitx 5](https://fcitx-im.org/) で動作する日本語インプットメソッドです。  
[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) を変換エンジンに採用し、  
オプションでZenzaiニューラル変換 (llama.cppバックエンド、Vulkan GPU / CPU対応) を利用できます。  

本リポジトリは [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) をベースにしたコミュニティ版で、現在のバージョンは **v0.2.22** です。  

> **上流版 (hazkey 公式) の情報**  
> - ホームページ: [https://hazkey.hiira.dev](https://hazkey.hiira.dev)  
> - ドキュメント: [https://hazkey.hiira.dev/docs](https://hazkey.hiira.dev/docs)  

<br>

## 対応環境

| 区分 | ディストリビューション |
|---|---|
| **動作確認・サポート対象** | Fedora 44<br>openSUSE Leap 16<br>Debian 13 (Trixie) x64 |
| **CI ビルド・パッケージ頒布対象** (動作確認・サポート対象外) | 上記に加えて、<br>Debian 13 (Trixie) AArch64<br>Ubuntu 26.04<br>openSUSE Tumbleweed |

- パッケージの頒布は、その環境での動作保証を意味しません。  
- その他のディストリビューションでの動作は保証しません。  
- 上流版の対応環境・インストール方法については、[上流ドキュメント](https://hazkey.hiira.dev/docs) を参照してください。  

<br>

## コミュニティ版の主な機能 (v0.2.2-community 以降)

上流に対するコミュニティ版独自の追加機能・改善の概要です。  

| 機能 | 内容 |
|---|---|
| ユーザ辞書 (品詞・動詞活用対応) | TSV形式 (`読み<TAB>単語<TAB>コメント[<TAB>品詞]`) で単語を登録できる辞書<br>品詞 (固有名詞・人名・地名・動詞) を指定すると変換エンジンの接続コスト評価に品詞が反映される。<br>設定UIの辞書タブから追加・編集・インポート・エクスポートが可能 |
| 動詞活用エンジン | azooKeyの `JapaneseConjugationBuilder` を移植<br>ユーザ辞書に登録した動詞から全活用形を自動生成し、五段活用・一段活用・サ行変格に対応 |
| 文節境界調整 | 変換中に `Shift+Left` / `Shift+Right` で文節の境界を直接調整できる |
| ライブ変換トグル | `Ctrl+Shift+L` (デフォルト、設定で変更可能) でライブ変換のON / OFFを即座に切替え<br>OFF時のモードは記憶され、アプリ間の切替をまたいで維持される |
| 予測候補の先頭表記固定 | サジェスト候補にカーソルを合わせて `F5` (変更可能) を押すと、その表記を先頭の固定表記として受理しつつ続きを入力できる |
| 学習データの削除・履歴管理 | 候補フォーカス中に `Ctrl+D` (設定で変更可能、「候補学習削除ホットキー」) でその候補の学習データを削除<br>設定UIの「入力履歴データの管理」から入力履歴を選択して削除するダイアログも利用可能 |
| Emoji 17直接変換 | Emoji 17.0辞書による絵文字の直接変換候補を追加 (設定UI「拡張絵文字」、デフォルトON)。通常変換の候補にのみ注入され、サジェスト・ライブ変換には混入しない |
| 候補ウィンドウのマウス選択 | 変換候補ウィンドウの候補をマウスクリックでも選択できる |
| Zenzai設定の拡充 | プロファイルごとのトピック・文体・好みの指定、任意のGGUFファイルのカスタムモデル指定、リッチ候補の候補一覧 / サジェスト個別切替、GUIからのZenzaiモデル管理 (ダウンロード・有効化・削除) |
| プロファイルごとの履歴分離 | [プロファイル非依存の入力履歴]を無効にすると、プロファイルごとに学習データを分離して保存できる |
| サーバ管理の安定化 | クライアント更新時のhazkey-server自動再起動、不正設定ファイルの安全なパース、サーバプロセス管理の改善 |
| マルチ GPU 環境の SIGILL 回避 | NVIDIAとAMD/Intel iGPUが同居する環境での起動時クラッシュ ([上流 Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29)) を3層の自動回避で解消 (下記トラブルシューティング参照) |

<br>

## クイックスタート (GitHub Releases からインストール)

サポート対象環境では、ソースビルド不要でGitHub Releasesのパッケージをインストールできます。  

1. [Releases ページ](https://github.com/presire/hazkey-community/releases) から最新版 (`v0.2.20-community` 以降) を開きます。  
2. お使いのディストリビューション向けのアーカイブ (`.deb` または `.rpm`) をダウンロードします。  
   パッケージは、Debian 13 / Ubuntu 26.04向けに `.deb`、Fedora 44 / openSUSE Leap 16 / Tumbleweed 向けに `.rpm` が頒布されます。  
3. ダウンロードしたパッケージをインストールします。(パスはダウンロード先に合わせてください)  
   
   ```sh
   # Fedora (ダウンロードした .rpm のパスを指定)
   sudo dnf install ./fcitx5-hazkey-*.rpm
   
   # openSUSE (ダウンロードした .rpm のパスを指定)
   sudo zypper install ./fcitx5-hazkey-*.rpm
   
   # Debian / Ubuntu 系 (ダウンロードした .deb のパスを指定)
   sudo apt install ./fcitx5-hazkey_*_amd64.deb
   ```
   
4. Fcitx 5を再起動します。(ログアウト / ログイン、または下記「初回の有効化」の手順)  

> インストール後、設定UI (hazkey-settings) と サーバ (hazkey-server) は同じバージョンで揃います。  
> クライアントとサーバのバージョンが不一致になった場合は、hazkey-server が自動的に再起動されます。  

### ダウンロードの検証 (SHA-256・GPG署名)

Releasesページにはパッケージと合わせて `SHA256SUMS` が置かれています。  
ダウンロード後は、次の手順で破損・改ざんの有無を確認できます。  

```sh
# .deb / .rpmと同じディレクトリにSHA256SUMSを配置して実行
sha256sum -c SHA256SUMS
```

RPMパッケージはGPG署名付きで頒布されています。(DEBは署名検証を行わないため不要です)  
初回に1回だけ公開鍵 (`RPM-GPG-KEY-hazkey`、Releasesページから取得) を登録すると、  
以降のdnf / zypperでのインストール時に署名警告が表示されなくなります。  

```sh
# 公開鍵の登録 (初回のみ)
sudo rpm --import RPM-GPG-KEY-hazkey

# 署名の確認 (任意)
rpm -K ./fcitx5-hazkey-*.rpm
```

ビルドの来歴証明 (Artifact Attestation) も付与されています。  
ghコマンドがある環境では、次のコマンドで「このCIでビルドされた」ことを検証できます。(任意)  

```sh
gh attestation verify ./fcitx5-hazkey-*.rpm --owner presire
```

<br>

## 初回の有効化 (Fcitx 5に登録)

1. Fcitx 5を再起動します。  
   
   ```sh
   systemctl --user restart fcitx5.service
   # または fcitx5 を終了してから再度起動
   ```
   
2. Fcitx 5の設定ツール (タスクトレイアイコンから[設定]、または `fcitx5-configtool`) を開き、入力メソッドの追加から **Hazkey** を登録します。  
3. 入力メソッドの切替 (デフォルトでは `Super+Space` など、Fcitx 5側の設定に依存) でHazkeyに切り替え、ローマ字入力してかなが変換できることを確認します。  
4. 設定を変更する場合は、アプリメニューまたはターミナルから **hazkey-settings** を起動します。  
   
   ```sh
   hazkey-settings
   ```

<br>

## Zenzai (ニューラル変換) のセットアップ

Zenzaiは、llama.cppをバックエンドとするオプションのニューラル変換機能です。  
**GPU (Vulkan) がなくてもCPUだけで使用できます**。  

ローエンドGPUよりCPUの方が速い・安定な場合もあるため、必ずしもGPUが必要ではありません。  

### モデルの選択

Zenzaiモデルは、設定UIの[AI]タブにある[Zenzaiモデルの管理]からダウンロード・有効化・削除できます。  
ダウンロード時は、SHA-256の検証が行われます。  

現在提供されているモデルは以下の通りです。  

| モデル | サイズ | 特徴 | ライセンス |
|---|---|---|---|
| **zenz-v3.2-small** | 約 74 [MB] | 推奨<br>最新世代の標準モデル | Apache-2.0 |
| **zenz-v3.2-xsmall** | 約 21 [MB] | 軽量<br>CPUで高速、精度はやや低め | Apache-2.0 |
| zenz-v3.1-small | 約 74 [MB] | 旧世代<br>既存環境との互換維持用 | CC-BY-SA-4.0 |

新規利用は **zenz-v3.2-small** を推奨します。  
CPU中心で使う・軽量重視の場合は **zenz-v3.2-xsmall** が適しています。  

v3.1はv3.2の後継に置き換えられているため、既存環境の再現用途以外での新規利用は推奨しません。  

### 有効化の手順

1. `hazkey-settings` を起動し、[AI]タブを開きます。  
2. [Zenzaiモデルの管理]から利用したいモデルをダウンロードします。  
3. [Zenzaiを有効化]にチェックを入れ、バックエンドデバイス (CPUまたはVulkan GPU) を選択して、[適用]または[OK]を押します。  
4. GPUバックエンドの選択肢に表示されない場合は、Vulkanドライバの導入状態を確認した上でFcitx 5を再起動します。  
   (`systemctl --user restart fcitx5.service`)  

Vulkanを使ったGPU変換には、各ディストリビューションのVulkanドライバ (NVIDIA公式ドライバ、MesaのRADV/ANVなど) が必要です。  
`vulkaninfo --summary` (パッケージ `vulkan-tools`) でGPUが列挙されれば利用可能です。  

#### Vulkanドライバのインストール例

使用するGPUとディストリビューションに応じて、以下を参考にインストールしてください。  
`vulkan-tools`は、デバイスの確認に使用する`vulkaninfo`コマンドを含みます。  

**openSUSE Leap 16**  

```sh
# Intel GPU/iGPU
sudo zypper install libvulkan_intel vulkan-tools

# AMD GPU/iGPU
sudo zypper install libvulkan_radeon vulkan-tools

# NVIDIA GPU (NVIDIAリポジトリの登録と再起動が必要)
sudo zypper addrepo https://download.nvidia.com/opensuse/leap/16.0/ nvidia
sudo zypper --gpg-auto-import-keys refresh
sudo zypper install nvidia-open-driver-G06-signed-kmp-default nvidia-video-G06 nvidia-gl-G06 vulkan-tools
```

**Fedora 44**  

```sh
# Intel GPU/iGPU / AMD GPU/iGPU (Mesa ANV / RADV)
sudo dnf install mesa-vulkan-drivers vulkan-tools

# NVIDIA GPU (RPM Fusionの登録と再起動が必要)
sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
                 https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install akmod-nvidia vulkan-tools
```

**Debian 13 (Trixie)**  

```sh
# Intel GPU/iGPU / AMD GPU/iGPU (Mesa ANV / RADV)
sudo apt install mesa-vulkan-drivers vulkan-tools

# NVIDIA GPU (non-freeコンポーネントの有効化と再起動が必要)
sudo apt install nvidia-kernel-dkms nvidia-driver nvidia-vulkan-icd vulkan-tools
```

NVIDIAドライバは、GPU世代によって必要なパッケージや対応状況が異なります。  
詳細は各ディストリビューションのドキュメントを参照してください。  
([openSUSE](https://en.opensuse.org/SDB:NVIDIA_drivers)、[Fedora](https://rpmfusion.org/Howto/NVIDIA)、[Debian](https://wiki.debian.org/NvidiaGraphicsDrivers))  

### GPU / iGPUの最低要件と性能の目安

GPU/iGPUを使用するための最低ラインは、Vulkan 1.2以上に対応し、システムとHazkeyから認識できることです。  

#### 動作上の最低条件

GPU/iGPUでZenzaiを使用する場合、次の条件をすべて満たす必要があります。  

- Vulkan 1.2以上に対応したGPUまたはiGPUと、対応するVulkanドライバがインストールされていること  
- hazkey-serverが `GGML_VULKAN=ON` でビルドされていること  
- `vulkaninfo --summary` で対象デバイスが列挙されること  
- Fcitx 5再起動後、`hazkey-settings` の[AI]タブで対象デバイスがVulkanバックエンドとして表示され、選択できること  

これらはVulkanバックエンドを利用できるかの確認条件であり、変換速度や安定性を保証するものではありません。  

#### 一般的なVulkan対応例

以下は、Vulkan 1.2以上に対応する構成の代表例です。  
***hazkey-communityでZenzaiの動作を確認・認定した機種一覧ではなく、最低要件や推奨機種を示すものでもありません。***  

| 区分 | 型番・製品系列の例 |
|---|---|
| NVIDIA GeForce (dGPU) | GeForce GTX 1050<br>GTX 1650<br>GTX 1660 SUPER<br>RTX 3060<br>RTX 4060 |
| AMD Radeon (dGPU) | Radeon RX 560<br>RX 6400<br>RX 6600<br>RX 7600 |
| Intel iGPU | Intel UHD Graphics 630<br>UHD Graphics 730<br>UHD Graphics 770<br>Iris Xe Graphics |
| AMD iGPU | Radeon Vega 8<br>Radeon 680M<br>Radeon 760M<br>Radeon 780M |

Vulkan対応状況の確認には、[NVIDIA Vulkan Driver Support](https://developer.nvidia.com/vulkan-driver)、[Mesa RADV](https://docs.mesa3d.org/drivers/radv.html)、[Intel Supported APIs](https://www.intel.com/content/www/us/en/support/articles/000005524/graphics.html)、[Khronosの適合製品一覧](https://www.khronos.org/conformance/adopters/conformant-products)を参照してください。  

同じ型番でも、OS、Vulkanドライバの種類とバージョン、デスクトップ版・モバイル版・OEM版によって結果が異なります。  
llama.cppの実行時のデバイス機能検査により、Vulkan 1.2対応のデバイスでも利用できない場合があります。  

上記はVulkan API対応の目安であり、Hazkeyでの変換速度や安定性を示すものではありません。  
iGPUはシステムメモリを共有するため、専用VRAMのGPUとは利用可能なメモリ容量や帯域が異なります。  

#### 性能について

本リポジトリでは、特定のGPU型番・世代、GPU/iGPUの最低性能、VRAM容量、最低処理速度を定めていません。  
モデルファイルのサイズ（約 21 [MB] / 約 74 [MB]）は、実行時に必要なVRAM容量を示すものではありません。  

GPU/iGPUの性能、専用メモリまたは共有メモリの空き容量、Vulkanドライバ、CPU、システムの負荷によって、変換速度や安定性は変わります。  
ローエンドのGPU/iGPUではCPUより遅くなる場合もあるため、実際の環境でCPUバックエンドとVulkanバックエンドを比較し、  
より速く安定して動作するバックエンドを選択してください。  

GPU/iGPUが条件を満たさない場合や、GPU/iGPUよりCPUの方が適している場合でも、CPUバックエンドでZenzaiを使用できます。  

### モデルの保存場所とアクティブモデル

- ダウンロードしたモデル本体:  
  `~/.local/share/hazkey/zenzai/models/<モデルキー名>.gguf`  
- アクティブなモデル:  
  `~/.local/share/hazkey/zenzai/zenzai.gguf`  
  (上記models配下へのシンボリックリンク。[Zenzaiモデルの管理]のアクティブ化 / 無効化でこのリンクが切り替わります)  
- サーバは `HAZKEY_ZENZAI_MODEL` 環境変数 (任意) > ユーザディレクトリの `zenzai.gguf` > システム配備のモデル の順に探索します。  

<br>

## 設定・環境のリファレンス

hazkey-communityが使うファイルの場所と、サーバ起動時に効く環境変数をここにまとめます。  

### ファイルの場所 (XDGベースディレクトリ準拠)

| 用途 | パス |
|---|---|
| 設定本体 | `$XDG_CONFIG_HOME/hazkey/config.json`<br>(通常は `~/.config/hazkey/config.json`) |
| 環境変数ファイル | `$XDG_CONFIG_HOME/hazkey/env`<br>(通常は `~/.config/hazkey/env`) |
| ユーザ辞書 | `$XDG_CONFIG_HOME/hazkey/user_dictionary.tsv` |
| Zenzaiモデル | `$XDG_DATA_HOME/hazkey/zenzai/`<br>(通常は `~/.local/share/hazkey/zenzai/`) |
| 学習データ (入力履歴) | `$XDG_STATE_HOME/hazkey/` 配下<br>(通常は `~/.local/state/hazkey/`) |
| サーバソケット | `$XDG_RUNTIME_DIR/hazkey-server.<uid>.sock` |

### 環境変数ファイル `~/.config/hazkey/env`

`hazkey-server` の起動時、ラッパースクリプトがこのファイルを `source` してサーバプロセスに引き継ぎます。  
1行1変数の `KEY=value` 形式 (`export` 不要、`#` 以降はコメント)  

ファイルが存在しない場合は何も行われません。  

| 変数名 | 用途 | 設定値 |
|---|---|---|
| `VK_DRIVER_FILES` | 使用するVulkan ICDの固定 (マルチGPUのSIGILL回避) | ICDのJSONパス<br>(例: `/usr/share/vulkan/icd.d/nvidia_icd.json`)<br><br>実在名は `ls /usr/share/vulkan/icd.d/` コマンドで確認 |
| `VK_ICD_FILENAMES` | 同上 (Vulkan loader向けの別名)<br>`VK_DRIVER_FILES` と同じ値を書く | 同上 |
| `HAZKEY_ZENZAI_CPU_THREADS` | Zenzai CPU推論のスレッド数 | `1`〜`8`<br>未設定・無効値時は既定動作 |
| `HAZKEY_ZENZAI_DEADLINE_MS` | Zenzai CPU推論1回の上限時間 (ミリ秒) | `0`〜`2000`<br>`0` は期限なし。<br>超過時はニューラル変換なしにフォールバック |
| `HAZKEY_ZENZAI_MODEL` | Zenzai モデルファイル (`zenzai.gguf`) の明示指定 (上級者向け) | 実在する通常ファイルのパス |
| `HAZKEY_DICTIONARY` | 辞書ディレクトリの明示指定 (上級者向け) | 実在するディレクトリのパス |
| `GGML_BACKEND_DIR` | llama.cppバックエンド (`.so`) の探索ディレクトリ (上級者向け) | ディレクトリのパス (末尾 `/` は自動補完) |

**設定例**:  

```sh
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
# NVIDIA GPU のみに固定する例
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
HAZKEY_ZENZAI_CPU_THREADS=4
HAZKEY_ZENZAI_DEADLINE_MS=0
EOF

# 次回サーバ起動時に反映 (即時反映したい場合はサーバを終了)
pkill -u $USER -x hazkey-server
```

> Systemdのドロップイン (`fcitx5.service.d/*.conf` の `Environment=`) でも環境変数は設定できますが、  
> ラッパースクリプトがenvファイルを `source` するため、両方に同じ変数を書いた場合は **`~/.config/hazkey/env` 側が優先**されます。  
> 混在させずどちらか一方を使用してください。  

<br>

## ソースからのビルド

### 依存関係

- Swift >= 6.1  
- Fcitx 5 >= 5.0.4 (開発ヘッダ含む)  
- Qt >= 6.7 (6.2 以降でもビルド可能ですが表示が崩れる場合があります)  
- CMake >= 3.21 (4.x以降推奨)  
- Protobuf >= 3.12  
- Ninja  
- Gettext  
- Vulkan SDKヘッダ (`libvulkan-dev` / `vulkan-headers`)  
  `GGML_VULKAN=ON` (デフォルト) のビルドで必要  

各ディストリビューションでの依存パッケージの導入は、CIの定義 (`.github/workflows/build.yml`) が参照になります。  

### ビルド手順

```sh
git clone --recursive https://github.com/presire/hazkey-community
cd hazkey-community

mkdir build && cd build
cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      ..
ninja -j $(nproc)
sudo ninja install
```

インストール後は、Fcitx 5を再起動して入力メソッドに登録してください。(上記「初回の有効化」参照)  

### ビルドオプション

| オプション | デフォルト | 説明 |
|---|---|---|
| `GGML_VULKAN` | `ON` | ZenzaiのVulkan (GPU) バックエンド<br>CPU専用ビルドにする場合は `-DGGML_VULKAN=OFF` |
| `HAZKEY_SERVER_ENABLE_ZENZAI` | `ON` | Zenzaiニューラル変換機能の有効化 |
| `SWIFT_LINK_PATH` | (未指定) | Swiftランタイムライブラリのリンクパス<br>swiftly等でインストールしたツールチェーンをCMakeが見つけない場合に、`<ツールチェーン>/usr/lib/swift/linux` を明示する |

CPU専用ビルドの例:  

```sh
cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DGGML_VULKAN=OFF \
      ..
```

> **注意**:  
> ソースの配置パスに角括弧 (`[` `]`) を含めないでください。  
> パスに角括弧が含まれていると、CMakeの `file(GLOB)` が誤解釈し、llama.cppのVulkanビルドが失敗することがあります。  
> 角括弧を含まないパスにクローンするか、角括弧を含まないシンボリックリンク経由でcmakeコマンドを実行してください。  

<br>

## トラブルシューティング

### マルチGPU環境でhazkey-serverがSIGILLでクラッシュする

NVIDIA GPUとAMD/Intel iGPUが同居する環境 (両方のVulkan ICDがインストール済み) で、`hazkey-server` が起動直後にSIGILL (signal 4)でクラッシュする現象があります。  
([上流 Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29))  

**原因**:  
Zenzai初期化時にVulkan loaderがシステム内の全ICDをロードし、ベンダー混在の競合状態でSwiftランタイムのprecondition failure (`ud2` 命令、SIGILL) が発生します。  
SIGILLはtrap命令のため `do/catch` で捕捉できません。  

**コミュニティ版の自動回避 (3層)**:  

1. **ラッパースクリプト** (`hazkey-server.sh`):  
   `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` が未設定の場合、検出したICDのうち最初の1つだけを設定してサーバを起動します。  
2. **変換エンジン (フォーク版) 内蔵のピン留め**:  
   使用中のAzooKeyKanaKanjiConverterフォーク版 (`presire/AzooKeyKanaKanjiConverter` のhazkeyブランチ) が、バックエンド初期化の前にICDを1つに絞る処理を組み込みで実行します。  
3. **CPUフォールバック**:  
   Vulkanを完全に無効化したい場合は `-DGGML_VULKAN=OFF` のCPU専用ビルドが可能です。  

それでも症状が出る・特定のGPUに固定したい場合は、`~/.config/hazkey/env` で `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` を明示してください。  
(書式・設定例は上記「設定・環境のリファレンス」参照)  

ICDのファイル名はドライバにより異なります。  
(NVIDIA: `nvidia_icd.json`、AMD Mesa: `radeon_icd.json`、AMD 公式: `amd_icd.x86_64.json`、Intel Mesa: `intel_icd.x86_64.json` など)  

実際のファイル名は `ls /usr/share/vulkan/icd.d/` コマンドで確認してください。  

### Fcitx 5が新しいバージョンを認識しない

```sh
fcitx5-remote -r                          # 設定リロード
rm -rf ~/.cache/fcitx5/hazkey/            # キャッシュクリア
systemctl --user restart fcitx5.service   # 完全再起動
```

学習データは `~/.local/state/hazkey/` に保持されるため失われません。  

### サーバに接続できない

```sh
pgrep -af hazkey-server                              # 起動確認
ls -la "$XDG_RUNTIME_DIR"/hazkey-server.*.sock       # ソケット確認
```

サーバプロセスが終わっている場合は Fcitx 5を再起動すると再度起動します。  
手動起動での切り分けは、インストール先の `hazkey-server` (ラッパースクリプト) を実行して確認できます。  

### ユーザ辞書が反映されない

- `~/.config/hazkey/user_dictionary.tsv` の書式 (`読み<TAB>単語<TAB>コメント[<TAB>品詞]`) を確認してください。  
- サーバはファイルの更新日時を監視して自動再読込しますが、反映されない場合は `pkill -u $USER -x hazkey-server` でサーバを再起動してください。  

### ZenzaiのGPUデバイスが選択肢に出ない

- `vulkaninfo --summary` で GPUが列挙されるか確認してください。  
- Vulkan ドライバ導入後は Fcitx 5 (およびサーバ) の再起動が必要です。  
- CPUでもZenzaiは使用可能です。  
  バックエンドデバイスに「CPU」を選択してください。  

<br>

## 上流・関連プロジェクト

| プロジェクト | 用途 |
|---|---|
| [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) | 本プロジェクトの上流<br>ドキュメント: [https://hazkey.hiira.dev/docs](https://hazkey.hiira.dev/docs) |
| [azooKey/AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) | 変換エンジン (本プロジェクトは、forkのhazkeyブランチを使用) |
| [ensan-hcl/azooKey](https://github.com/ensan-hcl/azooKey) | 動詞活用エンジンの移植元 |
| [Miwa-Keita/zenz-v3.2-small-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf) / [zenz-v3.2-xsmall-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.2-xsmall-gguf) / [zenz-v3.1-small-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf) | Zenzaiモデル (GGUF) |
| [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | Zenzaiの推論バックエンド |
| [fcitx/fcitx5](https://github.com/fcitx/fcitx5) | インプットメソッドフレームワーク |

## ライセンス

[MIT License](./LICENSE)  

本プロジェクトは [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) (MIT License) をベースにしています。  
Zenzaiモデルのライセンスは上記のモデル一覧を参照してください。  
