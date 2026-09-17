/**
 * @file zenzai_download_validation.cpp
 * @brief 管理対象Zenzaiモデル成果物の検証と確定処理を実装する
 */

#include "zenzai_download_validation.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>

namespace {

void setErrorMessage(QString* errorMessage, const QString& message) {
    if (errorMessage) {
        *errorMessage = message;
    }
}

void removeTemporaryFile(const QString& temporaryPath) {
    QFile::remove(temporaryPath);
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

bool finalizeModelDownload(const QString& modelPath, const QByteArray& downloadedData,
                           ModelDownloadValidation validation,
                           QString* errorMessage) {
    const QString temporaryPath = modelPath + ".tmp";
    if (validation != ModelDownloadValidation::Accepted) {
        removeTemporaryFile(temporaryPath);
        return false;
    }

    const QString parentDirectory = QFileInfo(modelPath).absolutePath();
    if (!QDir().mkpath(parentDirectory)) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to create model directory: %1")
                            .arg(parentDirectory));
        removeTemporaryFile(temporaryPath);
        return false;
    }

    if (QFile::exists(temporaryPath) && !QFile::remove(temporaryPath)) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to remove stale temporary file: %1")
                            .arg(temporaryPath));
        return false;
    }

    QFile temporaryFile(temporaryPath);
    if (!temporaryFile.open(QIODevice::WriteOnly)) {
        setErrorMessage(errorMessage, temporaryFile.errorString());
        removeTemporaryFile(temporaryPath);
        return false;
    }

    const qint64 bytesWritten = temporaryFile.write(downloadedData);
    if (bytesWritten != static_cast<qint64>(downloadedData.size()) ||
        !temporaryFile.flush()) {
        setErrorMessage(errorMessage, temporaryFile.errorString());
        temporaryFile.close();
        removeTemporaryFile(temporaryPath);
        return false;
    }
    temporaryFile.close();

    if (QFile::exists(modelPath) && !QFile::remove(modelPath)) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to remove old model file: %1")
                            .arg(modelPath));
        removeTemporaryFile(temporaryPath);
        return false;
    }

    if (!QFile::rename(temporaryPath, modelPath)) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to rename temporary model file: %1")
                            .arg(temporaryPath));
        removeTemporaryFile(temporaryPath);
        return false;
    }

    return true;
}

bool finalizeStreamedModelDownload(const QString& modelPath,
                                   ModelDownloadValidation validation,
                                   QString* errorMessage) {
    const QString temporaryPath = modelPath + ".tmp";
    if (validation != ModelDownloadValidation::Accepted) {
        removeTemporaryFile(temporaryPath);
        return false;
    }

    const QString parentDirectory = QFileInfo(modelPath).absolutePath();
    if (!QDir().mkpath(parentDirectory)) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to create model directory: %1")
                            .arg(parentDirectory));
        removeTemporaryFile(temporaryPath);
        return false;
    }

    if (QFile::exists(modelPath) && !QFile::remove(modelPath)) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to remove old model file: %1")
                            .arg(modelPath));
        removeTemporaryFile(temporaryPath);
        return false;
    }

    if (!QFile::rename(temporaryPath, modelPath)) {
        setErrorMessage(errorMessage,
                        QStringLiteral("Failed to rename temporary model file: %1")
                            .arg(temporaryPath));
        removeTemporaryFile(temporaryPath);
        return false;
    }

    return true;
}
