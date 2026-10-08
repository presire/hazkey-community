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
 * @brief モデル保存先ディレクトリを検証して、ディレクトリ記述子として開く
 * @param directoryPath モデル保存先ディレクトリ (末端が無ければ0700で作成する)
 * @param errorMessage 失敗理由 (英語の詳細) を受け取る任意の出力先
 * @return 検証済みディレクトリの記述子 (呼び出し側がclose()する)、失敗時は-1
 *
 * @details 末端をシンボリックリンクではない実ディレクトリとして
 *          O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC で開き、開いた記述子に対して
 *          fstat() で (1) ディレクトリであること (2) 現在のuid所有であること
 *          を確認する。group/otherに書込権限があれば、開いた記述子に fchmod() して
 *          その権限を外す (旧版や umask 002 の環境が作ったディレクトリを拒否しないため)。
 *          確認と権限の変更は開いた実体に対して行うため、検証と使用の間にパス名が
 *          差し替えられても影響しない。検証に失敗したら何も作成せず-1を返す。
 *
 *          保護の境界: 他ユーザによる差替え・書込みと、古い・差し替え済みの
 *          一時ファイルパスから保護する。同一UIDで動く任意の悪意あるプロセスに
 *          対する防御は目的としない (そのプロセスは利用者のモデルを直接書き換えられる)。
 */
int openVerifiedModelDirectory(const QString& directoryPath,
                               QString* errorMessage = nullptr);

/**
 * @brief 検証済みディレクトリ内に、0600の新規一時ファイルを作成して開く
 * @param directoryFd openVerifiedModelDirectory() が返した記述子
 * @param temporaryName ディレクトリ直下のファイル名 (区切り文字・"."・".." は不可)
 * @param errorMessage 失敗理由を受け取る任意の出力先
 * @return 読み書き可能な記述子 (呼び出し側がclose()する)、失敗時は-1
 *
 * @details 同名の古い一時ファイル・シンボリックリンクは、リンク自体を unlinkat() で
 *          外してから O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC・0600 で新規作成する。
 *          最初の書込みの前から権限は0600で、書込み先を辿らせない。
 */
int createPrivateTemporaryFile(int directoryFd, const QString& temporaryName,
                               QString* errorMessage = nullptr);

/**
 * @brief 開いている記述子の内容を先頭からEOFまで読み、SHA256を計算する
 * @param fd 読み出し可能な記述子 (pread() を使うため位置を動かさない)
 * @param maxBytes 許容する最大バイト数。超えたら失敗とする
 * @param bytesRead 読んだバイト数を受け取る出力先
 * @param sha256Hex SHA256の16進表現を受け取る出力先
 * @param errorMessage 失敗理由を受け取る任意の出力先
 * @return EOFまで読めて上限内ならtrue
 */
bool hashDescriptorContents(int fd, qint64 maxBytes, qint64* bytesRead,
                            QString* sha256Hex, QString* errorMessage = nullptr);

/**
 * @brief finalizeStreamedModelDownload() の結果
 *
 * @details validation は「ディスク上の内容」を検証した結果である。内容を読む前に
 *          失敗した場合 (引数不正・記述子の不整合・入出力エラー) と、内容は受入可能
 *          だったが確定に失敗した場合は Accepted のままで、committed=false かつ
 *          errorMessage に理由が入る。
 */
struct StreamedModelFinalization {
    bool committed = false;
    ModelDownloadValidation validation = ModelDownloadValidation::Accepted;
    /** 記述子から再計算したバイト数 (内容を読めた場合のみ有効) */
    qint64 diskBytes = 0;
    /** 記述子から再計算したSHA256の16進表現 (内容を読めた場合のみ有効) */
    QString diskSha256Hex;
    QString errorMessage;
};

/**
 * @brief ストリーミング受信済みの一時ファイルを、ディスク上の内容を再検証してから確定する
 * @param directoryFd openVerifiedModelDirectory() が返したモデル保存先の記述子
 * @param temporaryName 保存先直下の一時ファイル名 (createPrivateTemporaryFile() で作成したもの)
 * @param finalName 保存先直下の最終ファイル名
 * @param fileDescriptor 一時ファイルを書き出した、開いたままの記述子 (必須。負なら失敗)
 * @param expectedBytes 正の値なら必須の正確なサイズ、0以下ならサイズ検証を省略する
 * @param expectedSha256 SHA256の16進期待値
 * @return 確定結果。committed が真のときだけ最終ファイルが置き換えられている
 *
 * @details 受信時に計算したハッシュは信用しない。fsync() の後、同じ記述子から
 *          先頭を pread() で読み直してSHA256とサイズを再計算し、期待値と比べる。
 *          これにより検証したバイト列は、その記述子 (inode) の実バイト列になる。
 *          確定は、fstatat(AT_SYMLINK_NOFOLLOW) で一時ファイル名が記述子と同じ
 *          dev/ino であることを確認してから、renameat() をディレクトリ記述子経由で
 *          行う (パス名の再解決をしない)。既存モデルは削除せず、renameat() が原子的に置換する。
 *          記述子は通常ファイル・現在のuid所有・リンク数1・group/other書込権限なしで
 *          なければならない。検証が拒否した場合は、記述子と同じ実体の一時ファイルだけを
 *          削除する (別の実体に差し替えられていれば何も削除しない)。
 *
 *          保護の境界: 他ユーザおよび古い・差し替え済みの一時ファイルパスから守る。
 *          同一UIDの任意のプロセスに対する防御は主張しない。
 */
StreamedModelFinalization finalizeStreamedModelDownload(
    int directoryFd, const QString& temporaryName, const QString& finalName,
    int fileDescriptor, qint64 expectedBytes, const QString& expectedSha256);

#endif  // ZENZAI_DOWNLOAD_VALIDATION_H
