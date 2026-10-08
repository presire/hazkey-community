/**
 * @file zenzai_download_validation.cpp
 * @brief 管理対象Zenzaiモデル成果物の検証と確定処理を実装する
 */

#include "zenzai_download_validation.h"

#include <QByteArray>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>

#include <cerrno>
#include <cstring>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace {

void setErrorMessage(QString* errorMessage, const QString& message) {
    if (errorMessage) {
        *errorMessage = message;
    }
}

QString errnoText() { return QString::fromLocal8Bit(std::strerror(errno)); }

/** @brief ディレクトリ直下の単純なファイル名か (区切り文字・"."・".."・空は不可) */
bool isPlainFileName(const QString& name) {
    return !name.isEmpty() && name != QStringLiteral(".") &&
           name != QStringLiteral("..") && !name.contains(QLatin1Char('/')) &&
           !name.contains(QLatin1Char('\0'));
}

/** @brief fdを閉じるだけの最小RAII */
class ScopedDescriptor {
   public:
    explicit ScopedDescriptor(int fd) : fd_(fd) {}
    ~ScopedDescriptor() {
        if (fd_ >= 0) {
            ::close(fd_);
        }
    }
    ScopedDescriptor(const ScopedDescriptor&) = delete;
    ScopedDescriptor& operator=(const ScopedDescriptor&) = delete;
    int get() const { return fd_; }
    int release() {
        const int fd = fd_;
        fd_ = -1;
        return fd;
    }

   private:
    int fd_;
};

/**
 * @brief ディレクトリ内の名前が、記述子と同じ実体 (dev/ino) を指す通常ファイルか確認する
 *
 * @details fstatat(AT_SYMLINK_NOFOLLOW) なので、名前がシンボリックリンクや別ファイルへ
 *          差し替えられていれば不一致になる。
 */
bool nameMatchesDescriptor(int directoryFd, const QByteArray& name, int fd) {
    struct stat byName {};
    struct stat byDescriptor {};
    if (::fstatat(directoryFd, name.constData(), &byName, AT_SYMLINK_NOFOLLOW) != 0 ||
        ::fstat(fd, &byDescriptor) != 0) {
        return false;
    }
    return S_ISREG(byName.st_mode) && S_ISREG(byDescriptor.st_mode) &&
           byName.st_dev == byDescriptor.st_dev &&
           byName.st_ino == byDescriptor.st_ino;
}

/** @brief 名前が記述子と同じ実体のときだけ削除する (別の実体に差し替えられていれば残す) */
void removeOwnTemporary(int directoryFd, const QByteArray& name, int fd) {
    if (nameMatchesDescriptor(directoryFd, name, fd)) {
        ::unlinkat(directoryFd, name.constData(), 0);
    }
}

ModelDownloadValidation validateSizeAndHash(qint64 receivedBytes,
                                            qint64 expectedBytes,
                                            const QString& actualSha256Hex,
                                            const QString& expectedSha256) {
    if (expectedBytes > 0 && receivedBytes != expectedBytes) {
        return ModelDownloadValidation::SizeMismatch;
    }

    if (actualSha256Hex.compare(expectedSha256, Qt::CaseInsensitive) != 0) {
        return ModelDownloadValidation::ChecksumMismatch;
    }

    return ModelDownloadValidation::Accepted;
}

}  // namespace

bool downloadExceedsSizeLimit(qint64 receivedBytes, qint64 declaredTotalBytes,
                              qint64 expectedBytes) {
    const qint64 limit =
        expectedBytes > 0 ? expectedBytes : kUnknownSizeModelDownloadLimitBytes;
    return receivedBytes > limit || declaredTotalBytes > limit;
}

ModelDownloadValidation validateModelDownload(
    const QByteArray& downloadedData, qint64 expectedBytes,
    const QString& expectedSha256) {
    const QString calculatedSha256 = QString::fromLatin1(
        QCryptographicHash::hash(downloadedData, QCryptographicHash::Sha256).toHex());
    return validateSizeAndHash(downloadedData.size(), expectedBytes,
                               calculatedSha256, expectedSha256);
}

ModelDownloadValidation validateStreamedModelDownload(
    qint64 receivedBytes, qint64 expectedBytes,
    const QString& actualSha256Hex, const QString& expectedSha256) {
    return validateSizeAndHash(receivedBytes, expectedBytes, actualSha256Hex,
                               expectedSha256);
}

int openVerifiedModelDirectory(const QString& directoryPath, QString* errorMessage) {
    const QString cleanPath = QDir::cleanPath(QFileInfo(directoryPath).absoluteFilePath());
    const QByteArray encodedPath = QFile::encodeName(cleanPath);

    // 親は通常どおり作成し、末端だけを0700で作る (既存ならEEXISTで検証へ進む)
    QDir().mkpath(QFileInfo(cleanPath).absolutePath());
    if (::mkdir(encodedPath.constData(), 0700) != 0 && errno != EEXIST) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to create model directory: %1 (%2)")
                            .arg(cleanPath, errnoText()));
        return -1;
    }

    // 末端がシンボリックリンクなら O_NOFOLLOW により開けない
    ScopedDescriptor directory(::open(
        encodedPath.constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (directory.get() < 0) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Model directory is not a real directory: %1 (%2)")
                            .arg(cleanPath, errnoText()));
        return -1;
    }

    // 検証は開いた実体に対して行う (パス名の再解決をしない)
    struct stat info {};
    if (::fstat(directory.get(), &info) != 0) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to inspect model directory: %1 (%2)")
                            .arg(cleanPath, errnoText()));
        return -1;
    }
    if (!S_ISDIR(info.st_mode) || info.st_uid != ::getuid()) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Model directory must be owned by the current user: %1")
                            .arg(cleanPath));
        return -1;
    }
    // 旧版や umask 002 の環境が作った group/other 書込可のディレクトリは、拒否せずに書込権限を外す
    // fchmod() は検証した実体 (開いた記述子) に対して行うため、パス名の差し替えの影響を受けない
    if ((info.st_mode & (S_IWGRP | S_IWOTH)) != 0 &&
        ::fchmod(directory.get(), info.st_mode & 07755 & ~(S_IWGRP | S_IWOTH)) != 0) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to remove group/other write permission from "
                                       "model directory: %1 (%2)")
                            .arg(cleanPath, errnoText()));
        return -1;
    }
    return directory.release();
}

int createPrivateTemporaryFile(int directoryFd, const QString& temporaryName,
                               QString* errorMessage) {
    if (directoryFd < 0 || !isPlainFileName(temporaryName)) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Invalid temporary model file name: %1")
                            .arg(temporaryName));
        return -1;
    }

    const QByteArray encodedName = QFile::encodeName(temporaryName);
    // 古い一時ファイルやシンボリックリンクは、リンク自体を外して書込み先を辿らせない
    if (::unlinkat(directoryFd, encodedName.constData(), 0) != 0 && errno != ENOENT) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to remove stale temporary file: %1 (%2)")
                            .arg(temporaryName, errnoText()));
        return -1;
    }

    const int fd = ::openat(directoryFd, encodedName.constData(),
                            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to create temporary model file: %1 (%2)")
                            .arg(temporaryName, errnoText()));
        return -1;
    }
    return fd;
}

bool hashDescriptorContents(int fd, qint64 maxBytes, qint64* bytesRead,
                            QString* sha256Hex, QString* errorMessage) {
    if (fd < 0) {
        setErrorMessage(errorMessage, QStringLiteral("Invalid file descriptor"));
        return false;
    }

    QCryptographicHash hash(QCryptographicHash::Sha256);
    QByteArray buffer(1 << 20, Qt::Uninitialized);
    qint64 total = 0;
    for (;;) {
        const ssize_t count =
            ::pread(fd, buffer.data(), static_cast<size_t>(buffer.size()),
                    static_cast<off_t>(total));
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            setErrorMessage(errorMessage,
                            QStringLiteral("Failed to read back model file: %1")
                                .arg(errnoText()));
            return false;
        }
        if (count == 0) {
            break;
        }
        total += count;
        if (total > maxBytes) {
            if (bytesRead) {
                *bytesRead = total;
            }
            setErrorMessage(errorMessage,
                            QStringLiteral("Model file exceeds the allowed size"));
            return false;
        }
        hash.addData(QByteArrayView(buffer.constData(), static_cast<qsizetype>(count)));
    }

    if (bytesRead) {
        *bytesRead = total;
    }
    if (sha256Hex) {
        *sha256Hex = QString::fromLatin1(hash.result().toHex());
    }
    return true;
}

StreamedModelFinalization finalizeStreamedModelDownload(
    int directoryFd, const QString& temporaryName, const QString& finalName,
    int fileDescriptor, qint64 expectedBytes, const QString& expectedSha256) {
    StreamedModelFinalization result;

    if (directoryFd < 0 || fileDescriptor < 0 || !isPlainFileName(temporaryName) ||
        !isPlainFileName(finalName) || temporaryName == finalName) {
        result.errorMessage = QStringLiteral(
            "A verified directory, a file descriptor and plain file names are required");
        return result;
    }
    const QByteArray encodedTemporary = QFile::encodeName(temporaryName);
    const QByteArray encodedFinal = QFile::encodeName(finalName);

    // 記述子自体が、自分の私的な通常ファイルであること (リンク数1はハードリンク別名の排除)
    struct stat info {};
    if (::fstat(fileDescriptor, &info) != 0) {
        result.errorMessage =
            QStringLiteral("Failed to inspect temporary model file: %1").arg(errnoText());
        return result;
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != ::geteuid() || info.st_nlink != 1 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        result.errorMessage = QStringLiteral(
            "Temporary model file is not a private regular file: %1").arg(temporaryName);
        removeOwnTemporary(directoryFd, encodedTemporary, fileDescriptor);
        return result;
    }

    // 永続化してから、同じ記述子の実バイト列を読み直す。受信時のハッシュは信用しない
    if (::fsync(fileDescriptor) != 0) {
        result.errorMessage =
            QStringLiteral("Failed to flush temporary model file: %1").arg(errnoText());
        removeOwnTemporary(directoryFd, encodedTemporary, fileDescriptor);
        return result;
    }

    const qint64 limit =
        expectedBytes > 0 ? expectedBytes : kUnknownSizeModelDownloadLimitBytes;
    QString hashError;
    if (!hashDescriptorContents(fileDescriptor, limit, &result.diskBytes,
                                &result.diskSha256Hex, &hashError)) {
        if (result.diskBytes > limit) {
            result.validation = ModelDownloadValidation::SizeMismatch;
        }
        result.errorMessage = hashError;
        removeOwnTemporary(directoryFd, encodedTemporary, fileDescriptor);
        return result;
    }

    result.validation = validateStreamedModelDownload(
        result.diskBytes, expectedBytes, result.diskSha256Hex, expectedSha256);
    if (result.validation != ModelDownloadValidation::Accepted) {
        removeOwnTemporary(directoryFd, encodedTemporary, fileDescriptor);
        return result;
    }

    // 名前が記述子と同じ実体を指す場合だけ、ディレクトリ記述子経由で原子的に置換する
    if (!nameMatchesDescriptor(directoryFd, encodedTemporary, fileDescriptor)) {
        result.errorMessage = QStringLiteral(
            "Temporary model file was replaced or removed: %1").arg(temporaryName);
        return result;
    }
    if (::renameat(directoryFd, encodedTemporary.constData(), directoryFd,
                   encodedFinal.constData()) != 0) {
        result.errorMessage =
            QStringLiteral("Failed to rename temporary model file: %1 (%2)")
                .arg(temporaryName, errnoText());
        removeOwnTemporary(directoryFd, encodedTemporary, fileDescriptor);
        return result;
    }

    // 改名の永続化は最善努力 (失敗しても確定済みの内容は有効)
    ::fsync(directoryFd);
    result.committed = true;
    return result;
}

bool finalizeModelDownload(const QString& modelPath, const QByteArray& downloadedData,
                           ModelDownloadValidation validation,
                           QString* errorMessage) {
    const QString parentDirectory = QFileInfo(modelPath).absolutePath();
    const QString finalName = QFileInfo(modelPath).fileName();
    const QString temporaryName = finalName + QStringLiteral(".tmp");
    if (validation != ModelDownloadValidation::Accepted) {
        QFile::remove(modelPath + QStringLiteral(".tmp"));
        return false;
    }

    const ScopedDescriptor directory(openVerifiedModelDirectory(parentDirectory, errorMessage));
    if (directory.get() < 0) {
        return false;
    }

    const ScopedDescriptor file(
        createPrivateTemporaryFile(directory.get(), temporaryName, errorMessage));
    if (file.get() < 0) {
        return false;
    }

    qint64 written = 0;
    while (written < downloadedData.size()) {
        const ssize_t count =
            ::write(file.get(), downloadedData.constData() + written,
                    static_cast<size_t>(downloadedData.size() - written));
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            setErrorMessage(errorMessage,
                            QStringLiteral("Failed to write temporary model file: %1")
                                .arg(errnoText()));
            ::unlinkat(directory.get(), QFile::encodeName(temporaryName).constData(), 0);
            return false;
        }
        written += count;
    }

    // 呼び出し側が受入判定済みの本文と、ディスク上の内容が一致することを再確認して確定する
    const QString expectedSha256 = QString::fromLatin1(
        QCryptographicHash::hash(downloadedData, QCryptographicHash::Sha256).toHex());
    const StreamedModelFinalization finalization = finalizeStreamedModelDownload(
        directory.get(), temporaryName, finalName, file.get(), downloadedData.size(),
        expectedSha256);
    if (!finalization.committed) {
        setErrorMessage(errorMessage, finalization.errorMessage);
    }
    return finalization.committed;
}
