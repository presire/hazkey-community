# ソースからのビルド

## 依存関係

- Swift >= 6.1  
- Fcitx 5 >= 5.0.4 (開発ヘッダ含む。`ENABLE_FCITX5=ON` 時に必要)  
- IBus (開発ヘッダ `libibus-1.0-dev` / `ibus-devel`。`ENABLE_IBUS=ON` 時に必要)  
- Qt >= 6.7 (6.2 以降でもビルド可能ですが表示が崩れる場合があります)  
- CMake >= 3.21 (4.x以降推奨)  
- Protobuf >= 3.12  
- Ninja  
- Gettext  
- Vulkan SDKヘッダ (`libvulkan-dev` / `vulkan-headers`)  
  `GGML_VULKAN=ON` (デフォルト) のビルドで必要  

以下では、CI (`.github/workflows/build.yml`) で実際にビルド確認済みの4ディストリビューション向けに、  
Swiftのインストールから依存パッケージの導入までを個別に示します。  

## Swiftのインストール

Hazkey-Communityのビルドには Swift 6.1 以上が必要です。  
公式ツールの [swiftly](https://www.swift.org/install/linux/swiftly) を使用してインストールします。  

> **2026年9月時点の注意**:  
> Fedora 44 / openSUSE Leap 16 / Debian 13 (Trixie) / Ubuntu 26.04 は、  
> いずれも [swift.orgの公式リリースtoolchain](https://www.swift.org/platform-support/) が未公開、  
> または、swiftly (現行配布版 v1.1.3) の自動検出リストに未登録のため、`swiftly init` は「非公式プラットフォーム」と判定します。  
> `--platform` オプションで、実際に動作確認が取れている近いプラットフォームのtoolchainを明示指定してください。  
> (将来のswiftly/Swiftリリースで自動検出に対応した場合、`--platform` 指定は不要になります)  

### Fedora 44

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
> `fedora39` ツールチェーンは古いglibc上でビルドされているため、新しいFedora上でも問題なく動作します。  
> (`fedora41` ツールチェーンも公開されていますが、現行のswiftlyの`--platform`からは選択できません)  

### openSUSE Leap 16

```sh
sudo zypper install pkg-config binutils gcc gcc-c++ git gzip glibc-static \
                    libbsd-devel libedit-devel libicu-devel libcurl-devel \
                    ncurses-devel sqlite3-devel zlib-devel python3

curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar xf swiftly-$(uname -m).tar.gz
```

`./swiftly init` 実行時に以下のエラーが表示される場合、  
openSUSEは証明書パスがDebian系と異なるため、シンボリックリンクの作成が必要です。  

```sh
# Error: The ca-certificates package is not installed. Swiftly won't be able to trust the sites ...
sudo ln -s /var/lib/ca-certificates/ca-bundle.pem \
           /etc/ssl/certs/ca-certificates.crt
```

```sh
./swiftly init --quiet-shell-followup --platform ubi9
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && hash -r

swiftly install latest
swift --version
```

> openSUSE / SLE系は、swift.orgで公式サポートされたことが1度もないため、  
> **RHEL 9 (`ubi9`) のtoolchainを選択してください**。  
> 
> openSUSE Leap 16でのRHEL 9 toolchain選択は動作確認済みです。  
> `swiftly`/`swift`実行時に `libxml2.so.2` が見つからないエラーが出た場合は、以下を試してください。  

> ```sh
> sudo zypper install libxml2-16
> sudo ln -sf libxml2.so.16 /usr/lib64/libxml2.so.2
> ```

### Debian 13 (Trixie) / Ubuntu 26.04

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
> sudo ln -sf /usr/lib/x86_64-linux-gnu/libxml2.so.16 \
>             /usr/lib/x86_64-linux-gnu/libxml2.so.2
> ```

## 依存パッケージのインストール

各ディストリビューションでの依存パッケージの導入コマンドは以下の通りです。  
`-DGGML_VULKAN=OFF` のCPU専用ビルドでは、  
Vulkan関連パッケージ (`vulkan-headers` / `vulkan-loader-devel` / `glslc` / `spirv-headers` 等) のインストールを省略できます。  

### Fedora 44

```sh
sudo dnf install cmake ninja-build gettext pkgconf-pkg-config \
                 protobuf-devel protobuf-compiler protobuf-lite-devel \
                 fcitx5-devel fcitx5-qt-devel \
                 ibus-devel \
                 qt6-qtbase-devel qt6-qttools-devel \
                 vulkan-headers vulkan-loader-devel mesa-vulkan-drivers \
                 libglvnd-devel mesa-libGL-devel libxkbcommon-devel glslc glslang-devel \
                 spirv-headers-devel
```

> `ibus-devel` は IBus フロントエンド (`-DENABLE_IBUS=ON`) のビルド時に必要です。Fcitx 5 版のみ建てる場合は省略できます。

### openSUSE Leap 16

```sh
sudo zypper install cmake ninja gettext-tools protobuf-devel fcitx5-devel \
                    ibus-devel \
                    qt6-base-devel qt6-tools-devel qt6-linguist-devel \
                    patterns-devel-vulkan-devel_vulkan \
                    vulkan-headers shaderc glslang-devel spirv-headers
```

> `ibus-devel` は IBus フロントエンド (`-DENABLE_IBUS=ON`) のビルド時に必要です。Fcitx 5 版のみ建てる場合は省略できます。

### Debian 13 (Trixie) / Ubuntu 26.04

```sh
sudo apt install cmake ninja-build pkg-config gettext \
                 protobuf-compiler libprotobuf-dev \
                 libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
                 libibus-1.0-dev \
                 qt6-base-dev qt6-tools-dev qt6-tools-dev-tools qt6-l10n-tools \
                 libvulkan-dev libglx-dev libgl1-mesa-dev libxkbcommon-dev glslc \
                 spirv-headers
```

> `libibus-1.0-dev` は IBus フロントエンド (`-DENABLE_IBUS=ON`) のビルド時に必要です。Fcitx 5 版のみ建てる場合は省略できます。

`spirv-headers` 系パッケージは、  
内蔵のllama.cppがVulkanバックエンドのCMake configure時に `find_package(SPIRV-Headers)` を要求するため、  
Vulkanビルドでは必須です。  

パッケージ名の最新の定義は、CIの定義 (`.github/workflows/build.yml`) も参照してください。  

## ビルド手順

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

インストール後は、使用中のフレームワークを再起動して入力メソッドに登録してください。(Fcitx 5・IBus とも[初回の有効化](../README.md#初回の有効化) 参照)  
既定のビルドは Fcitx 5 版のみで、IBus 版が必要な場合は `-DENABLE_IBUS=ON` を付けてください。  

## ビルドオプション

| オプション | デフォルト | 説明 |
|---|---|---|
| `ENABLE_FCITX5` | `ON` | Fcitx 5 フロントエンド (`fcitx5-hazkey`) をビルド |
| `ENABLE_IBUS` | `OFF` | IBus フロントエンド (`ibus-hazkey`) をビルド (`pkg-config ibus-1.0` が必要) |
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
