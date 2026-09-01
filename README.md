# fcitx5-hazkey-community

[![based on 7ka-Hiira/hazkey](https://img.shields.io/badge/based%20on-7ka--Hiira%2Fhazkey-blue)](https://github.com/7ka-Hiira/hazkey)  

> このプロジェクトは [7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey) をベースにしたカスタマイズ版です。(v0.2.2-community以降)  
> ユーザ辞書 (品詞・動詞活用対応)・動詞活用エンジン、候補ウィンドウでのマウス選択、ライブ変換トグルホットキー、文節境界調整・自動変換の改善、  
> Zenzai設定の拡充 (トピック・文体・好み・カスタムモデル・リッチ候補)、プロファイルごとの学習履歴分離、設定UI強化 (辞書タブ・動詞活用情報表示・設定リセット)、  
> サーバ設定の堅牢化、サーバプロセス管理の安定化、マルチGPU環境でのSIGILLクラッシュ回避 ([Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29)) 等の追加機能を含みます。  

Hazkey input method for fcitx5  

[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)を利用したIMEです。  

> ホームページ (上流版)  
> [https://hazkey.hiira.dev](https://hazkey.hiira.dev)  
> ドキュメント (上流版)  
> [https://hazkey.hiira.dev/docs](https://hazkey.hiira.dev/docs)  

<br>

## コミュニティ版の追加機能 (v0.2.2-community以降)

本カスタマイズ版では、上流 ([7ka-Hiira/hazkey](https://github.com/7ka-Hiira/hazkey)) の `v0.2.2-community` 以降において、以下の機能追加・改善を行っています。  

### ユーザ辞書 (品詞・動詞活用対応)

TSV形式 (`読み<TAB>単語<TAB>コメント[<TAB>品詞]`) で単語を登録できる軽量なユーザ辞書です。  
品詞 (固有名詞・人名・地名・動詞) を指定すると、AzooKeyKanaKanjiConverterの接続コスト評価に正しく参加するようになり、  
候補ランキングに品詞が反映されます。  

従来は、単純な前方挿入でエンジンのラティスをバイパスしていたため、品詞がランキングに影響しませんでした。  
既存の3列TSVファイルも後方互換性を保ち読み込めます。  

### 動詞活用エンジン (azooKey由来)

azooKeyの `JapaneseConjugationBuilder` を移植した動詞活用エンジンです。  
ユーザ辞書に登録した動詞エントリから全活用形を自動生成し、それぞれに正しいCIDを割り当てて接続コスト評価を適切に行います。  

五段活用 (か・が・さ・た・な・ば・ま・ら・わ行)・一段活用・サ行変格 (する) に対応しています。  

### 候補ウィンドウでのマウス選択

変換候補ウィンドウに表示された候補を、キーボードだけでなくマウスクリックでも選択できるようになりました。  
候補選択に関する回帰テストも追加し、動作の安定性を確保しています。  

### 文節境界調整 (Shift+Left / Shift+Right)

変換中に `Shift+Left` / `Shift+Right` で文節の境界を直接調整できるようになりました。  
エンジンが判定した文節区切りをユーザ側で微調整できるため、複雑な文でも意図通りに変換しやすくなります。  

### 自動変換の最小文字数を設定可能に

ライブ変換 (自動変換) がトリガーされるまでの最小文字数を設定UIから変更可能になりました。  
入力中の空の未確定文字列 (preedit) 更新による入力消失も回避されるよう改善されています。  

### ライブ変換トグルホットキー

`Ctrl+Shift+L` (デフォルト、設定で変更可能) でライブ変換のON / OFFを即座に切り替えられます。  

トグルはサーバ側の `auto_convert_mode` を同期的に切り替え (約3〜5msで体感不可)、  
OFF時のモードは記憶されてアプリ間のコンテキスト切替をまたいで維持されます。  

### Zenzai設定の拡充 (トピック・文体・好み・カスタムモデル・リッチ候補)

設定UIからZenzaiニューラル変換の「トピック」「文体」「好み」をプロファイルごとに指定できるようになり、  
ユーザプロファイルに加えてより細かく変換の傾向を調整できます。  

任意のGGUFファイルをカスタムZenzaiモデルとして直接指定して使用できるようになりました。  
指定したファイルが実在の通常ファイルでない場合は無効なものとして扱われ、安全にフォールバックします。  

「リッチ候補」の要求を、変換候補一覧 (候補ウィンドウ) と入力中の提案 (サジェスト) とで個別にON / OFF切り替えられるようになりました。  

### プロファイルごとの学習履歴の分離

「プロファイル非依存の入力履歴」設定を無効にすることで、プロファイルごとに学習データ (入力履歴) を別ディレクトリへ分離して保存できます。  
プロファイル単位でのデータ削除・履歴ディレクトリ選択についても回帰テストを追加し、動作を保証しています。  

### 設定UI強化 (辞書タブ・動詞活用情報表示・設定リセット)

ユーザ辞書の追加・編集・削除・TSV形式でのインポート・エクスポート、プロファイルごとの有効 / 無効切替を辞書タブに集約しました。  
単語編集ダイアログで「動詞」を選ぶと、読みの語尾から活用形が自動生成されることがUI上に表示されます。  

設定を初期値に戻す「リセット」ボタンを追加しました。リセット直後は初期値をプレビュー表示するのみで、  
既存のランタイム設定は保持されたまま、「適用」または「OK」を押すまで実際には保存されません。  
また、サーバへの設定保存に失敗した場合はエラーダイアログで通知されるようになりました。  

### サーバ設定の堅牢化

不正な形式のJSONファイルやカスタムキーマップファイルを読み込んでもクラッシュせず、安全にパースするようになりました。  
プロファイルが空の場合や、列挙値・数値範囲が不正な設定値は保存時に拒否されます。  
これらの検証ロジックに対する回帰テストも追加されています。  

### サーバプロセス管理の安定化

クライアント (fcitx5-hazkey) 更新時にhazkey-serverを自動再起動する仕組みを追加し、  
プロセス起動検出・再起動ハンドリング・学習データ保存の信頼性を向上させました。  

これによりバージョンアップ時の再起動トラブルが軽減されています。  

### マルチGPU環境でのSIGILLクラッシュ回避 ([Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29))

NVIDIA GPUとAMD/Intel iGPUが同居するLinux環境において、hazkey-serverが起動直後にSIGILLでクラッシュする問題を、  
ラッパースクリプトによるICDピン留め・Zenzaiビルド時パッチ・CPUフォールバック (`-DGGML_VULKAN=OFF`) の3層で自動回避します。  

詳細は下記「トラブルシューティング」セクションを参照してください。  

<br>

## ビルド

### 依存関係

- Swift >= 6.1
- fcitx5 >= 5.0.4
- Qt >= 6.7 (6.2以降でビルド可能ですが表示が崩れる場合があります)
- CMake >= 3.21 (4.x以降推奨)
- Protobuf >= 3.12
- Ninja
- Gettext
- Vulkan SDKヘッダ (`libvulkan-dev` / `vulkan-headers`) - `GGML_VULKAN=ON` (デフォルト) のビルドで必要

以下では、CI (`.github/workflows/build.yml`) で実際にビルド確認済みの4ディストリビューション向けに、  
Swiftのインストールから依存パッケージの導入までを個別に示します。  

### Swiftのインストール

Hazkeyのビルドには Swift 6.1 以上が必要です。  
公式ツールの [swiftly](https://www.swift.org/install/linux/swiftly) を使用してインストールします。  

> **2026年8月時点の注意**:  
> Fedora 44 / openSUSE Leap 16 / Debian 13 (Trixie) / Ubuntu 26.04 は、  
> いずれも [swift.orgの公式リリースtoolchain](https://www.swift.org/platform-support/) が未公開、または  
> swiftly (現行配布版 v1.1.3) の自動検出リストに未登録のため、`swiftly init` は「非公式プラットフォーム」と判定します。  
> `--platform` オプションで、実際に動作確認が取れている近いプラットフォームのtoolchainを明示指定してください。  
> (将来のswiftly/Swiftリリースで自動検出に対応した場合、`--platform` 指定は不要になります)  

#### Fedora 44

```sh
sudo dnf install git curl

curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
./swiftly init --quiet-shell-followup --platform fedora39
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && hash -r

swiftly install latest
swift --version
```

> Fedora 44は`fedora44`として自動検出されないため、公式リリースtoolchainが存在する`fedora39`を明示指定します。  
> `fedora39` toolchainは古いglibc上でビルドされているため、新しいFedora上でも問題なく動作します。  
> (`fedora41` toolchainも公開されていますが、現行のswiftlyの`--platform`からは選択できません)  

#### openSUSE Leap 16

```sh
sudo zypper install pkg-config binutils gcc gcc-c++ git gzip glibc-static libbsd-devel libedit-devel \
                    libicu-devel libcurl-devel ncurses-devel sqlite3-devel zlib-devel python3

curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar xf swiftly-$(uname -m).tar.gz
cd swiftly-$(uname -m)
```

`./swiftly init` 実行時に以下のエラーが表示される場合、openSUSEは証明書パスがDebian系と異なるため、シンボリックリンクの作成が必要です。  

```sh
# Error: The ca-certificates package is not installed. Swiftly won't be able to trust the sites ...
sudo ln -s /var/lib/ca-certificates/ca-bundle.pem /etc/ssl/certs/ca-certificates.crt
```

```sh
./swiftly init --quiet-shell-followup --platform ubi9
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && hash -r

swiftly install latest
swift --version
```

> openSUSE/SUSE系はswift.orgで公式サポートされたことが1度もないため、**RHEL 9 (`ubi9`) のtoolchainを選択してください**。  
> openSUSE Leap 16でのRHEL 9 toolchain選択は動作確認済みです。  
> `swiftly`/`swift`実行時に `libxml2.so.2` が見つからないエラーが出た場合は、以下を試してください。  

> ```sh
> sudo zypper install libxml2-16
> sudo ln -sf libxml2.so.16 /usr/lib64/libxml2.so.2
> ```

#### Debian 13 (Trixie) / Ubuntu 26.04

```sh
sudo apt update
sudo apt install build-essential ca-certificates curl git

curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
```

```sh
# Debian 13 (Trixie): Debian 13向けの公式toolchainは未公開のため、Debian 12を指定
./swiftly init --quiet-shell-followup --platform debian12

# Ubuntu 26.04: Ubuntu 26.04向けの公式toolchainは未公開のため、Ubuntu 24.04を指定
./swiftly init --quiet-shell-followup --platform ubuntu24.04
```

```sh
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && hash -r

swiftly install latest
swift --version
```

> **Ubuntu 26.04のみ追加対応が必要**:  
> `ubuntu24.04`向けtoolchainは`libxml2.so.2`を要求しますが、  
> Ubuntu 26.04は soname が上がった `libxml2.so.16` のみを同梱しているため、シンボリックリンクを作成してください。  

> ```sh
> sudo apt install libxml2-16
> sudo ln -sf /usr/lib/x86_64-linux-gnu/libxml2.so.16 /usr/lib/x86_64-linux-gnu/libxml2.so.2
> ```

### 依存関係ライブラリのインストール

Hazkeyのビルドに必要な依存パッケージをインストールします。  
Vulkanを使用しない場合は `vulkan-headers` 系パッケージのインストールを省略できます (`-DGGML_VULKAN=OFF` でビルド)。  
`spirv-headers` 系パッケージは、内蔵のllama.cppがVulkanシェーダのビルド時にSPIR-Vヘッダを要求するため必須です (`-DGGML_VULKAN=OFF` の場合もCMake configure時に `find_package` が要求します)。  

#### Fedora 44

```sh
sudo dnf install cmake ninja-build gettext pkgconf-pkg-config \
                 protobuf-devel protobuf-compiler protobuf-lite-devel \
                 fcitx5-devel fcitx5-qt-devel \
                 qt6-qtbase-devel qt6-qttools-devel \
                 vulkan-headers vulkan-loader-devel mesa-vulkan-drivers \
                 libglvnd-devel mesa-libGL-devel libxkbcommon-devel glslc glslang-devel \
                 spirv-headers-devel
```

#### openSUSE Leap 16

```sh
sudo zypper install cmake ninja gettext-tools protobuf-devel fcitx5-devel \
                    qt6-base-devel qt6-tools-devel qt6-linguist-devel vulkan-headers \
                    spirv-headers \
                    shaderc glslang-devel  # Vulkanを有効にする場合
```

#### Debian 13 (Trixie) / Ubuntu 26.04

```sh
sudo apt install cmake ninja-build pkg-config gettext \
                 protobuf-compiler libprotobuf-dev \
                 libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
                 qt6-base-dev qt6-tools-dev qt6-tools-dev-tools qt6-l10n-tools \
                 libvulkan-dev libglx-dev libgl1-mesa-dev libxkbcommon-dev glslc \
                 spirv-headers
```

### ソースビルド・インストール手順

ninjaを利用します。  

```sh
git clone --recursive https://github.com/presire/hazkey-community
cd hazkey-community

mkdir build && cd build

cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release  \
      -DCMAKE_INSTALL_PREFIX=/usr \
      ..
ninja
sudo ninja install
```

> swiftlyでインストールしたSwiftツールチェーンを使う場合、CMakeがランタイムライブラリを見つけられないことがあります。  
> その場合は `-DSWIFT_LINK_PATH=$HOME/.local/share/swiftly/toolchains/<バージョン>/usr/lib/swift/linux` を追加してください。  

> **注意:  
> ソースの配置パスに角括弧 `[` `]` を含めないでください。**  
> パスに角括弧が含まれていると (例: `[開発]hazkey-community`)、CMakeの `file(GLOB)` が角括弧を文字クラスとして解釈するため、
> llama.cppのVulkanビルド (`ExternalProject_Add`) が「source directory is empty」と誤検出してconfigureに失敗します。  
> 角括弧を含まないパスにcloneするか、`ln -sfn /actual/path/hazkey-community /tmp/hazkey-src-link` のように  
> 角括弧を含まないsymlink経由でcmakeを実行してください。全角文字自体は問題ありません。  

### ビルドオプション

| オプション | デフォルト | 説明 |
|---|---|---|
| `GGML_VULKAN` | `ON` | Zenzaiニューラル変換のVulkanバックエンド<br>GPUアクセラレーションを使用しない場合は、<br>`-DGGML_VULKAN=OFF` でCPU専用ビルドになります。 |

CPU専用ビルドの例:  

```sh
git clone --recursive https://github.com/presire/hazkey-community
cd hazkey-community

mkdir build && cd build

cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release  \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DGGML_VULKAN=OFF \
      ..
ninja
sudo ninja install
```

### Zenzai (GPUニューラル変換) のセットアップ

Zenzaiは、ニューラル変換用のモデルとGGMLバックエンドを使用するオプション機能です。  
GPUバックエンド (Vulkan) を使用する場合は、Hazkeyを `-DGGML_VULKAN=ON` (デフォルト) でビルドした上で、  
以下の手順でVulkanドライバを導入してください。**CPUバックエンドのみでもZenzaiは使用可能**です。  

#### NVIDIA GPU

```sh
#  Fedora 44 (RPM Fusionを使用。NVIDIA公式CUDAリポジトリはRHEL/CentOS向けのため非推奨) 
sudo dnf install \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda vulkan-tools
## Maxwell/Pascal/Volta世代 (GeForce GTX 900/10系等) は580xxブランチを使用
# sudo dnf install akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda vulkan-tools
sudo akmods --force && sudo dracut --force
sudo reboot

#  openSUSE Leap 16 
sudo zypper addrepo --refresh 'https://download.nvidia.com/opensuse/leap/$releasever/' NVIDIA
sudo zypper refresh
sudo zypper install nvidia-driver-G07-kmp-meta nvidia-gl-G07 vulkan-tools
## GeForce GT 1030を含むPascal世代以前のGPUはG06系列 (プロプライエタリ) を使用
# sudo zypper install nvidia-driver-G06-kmp-meta nvidia-gl-G06 vulkan-tools
sudo reboot

#  Debian 13 (Trixie) 
sudo sed -i 's/^Components: main non-free-firmware/Components: main contrib non-free non-free-firmware/' \
  /etc/apt/sources.list.d/debian.sources
sudo apt update
sudo apt install linux-headers-$(uname -r) nvidia-driver firmware-misc-nonfree
sudo reboot

#  Ubuntu 26.04 (標準のrestrictedリポジトリから導入。PPA追加は不要) 
sudo ubuntu-drivers install
sudo reboot
```

再起動後、NVIDIAドライバとVulkanを確認します。  

```sh
nvidia-smi
vulkaninfo --summary
```

`vulkaninfo --summary` の出力にNVIDIA GPUが表示されれば、Vulkanバックエンドは利用可能です。  

#### AMD GPU

```sh
# Fedora 44
sudo dnf install mesa-vulkan-drivers vulkan-tools

# openSUSE Leap 16
sudo zypper install libvulkan_radeon vulkan-tools

# Debian 13 (Trixie) / Ubuntu 26.04
sudo apt install mesa-vulkan-drivers vulkan-tools
```

```sh
vulkaninfo --summary
```

`vulkaninfo --summary` の出力にAMD Radeon GPUが表示されれば、Vulkanドライバは利用可能です。  

> `vulkaninfo` は上記いずれのディストリビューションでも `vulkan-tools` パッケージに含まれます (`mesa-utils` は不要です)。  
> ドライバ導入後は `ls /usr/share/vulkan/icd.d/` で `nvidia_icd.json` (NVIDIA) または  
> `radeon_icd*.json` (AMD) が存在することを確認してください。マルチGPU環境での注意点は下記トラブルシューティングを参照してください。  

#### モデルのダウンロードと有効化

1. hazkey-settingsを起動して、[AI]タブを開きます。  
2. 黄色の警告欄にある [モデルをダウンロード]ボタンを押下します。  
3. Zenzai v3.1 smallモデルが自動的にダウンロードされ、SHA-256を検証した後に以下のディレクトリへ保存されます。  
   `~/.local/share/hazkey/zenzai/zenzai.gguf`  
4. ダウンロード完了後に[再読み込み]ボタンを押下します。  
5. [Zenzaiを有効化]チェックボックスにチェックを入れて、[適用]または[OK]ボタンを押下します。  
6. Vulkan GPUがバックエンドの選択肢に表示されない場合は、Fcitx5を再起動してください。  
   `fcitx5-remote -r`  

## トラブルシューティング

### マルチGPU環境でhazkey-serverがSIGILLでクラッシュする

NVIDIA GPUとAMD/Intel iGPUが同居するLinux環境 (両方のVulkan ICDがインストール済み) で、  
`hazkey-server` が起動直後にSIGILL (signal 4) でクラッシュする現象があります。  
上流Issue [#29](https://github.com/7ka-Hiira/hazkey/issues/29) を参照してください。  

**原因**:  
Zenzai初期化時に `ggml_backend_load_all()` → Vulkan loaderがシステム内の全ICD (`nvidia_icd.json`, `radeon_icd.json` 等) をロードして、  
ベンダー混在の競合状態でSwiftランタイムのprecondition failure (`ud2` → SIGILL) が発生します。  

SIGILLはtrap命令のため `do/catch` で捕捉できません。  

**回避策**:  

本プロジェクトでは、以下の3層で自動的に回避します。  

1. **ラッパースクリプト** (`hazkey-server.sh`):  
   `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` が未設定の場合、  
   検出したICDのうち最初の1つだけを `export` してからhazkey-serverを起動します。  
2. **Zenzai側** (`AzooKeyKanaKanjiConverter` fork):  
   `ZenzContext.createContext` が `ggml_backend_load_all()` を呼ぶ前に、  
   ICDを1つに絞るロジックをビルド時にパッチとして自動適用します。  
   (`hazkey-server/patches/0001-zenzai-pin-vulkan-icd.patch`)
3. **CPUフォールバック**:  
   Vulkanを完全に無効化したい場合は `-DGGML_VULKAN=OFF` でCPU専用ビルドが可能です。  

**ユーザによる明示的な指定** (最も優先されます):  

```sh
# 例: NVIDIA GPUのみに固定
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
EOF
```

```sh
# 例: AMD GPUのみに固定
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
EOF
```

```sh
# 例: Intel iGPUのみに固定
mkdir -p ~/.config/hazkey
cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/intel_icd.x86_64.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.x86_64.json
EOF
```

> 注意:  
> ICDファイル名はディストリビューション・ドライバにより異なります。  
> - **AMD**: Mesa (RADV) は `radeon_icd.json`、AMD公式ドライバ (amdvlk) は `amd_icd.x86_64.json`  
> - **Intel**: Mesa (ANV) は `intel_icd.x86_64.json` (32ビット環境では `intel_icd.i686.json`)  
>
> 実際のファイル名は、`ls /usr/share/vulkan/icd.d/` コマンドで確認してください。  

<u>`~/.config/hazkey/env` に書いた環境変数は、hazkey-server起動時に読み込まれ、自動判定を上書きします。</u>  

#### Systemdサービスユニットのドロップインによる設定

hazkey-serverはfcitx5がオンデマンドで起動する子プロセスとして動作するため、  
fcitx5ユーザサービス (`/usr/lib/systemd/user/fcitx5.service`) に環境変数を設定すると、  
子プロセスのhazkey-serverにも継承されます。  

ラッパースクリプトは既存の環境変数を優先するため、ドロップインでの指定も確実に効きます。  

> **`~/.config/hazkey/env` との優先関係**:  
> ラッパースクリプトは `~/.config/hazkey/env` を `source` するため、  
> 両方に異なる値を書いた場合は **`~/.config/hazkey/env` 側が優先**されます。  
> そのため、混在させず、どちらか一方を使用してください。  

**ドロップインファイルの作成**:  

```sh
mkdir -p ~/.config/systemd/user/fcitx5.service.d
```

```ini
# ~/.config/systemd/user/fcitx5.service.d/vulkan-icd.conf
# 例: NVIDIA GPUのみに固定

[Service]
Environment="VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json"
Environment="VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json"
```

他のGPU向けは `Environment=` の値を以下に差し替えてください:  

| GPU | 設定値 |
|---|---|
| AMD (Mesa RADV) | `/usr/share/vulkan/icd.d/radeon_icd.json` |
| AMD (amdvlk) | `/usr/share/vulkan/icd.d/amd_icd.x86_64.json` |
| Intel (Mesa ANV) | `/usr/share/vulkan/icd.d/intel_icd.x86_64.json` |

**反映と確認**:  

```sh
systemctl --user daemon-reload
systemctl --user restart fcitx5.service

# 適用されている環境変数を確認
systemctl --user show fcitx5.service | grep ^Environment
# fcitx5プロセスが実際に持っている環境変数 (hazkey-serverも継承)
cat /proc/$(pgrep -x fcitx5)/environ | tr '\0' '\n' | grep VK_
```

## ライセンス

[MIT License](./LICENSE)  
