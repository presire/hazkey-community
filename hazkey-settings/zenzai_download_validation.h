#ifndef ZENZAI_DOWNLOAD_VALIDATION_H
#define ZENZAI_DOWNLOAD_VALIDATION_H

#include <QByteArray>
#include <QString>
#include <QtGlobal>

/**
 * @brief ダウンロードした管理対象モデル成果物の整合性検証結果
 */
enum class ModelDownloadValidation {
    Accepted,
    SizeMismatch,
    ChecksumMismatch,
};

/** @brief 期待バイト数が未知 (0以下) のモデルに適用する受信サイズの絶対上限 (4 GiB) */
constexpr qint64 kUnknownSizeModelDownloadLimitBytes = Q_INT64_C(4) * 1024 * 1024 * 1024;

/**
 * @brief 受信中のモデルが許容サイズを超えたかを判定する
 * @param receivedBytes 受信済みバイト数
 * @param declaredTotalBytes 応答が申告した総バイト数 (Content-Length相当、不明なら0以下)
 * @param expectedBytes 正の値なら許容上限、0以下なら kUnknownSizeModelDownloadLimitBytes を上限とする
 * @return 受信済みまたは申告総量が上限を超えるならtrue
 */
bool downloadExceedsSizeLimit(qint64 receivedBytes, qint64 declaredTotalBytes,
                              qint64 expectedBytes);

/**
 * @brief モデル本文を期待バイト数とSHA256で順番に検証する
 * @param downloadedData ネットワークから実際に受信した本文
 * @param expectedBytes 正の値なら必須の正確な本文サイズ、0以下ならサイズ検証を省略する
 * @param expectedSha256 SHA256の16進期待値
 * @return サイズ不一致、SHA256不一致、または受入可能な本文を表す結果
 */
ModelDownloadValidation validateModelDownload(
    const QByteArray& downloadedData, qint64 expectedBytes,
    const QString& expectedSha256);

/**
 * @brief ストリーミング受信済み本文を期待バイト数とSHA256で順番に検証する
 * @param receivedBytes ディスクへ書き出した実際の受信バイト数
 * @param expectedBytes 正の値なら必須の正確な本文サイズ、0以下ならサイズ検証を省略する
 * @param actualSha256Hex 受信本文全体のSHA256の16進表現 (大文字小文字を問わない)
 * @param expectedSha256 SHA256の16進期待値
 * @return サイズ不一致、SHA256不一致、または受入可能な本文を表す結果
 *
 * @details validateModelDownload() と同じ受入基準を、メモリ上の本文なしで適用する。
 *          増分ハッシュ (QCryptographicHash::result().toHex()) の結果をそのまま渡せる。
 */
ModelDownloadValidation validateStreamedModelDownload(
    qint64 receivedBytes, qint64 expectedBytes,
    const QString& actualSha256Hex, const QString& expectedSha256);

/**
 * @brief 検証済み本文だけを一時ファイル経由で管理対象モデルパスへ確定する
 * @param modelPath 最終モデルパス
 * @param downloadedData 保存する受信本文
 * @param validation validateModelDownload()の結果
 * @param errorMessage 保存失敗時の詳細メッセージを受け取る任意の出力先
 * @return Acceptedの本文を保存して確定できた場合はtrue
 *
 * @details Accepted以外ではmodelPathを変更せず、modelPath + ".tmp" を削除する。
 */
bool finalizeModelDownload(const QString& modelPath, const QByteArray& downloadedData,
                           ModelDownloadValidation validation,
                           QString* errorMessage = nullptr);

/**
 * @brief ストリーミング受信済みの一時ファイルだけを管理対象モデルパスへ確定する
 * @param modelPath 最終モデルパス (modelPath + ".tmp" が受信済み本文であること)
 * @param validation validateStreamedModelDownload() の結果
 * @param errorMessage 保存失敗時の詳細メッセージを受け取る任意の出力先
 * @return Acceptedの一時ファイルを改名して確定できた場合はtrue
 *
 * @details Accepted以外ではmodelPathを変更せず、modelPath + ".tmp" を削除する。
 *          finalizeModelDownload() と同じ確定基準だが、本文の書出しは行わない
 *          (readyRead駆動で既に一時ファイルへ書き出し済みのため)。
 */
bool finalizeStreamedModelDownload(const QString& modelPath,
                                   ModelDownloadValidation validation,
                                   QString* errorMessage = nullptr);

#endif  // ZENZAI_DOWNLOAD_VALIDATION_H
