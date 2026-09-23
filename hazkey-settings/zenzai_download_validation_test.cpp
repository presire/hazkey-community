/**
 * @file zenzai_download_validation_test.cpp
 * @brief 管理対象Zenzaiモデルのダウンロード検証と確定処理のQt Test
 *
 * 実受信本文のサイズ、SHA256、tmp経由の確定処理を一時XDGデータディレクトリで検証する。
 */

#include <QtTest/QtTest>

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QProcess>
#include <QTemporaryDir>

#include "zenzai_download_validation.h"

class ZenzaiDownloadValidationTest : public QObject {
    Q_OBJECT

   private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();
    void testAcceptedArtifactIsFinalized();
    void testSizeMismatchPrecedesChecksum();
    void testChecksumMismatchLeavesNoArtifact();
    void testUnknownExpectedBytesUsesShaOnly();
    void testChecksumComparisonIsCaseInsensitive();
    void testRejectedDownloadClearsStaleTmpAndPreservesExistingModel();
    void testMalformedInputsLeaveNoArtifacts();
    void testPostRejectionFilesystemListing();
    void testStreamedAcceptedArtifactIsFinalized();
    void testStreamedSizeMismatchPrecedesChecksum();
    void testStreamedChecksumMismatchLeavesNoArtifact();
    void testStreamedUnknownExpectedBytesUsesShaOnly();
    void testStreamedChecksumComparisonIsCaseInsensitive();
    void testStreamedRejectionClearsTmpAndPreservesExistingModel();

   private:
    QString modelDirectory() const;
    QString modelPath(const QString& key) const;
    QString sha256(const QByteArray& data) const;
    void writeFile(const QString& path, const QByteArray& data) const;
    QByteArray readFile(const QString& path) const;

    QTemporaryDir tempDir_;
    QString originalXdgDataHome_;
};

void ZenzaiDownloadValidationTest::initTestCase() {
    QVERIFY(tempDir_.isValid());
    originalXdgDataHome_ = qEnvironmentVariable("XDG_DATA_HOME");
    qputenv("XDG_DATA_HOME", tempDir_.path().toUtf8());
}

void ZenzaiDownloadValidationTest::cleanupTestCase() {
    if (originalXdgDataHome_.isEmpty()) {
        qunsetenv("XDG_DATA_HOME");
    } else {
        qputenv("XDG_DATA_HOME", originalXdgDataHome_.toUtf8());
    }
}

void ZenzaiDownloadValidationTest::init() {
    QDir(tempDir_.path()).removeRecursively();
    QVERIFY(QDir().mkpath(tempDir_.path()));
}

QString ZenzaiDownloadValidationTest::modelDirectory() const {
    return tempDir_.path() + "/hazkey-community/zenzai/models";
}

QString ZenzaiDownloadValidationTest::modelPath(const QString& key) const {
    return modelDirectory() + "/" + key + ".gguf";
}

QString ZenzaiDownloadValidationTest::sha256(const QByteArray& data) const {
    return QString::fromLatin1(
        QCryptographicHash::hash(data, QCryptographicHash::Sha256).toHex());
}

void ZenzaiDownloadValidationTest::writeFile(const QString& path,
                                              const QByteArray& data) const {
    QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write(data), qint64(data.size()));
}

QByteArray ZenzaiDownloadValidationTest::readFile(const QString& path) const {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return QByteArray();
    }
    return file.readAll();
}

void ZenzaiDownloadValidationTest::testAcceptedArtifactIsFinalized() {
    const QByteArray downloadedData("verified model artifact");
    const QString path = modelPath("accepted");
    const ModelDownloadValidation validation = validateModelDownload(
        downloadedData, downloadedData.size(), sha256(downloadedData));

    QCOMPARE(static_cast<int>(validation),
             static_cast<int>(ModelDownloadValidation::Accepted));
    QVERIFY(finalizeModelDownload(path, downloadedData, validation));
    QVERIFY(QFile::exists(path));
    QCOMPARE(readFile(path), downloadedData);
    QVERIFY(!QFile::exists(path + ".tmp"));
}

void ZenzaiDownloadValidationTest::testSizeMismatchPrecedesChecksum() {
    const QByteArray downloadedData("truncated");
    const QString path = modelPath("size-mismatch");
    const ModelDownloadValidation validation = validateModelDownload(
        downloadedData, downloadedData.size() + 1,
        sha256(QByteArray("different body with a different checksum")));

    QCOMPARE(static_cast<int>(validation),
             static_cast<int>(ModelDownloadValidation::SizeMismatch));
    QVERIFY(!finalizeModelDownload(path, downloadedData, validation));
    QVERIFY(!QFile::exists(path));
    QVERIFY(!QFile::exists(path + ".tmp"));
}

void ZenzaiDownloadValidationTest::testChecksumMismatchLeavesNoArtifact() {
    const QByteArray downloadedData("same-size payload");
    const QString path = modelPath("checksum-mismatch");
    const ModelDownloadValidation validation = validateModelDownload(
        downloadedData, downloadedData.size(), sha256(QByteArray("other-payload-xx")));

    QCOMPARE(static_cast<int>(validation),
             static_cast<int>(ModelDownloadValidation::ChecksumMismatch));
    QVERIFY(!finalizeModelDownload(path, downloadedData, validation));
    QVERIFY(!QFile::exists(path));
    QVERIFY(!QFile::exists(path + ".tmp"));
}

void ZenzaiDownloadValidationTest::testUnknownExpectedBytesUsesShaOnly() {
    const QByteArray downloadedData("legacy zenz body");

    QCOMPARE(static_cast<int>(validateModelDownload(downloadedData, 0,
                                                     sha256(downloadedData))),
             static_cast<int>(ModelDownloadValidation::Accepted));
    QCOMPARE(static_cast<int>(validateModelDownload(downloadedData, -1,
                                                     sha256(downloadedData))),
             static_cast<int>(ModelDownloadValidation::Accepted));
}

void ZenzaiDownloadValidationTest::testChecksumComparisonIsCaseInsensitive() {
    const QByteArray downloadedData("uppercase expected SHA256");

    QCOMPARE(static_cast<int>(validateModelDownload(
                 downloadedData, downloadedData.size(), sha256(downloadedData).toUpper())),
             static_cast<int>(ModelDownloadValidation::Accepted));
}

void ZenzaiDownloadValidationTest::testRejectedDownloadClearsStaleTmpAndPreservesExistingModel() {
    const QString path = modelPath("preserve-existing");
    const QByteArray existingData("previously verified managed model");
    writeFile(path, existingData);
    writeFile(path + ".tmp", QByteArray("stale temporary content"));

    const QByteArray rejectedData("short");
    const ModelDownloadValidation validation = validateModelDownload(
        rejectedData, rejectedData.size() + 1, sha256(QByteArray("wrong checksum")));

    QCOMPARE(static_cast<int>(validation),
             static_cast<int>(ModelDownloadValidation::SizeMismatch));
    QVERIFY(!finalizeModelDownload(path, rejectedData, validation));
    QCOMPARE(readFile(path), existingData);
    QVERIFY(!QFile::exists(path + ".tmp"));
}

void ZenzaiDownloadValidationTest::testMalformedInputsLeaveNoArtifacts() {
    struct RejectedInput {
        QString key;
        QByteArray data;
        qint64 expectedBytes;
        QString expectedSha256;
        ModelDownloadValidation expectedValidation;
    };
    const QVector<RejectedInput> rejectedInputs = {
        {"truncated", QByteArray("short"), 6, sha256(QByteArray("short")),
         ModelDownloadValidation::SizeMismatch},
        {"empty", QByteArray(), 1, sha256(QByteArray()),
         ModelDownloadValidation::SizeMismatch},
        {"oversize", QByteArray("too long"), 1, sha256(QByteArray("too long")),
         ModelDownloadValidation::SizeMismatch},
        {"non-hex-sha", QByteArray("same"), 4, QStringLiteral("not-a-hex-sha"),
         ModelDownloadValidation::ChecksumMismatch},
    };

    for (const RejectedInput& input : rejectedInputs) {
        const QString path = modelPath(input.key);
        const ModelDownloadValidation validation = validateModelDownload(
            input.data, input.expectedBytes, input.expectedSha256);
        QCOMPARE(static_cast<int>(validation), static_cast<int>(input.expectedValidation));
        QVERIFY(!finalizeModelDownload(path, input.data, validation));
        QVERIFY(!QFile::exists(path));
        QVERIFY(!QFile::exists(path + ".tmp"));
    }
}

void ZenzaiDownloadValidationTest::testPostRejectionFilesystemListing() {
    const QString directory = modelDirectory();
    QVERIFY(QDir().mkpath(directory));

    const QString sizeMismatchPath = modelPath("listing-size-mismatch");
    const QByteArray sizeMismatchData("short");
    const ModelDownloadValidation sizeMismatch = validateModelDownload(
        sizeMismatchData, sizeMismatchData.size() + 1,
        sha256(QByteArray("different checksum")));
    QVERIFY(!finalizeModelDownload(sizeMismatchPath, sizeMismatchData, sizeMismatch));

    const QString checksumMismatchPath = modelPath("listing-checksum-mismatch");
    const QByteArray checksumMismatchData("same-size");
    const ModelDownloadValidation checksumMismatch = validateModelDownload(
        checksumMismatchData, checksumMismatchData.size(),
        sha256(QByteArray("other-size")));
    QVERIFY(!finalizeModelDownload(checksumMismatchPath, checksumMismatchData,
                                   checksumMismatch));

    QProcess listing;
    listing.start(QStringLiteral("ls"), {QStringLiteral("-la"), directory});
    QVERIFY(listing.waitForStarted());
    QVERIFY(listing.waitForFinished());
    QCOMPARE(listing.exitCode(), 0);
    const QString listingOutput = QString::fromLocal8Bit(listing.readAllStandardOutput());
    QVERIFY(!listingOutput.contains(QStringLiteral(".gguf")));
    QVERIFY(!listingOutput.contains(QStringLiteral(".tmp")));
    qInfo().noquote() << QStringLiteral("Post-rejection ls -la %1:\n%2")
                             .arg(directory, listingOutput);
}

void ZenzaiDownloadValidationTest::testStreamedAcceptedArtifactIsFinalized() {
    const QByteArray streamedData("verified streamed model artifact");
    const QString path = modelPath("streamed-accepted");
    writeFile(path + ".tmp", streamedData);

    const ModelDownloadValidation validation = validateStreamedModelDownload(
        streamedData.size(), streamedData.size(), sha256(streamedData),
        sha256(streamedData));

    QCOMPARE(static_cast<int>(validation),
             static_cast<int>(ModelDownloadValidation::Accepted));
    QVERIFY(finalizeStreamedModelDownload(path, validation));
    QVERIFY(QFile::exists(path));
    QCOMPARE(readFile(path), streamedData);
    QVERIFY(!QFile::exists(path + ".tmp"));
}

void ZenzaiDownloadValidationTest::testStreamedSizeMismatchPrecedesChecksum() {
    const QByteArray streamedData("truncated");
    const QString path = modelPath("streamed-size-mismatch");
    writeFile(path + ".tmp", streamedData);

    const ModelDownloadValidation validation = validateStreamedModelDownload(
        streamedData.size(), streamedData.size() + 1,
        sha256(streamedData),
        sha256(QByteArray("different body with a different checksum")));

    QCOMPARE(static_cast<int>(validation),
             static_cast<int>(ModelDownloadValidation::SizeMismatch));
    QVERIFY(!finalizeStreamedModelDownload(path, validation));
    QVERIFY(!QFile::exists(path));
    QVERIFY(!QFile::exists(path + ".tmp"));
}

void ZenzaiDownloadValidationTest::testStreamedChecksumMismatchLeavesNoArtifact() {
    const QByteArray streamedData("same-size payload");
    const QString path = modelPath("streamed-checksum-mismatch");
    writeFile(path + ".tmp", streamedData);

    const ModelDownloadValidation validation = validateStreamedModelDownload(
        streamedData.size(), streamedData.size(), sha256(streamedData),
        sha256(QByteArray("other-payload-xx")));

    // 受信本文のハッシュと期待SHAが一致しないため ChecksumMismatch になる
    QCOMPARE(static_cast<int>(validation),
             static_cast<int>(ModelDownloadValidation::ChecksumMismatch));
    QVERIFY(!finalizeStreamedModelDownload(path, validation));
    QVERIFY(!QFile::exists(path));
    QVERIFY(!QFile::exists(path + ".tmp"));
}

void ZenzaiDownloadValidationTest::testStreamedUnknownExpectedBytesUsesShaOnly() {
    const QByteArray streamedData("legacy zenz body");

    QCOMPARE(static_cast<int>(validateStreamedModelDownload(
                 streamedData.size(), 0, sha256(streamedData), sha256(streamedData))),
             static_cast<int>(ModelDownloadValidation::Accepted));
    QCOMPARE(static_cast<int>(validateStreamedModelDownload(
                 streamedData.size(), -1, sha256(streamedData), sha256(streamedData))),
             static_cast<int>(ModelDownloadValidation::Accepted));
}

void ZenzaiDownloadValidationTest::testStreamedChecksumComparisonIsCaseInsensitive() {
    const QByteArray streamedData("uppercase expected SHA256");

    QCOMPARE(static_cast<int>(validateStreamedModelDownload(
                 streamedData.size(), streamedData.size(), sha256(streamedData),
                 sha256(streamedData).toUpper())),
             static_cast<int>(ModelDownloadValidation::Accepted));
}

void ZenzaiDownloadValidationTest::testStreamedRejectionClearsTmpAndPreservesExistingModel() {
    const QString path = modelPath("streamed-preserve-existing");
    const QByteArray existingData("previously verified managed model");
    writeFile(path, existingData);
    const QByteArray rejectedData("short");
    writeFile(path + ".tmp", rejectedData);

    const ModelDownloadValidation validation = validateStreamedModelDownload(
        rejectedData.size(), rejectedData.size() + 1, sha256(rejectedData),
        sha256(QByteArray("wrong checksum")));

    QCOMPARE(static_cast<int>(validation),
             static_cast<int>(ModelDownloadValidation::SizeMismatch));
    QVERIFY(!finalizeStreamedModelDownload(path, validation));
    QCOMPARE(readFile(path), existingData);
    QVERIFY(!QFile::exists(path + ".tmp"));
}

QTEST_MAIN(ZenzaiDownloadValidationTest)
#include "zenzai_download_validation_test.moc"
