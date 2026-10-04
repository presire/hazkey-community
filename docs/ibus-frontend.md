> Hazkey CommunityのIBusフロントエンド (ibus-hazkey-community) の詳細ドキュメントです。  

# IBusフロントエンド (実験的)

Fcitx 5と同じhazkey-community-serverを利用する実験的なIBusフロントエンド (ibus-hazkey-community) です。  
GitHub Releasesのibus-hazkey-communityパッケージ (DEB / RPM) で導入するのが手軽です。  

([README クイックスタート](../README.md#クイックスタート-github-releasesからインストール)参照)  

ソースコードからビルドする場合は、CMakeで `-DENABLE_IBUS=ON` オプションを指定します。  
(既定は**OFF**、**pkg-config ibus-1.0**が必要)  

```sh
cmake -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DENABLE_IBUS=ON \
      ..
ninja -j $(nproc)
sudo ninja install
```

インストール後はibus-daemonを再起動して、ibus list-engineに**Hazkey Community**が表示されることを確認してください。  

エンジンは、`${CMAKE_INSTALL_LIBEXECDIR}/ibus-hazkey-community/ibus-engine-hazkey-community`、  
component XMLは、`${CMAKE_INSTALL_DATADIR}/ibus/component/ibus-hazkey-community.xml` に配置されます。  

トランスポートはFcitx 5版と共通 (`hazkey-frontend-common/`) で、候補リフレッシュの間引きポリシーも共通です。  
(`hazkey-frontend-common/candidate_refresh_coalescer.h - hazkey::frontend::CandidateRefreshCoalescer`、30[ms]の立ち上がりエッジ型デバウンス)  

IBus版も連続キー入力時の表示専用リフレッシュを同じポリシーで間引き、タイマのみGLib (g_timeout_add) のアダプタで駆動します。  

> 立ち上がりエッジ型デバウンス (リーディングエッジ方式のデバウンス) とは  
> デバウンスとは、短時間に連続して発生するイベントを1回にまとめる (間引く) 手法のことです。  
> 元々は、チャタリングする物理スイッチの信号処理用語で、ソフトウェアではリサイズ・スクロール・キー入力時の連続リフレッシュ抑制等に使用されます。  
>  
> 連続キー入力中に候補表示の更新要求が連発しても、先頭の1件はすぐ反映し、30[ms]以内の後続要求は捨てることにより、  
> 入力応答性を落とさず描画負荷だけを抑えています。  

## IBusフロントエンドの既知の制約

- **Fcitx 5とIBusの同時有効化による入力に対応しています。**  
  hazkey-community-serverは、接続ごとに独立した入力セッション (`hazkey-server/Sources/hazkey-server/state.swift - HazkeyServerState`) を持ち、  
  変換エンジン・ユーザ辞書・学習メモリ・Zenzaiモデルは全接続で共有します。  
  (`hazkey-server/Sources/hazkey-server/state.swift - HazkeySharedResources`)  
  
  接続を奪い合いません。  
- **hazkey-community-settingsを起動しても、IME側の入力接続は切断されません。**  
- **同時接続の上限は8です**  
  (`hazkey-server/Sources/hazkey-server/socketManager.swift — SocketManager.maxClientCount`)  
  超過した新規接続は、accept直後にサーバが閉じ、既存セッションは保護されます。  
- **停滞したクライアントが他方を巻き込みません。**  
  ソケットI/Oは期限付きpollで待機 (デフォルトは10秒) するため、  
  (`hazkey-server/Sources/hazkey-server/socketUtils.swift - readData(from:count:timeoutMs:)` / `writeData(to:data:timeoutMs:)`)、  
  応答を返さない/読み取らないクライアントは `hazkey-server/Sources/hazkey-server/socketUtils.swift - SocketError.ioTimeout` で切断され、  
  他のクライアントの処理が再開します。  
- **hazkey-community-settingsで設定を変更しても、他方の入力中テキストは失われません。**  
  設定変更時の再初期化は要求元の接続だけが自分の組成をリセットし、他の接続は組成を保持します。  
  入力テーブルは名前ごとにレジストリへ追加登録されるため (`InputStyleManager.registerInputStyle`)、  
  変更前に挿入済みの要素は旧テーブル名のまま解決できます。  
  
  残差:  
  組成の途中で設定を変更した場合、変更前に入力したキーは旧マッピング、変更後のキーは新マッピングになります。(同一組成内での混在)  
- **残差リスク**:  
  サーバは単一スレッドでリクエストを直列処理するため、片方のZenzai推論中はもう片方の同期RPC応答が遅延し得ます。  
  (クライアントのread timeoutは最大10秒以内、機能的な破綻はありません)  
- **Fcitx 5版の主要な入力操作は、IBus版にも移植済みです。**  
  ライブ変換トグル、文節境界調整 (`[Shift] + [Left]` / `[Shift] + [Right]`)、予測候補受入、学習データの個別削除、Zenzaiトグル、  
  `[F6]`〜`[F10]` と `[Ctrl] + [U]` / `[Ctrl] + [I]` / `[Ctrl] + [O]` / `[Ctrl] + [P]` / `[Ctrl] + [T]` の直接変換、  
  `[Alt]` + 数字での候補選択、生ひらがな + カーソル位置の補助表示 (FcitxのAuxUp / AuxDown) を含みます。  
  無変換キーはFcitx 5版と同様に、組成中に消費されるNOPです。(直接変換は行いません)  
- **パネルの入力モード表示 (IBusProperty) に対応しています。**  
  パネルに「あ」(通常入力) /「A」(直接入力) と、Zenzai の状態を表示します。  
  言語バーの「あ / A」をクリックすると、直接入力をトグルできます。([Shift]キー単体押下と同じRPC経路を利用)  
- **Zenzaiのトグル (ホットキー / パネルのプロパティ) とライブ変換トグル (ホットキー) は、補助テキストに一時的なヒントを約1秒表示します。**  
  IBusにはGNOME Shellを含む全パネルが描画する一時ポップアップAPIが無い ([ibus-rime](https://github.com/rime/ibus-rime) の `status_hint.c` と同じく  
  補助テキストの一時表示で代替。  
  IBus 1.5.33以降の `ibus_engine_send_message()` は、UnstableでGNOME Shell非対応のため採用していません)  
- **候補リストに数字ラベル (1〜9, 0) と縦向き表示を設定しています。**  
- **クライアントのcapability (`set_capabilities`) を反映します。**  
  surrounding text非対応のクライアントでは、surrounding textの取得・送信を行いません。  
  capabilityを申告しないクライアントでは従来どおり動作します。  
- **IBusに固有の未対応項目 (見送り)**:  
  - surrounding textの書き込み経路 (`delete_surrounding_text` / `forward_key_event`) は、サーバ側の新規RPCが必要なため未対応です。  
  - Fcitx 5版の[Tabキーで選択]表示可否設定 (`showTabToSelect`) に相当するIBus側の設定経路はありません。  
    Fcitx 5版の既定値は[表示]であり、IBusは組成中に常時表示するため実質同挙動です。  
- **RPCは非同期化されており、`process_key_event` はサーバ応答でブロックしません。**  
  IBus側の入力状態機械 (`hazkey::ibus::HazkeyState`) は専用ワーカースレッドで逐次実行され、  
  preedit・候補リスト・IBusProperty・補助テキストの更新はGLibメインループへ配送されて適用されます。  
  
  サーバが遅い間もキー入力処理は即座に戻り、応答到着後に表示へ反映されます。  
  既存のread timeout (最大10秒)・response 上限2[MB]・再接続・read-throughキャッシュ無効化・RPC順序は維持しています。  
  
  応答到着前に次のキーが入力された場合、consume / forwardの判定は直前の確定済み状態に基づくため、稀にサーバレイテンシ分だけ順序がずれることがあります。  
  (未処理と判明したキーは `ibus_engine_forward_key_event` でアプリへ転送されるため、キーが失われることはありません)  
  
  なお、Fcitx 5フロントエンドは従来どおり同期のままです。  
