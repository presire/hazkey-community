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

| 機能 | 内容 |
|---|---|
| ユーザ辞書 (品詞・動詞活用対応) | TSV形式 (`読み<TAB>単語<TAB>コメント[<TAB>品詞]`) で単語を登録できる軽量なユーザ辞書。<br><br>品詞 (固有名詞・人名・地名・動詞) を指定すると、AzooKeyKanaKanjiConverterの接続コスト評価に正しく参加するようになり、候補ランキングに品詞が反映される。<br><br>従来は単純な前方挿入でエンジンのラティスをバイパスしていたため品詞がランキングに影響しなかった。<br>既存の3列TSVファイルも後方互換性を保ち読み込める。 |
| 動詞活用エンジン (azooKey由来) | azooKeyの `JapaneseConjugationBuilder` を移植した動詞活用エンジン。<br><br>ユーザ辞書に登録した動詞エントリから全活用形を自動生成し、<br>それぞれに正しいCIDを割り当てて接続コスト評価を適切に行う。<br><br>五段活用 (か・が・さ・た・な・ば・ま・ら・わ行)・一段活用・サ行変格 (する) に対応。 |
| 候補ウィンドウでのマウス選択 | 変換候補ウィンドウに表示された候補を、キーボードだけでなくマウスクリックでも選択可能。<br><br>候補選択に関する回帰テストも追加し、動作の安定性を確保。 |
| 文節境界調整 (`Shift+Left` / `Shift+Right`) | 変換中に `Shift+Left` / `Shift+Right` で文節の境界を直接調整可能。<br><br>エンジンが判定した文節区切りをユーザ側で微調整できるため、<br>複雑な文でも意図通りに変換しやすい。 |
| 自動変換の最小文字数を設定可能に | ライブ変換 (自動変換) がトリガーされるまでの最小文字数を設定UIから変更可能。<br><br>入力中の空の未確定文字列 (preedit) 更新による入力消失も回避されるよう改善。 |
| ライブ変換トグルホットキー | `Ctrl+Shift+L` (デフォルト、設定で変更可能) でライブ変換のON / OFFを即座に切替え。<br><br>トグルはサーバ側の `auto_convert_mode` を同期的に切替え (約3〜5[ms]で体感不可)<br><br>OFF時のモードは記憶されてアプリ間のコンテキスト切替をまたいで維持される。 |
| Zenzai設定の拡充 (トピック・文体・好み・カスタムモデル・リッチ候補) | 設定UIからZenzaiニューラル変換の「トピック」「文体」「好み」をプロファイルごとに指定でき、<br>ユーザプロファイルに加えてより細かく変換の傾向を調整可能。<br><br>任意のGGUFファイルをカスタムZenzaiモデルとして直接指定可能<br>(実在の通常ファイルでない場合は無効として安全にフォールバック)<br><br>「リッチ候補」の要求を、変換候補一覧 (候補ウィンドウ) と<br>入力中の提案 (サジェスト) とで個別にON / OFF切替え可能。 |
| プロファイルごとの学習履歴の分離 | 「プロファイル非依存の入力履歴」設定を無効にすることで、<br>プロファイルごとに学習データ (入力履歴) を別ディレクトリへ分離して保存可能。<br><br>プロファイル単位でのデータ削除・履歴ディレクトリ選択についても回帰テストを追加し、動作を保証。 |
| 設定UI強化 (辞書タブ・動詞活用情報表示・設定リセット) | ユーザ辞書の追加・編集・削除・TSV形式でのインポート・エクスポート、プロファイルごとの有効 / 無効切替を辞書タブに集約。<br><br>単語編集ダイアログで「動詞」を選ぶと、読みの語尾から活用形が自動生成されることがUI上に表示される。<br><br>設定を初期値に戻す「リセット」ボタン (リセット直後は初期値のプレビュー表示のみで、「適用」または「OK」まで実際には保存されない)<br><br>サーバへの設定保存失敗時はエラーダイアログで通知。 |
| サーバ設定の堅牢化 | 不正な形式のJSONファイルやカスタムキーマップファイルを読み込んでもクラッシュせず、安全にパース。<br><br>プロファイルが空の場合や、列挙値・数値範囲が不正な設定値は保存時に拒否。<br><br>これらの検証ロジックに対する回帰テストも追加。 |
| サーバプロセス管理の安定化 | クライアント (fcitx5-hazkey) 更新時にhazkey-serverを自動再起動する仕組みを追加し、<br>プロセス起動検出・再起動ハンドリング・学習データ保存の信頼性を向上。<br><br>バージョンアップ時の再起動トラブルを軽減。 |
| マルチGPU環境でのSIGILLクラッシュ回避 ([Issue #29](https://github.com/7ka-Hiira/hazkey/issues/29)) | NVIDIA GPUとAMD/Intel iGPUが同居するLinux環境において、<br>hazkey-serverが起動直後にSIGILLでクラッシュする問題を、<br>ラッパースクリプトによるICDピン留め・Zenzaiビルド時パッチ・CPUフォールバック (`-DGGML_VULKAN=OFF`) の3層で自動回避。<br><br>詳細は下記「トラブルシューティング」セクションを参照。 |

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

> **2026年9月時点の注意**:  
> Fedora 44 / openSUSE Leap 16 / Debian 13 (Trixie) / Ubuntu 26.04 は、  
> いずれも [swift.orgの公式リリースtoolchain](https://www.swift.org/platform-support/) が未公開、  
> または、swiftly (現行配布版 v1.1.3) の自動検出リストに未登録のため、`swiftly init` は「非公式プラットフォーム」と判定します。  
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
>   
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

#### Vulkanデバイスの選び方 (GPU性能の目安)

Radeon RX 550のような非力なGPUでは、全レイヤをオフロードすると転送オーバーヘッドが勝ってCPUより致命的に遅くなる場合があります。  
Vulkanデバイスを選ぶ時は、下記の最低ラインを目安にしてください。  

<br>

**共通の最低ライン (Zenzaiクラスの小規模モデルをVulkanで実用するため)**:  

- VRAM 6[GB]以上、帯域 200[GB/s]以上、Vulkan 1.3 + `VK_KHR_cooperative_matrix` または FP16対応  
- NVIDIA: GTX 1660 SUPER / RTX 3050 6[GB]以上  
- AMD: RX 6600 8[GB]以上  
- Intel: Arc A380 6[GB]以上  
- これ未満の場合は、`-DGGML_VULKAN=OFF` を付加してCPU専用ビルドにするか、`VK_DRIVER_FILES` でiGPU/CPU側に倒す方が実用的です。  

<br>

モデル別の仕様・推奨性能は以下の通りです。  
仕様値は、Hugging Face 上の各GGUFリポジトリと設定UIのモデル管理 (`hazkey-settings/zenzai_models.cpp` の `availableZenzaiModels()`) より。  

<br>

| モデル (キー) | Hugging Face (GGUF) | パラメータ / 量子化 / 実測サイズ | ライセンス | 設定UIでの扱い |
|---|---|---|---|---|
| zenz-v3.2-small | [Miwa-Keita/zenz-v3.2-small-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf) | 95.1M params / Q5_K_M / 73.9[MB]<br>(UI表記 ~74 [MB]) | Apache-2.0 | `recommended: true`<br>(推奨・最新・最高精度) |
| zenz-v3.2-xsmall | [Miwa-Keita/zenz-v3.2-xsmall-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.2-xsmall-gguf) | 25.6M params / Q5_K_M / 21[MB]<br>(UI表記 ~21 [MB]) | Apache-2.0 | 軽量・CPU高速・やや低精度 |
| zenz-v3.1-small | [Miwa-Keita/zenz-v3.1-small-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf) | 95.1M params / Q5_K_M / 73.9[MB]<br>(UI表記 ~74 [MB]) | CC-BY-SA-4.0 | `isLegacyGen: true`<br>(旧世代・互換維持用) |

<br>

いずれもアーキテクチャは `gpt2` (かな漢字変換特化の条件付き言語モデル) で、モデルカードのREADMEは空のため精度の数値比較は公開されていません。  

系列の位置づけは、  
azooKey本体の [Update zenz models to v3.2 (#725)](https://github.com/azooKey/azooKey/commit/c77a57745a12b435c28c072811bc01e0c3a611ed) がv3.1-small/xsmallをv3.2-small/xsmallに置換している通り、  
**v3.2がv3.1の後継**です。  

v3.1-smallは互換維持用と捉え、新規利用はv3.2-smallを選んでください。  

ライセンスもv3.1系のCC-BY-SA-4.0からv3.2系のApache-2.0に変更されています。  

<br>

- **zenz-v3.2-small (Q5_K_M, 73.9 [MB], 推奨・最新・最高精度)**:  
  上記の共通最低ラインをそのまま適用してください。  
  
  GTX 1660 SUPER / RTX 3050 6[GB]、RX 6600 8[GB]、Arc A380 6[GB]以上が目安です。  
  RX 550級 (2[GB]、帯域 ~112[GB/s]、FP16が弱い) ではモデル自体 (74[MB]弱) はVRAMに載っても、  
  KV cache・PCIe転送・弱いシェーダ性能がボトルネックになり、CPU (`HAZKEY_ZENZAI_CPU_THREADS=4` 程度) より遅くなります。  
  
- **zenz-v3.2-xsmall (Q5_K_M, 21 [MB], 軽量・CPU高速・やや低精度)**:  
  パラメータがsmallの約1/4 (95.1M → 25.6M) のため要求は一段低くなります。  
  
  目安はVRAM 2〜4[GB]以上・Vulkan 1.2以上で、UHD 770 / Iris Xe / Radeon 760M/780M級の現行iGPUや、  
  GTX 1650 / RX 6400 / Arc A310級でも実用になります。  
  
  ただし、計算量が小さい分、転送オーバーヘッドの比率が上がるため、  
  RX 550級の弱いdGPUよりCPU (4スレッド程度) や現行iGPUの方が速い・安定な場合が多く、あえて弱いdGPUを選ぶ必要はありません。  
  
  CPU専用でも十分速いモデルです。
  
- **zenz-v3.1-small (Q5_K_M, 73.9 [MB], 旧世代・互換維持用)**:  
  GGUFの実測サイズ・パラメータ数がv3.2-smallと同一 (95.1M / 73.9[MB]) のため、推奨性能はv3.2-smallと同じです。  
  共通最低ライン (GTX 1660 SUPER / RX 6600 / Arc A380以上) を適用してください。  
  
  ***※ただし、新規に選ぶ理由は薄く、既存環境の再現用と割り切ってください。***  

<br>

> **注意**:  
> 3モデルとも数十[MB]級のため、6[GB]というVRAM基準は「モデルが載るか」ではなく「帯域・FP16スループット・ドライバ成熟度で実用速度が出るか」の基準です。  
> small系 (74[MB]) と xsmall (21[MB]) で推奨を分けたのはこのためで、xsmallは弱いGPUでも動作自体はしますが、  
> IME用途の短文・低遅延推論ではGPU転送損が相対的に大きく、CPUの方が安定する逆転現象が起きます。  

<br>

**デバイス名の例 (設定UIの選択肢・`vulkaninfo --summary` / `lspci`表示の目安)**:  

- デスクトップ向けグラフィックボード:  
  - Intel: Arc A380 / A580 / A750 / A770 / Battlemage B580  
  - NVIDIA: GeForce GTX 1660 SUPER / RTX 3060 / RTX 4060 / RTX 4070  
  - AMD: RX 6600 / RX 7600 / RX 6700 XT  
- CPU内蔵iGPU:
  - Intel: UHD Graphics 730 / 770 / Iris Xe Graphics / Core Ultra内蔵Arc Graphics (140V/140T等)  
  - AMD: Radeon Vega 8 / Radeon 760M / 780M / Ryzen 8600G内蔵 Radeon Graphics  
- ラップトップ向けdGPU (モバイル):  
  - Intel: Arc A370M / A550M / A730M  
  - NVIDIA: GeForce MX550 / RTX 3050 Laptop / RTX 4050/4060 Laptop / RTX 3060 Laptop  
  - AMD: Radeon RX 6500M / RX 6600M / RX 7600M XT / RX 6800M  

<br>

弱いdGPU + 強いiGPUの混在 (例: RX 550 + Ryzen 780M) ではiGPU側が速い場合があるため、単純なdGPU優先は避けてください。  
確実に外す場合は、`~/.config/hazkey/env` で `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` を明示するか、  
CPU専用ビルド (`-DGGML_VULKAN=OFF`) を使用してください。  

詳細は下記トラブルシューティングを参照してください。  

<br>

### `~/.config/hazkey/env` による詳細設定

`hazkey-server` 起動時に読み込まれる環境変数ファイルです。  
Vulkan ICDの固定とZenzai CPU予算制御などを、設定UIを経由せずに上書きできます。  

**読み込みの仕組み**:  
ラッパースクリプト (`hazkey-server/hazkey-server.sh.in`) が  
`${XDG_CONFIG_HOME:-$HOME/.config}/hazkey/env` (通常は `~/.config/hazkey/env`) を `set -a` で `source` し、  
`exec` する `hazkey-server` プロセスに引き継ぎます。  

ファイルが存在しない場合は何もしません。  
書式は1行1変数の `KEY=value` (`export` は不要、`#` 以降はコメント)  

<br>

| 変数名 | 用途 | 設定値 |
|---|---|---|
| `VK_DRIVER_FILES` | 使用するVulkan ICDの固定 (マルチGPUのSIGILL回避) | ICDのJSONパス (例: `/usr/share/vulkan/icd.d/nvidia_icd.json`)<br>実在名は、`ls /usr/share/vulkan/icd.d/` で確認 |
| `VK_ICD_FILENAMES` | 同上 (Vulkan loader向けの別名)<br>`VK_DRIVER_FILES` と同じ値を書く | 同上 |
| `HAZKEY_ZENZAI_CPU_THREADS` | Zenzai CPU推論のスレッド数 (オプトイン) | `1`〜`8` |
| `HAZKEY_ZENZAI_DEADLINE_MS` | Zenzai CPU推論の締切時間ミリ秒 (オプトイン) | `0`〜`2000`<br>`0` は無期限 (締切なし)<br>締切超過時はニューラル変換なしにフォールバック |
| `HAZKEY_ZENZAI_MODEL` | Zenzaiモデル (`zenzai.gguf`) の明示指定 (上級者向け) | 実在する通常ファイルのパス<br>環境変数 > `~/.local/share/hazkey/zenzai/zenzai.gguf` > システム配備の順に探索 |
| `HAZKEY_DICTIONARY` | 辞書ディレクトリの明示指定 (上級者向け) | 実在するディレクトリのパス |
| `GGML_BACKEND_DIR` | llama.cppバックエンド (`.so`) の探索ディレクトリ (上級者向け) | ディレクトリのパス (末尾 `/` はなくても可、自動補完) |

デフォルト値 (未設定・無効値時の動作):

- `VK_DRIVER_FILES`:  
  未設定時は検出された最初のICDに自動ピン留め。  
- `VK_ICD_FILENAMES`:  
   同上  
- `HAZKEY_ZENZAI_CPU_THREADS`:  
  未設定時は既存動作を維持  
  `0`・`9`・非数値など範囲外はデフォルト動作にフォールバック  
- `HAZKEY_ZENZAI_DEADLINE_MS`:  
  未設定時は既存動作を維持  
  負数・範囲外・非数値などはデフォルト動作にフォールバック  
- `HAZKEY_ZENZAI_MODEL`:  
  未設定時は自動検出  
  実在しない・通常ファイルでない場合は、次の候補にフォールバック  
- `HAZKEY_DICTIONARY`:  
  未設定時・存在しない場合はシステムの `Dictionary` を使用  
- `GGML_BACKEND_DIR`:  
  未設定時は `<systemLibrary>/libllama/backends/` を使用  

<br>

**設定例** (Vulkan固定 + CPU予算制御の併用):  

```sh
mkdir -p ~/.config/hazkey

cat > ~/.config/hazkey/env <<'EOF'
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
HAZKEY_ZENZAI_CPU_THREADS=4
HAZKEY_ZENZAI_DEADLINE_MS=0
EOF

# 次回サーバ起動時に反映 (即時反映したい場合)
pkill -x hazkey-server
```

> **注意**:  
> - `XDG_CONFIG_HOME` が設定されている環境では `~/.config/hazkey/env` ではなく `$XDG_CONFIG_HOME/hazkey/env` が読まれます。  
> - systemdドロップイン (`fcitx5.service.d/*.conf` の `Environment=`) と両方に異なる値を書いた場合は、  
>   **`~/.config/hazkey/env` 側が優先**されます。(ラッパーが `source` で上書きするため)  
>   混在させず、どちらか一方を使ってください。  
> - `HAZKEY_ZENZAI_CPU_THREADS` / `HAZKEY_ZENZAI_DEADLINE_MS` の実体は `AzooKeyKanaKanjiConverter` fork側で読み取られます。  
    不正値はクラッシュせず既存動作にフォールバックします。  

<br>

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
