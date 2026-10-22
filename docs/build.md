# ソースコードからのビルド

## 依存関係

- Swift >= 6.1  
- Fcitx 5 >= 5.0.4 (開発ヘッダ含む)  
  `ENABLE_FCITX5=ON`オプション指定時に必要  
- IBus (開発ヘッダ: `libibus-1.0-dev` / `ibus-devel`)  
  `ENABLE_IBUS=ON`オプション指定時に必要  
- Qt >= 6.7 (6.2以降でもビルド可能ですが表示が崩れる場合があります)  
- CMake >= 3.21 (4.x以降推奨)  
- Protobuf >= 3.12  
- Ninja  
- Gettext  
- Vulkan SDKヘッダ (`libvulkan-dev` / `vulkan-headers`)  
  `GGML_VULKAN=ON`オプション指定時に必要 (デフォルト)  

以下では、CI (`.github/workflows/build.yml`) で実際にビルド確認済みの4ディストリビューション向けに、  
Swiftのインストールから依存パッケージの導入までを個別に示します。  

## Swiftのインストール

Hazkey Communityのビルドには、Swift 6.1以上が必要です。  
公式ツールの[swiftly](https://www.swift.org/install/linux/swiftly)を使用してインストールします。  

> **2026年10月時点の注意**:  
> Debian 13 (Trixie) / Ubuntu 26.04 は、[swift.orgの公式リリース ツールチェーン](https://www.swift.org/platform-support/) が公開されています (`debian13` / `ubuntu26.04`)。  
> Fedora 44 / openSUSE Leap 16 / openSUSE Tumbleweed 向けのツールチェーンは無いため、  
> それぞれFedora Linux 41 (`fedora41`) / RHEL 9 (`ubi9`) のツールチェーンを使います。  
> 以下の手順では、どのディストリビューションでも`--platform`オプションでツールチェーンを明示指定します。  
> (CIの`.github/workflows/build.yml`も、同じ対応でSwift 6.4.1のツールチェーンを使います)  

### Fedora 44

```sh
sudo dnf install git curl

curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz

./swiftly init --quiet-shell-followup --platform fedora41
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && hash -r

swiftly install latest
swift --version
```

> Fedora 44向けのツールチェーンは無いため、公式リリースツールチェーンが存在する最新のFedora (`fedora41`) を明示指定します。  
> `swiftly init`の対話メニューでは「Fedora Linux 41」に当たります。  
> `fedora41`ツールチェーンは古いglibc上でビルドされているため、新しいFedora上でも動作します。  

### openSUSE Leap 16

```sh
sudo zypper install pkg-config binutils gcc gcc-c++ git gzip glibc-static \
                    libbsd-devel libedit-devel libicu-devel libcurl-devel \
                    ncurses-devel sqlite3-devel zlib-devel python3

curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar xf swiftly-$(uname -m).tar.gz
```

`./swiftly init`コマンドの実行時に以下のエラーが表示される場合、  
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
> **RHEL 9 (`ubi9`) のツールチェーンを選択してください**。  
> 
> openSUSE Leap 16でのRHEL 9ツールチェーン選択は動作確認済みです。  
> `swiftly`/`swift`コマンド実行時において、`libxml2.so.2`が見つからないエラーが出た場合は、以下を試してください。  

> ```sh
> sudo zypper install libxml2-16
> sudo ln -sf libxml2.so.16 /usr/lib64/libxml2.so.2
> ```

> この対処が必要なのは、**ソースからビルドする環境のSwiftツールチェーン (`swiftly`/`swift`コマンド) を動かす場合だけ**です。  
> ビルドしたhazkey-community-serverはSwiftランタイムを静的にリンクしており、`libxml2.so.2`に依存しません。  
> GitHub Releasesの`.rpm` / `.deb`パッケージの導入・実行に、`libxml2.so.2`は不要です。  

### Debian 13 (Trixie) / Ubuntu 26.04

```sh
sudo apt update
sudo apt install build-essential ca-certificates curl git

curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
```

```sh
# Debian 13 (Trixie): Debian 13向けの公式ツールチェーンを指定
./swiftly init --quiet-shell-followup --platform debian13

# Ubuntu 26.04: Ubuntu 26.04向けの公式ツールチェーンを指定
./swiftly init --quiet-shell-followup --platform ubuntu26.04
```

```sh
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && hash -r

swiftly install latest
swift --version
```

> `ubuntu26.04`向けツールチェーンはUbuntu 26.04の`libxml2.so.16`をそのまま使うため、  
> 以前の`ubuntu24.04`向けツールチェーンで必要だった`libxml2.so.2`のシンボリックリンクは不要です。  
> `libxml2.so.16`が見つからないエラーが出た場合は、`sudo apt install libxml2-16`を実行してください。  

## 依存パッケージのインストール

各ディストリビューションでの依存パッケージの導入コマンドは以下の通りです。  

`-DGGML_VULKAN=OFF`オプションのCPU専用ビルドでは、  
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

> `libibus-1.0-dev`パッケージは、IBusフロントエンド (`-DENABLE_IBUS=ON`) のビルド時に必要です。  
> Fcitx 5版のみビルドする場合は省略可能です。

### openSUSE Leap 16

```sh
sudo zypper install cmake ninja gettext-tools protobuf-devel fcitx5-devel \
                    ibus-devel \
                    qt6-base-devel qt6-tools-devel qt6-linguist-devel \
                    patterns-devel-vulkan-devel_vulkan \
                    vulkan-headers shaderc glslang-devel spirv-headers
```

> `libibus-1.0-dev`パッケージは、IBusフロントエンド (`-DENABLE_IBUS=ON`) のビルド時に必要です。  
> Fcitx 5版のみビルドする場合は省略可能です。

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

> `libibus-1.0-dev`パッケージは、IBusフロントエンド (`-DENABLE_IBUS=ON`) のビルド時に必要です。  
> Fcitx 5版のみビルドする場合は省略可能です。

`spirv-headers`系パッケージは、内蔵のllama.cppがVulkanバックエンドのCMakeコマンド実行時に`find_package(SPIRV-Headers)`を要求するため、  
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

インストール後は、使用中のフレームワークを再起動して入力メソッドに登録してください。(Fcitx 5・IBusとも[初回の有効化](../README.md#初回の有効化)を参照)  
既定のビルドはFcitx 5版のみであり、IBus版が必要な場合は`-DENABLE_IBUS=ON`オプションを指定してください。  

## ビルドオプション

| オプション | デフォルト | 説明 |
|:---|:---:|:---|
| **`ENABLE_FCITX5`** | `ON` | Fcitx 5フロントエンド (`fcitx5-hazkey`) をビルド |
| **`ENABLE_IBUS`** | `OFF` | IBusフロントエンド (`ibus-hazkey`) をビルド (`pkg-config ibus-1.0`が必要) |
| **`ENABLE_SELINUX`** | `OFF` | SELinuxポリシーモジュール (hazkey_community) をビルド<br>`/usr`以外へのインストール時の拒否を避けるために使用する<br>(`checkmodule`、`semodule_package`、`semodule`、`restorecon`が必要<br><br>詳細は、[SELinuxポリシー](../selinux/README.md)を参照) |
| **`GGML_VULKAN`** | `ON` | ZenzaiのVulkan (GPU) バックエンド<br>CPU専用ビルドにする場合は、`-DGGML_VULKAN=OFF`オプションを指定する |
| **`HAZKEY_SERVER_ENABLE_ZENZAI`** | `ON` | Zenzaiニューラル変換機能の有効化 |
| **`HAZKEY_SERVER_STATIC_SWIFT_STDLIB`** | `ON` | Swift標準ライブラリをhazkey-community-serverに静的リンク<br>`OFF`にすると動的リンクになり、実行環境にもSwiftランタイムが必要になる |
| **`SWIFT_DYNAMIC_LIB_PATH`** | (自動検出) | 静的リンク時に追加するSwiftライブラリのリンクパス ([swiftlang/swift#78003](https://github.com/swiftlang/swift/issues/78003) の回避用)<br>未指定時は、`swift -print-target-info`から自動検出する |
| **`SWIFT_LINK_PATH`** | (未指定) | Swiftランタイムライブラリのリンクパス<br>swiftly等でインストールしたツールチェーンをCMakeが見つけない場合に、`<ツールチェーン>/usr/lib/swift/linux`を明示する |

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
> パスに角括弧が含まれていると、CMakeの`file(GLOB)`が誤解釈し、llama.cppのVulkanビルドが失敗することがあります。  
> 角括弧を含まないパスにクローンするか、角括弧を含まないシンボリックリンク経由でcmakeコマンドを実行してください。  

### Swift標準ライブラリの静的リンク

GitHub Releasesのパッケージと同様に、Swift標準ライブラリを静的リンクしてビルドすると、  
ビルドしたバイナリを実行する環境にSwift (ツールチェーン・ランタイム) をインストールする必要がなくなります。  
(ビルドする環境には、上記「Swiftのインストール」の手順でSwiftが必要です)  

静的リンクは既定で有効 (`HAZKEY_SERVER_STATIC_SWIFT_STDLIB=ON`) のため、上記「ビルド手順」のとおりにビルドすれば静的リンクされます。  
明示する場合は、次のように指定します。  

```sh
cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DHAZKEY_SERVER_STATIC_SWIFT_STDLIB=ON \
      ..
ninja -j $(nproc)
sudo ninja install
```

ビルド時において、`Detected Swift dynamic library path: ...`メッセージが表示されれば、リンクパスは自動検出されています。  

もし、`Failed to detect Swift dynamic library path`の警告が表示されてビルドが失敗する場合は、  
`-DSWIFT_DYNAMIC_LIB_PATH=<ツールチェーン>/usr/lib/swift/linux`オプションを指定してください。  

インストール後、Swiftのランタイムライブラリ (`libswiftCore.so`等) に依存していないことは、次のコマンドで確認できます。  
(何も表示されなければ静的リンクされています)  

```sh
ldd /usr/lib*/hazkey-community/hazkey-community-server | grep -i swift
```
