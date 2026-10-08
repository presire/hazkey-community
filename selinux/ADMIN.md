# Hazkey Community SELinux Policy Module - 管理者ガイド

インストール手順と基本的な使い方は、README.mdを参照してください。  
このガイドでは、ポリシーの設計、各規則が必要な理由、カスタマイズ、監査の方法を説明します。  

## 1. アーキテクチャ

### 1.1 プロセスとドメイン

```
fcitx5 / ibus-daemon / 設定GUI  (起動元のドメイン: unconfined_t / user_t / staff_t)
  │  fcitx5-hazkey-community.so、ibus-engine-hazkey-community、hazkey-community-settings
  │
  │ 絶対パス <bindir>/hazkey-community-server で起動 (PATHを検索しない。g_spawn / QProcess / fork + exec)
  ▼
<bindir>/hazkey-community-server  (ラッパースクリプト、bin_t、起動元のドメインのまま)
  │  ~/.config/hazkey-community/envを読み込む (変換サーバはenvを変更できない)
  │
  │ exec (ドメイン遷移)
  ▼
<libdir>/hazkey-community/hazkey-community-server  (hazkey_community_exec_t)
  │  hazkey_community_server_tで動作
  │
  ├─ 自身を--probe-backends付きで再実行 (同じドメイン、Vulkanの安全確認、posix_spawn)
  └─ $XDG_RUNTIME_DIR/hazkey-community-server.<UID>.sockで接続を待つ
         ▲
         └─ クライアント (fcitx5 / IBus / 設定GUI) が接続する (connectto)
```

ドメイン遷移は、ラッパースクリプトではなく、実体の実行ファイルの実行時に起こります。  
このため、環境変数ファイル (env) の読み込みは、起動元のドメインで行われます。  
envで設定した環境変数は、ドメイン遷移時に削除されずに変換サーバへ引き継がれます。(`noatsecure`の許可)  

envは、ラッパースクリプトがシェルスクリプトとして起動元のドメインで読み込みます。  
変換サーバがenvを作成・変更・置換できると、侵害された変換サーバが、起動元のドメインで任意のコマンドを実行できてしまいます。  
このため、変換サーバが`~/.config/hazkey-community`内で書き込めるファイルは、config.jsonと、その保存に使う一時ファイルconfig.json.tmp (どちらもhazkey_community_config_t) だけです。  
削除はこの型のファイルだけに許可します。  
設定ディレクトリ内のファイルの名前の変更・リンクの作成と、設定ディレクトリ自体の削除・名前の変更・属性 (パーミッション) の変更は許可しません。  
名前の変更を許可するとconfig.jsonをenvへ改名でき、ディレクトリのパーミッションの変更を許可すると他のユーザにenvを置き換えさせられるためです。  

このため、変換サーバはconfig.jsonを名前の変更で置き換えずに、完全な内容を先にconfig.json.tmpへ書いてから上書きし、最後にconfig.json.tmpを削除します。  
上書きの途中で停止した場合は、次回の起動時にconfig.json.tmpから設定を復元します。  
変換サーバは起動時に設定ディレクトリを0700へ変更しようとしますが、ポリシーで拒否します (監査ログには記録しません)。  
設定ディレクトリを他のユーザから読めないようにする場合は、`chmod 700 ~/.config/hazkey-community`を実行してください。  

### 1.2 インストール先とラベル

| インストール先 | ラベル規則の定義元 |
|---|---|
| `/usr` | hazkey_community.fc (固定) |
| `/usr/local` | hazkey_community.fc (固定) |
| `/opt/hazkey-community` | hazkey_community.fc (固定) |
| `~/.local` | hazkey_community.fc (固定、HOME_DIRで指定) |
| 上記以外 (`/opt/hazkey`、`~/apps`等) | CMakeが、hazkey_community.fc.inの`@HAZKEY_SELINUX_PREFIX_CONTEXTS@`へ生成 |

各インストール先には、`lib`と`lib64`の両方の規則があります。  
Debian系の`lib/x86_64-linux-gnu`と`lib/aarch64-linux-gnu`の規則も、固定で含みます。  
標準以外のライブラリディレクトリは、CMakeが生成します。  

| パス (`P`はプレフィックス、`L`はライブラリディレクトリ) | 型 |
|---|---|
| `P/L/hazkey-community(/.*)?` | lib_t |
| `P/L/hazkey-community/hazkey-community-server` | hazkey_community_exec_t |
| `P/L/hazkey-community/hazkey-community-settings` | bin_t |
| `P/L/fcitx5/fcitx5-hazkey-community\.so` | lib_t |
| `P/libexec/ibus-hazkey-community(/.*)?` | bin_t |
| `P/share/hazkey-community(/.*)?` | usr_t (ホームディレクトリへのインストールを除く) |

ホームディレクトリへインストールした辞書 (`~/.local/share/hazkey-community`) は、ユーザデータと同じhazkey_community_data_home_tです。  

### 1.3 ユーザデータ

| パス | 型 | 内容 |
|---|---|---|
| `~/.config/hazkey-community` | hazkey_community_conf_home_t | user_dictionary.tsv、env、`keymap/`、`table/`<br>(変換サーバは読み取りだけ) |
| `~/.config/hazkey-community/config.json` | hazkey_community_config_t | 変換サーバが書き込む設定ファイル |
| `~/.config/hazkey-community/config.json.tmp` | hazkey_community_config_t | config.jsonの保存に使う一時ファイル (保存の完了時に削除) |
| `~/.local/share/hazkey-community` | hazkey_community_data_home_t | Zenzaiのモデル (`zenzai/`、zenzai.gguf) |
| `~/.local/state/hazkey-community` | hazkey_community_state_home_t | 学習データ (`memory/`) |
| `~/.cache/hazkey-community` | hazkey_community_cache_home_t | キャッシュ |
| `/run/user/<UID>/hazkey-community-server.<UID>.sock` | hazkey_community_runtime_t | クライアント接続用のソケット |
| `/run/user/<UID>/hazkey-community-server.<UID>.lock` | hazkey_community_runtime_t | 単一起動用のロックファイル |
| `/tmp/hazkey-community-*` | hazkey_community_tmp_t | [XDG_RUNTIME_DIR]が未設定の時のソケットの置き場所<br>CPU専用バックエンドの一時配置 |

専用のディレクトリは、名前付きの型遷移 (ディレクトリ名hazkey-community) により、  
変換サーバ・設定GUI・移行スクリプトのどれが作成しても、専用の型になります。  
config.jsonとconfig.json.tmpも同様に、名前付きの型遷移で、作成時にhazkey_community_config_tになります。  

新しく作成したユーザで`~/.config`、`~/.local`、`~/.local/share`、`~/.cache`が存在しない場合は、  
変換サーバが、基本ポリシーと同じ型 (config_home_t等) でこれらのディレクトリを作成します。  

ユーザデータの型は、ホームディレクトリの属性 (user_home_type) または一時ファイルの属性 (user_tmp_type) を持ちます。  
このため、ユーザ自身 (unconfined_t、user_t、staff_t) は、通常どおり読み書きできます。  
Debian 13とUbuntu 26.04の基本ポリシーには、この2つの属性がありません。  
そのため、属性の付与はoptionalブロックの中に置き、存在する環境だけで有効にします。  
これらの環境では、同等の属性 (user_home_content_type、xdg_config_type、xdg_data_type、xdg_cache_type) も、optionalブロックで付与します。  

### 1.4 型名の系統 (Fedora / openSUSE と Debian / Ubuntu)

hazkey_community.teは、Fedora / RHEL / openSUSE (redhat系統) の型名で書いています。  
Debian 13とUbuntu 26.04 (refpolicy系統) は、同じ役割の型の名前が異なります。  
ビルド時に、hazkey_community_refpolicy.awkが、次のとおり置き換えます。  

| redhat系統 | refpolicy系統 |
|---|---|
| config_home_t | xdg_config_t |
| data_home_t | xdg_data_t |
| gconf_home_t | xdg_data_t |
| cache_home_t | xdg_cache_t |
| home_bin_t | user_bin_t |
| passwd_file_t | etc_t |
| user_tmp_t | user_runtime_t |

refpolicy系統には、次の違いがあります。  

- ~/.localと~/.local/shareと~/.local/stateが、全てxdg_data_tです  
  このため、`state`と`share`の名前付きの型遷移 (gconf_home_tの下での遷移) は、生成時に削除します  
  変換サーバが`~/.local/state/hazkey-community`を新規作成した場合は、hazkey_community_data_home_tが付きます  
  変換サーバは、4つのユーザデータの型の全てに同じ権限を持つため、動作に影響はありません  
  `restorecon`で、本来の型 (hazkey_community_state_home_t) へ戻せます  
- `/run/user/<UID>` ([XDG_RUNTIME_DIR]) のラベルが、Fedora / openSUSEではuser_tmp_t、Debian / Ubuntuではuser_runtime_tです  
  このため、ソケットとロックファイルを作成するための許可と型遷移は、user_runtime_tに対して生成します  
  ([XDG_RUNTIME_DIR]が未設定の時の代替置き場 (`/tmp/hazkey-community-runtime-<UID>`) は、どちらの系統でも同じです)  
- ユーザ (user_t、staff_t) へのアクセス許可は、xdg_config_type、xdg_data_type、xdg_cache_typeの属性を、  
  optionalブロックで、hazkey_community_*_home_t型へ付与して実現します  

置き換えの対象は、hazkey_community.teとhazkey_community.ifの、コメントを除くコード部分だけです。  
hazkey_community.ifも、CMakeがインストールするものは系統に合わせて変換済みです  
(Makefileでビルドした場合は、`make interface`で、`.build/hazkey_community.if`に生成できます)  
系統は、`/etc/selinux/*/contexts/files/file_contexts.homedirs`にxdg_config_tが含まれるかで判定します。  
明示する場合は、`make FLAVOR=refpolicy`または`-DHAZKEY_SELINUX_POLICY_FLAVOR=refpolicy`を指定します。  

## 2. セキュリティモデル

### 2.1 方針

- 変換サーバは全てのキー入力を受け取るため、TCPとUDPの通信、ポート番号への束縛 (`name_bind`) を一切許可しません  
  (2.4を参照)  
- ホームディレクトリへの書き込みは、Hazkey Community専用のディレクトリと、GPUドライバのキャッシュ (`~/.cache`) に限定します  
  (GPUドライバのキャッシュは、[hazkey_community_write_gpu_cache]で無効にできます)  
- 起動元のドメインで読み込まれるenvは、変換サーバから変更できません  
- 他のプロセスへの`ptrace`、他のユーザのファイルとシステムファイルへの書き込みは許可しません  
- ソケットへの接続は、ファイルのパーミッション (0600) とUIDに加えて、SELinuxでunconfined_t / user_t / staff_tに限定します  

### 2.2 変換サーバに許可する操作

| 分類 | 内容 | 理由 |
|---|---|---|
| 実行 | hazkey_community_exec_tの再実行 | `--probe-backends`によるVulkanの隔離確認 |
| 読み取り | lib_t、ld_so_t、textrel_shlib_t | llama.cpp / GGMLのバックエンドの読み込み |
| 読み取り | usr_t、etc_t、locale_t、passwd_file_t | 辞書、VulkanのICDの定義、ロケール、`getpwuid()` |
| 読み取り | proc_t、sysctl_kernel_t、sysctl_vm_t、sysfs_t、cgroup_t | CPU数・メモリ量・GPUの情報 |
| 読み書き | 専用のホームディレクトリの型 | 学習データ・モデル・キャッシュ |
| 書き込み・削除 | hazkey_community_config_t | config.jsonの保存とconfig.json.tmpの削除、旧版が作成したconfig.jsonの0600への変更<br>(設定ディレクトリの他のファイルは読み取りだけ) |
| 作成 | config_home_t、gconf_home_t、data_home_t、cache_home_tのディレクトリ | 新しいユーザの`~/.config`等の作成 (名前付きの型遷移) |
| 作成 | hazkey_community_runtime_t | ソケットとロックファイル (`flock`) |
| 作成 | hazkey_community_tmp_t、hazkey_community_tmpfs_t | 一時ディレクトリ、GPUドライバの共有メモリ |
| 接続 | systemd_userdbd_t、systemd_machined_t、kernel_tの`unix_stream_socket` | `getpwuid()`や`getgrgid()`が`/run/systemd/userdb`のソケットへ問い合わせる<br>(`io.systemd.DynamicUser`は、起動の早い段階で作られるため、持ち主がkernel_tになる) |
| シグナル | 自ドメイン | 旧サーバの終了 (`SIGTERM` / `SIGKILL`) と生存確認<br>(モジュールの導入前から動作しているunconfined_tのサーバは対象外) |
| デバイス | dri_device_t、xserver_misc_device_t | GPUの使用 ([hazkey_community_use_gpu]) |
| プロセス | `execmem` | Vulkanドライバ (lavapipe、NVIDIA) の実行時のコード生成 ([hazkey_community_use_gpu] と [hazkey_community_gpu_execmem]) |

### 2.3 監査しない操作 (dontaudit)

| 対象 | 理由 |
|---|---|
| dri_device_t | GPUを無効にした場合もVulkanのローダーがデバイスを探索するが、CPUで正常に動作する |
| ホームディレクトリ配下の一般的な型の読み取り | [hazkey_community_read_user_files]が無効でも、Vulkanのローダーが設定を探索する |
| 他のドメインの`/proc/<PID>` | ロックファイルのPIDが他のドメインのプロセスに再利用されていた場合で、変換サーバではないと判定するだけ |
| `dac_override`、`dac_read_search`、`sys_ptrace` | 他のユーザのプロセスの`/proc/<PID>`を読む時の、カーネルによる権限の確認 |
| cache_home_tへの書き込み<br>([hazkey_community_write_gpu_cache]の無効時) | GPUドライバがキャッシュを作成できないだけで、GPUによる変換は動作する |
| 起動元のドメインの`unix_dgram_socket` | 起動元から継承しただけで、使用しないファイルディスクリプタ |

### 2.4 ネットワーク通信を許可しない理由

変換サーバは、子プロセス (`--probe-backends`) を`posix_spawn`で起動し、`waitpid`で終了を待ちます。  
旧サーバの終了も、ロックファイルのPIDを`/proc`とpidfdで確認して行い、外部コマンド (`pgrep`) は実行しません。  
このため、swift-corelibs-foundationの`Process`が子プロセスの監視に作成するループバックのUDPソケットは不要で、  
このモジュールは`udp_socket`と`tcp_socket`の両方を許可しません。  

## 3. インターフェース (hazkey_community.if)

| インターフェース | 説明 |
|---|---|
| `hazkey_community_domtrans(domain)` | 変換サーバを実行して、ドメイン遷移する |
| `hazkey_community_run(domain, role)` | ドメイン遷移と、ロールへの関連付け |
| `hazkey_community_stream_connect(domain)` | 変換サーバのソケットへの接続 |
| `hazkey_community_signal(domain)` | 変換サーバへのシグナルの送信と、プロセスの情報の参照 |
| `hazkey_community_read_user_content(domain)` | 専用のホームディレクトリの読み取り |
| `hazkey_community_manage_user_content(domain)` | 専用のホームディレクトリの管理と、ラベルの変更 |
| `hazkey_community_home_filetrans(domain)` | 専用のディレクトリとconfig.jsonの作成時の型遷移 |
| `hazkey_community_role(role, domain)` | 制限ユーザのロールでHazkey Communityを使うための一括の許可 |

### 3.1 独自の制限ユーザで使う例

```
policy_module(myuser_hazkey, 1.0.0)

gen_require(`
	type myuser_t;
	role myuser_r;
')

hazkey_community_role(myuser_r, myuser_t)
```

```sh
# hazkey_community.ifをインストール先のincludeディレクトリへコピーしてからビルドする
# (Debian / Ubuntuでは、型名を変換済みの.build/hazkey_community.if、またはCMakeがインストールしたものを使う)
sudo cp hazkey_community.if /usr/share/selinux/devel/include/contrib/
make -f /usr/share/selinux/devel/Makefile myuser_hazkey.pp
sudo semodule -i myuser_hazkey.pp
```

## 4. カスタマイズ

### 4.1 標準以外のインストール先

CMakeでビルドした場合は、ラベル規則を自動で生成します。  
スタンドアロンのMakefileを使う場合や、インストール後に場所を移した場合は、`semanage`で同等の規則を追加します。  

```sh
P=/opt/hazkey
sudo semanage fcontext -a -t lib_t "$P/lib64/hazkey-community(/.*)?"
sudo semanage fcontext -a -t hazkey_community_exec_t -f f "$P/lib64/hazkey-community/hazkey-community-server"
sudo semanage fcontext -a -t bin_t -f f "$P/lib64/hazkey-community/hazkey-community-settings"
sudo semanage fcontext -a -t bin_t "$P/libexec/ibus-hazkey-community(/.*)?"
sudo semanage fcontext -a -t usr_t "$P/share/hazkey-community(/.*)?"
sudo semanage fcontext -a -t lib_t -f f "$P/lib64/fcitx5/fcitx5-hazkey-community\.so"
sudo semanage fcontext -a -t bin_t -f f "$P/bin/hazkey-community-server"
sudo restorecon -R -v "$P"
```

### 4.2 モデルや辞書をホームディレクトリ以外に置く

読み取り専用の型usr_tを付けます。  
hazkey_community_data_home_tを付けると、変換サーバにそのディレクトリの変更・削除の権限も与えるため、使わないでください。  

変換サーバは、モデルまでの途中のディレクトリも探索できる必要があります。  
`/opt`配下は親ディレクトリがusr_tのため探索できますが、`/srv` (var_t) や`/data` (etc_runtime_t) は探索できません。  

```sh
sudo semanage fcontext -a -t usr_t '/opt/zenzai-models(/.*)?'
sudo restorecon -R -v /opt/zenzai-models
```

### 4.3 GPUのデバイスに独自の型が付いている環境

AMDのROCm用のデバイス (`/dev/kfd`) や、ディストリビューション独自の型が付いたGPUのデバイスは、  
拒否ログを確認して、ローカルモジュールで許可します。  

```
module hazkey_community_gpu_local 1.0;

require {
    type hazkey_community_server_t;
    type hsa_device_t;
    class chr_file { getattr open read write ioctl map };
}

allow hazkey_community_server_t hsa_device_t:chr_file { getattr open read write ioctl map };
```

## 5. 監査

```sh
# 変換サーバの拒否
sudo ausearch -m AVC,USER_AVC -ts today | grep hazkey_community

# dontauditを一時的に無効にして、隠れている拒否を確認する
sudo semodule -DB
# ... 再現 ...
sudo semodule -B

# 許可されている規則の確認 (setools)
sesearch -A -s hazkey_community_server_t
sesearch -T -s unconfined_t -t hazkey_community_exec_t
```

## 6. 既知の制約

- ラッパースクリプト (`<bindir>/hazkey-community-server`) は、起動元のドメインで動作します  
  envは変換サーバからは保護されますが、起動元のドメインで動作する他のプログラムからは保護されません  
- config.jsonをエディタ等で置き換えると、型がhazkey_community_conf_home_tになり、変換サーバが設定を保存できなくなります  
  `restorecon`でラベルを戻してください  
- 性能計測用の [HAZKEY_PERF_EVIDENCE] に`/tmp`のファイルを指定すると、変換サーバは書き込めません  
  `/tmp`のファイルは、Fcitx 5が作った場合にuser_tmp_tになり、他のアプリのファイルを書き換えられる許可は追加していません  
  開発で計測するときは、`semanage permissive -a hazkey_community_server_t`で一時的に許可してください  
  通常の利用では、この環境変数を設定しないでください  
- unconfined_t、user_t、staff_t以外 (guest_t、xguest_t、独自のドメイン) からは、ドメイン遷移も実行もできません  
  `hazkey_community_role`で個別に許可してください  
- モジュールの導入前から動作している変換サーバは、unconfined_tのままです  
  新しい変換サーバからは終了できないため、モジュールの導入後に`pkill`で終了してください  
- [XDG_RUNTIME_DIR]を標準以外の場所に設定した場合、ソケットの型遷移は、親ディレクトリの型 (user_tmp_t / user_runtime_t / tmp_t) に依存します  
- `restorecon`によるラベルの付け直しは、既存ユーザのディレクトリとして`/home/*`と`/root`だけを対象にします  
  それ以外のホームディレクトリは、手動でラベルを付け直してください  
- 動作確認は、openSUSE Leap 16.0 (targeted、MLSの有効時) の実機と、各ディストリビューションのコンテナで行っています  
  Fedora 44、Debian 13、Ubuntu 26.04では、コンテナで、ビルド・`semodule -i`・`matchpathcon`によるラベルを確認しています  
  Debian 13とUbuntu 26.04で、実際に変換サーバをドメイン遷移させる動作は、未確認です  
- 系統が違う環境で作った.ppは読み込めません  
  導入先のディストリビューションで、ビルドし直してください  
- `/run/user/<UID>/hazkey-community-server.*`のファイルコンテキストの規則は、基本ポリシーの`/run/user/[^/]+/.+`の規則に負けて、`matchpathcon`で`<<none>>`になります  
  ソケットとロックファイルは、通常の型遷移 (ファイル名には依存しない遷移) でhazkey_community_runtime_tが付くため、動作に影響はありません  
  古いファイルは、rootで実行したCMakeのインストールが`chcon`で付け直します。それ以外の場合は、削除して作り直してください  

## 7. 高度なトラブルシューティング

| 症状 | 確認 | 対処 |
|---|---|---|
| 変換サーバが起動しない | `ausearch -m AVC -c hazkey-communit` | 拒否された型を確認して、ラベルの付け直し (`restorecon`) か規則を追加する |
| ドメインがunconfined_tのまま | `ls -Z <libdir>/hazkey-community/hazkey-community-server` | hazkey_community_exec_tでなければ`restorecon`を実行する |
| ロックファイルへの`write`が拒否される (`tcontext=...user_tmp_t`) | `ps -eZ \| grep hazkey-community-server`<br>`ls -Z /run/user/$UID/hazkey-community-server.*` | 別のインストール先の変換サーバがunconfined_tで動作している。その変換サーバに`restorecon`を実行して終了し、古いソケットとロックファイルを削除する |
| GPUが使われない | `getsebool hazkey_community_use_gpu hazkey_community_gpu_execmem`<br>`semodule -DB` | [hazkey_community_use_gpu]を有効にする<br>lavapipeやNVIDIAのドライバでは[hazkey_community_gpu_execmem]も有効にする<br>デバイスの型を確認する (4.3を参照) |
| カスタム重みを読み込めない | `getsebool hazkey_community_read_user_files` | [hazkey_community_read_user_files]を有効にするか、ファイルを専用のディレクトリへ移動する |
| 設定GUIから接続できない | `ls -Z /run/user/$UID/hazkey-community-server.*` | 古いソケットを削除して、変換サーバを再起動する |

原因が分からない場合は、変換サーバのドメインだけをpermissiveにして、拒否ログを集めてから元に戻します。  

```sh
sudo semanage permissive -a hazkey_community_server_t
# ... 再現 ...
sudo ausearch -m AVC -ts recent | grep hazkey_community_server_t | audit2allow
sudo semanage permissive -d hazkey_community_server_t
```

## 8. 推奨事項

- パッケージの作成時は、`%post`で`semodule -i`と`restorecon`を、`%postun` (削除時) で`semodule -r`を実行する  
- `audit2allow`で生成した規則は、そのまま追加せずに内容を確認する  
  (特に、ネットワークと他のユーザのファイルへの許可)  
- Booleanは、全て既定で有効です  
  GPUを使わない環境や、モデルを専用のディレクトリに置く運用では、無効にして権限を減らす  
