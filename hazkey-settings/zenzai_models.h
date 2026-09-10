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
};

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
     *          いずれも末尾に"/hazkey/zenzai"を付加する
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
     *
     * @param filePath ダイジェストを計算するファイルのパス
     * @return SHA256の16進文字列、または失敗時の空文字列
     */
    static QString calculateSHA256(const QString& filePath);

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
