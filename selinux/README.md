# Hazkey Community SELinux Policy Module

Hazkey Communityの変換サーバ (`hazkey-community-server`) 向けのSELinuxポリシーモジュールです。  

<br>

## 概要

Hazkey Communityを`/usr`以外 (`/usr/local`、`/opt`、ホームディレクトリ) にインストールすると、  
ファイルのラベルが、インストール先ごとの既定の型 (usr_t、gconf_home_t、home_bin_t等) になります。  

このため、制限ユーザ (user_t、staff_t) での実行が拒否されたり、監査ログに拒否が記録されたりすることがあります。  

このモジュールは、次のものを提供します。  

- 全てのインストール先に対する一貫したファイルラベル  
  (`/usr`、`/usr/local`、`/opt/hazkey-community`、`~/.local`、CMakeで指定した任意のプレフィックス)  
- 変換サーバ専用のドメイン (hazkey_community_server_t)  
  (変換サーバは全てのキー入力を受け取るため、TCPとUDPの通信と、ポート番号への束縛 (name_bind) を禁止します)  
- ユーザデータ (設定、学習データ、モデル、キャッシュ) 専用の型  
- 他のポリシーモジュールから利用するためのインターフェース (`hazkey_community.if`)  

### ドメイン

| ドメイン | 対象 | 説明 |
|---|---|---|
| hazkey_community_server_t | `<libdir>/hazkey-community/hazkey-community-server` | 変換サーバ<br>ログインユーザごとに1プロセス |

Fcitx 5のアドオン、IBusのエンジン、設定GUI、ラッパースクリプト (`<bindir>/hazkey-community-server`) は、  
起動元のドメインのまま動作します。  

### 主な型

| 型 | 対象 |
|---|---|
| hazkey_community_exec_t | 変換サーバの実行ファイル |
| hazkey_community_conf_home_t | `~/.config/hazkey-community`<br>ユーザ辞書、`env`等 (変換サーバは読み取りだけ) |
| hazkey_community_config_t | `~/.config/hazkey-community/config.json`、`config.json.tmp`<br>変換サーバが書き込む設定ファイルと、その保存に使う一時ファイル |
| hazkey_community_data_home_t | `~/.local/share/hazkey-community`<br>Zenzaiのモデル |
| hazkey_community_state_home_t | `~/.local/state/hazkey-community`<br>学習データ |
| hazkey_community_cache_home_t | `~/.cache/hazkey-community`<br>キャッシュ |
| hazkey_community_runtime_t | `$XDG_RUNTIME_DIR/hazkey-community-server.<UID>.sock`<br>`$XDG_RUNTIME_DIR/hazkey-community-server.<UID>.lock`<br>クライアント接続用のソケットと、単一起動用のロックファイル |
| hazkey_community_tmp_t | `/tmp/hazkey-community-*`<br>ソケットの代替の置き場所、CPU専用バックエンドの一時配置 |

### Boolean

| Boolean | 既定 | 説明 |
|---|---|---|
| [hazkey_community_use_gpu] | on | GPU (Vulkan) によるニューラル変換を許可する |
| [hazkey_community_gpu_execmem] | on | GPUの利用時に、実行可能なメモリの確保 (execmem) を許可する<br>(lavapipeやNVIDIAのドライバが実行時にコードを生成するために必要。AMDのRADV、IntelのANVでは不要) |
| [hazkey_community_read_user_files] | on | ホームディレクトリ配下の任意のモデルと辞書の読み取りを許可する<br>(設定GUIで指定したカスタム重み、[HAZKEY_ZENZAI_MODEL]で指定したモデル等) |
| [hazkey_community_write_gpu_cache] | on | GPUドライバが`~/.cache`直下に作成する共有のシェーダキャッシュへの書き込みを許可する<br>(`~/.cache/mesa_shader_cache`等) |

<br>

## サポート対象

| ディストリビューション | ポリシー | 型名の系統 (FLAVOR) | 動作確認 |
|---|---|---|---|
| openSUSE Leap 16 | targeted | redhat | 実機 (targeted、MLS有効時) とコンテナで、ビルド・読み込み・ラベルを確認 |
| openSUSE Tumbleweed | targeted | redhat | コンテナで、ビルド・読み込み・ラベルを確認 |
| Fedora 44 | targeted | redhat | コンテナで、ビルド・読み込み・ラベルを確認 |
| RHEL 9とRHEL 10系 | targeted | redhat | Fedoraと同じ系統 (未確認) |
| Debian 13 | default (`selinux-policy-default`) | refpolicy | コンテナで、ビルド・読み込み・ラベルを確認 (ドメイン遷移は未確認) |
| Ubuntu 26.04 | default (`selinux-policy-default`) | refpolicy | コンテナで、ビルド・読み込み・ラベルを確認 (ドメイン遷移は未確認) |

Debian 13とUbuntu 26.04のSELinuxは、公式に設定済みの環境ではなく、利用者が`selinux-policy-default`を導入して有効にする構成です。  
この2つのディストリビューションでは、基本ポリシーの型名が、upstreamのReference Policy (xdg_config_t等) です。  
このため、ビルド時にモジュールのソースの型名を自動で置き換えます。(下記の「型名の系統」を参照)  

### 型名の系統 (FLAVOR)

`hazkey_community.te`は、FedoraとopenSUSEの基本ポリシーの型名 (config_home_t、data_home_t等) で書かれています。  
Debian 13とUbuntu 26.04の基本ポリシーには、これらの型がありません。  
代わりに、xdg_config_t、xdg_data_t、xdg_cache_t、user_bin_t、etc_tが同じ役割を持ちます。  

ビルド時に、インストール済みの基本ポリシーを調べて、系統を自動で選びます。  
refpolicyの系統では、`hazkey_community_refpolicy.awk`が、型名を置き換えたソースをビルド用ディレクトリへ生成します。  
`Makefile`は`.build/`へ、CMakeはビルドディレクトリへ生成します。  

系統が違う環境で作成した`.pp`は読み込めません (型が存在しないため`semodule -i`コマンドが失敗します)。  
`.pp`は、導入先のディストリビューションの系統でビルドしてください。  

別のLinuxディストリビューション向けの`.pp`を作成する場合は、系統を明示的に指定します。  
パッケージ作成用のコンテナ (`/etc/selinux`が無い環境) やクロスビルドでは、系統を判定できません。  
この場合は、警告が表示されてredhatになるため、DebianとUbuntu向けは必ず明示してください。  

```sh
# Makefile
make FLAVOR=refpolicy

# CMake
cmake -DHAZKEY_SELINUX_POLICY_FLAVOR=refpolicy ...
```

<br>

## インストール

### 前提条件

```sh
# Fedora / RHEL
sudo dnf install selinux-policy-devel checkpolicy policycoreutils policycoreutils-python-utils

# openSUSE / SLE
sudo zypper install selinux-policy-devel checkpolicy policycoreutils policycoreutils-python-utils

# Debian / Ubuntu
sudo apt install selinux-policy-default checkpolicy policycoreutils semodule-utils selinux-utils make
```

<br>

### リリースに添付されたファイルの利用

GitHubのリリースには、ディストリビューションごとにビルドした`.pp`ファイルを、パッケージとは別に添付しています。  
`.deb`と`.rpm`パッケージには、ポリシーモジュールを含めていません。  
ビルド環境を用意せずに使う場合は、使用中のディストリビューションに対応するファイルを選んでください。  

| ファイル | 対象 |
|---|---|
| `selinux-hazkey-community-trixie.pp` | Debian 13 |
| `selinux-hazkey-community-ubuntu2604.pp` | Ubuntu 26.04 |
| `selinux-hazkey-community-fc44.pp` | Fedora 44 |
| `selinux-hazkey-community-leap16.pp` | openSUSE Leap 16 |
| `selinux-hazkey-community-tumbleweed.pp` | openSUSE Tumbleweed (リリース時点のスナップショットでビルド) |

`.pp`ファイルは、基本ポリシーの型名とバージョンに依存するため、他のディストリビューションでは読み込めない場合があります。  
その場合は、下記のビルド手順で、使用中の環境で作り直してください。  

```sh
# 例: Fedora 44の場合
sudo semodule -i selinux-hazkey-community-fc44.pp

# インストール先のラベルを付け直す (/usrの例。/usr/local、/opt/hazkey-community、~/.localは、対応するパスに読み替える)
sudo restorecon -R -v /usr/lib64/hazkey-community /usr/share/hazkey-community
```

配布した`.pp`が対応するインストール先は、`/usr`、`/usr/local`、`/opt/hazkey-community`、`~/.local`です。  
これ以外のインストール先 (例: `/opt/hazkey`) には対応していません。  
その場合は、後述のCMakeでのビルドで、インストール先を指定して作成し直してください。  

ビルドのたびに、CIでも、5種類のディストリビューションのコンテナ内で、ビルド・読み込み・ファイルのラベル・許可規則を検証しています。(`selinux/ci-verify.sh`)  

<br>

### CMakeでのビルド (推奨)

```sh
cd hazkey-community
mkdir build && cd build

cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DENABLE_SELINUX=ON \
      ..
ninja -j $(nproc)
sudo ninja install
```

`-DENABLE_SELINUX=ON`オプションを指定すると、次の処理を行います。  

- `CMAKE_INSTALL_PREFIX`オプションと`CMAKE_INSTALL_LIBDIR`オプション等から、標準以外のインストール先のラベル規則を生成します  
  (`hazkey_community.fc.in`から`hazkey_community.fc`を生成)  
- `hazkey_community.pp`を`<datadir>/selinux/packages`へインストールします。  
- rootで実行した場合は、次の処理も行います。  
  - `semodule -i`コマンドによるモジュールの読み込み  
  - `restorecon`コマンドによる、次のもののラベルの付け直し  
    インストールしたファイルと、既存ユーザのデータディレクトリ  
    `CMAKE_INSTALL_PREFIX`が`/opt/<名前>`の形式のときは、そのディレクトリ全体を対象にします。  
    (`/usr`や`/usr/local`は、他のパッケージのファイルを含むため、Hazkey Communityのファイルだけを対象にします)  
  - モジュールが対象とする他のインストール先 (`/usr/lib64/hazkey-community`など) は付け直しません。  
    ラベルが規則と一致しない場合は、警告と`restorecon`のコマンドを表示します。  

`DESTDIR`オプションを指定した場合 (パッケージの作成時) は、モジュールの読み込みとラベルの付け直しを行いません。  
パッケージの%post等で、`semodule -i`コマンドと`restorecon`コマンドを実行してください。  

`cmake --install --prefix`コマンドで、設定時と異なるインストール先を指定した場合も、モジュールを読み込みません。  
ラベル規則は設定時のインストール先で生成されるため、`-DCMAKE_INSTALL_PREFIX`を指定し直してください。  

ホームディレクトリへインストールする場合 (例: `-DCMAKE_INSTALL_PREFIX=$HOME/.local`) は、  
`cmake --install`コマンドを一般ユーザで実行した後に、モジュールの読み込みだけをrootで行います。  

```sh
ninja install
sudo semodule -i build/selinux/hazkey_community.pp
sudo restorecon -R -v ~/.local/lib*/hazkey-community \
                      ~/.local/lib*/fcitx5/fcitx5-hazkey-community.so \
                      ~/.local/libexec/ibus-hazkey-community \
                      ~/.config/hazkey-community \
                      ~/.local/share/hazkey-community \
                      ~/.local/state/hazkey-community \
                      ~/.cache/hazkey-community
```

Fcitx 5の設定によっては、アドオン (`fcitx5-hazkey-community.so`) が、  
プレフィックスではなくFcitx 5自体のライブラリディレクトリ (例: `/usr/lib64/fcitx5`) へインストールされます。  
この場合は、そのパスにも`restorecon`を実行してください。  
(CMakeによる自動のラベルの付け直しは、実際のインストール先を対象にします)  

<br>

### スタンドアロンでのビルド (Makefile)

`/usr`、`/usr/local`、`/opt/hazkey-community`、`~/.local`にインストールした場合は、CMakeを使用せずにビルドできます。  
`sudo make install`は、モジュールの読み込みと、インストールしたファイルのラベルの付け直しを行います。  

```sh
cd hazkey-community/selinux
make
sudo make install
```

<br>

### 変換サーバの再起動

モジュールを読み込む前から起動している変換サーバは、元のドメイン (unconfined_t) で動作しています。  
変換サーバを終了すると、次のキー入力時にFcitx 5またはIBusが変換サーバを自動で起動し、hazkey_community_server_tで動作します。  

```sh
pkill -u $USER -f '^([^ ]*/)?hazkey-community-server( |$)'
```

rootでCMakeのインストールを実行しても、実行中のセッションの古いソケットとロックファイルは再ラベル付けされません。  
(実行時の`chcon`による付け替えは、ラベルを確認してから`chcon`で付け替えるまでの間にファイルを置き換えられる競合 (TOCTOU) を避けるため、廃止しました)  

また、モジュールが対象とする他のインストール先 (`/usr/lib64/hazkey-community`など) にある変換サーバのラベルは、付け直しません。  
利用者が別の手順で入れた版の挙動 (隔離の有無) を、このインストールで変えないためです。  

ラベルが規則と一致しない場合は、インストールの最後に警告と`restorecon`のコマンドを表示します。  

ラベルのない変換サーバはunconfined_tで動作し、ソケットとロックファイルをuser_tmp_tで作るため、  
その変換サーバが動作している間は、hazkey_community_server_tの変換サーバが起動できません (`tcontext=...user_tmp_t`でwriteが拒否されます)。  

両方のインストール先を使用する場合は、表示されたコマンドでラベルを付け直すか、どちらか一方だけを残してください。  
なお、システム全体の再ラベル付け (`restorecon -R /usr`等) を行うと、他のインストール先にもラベルが付きます。  

モジュールの読み込み前 (またはラベルのない変換サーバの実行中) に作られた古いソケットとロックファイルは、user_tmp_tのままになり、`restorecon`ではラベルが戻りません。  
(基本ポリシーに、`/run/user`直下の全てのファイルを対象とする規則があり、モジュールの規則より優先されるため)  

hazkey_community_server_tの変換サーバは、これらを開くことも削除することもできません。  
(他のサービスのソケットを削除して置き換えられないように、user_tmp_tのファイルの削除は許可していません)  

このため、変換サーバの起動スクリプト (`hazkey-community-server`) が、変換サーバを起動する前に、使用中でない古いソケットとロックファイルを削除します。(追加の操作は不要です)  
作成し直したファイルには、型遷移によりhazkey_community_runtime_tが自動で付きます。  

ラベルのない変換サーバが動作している間は、ロックファイルが使用中のため削除されず、変換サーバがエラーメッセージを出して終了します。  
その場合は、ラベルのない変換サーバを終了してから、もう一度起動してください。  

それでも起動しない場合は、古いソケットとロックファイルを手動で削除してください。  

```sh
rm -f $XDG_RUNTIME_DIR/hazkey-community-server.*
```

<br>

## 設定

```sh
# GPUを使わない (CPU専用で変換する)
sudo setsebool -P hazkey_community_use_gpu off

# GPUは使うが、実行可能なメモリの確保を禁止する (AMDのRADV、IntelのANVの場合)
sudo setsebool -P hazkey_community_gpu_execmem off

# モデルと辞書を~/.local/share/hazkey-community以外に置かない
sudo setsebool -P hazkey_community_read_user_files off

# GPUドライバの共有のシェーダキャッシュ (~/.cache直下) へ書き込ませない
sudo setsebool -P hazkey_community_write_gpu_cache off
```

[hazkey_community_write_gpu_cache]を無効にする場合は、  
`~/.config/hazkey-community/env`でシェーダキャッシュの場所を専用のディレクトリへ変更すると、キャッシュを引き続き使用できます。  

```sh
MESA_SHADER_CACHE_DIR=$HOME/.cache/hazkey-community/mesa_shader_cache
__GL_SHADER_DISK_CACHE_PATH=$HOME/.cache/hazkey-community/nvidia
```

ホームディレクトリ以外にモデルを置く場合は、読み取り専用の型usr_tを付けます。  
(hazkey_community_data_home_tを付けると、変換サーバにそのディレクトリへの書き込みの権限も与えるため)  

変換サーバは、モデルまでの途中のディレクトリも探索できる必要があります。  
このため、`/opt`配下等、親ディレクトリにもusr_tが付いている場所に置いてください。  
`/data`のように親ディレクトリに別の型が付いている場所では、親ディレクトリを探索できないため読み込めません。  

```sh
sudo semanage fcontext -a -t usr_t '/opt/zenzai-models(/.*)?'
sudo restorecon -R -v /opt/zenzai-models
```

`~/.config/hazkey-community/config.json`をエディタ等で置き換えた場合は、型が変わり、変換サーバが設定を保存できなくなることがあります。  
`restorecon -v ~/.config/hazkey-community/config.json`でラベルを戻してください。  

<br>

## 検証

```sh
# モジュールの読み込み
sudo semodule -l | grep hazkey_community

# ファイルのラベル
ls -Z /usr/local/lib64/hazkey-community/hazkey-community-server
ls -dZ ~/.config/hazkey-community ~/.local/state/hazkey-community

# 変換サーバのドメイン
ps -eZ | grep hazkey-community-server
# 期待値: unconfined_u:unconfined_r:hazkey_community_server_t:s0-s0:c0.c1023 ...

# Boolean
getsebool -a | grep hazkey_community
```

<br>

## トラブルシューティング

### 拒否ログの確認

```sh
sudo ausearch -m AVC,USER_AVC -ts recent | grep hazkey
sudo ausearch -m AVC -ts recent -c hazkey-communit
```

プロセス名 (`/proc/<PID>/comm`) は15文字に切り詰められるため、`-c`オプションには`hazkey-communit`を指定します。  

### ラベルが付いていない

```sh
# 期待されるラベルの確認
matchpathcon /usr/local/lib64/hazkey-community/hazkey-community-server

# ラベルの付け直し
sudo restorecon -R -v /usr/local/lib64/hazkey-community
```

標準以外のインストール先 (例: `/opt/hazkey`) は、スタンドアロンの`Makefile`でビルドしたモジュールにはラベル規則が含まれません。  
CMakeでビルドするか、`semanage fcontext`で規則を追加してください。  
(規則の例は、`ADMIN.md`の「4.1 標準以外のインストール先」を参照)  

<br>

### GPUが使われない

`~/.config/hazkey-community/env`で[VK_DRIVER_FILES]等を指定している場合は、  
変換サーバへのドメイン遷移時に、環境変数が削除されていないか確認します。  
このモジュールはnoatsecureを許可しているため、通常は環境変数が引き継がれます。  

GPUのデバイスファイルに独自の型が付いている環境では、拒否ログを確認して許可を追加してください。  
(`ADMIN.md`の「4.3 GPUのデバイスに独自の型が付いている環境」を参照)  

<br>

### 一時的な回避

```sh
# 変換サーバのドメインだけをpermissiveにする
sudo semanage permissive -a hazkey_community_server_t

# 確認後に元に戻す
sudo semanage permissive -d hazkey_community_server_t
```

`setenforce 0` (システム全体のpermissive) は、原因の切り分け以外には使わないでください。  

<br>

### ローカルの追加ルール

```sh
sudo ausearch -m AVC -ts recent | grep hazkey_community_server_t | audit2allow -M hazkey_community_local
sudo semodule -i hazkey_community_local.pp
```

<br>

## アンインストール

モジュールを削除すると、hazkey_community_で始まる型のファイルは、ラベルのないunlabeled_tになります。  
変換サーバが読み書きできなくなるため、モジュールの削除後に、必ずラベルを付け直してください。  
付け直す対象は、インストールしたファイルだけではありません。  
各ユーザの設定、学習データ、キャッシュも含めてください。  

```sh
# Makefileでインストールした場合 (モジュールの削除と、下記のラベルの付け直しをまとめて行う)
cd hazkey-community/selinux
sudo make unload

# CMakeでインストールした場合 (インストール先が/usr/localの例)
sudo semodule -r hazkey_community
sudo restorecon -R -v /usr/local/lib64/hazkey-community
sudo restorecon -R -v /usr/local/libexec/ibus-hazkey-community \
                      /usr/local/share/hazkey-community

# 各ユーザのデータ (ユーザごとに実行する。変換サーバは終了)
pkill -u $USER -f '^([^ ]*/)?hazkey-community-server( |$)'
restorecon -R -v ~/.config/hazkey-community ~/.local/share/hazkey-community \
                 ~/.local/state/hazkey-community ~/.cache/hazkey-community
rm -f $XDG_RUNTIME_DIR/hazkey-community-server.*
```

`/opt/hazkey-community`にインストールした場合は、`/usr/local`の例の代わりに、次のコマンドを実行してください。  

```sh
sudo restorecon -R -v /opt/hazkey-community
```

削除後に、`ls -Z ~/.local/state/hazkey-community`コマンドで、unlabeled_tが残っていないことを確認できます。  

<br>

## ファイル構成

| ファイル | 説明 |
|---|---|
| `hazkey_community.te` | 型の宣言とアクセス規則 |
| `hazkey_community.fc` | ファイルラベル (スタンドアロンの`Makefile`用) |
| `hazkey_community_refpolicy.awk` | DebianとUbuntu向けに、型名を置き換えるスクリプト (ビルド時に自動で実行) |
| `hazkey_community.fc.in` | ファイルラベルのテンプレート (CMake用)<br>`@HAZKEY_SELINUX_PREFIX_CONTEXTS@`を、標準以外のインストール先の規則に置換する |
| `hazkey_community.if` | 他のポリシーモジュール向けのインターフェース<br>DebianとUbuntuでは、CMakeが型名を変換したものをインストールする |
| `CMakeLists.txt` | CMakeのビルド定義 |
| `Makefile` | スタンドアロンのビルド定義 |
| `ci-verify.sh` | CI用の検証スクリプト (ビルド、読み込み、ファイルのラベル、許可規則をコンテナ内で検証する) |
| `ADMIN.md` | 管理者向けの詳細なガイド |

<br>

## 参考

- [SELinux Project](https://github.com/SELinuxProject)  
- [Reference Policy](https://github.com/SELinuxProject/refpolicy)  
- [openSUSE SELinux](https://en.opensuse.org/Portal:SELinux)  
- [Red Hat: Using SELinux](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/index)  

<br>

## ライセンス

Hazkey Community本体と同じライセンス (MIT) です。  
