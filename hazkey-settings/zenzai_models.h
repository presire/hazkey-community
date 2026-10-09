/**
 * @file zenzai_models.h
 * @brief Zenzaiモデルのメタデータとローカル管理APIの宣言
 *
 * Zenzaiモデルの固定カタログ、保存先、SHA256照合、アクティブモデル用シンボリックリンク、および旧形式モデルの移行を扱う
 */

#ifndef ZENZAI_MODELS_H
#define ZENZAI_MODELS_H

#include <QString>
#include <QVector>
#include <QDir>
#include <QFile>
#include <QCryptographicHash>
#include <QSet>

/**
 * @brief Zenzaiモデル1件分のカタログ情報
 *
 * 各値はアプリケーションの固定カタログまたはそのカタログを利用するテスト用カタログから与えられる
 * ファイルの検証結果やダウンロード状態は保持しない
 */
struct ZenzaiModelOption {
    /** @brief カタログ内および管理対象ファイル名に使うモデルキー */
    QString key;
    /** @brief UIに表示するモデル名 */
    QString displayName;
    /** @brief UIに表示するモデルの説明文 */
    QString description;
    /** @brief モデルファイルのダウンロードURL */
    QString url;
    /** @brief 管理対象モデルファイルに期待するSHA256値 */
    QString sha256;
    /** @brief UIに表示するモデルサイズ */
    QString sizeDisplay;
    /** @brief UI上で推奨モデルとして扱うかどうか */
    bool recommended;
    /** @brief 旧世代モデルとして扱うかどうか */
    bool isLegacyGen;
    /** @brief ダウンロード検証に使う期待バイト数 0は未知を表す */
    qint64 expectedBytes = 0;
    /** @brief 量子化バリアントの表示ラベル (例: "Q5_K_M") 該当なしは空 */
    QString quantLabel;
};

/**
 * @brief 同一モデル系列に属するアーティファクト群
 *
 * @details 単一バリアント系列 (zenz) と複数量子化バリアント系列 (jinen-v2) を
 *          同一の型で表す variantsは表示・選択順序を保った順序付きリストである
 */
struct ZenzaiModelFamily {
    /** @brief 系列を識別するキー */
    QString familyKey;
    /** @brief UIに表示する系列名 */
    QString displayName;
    /** @brief UIに表示する系列の説明文 */
    QString description;
    /** @brief 系列に属するアーティファクトの順序付きリスト */
    QVector<ZenzaiModelOption> variants;
    /**
     * @brief 帰属表示に使う著作者名 空の場合は帰属表示を行わない
     *
     * @details 全て空の系列はUIに行を追加せず、従来どおりの外観を保つ
     */
    QString author;
    /** @brief 配布元リポジトリの絶対URL 空の場合は帰属表示を行わない */
    QString sourceUrl;
    /** @brief 帰属表示に使うライセンス名 (例: "CC-BY-SA-4.0") */
    QString licenseName;
    /** @brief ライセンス全文への絶対URL */
    QString licenseUrl;
    /**
     * @brief 話題/文体/好みの条件付け (条件トークン) に対応するかどうか
     *
     * @details zenz系は条件トークン (U+EE03〜U+EE06) による条件付けに対応する
     *          jinen-v2系は条件トークンを持たず、話題 / 文体 / 好みは設定UI上で無効化する
     *          ユーザープロファイルはjinen系でも入力でき、サーバ側で左文脈の先頭 (末尾25文字) に折り込まれる
     *          既定値はtrueで、不明な系列は有効側に倒す
     */
    bool supportsConditioning = true;
    /**
     * @brief Zenzaiの右文脈に対応するかどうか
     *
     * @details zenz-v3.2以降のzenz系列のみ対応する
     *          zenz-v3.1以前とjinen-v2系は非対応で、対応する設定項目は設定UI上で無効化する
     *          既定値はfalseで、不明な系列は無効側に倒す
     */
    bool supportsRightContext = false;
};

/**
 * @brief アプリケーションが提供する固定Zenzaiモデル系列カタログを返す
 *
 * @details 先頭3件は単一バリアントのzenz系列で従来の順序と値を保ち、
 *          末尾2件はjinen-v2 small/xsmall系列である
 *          返される参照はプロセス内で保持される固定値で、モデルのダウンロード状態を反映して変更されない
 *
 * @return 固定系列カタログへの読み取り専用参照
 */
const QVector<ZenzaiModelFamily>& availableZenzaiModelFamilies();

/**
 * @brief モデルキーからアーティファクトを検索する
 *
 * @details availableZenzaiModels()の平坦化カタログを線形探索し、
 *          一致した要素へのポインタを返す 見つからない場合はnullptrを返す
 *          返されるポインタはプロセス内で保持される固定値を指す
 *
 * @param key 検索するモデルキー
 * @return 一致したアーティファクトへのポインタ、またはnullptr
 */
const ZenzaiModelOption* findZenzaiModelByKey(const QString& key);

/**
 * @brief 系列キーまたはバリアントキーからモデル系列を検索する
 *
 * @details availableZenzaiModelFamilies()を線形探索し、familyKeyの一致または
 *          いずれかのvariants要素のkey一致で系列へのポインタを返す
 *          返されるポインタはプロセス内で保持される固定値を指す
 *
 * @param key 系列キーまたはバリアントキー
 * @return 一致した系列へのポインタ、またはnullptr
 */
const ZenzaiModelFamily* findZenzaiFamilyByKey(const QString& key);

/**
 * @brief 指定モデルの話題/文体/好みの条件付け対応可否を返す
 *
 * @details カタログに登録された系列はそのsupportsConditioningを返して、
 *          未登録のキー (カスタム重み等) はファイル名に "jinen" を含む場合のみfalse、それ以外はtrueを返す (不明な場合は有効側に倒す)
 *          falseでもユーザープロファイルは使用でき、サーバ側で左文脈の先頭 (末尾25文字) に折り込まれる
 *
 * @param modelKey モデルキーまたはモデルファイル名
 * @return 条件トークンによる条件付けに対応する場合はtrue
 */
bool zenzaiModelSupportsConditioning(const QString& modelKey);

/**
 * @brief 指定モデルがZenzaiの右文脈に対応するかどうかを返す
 *
 * @details カタログに登録された系列はそのsupportsRightContextを返す
 *          未登録のキー (カスタム重み等) はファイル名から世代を推定し、
 *          "jinen" を含む場合は非対応、"zenz-v<major>.<minor>" が3.2以上なら対応 (マイナー部は省略可、省略時は0扱い)、
 *          それ未満なら非対応、世代を判別できない場合は対応側に倒す
 *          空文字列はアクティブモデル未確定として対応側に倒す
 *
 * @param modelKeyOrPath モデルキー、モデルファイル名、またはモデルファイルのパス
 * @return 右文脈に対応する場合はtrue
 */
bool zenzaiModelSupportsRightContext(const QString& modelKeyOrPath);

/**
 * @brief 指定モデルがZenzaiのアラインメント区切りに対応するかどうかを返す
 *
 * @details カタログに登録された系列はそのsupportsRightContextを返す
 *          未登録のキー (カスタム重み等) は右文脈と同じファイル名からの世代推定だが、
 *          世代を判別できない場合は非対応側に倒す (右文脈とは逆)
 *          空文字列はアクティブモデル未確定として非対応とする
 *
 * @param modelKeyOrPath モデルキー、モデルファイル名、またはモデルファイルのパス
 * @return アラインメント区切りに対応する場合はtrue
 */
bool zenzaiModelSupportsAlignmentSeparator(const QString& modelKeyOrPath);

/**
 * @brief パスまたはファイル名がJinen系モデルを指すかどうかを返す
 *
 * @details ファイル名部分に "jinen" を含むかどうかを大文字小文字を区別せず判定する
 *          カタログ外のカスタム重みに対するフォールバック判定用
 *
 * @param path モデルファイルのパスまたはファイル名
 * @return Jinen系と推定される場合はtrue
 */
bool isJinenModelPath(const QString& path);

/**
 * @brief アプリケーションが提供する固定Zenzaiモデルカタログを返す
 *
 * カタログには現行の推奨モデル、より小さいモデル、および旧世代の互換モデルが含まれる
 * 返される参照はプロセス内で保持される固定値で、モデルのダウンロード状態を反映して変更されない
 *
 * @return 固定カタログへの読み取り専用参照
 */
const QVector<ZenzaiModelOption>& availableZenzaiModels();

/**
 * @brief 指定ファイルが、管理ディレクトリ内の旧世代カタログモデルかをメタデータだけで判定する
 *
 * @details 結果は「最新ではありません」という案内の表示にだけ使い、機能の有効化には関与しない
 *          そのためファイルの内容は一切読まない (SHA256を計算しない)
 *          名前とサイズだけで識別するので、GUIスレッドで任意サイズのファイルを読んで固まることがない
 *          シンボリックリンクは解決し、実体が ZenzaiModelManager::getModelsDir() 直下にある
 *          <key>.gguf で、<key>が旧世代エントリと一致し、サイズが正のexpectedBytesと等しい場合にだけtrueを返す
 *          管理ディレクトリ内で旧世代と同名かつ同サイズに差し替えられたファイルも対象になるが、影響は案内の文言だけである
 *          任意の場所のカスタム重みは常にfalse (未検証のカスタム扱い)
 *          expectedBytesが0以下 (未知) の旧世代エントリは、サイズで絞れないため対象にしない
 *
 * @param path 判定するモデルファイルのパス
 * @param catalog 照合に使うカタログ
 * @return 条件を満たす場合はtrue 存在しない、非通常ファイル、管理ディレクトリ外、不一致はfalse
 */
bool isManagedLegacyGenerationModel(const QString& path,
                                    const QVector<ZenzaiModelOption>& catalog);

/**
 * @brief Zenzaiモデルの保存・選択・移行を管理するユーティリティ
 *
 * 全メソッドは静的で、設定ファイルなどの状態を内部に保持しない
 */
class ZenzaiModelManager {
public:
    /**
     * @brief Zenzai関連ファイルの基本ディレクトリを返す
     *
     * @details XDG_DATA_HOMEが空でない場合はその値を使い、空の場合はQDir::homePath() + "/.local/share"を使い、
     *          いずれも末尾に"/hazkey-community/zenzai"を付加する
     *
     * @return Zenzaiの基本ディレクトリパス
     */
    static QString getZenzaiDir();

    /**
     * @brief 管理対象モデルを保存するディレクトリを返す
     *
     * @details getZenzaiDir()の末尾に"/models"を付加する
     *
     * @return 管理対象モデルディレクトリのパス
     */
    static QString getModelsDir();

    /**
     * @brief アクティブモデルを指すシンボリックリンクのパスを返す
     *
     * @details パスはgetZenzaiDir()の末尾に"/zenzai.gguf"を付加したものであり、旧形式の通常ファイルも同じパスを使用する
     *
     * @return アクティブモデル用リンクまたは旧形式ファイルのパス
     */
    static QString getSymlinkPath();

    /**
     * @brief モデルキーに対応する管理対象ファイルのパスを返す
     *
     * @param key ファイル名の拡張子より前に使うモデルキー
     * @return getModelsDir()の下にkey + ".gguf"を付加したパス
    */
    static QString getModelPath(const QString& key);
    
    /**
     * @brief ファイル内容のSHA256ダイジェストを計算する
     *
     * @details ファイルを読み取り専用で開き、全内容をSHA256で計算する
     *          結果は16進文字列で、QByteArray::toHex()の表記をそのまま返す
     *          ファイルを開けない場合または読み取りに失敗した場合は空文字列を返す
     *          同一プロセス内ではstat (サイズ+更新時刻) ベースのキャッシュを使い、
     *          変更のないファイルの再ハッシュを避ける 読み取り失敗はキャッシュしない
     *
     * @param filePath ダイジェストを計算するファイルのパス
     * @return SHA256の16進文字列、または失敗時の空文字列
     */
    static QString calculateSHA256(const QString& filePath);

    /**
     * @brief SHA256の実ハッシュ回数を返す (テスト専用)
     *
     * @details calculateSHA256()のstatキャッシュをすり抜けて実際にファイルを読み直した回数を数え、キャッシュヒット時は増えない
     *          回帰テストの検証用であり、通常運用では使わない
     *
     * @return プロセス開始 (または最後のリセット) 以降の実ハッシュ回数
     */
    static int sha256ActualComputeCount();

    /**
     * @brief SHA256の実ハッシュ回数を0に戻す (テスト専用)
     *
     * @details 回帰テストの検証用であり、通常運用では使わない
     */
    static void resetSha256ActualComputeCount();

    /**
     * @brief 管理対象モデルが存在し、カタログのSHA256と一致するか調べる
     *
     * @details 検査対象はmodel.keyから作る管理対象パスで、
     *          ファイルのSHA256はmodel.sha256と大文字小文字を区別せず比較する
     *
     * @param model 検査対象モデルのメタデータ
     * @return ファイルが存在し、SHA256が一致する場合はtrue
    */
    static bool isModelDownloaded(const ZenzaiModelOption& model);

    /**
     * @brief 指定カタログのダウンロード済みモデルキーを一度だけ走査して返す
     *
     * @details 同じキーは最初の検査結果を再利用する。呼び出し側はダイアログの
     *          表示期間中このスナップショットだけを参照し、ディスクを再検査しない。
     */
    static QSet<QString> downloadedModelKeys(const QVector<ZenzaiModelOption>& catalog);
    
    /**
     * @brief 指定した管理対象モデルをアクティブにする
     *
     * @details 管理対象ファイルが存在しない場合は失敗し、
     *          既存のシンボリックリンクは (リンク先が存在しない場合も含めて) 削除して置き換えるが、
     *          同じパスにある通常ファイルは暗黙に置き換えない
     *          基本ディレクトリを作成した後、管理対象ファイルを指すリンクを作る
     *          SHA256の検査はこのメソッドでは行わない
     *
     * @param key アクティブにするモデルのキー
     * @return リンクの作成まで成功した場合はtrue
     */
    static bool activateModel(const QString& key);

    /**
     * @brief 管理対象のアクティブモデル用リンクを解除する
     *
     * @details シンボリックリンクであれば、リンク先の有無にかかわらず削除し、通常ファイルはカスタムモデル保護のため削除しない
     *          リンクも通常ファイルも存在しない場合は成功として扱う
     *
     * @return リンクを削除できた場合、または対象が存在しない場合はtrue
     */
    static bool deactivateModel();

    /**
     * @brief 指定した管理対象モデルを削除する
     *
     * @details 管理対象ファイルが存在しない場合は失敗し、指定モデルがアクティブなら先にアクティブ用リンクを解除し、
     *          その後にモデルファイルを削除し、SHA256の検査はこのメソッドでは行わない
     *
     * @param key 削除するモデルのキー
     * @return モデルファイルの削除まで成功した場合はtrue
    */
    static bool deleteModel(const QString& key);
    
    /**
     * @brief 旧形式のモデルファイルを既定カタログに基づいて移行する
     *
     * @details availableZenzaiModels()をカタログとして使う呼び出しの簡易形であり、
     *          アプリケーションの固定カタログを使う通常運用向け
     */
    static void migrateLegacyModel();

    /**
     * @brief 旧形式のモデルファイルを指定カタログに基づいて移行する
     *
     * @details アクティブモデル用パスにある通常ファイルだけを対象とし、
     *          そのSHA256がカタログ内のモデルと一致した場合に限り、models/へ移動してリンクを作る
     *          移動先が既に存在する場合は、移動先のSHA256も一致するときだけ旧ファイルを削除してリンクを作る
     *          不一致の移動先やカタログにないファイルは変更しない
     *          catalog引数はテストなどでカタログを注入するための形であり、固定アプリケーションカタログを必ずしも使わない
     *
     * @param catalog 移行判定に使うモデルカタログ
    */
    static void migrateLegacyModel(const QVector<ZenzaiModelOption>& catalog);
    
    /**
     * @brief 現在アクティブなモデルのキーを取得する
     *
     * @details アクティブモデル用パスが存在するシンボリックリンクの場合に限り、
     *          リンク先ファイル名の末尾 ".gguf" を除いた文字列を返す
     *          カタログへの登録有無やSHA256は検査しない
     *
     * @return アクティブモデルのキー、または有効なリンクがない場合の空文字列
     */
    static QString getActiveModelKey();

    /**
     * @brief モデル情報をUI表示用ラベルに整形する
     *
     * @details displayNameを基にし、recommendedがtrueなら推奨表示を前置きし、
     *          downloadedがtrueならダウンロード済み表示を付加し、
     *          最後にsizeDisplayを " : " で連結し、前置きとダウンロード済み表示はMainWindowコンテキストの翻訳文字列を使う
     *
     * @param model ラベルに使うモデル情報
     * @param downloaded ダウンロード済み表示を付加するかどうか
     * @return UI表示用に整形したラベル
     */
    static QString formatModelLabel(const ZenzaiModelOption& model, bool downloaded);
};

#endif // ZENZAI_MODELS_H
