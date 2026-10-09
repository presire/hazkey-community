/**
 * @file zenzai_download_validation_test.cpp
 * @brief 管理対象Zenzaiモデルのダウンロード検証と確定処理のQt Test
 *
 * 実受信本文のサイズ、SHA256、tmp経由の確定処理を一時XDGデータディレクトリで検証する。
 * ストリーミング経路は、確定の直前に同じ記述子の実バイト列から再計算した結果で判定する。
 */

#include <QtTest/QtTest>

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QProcess>
#include <QTemporaryDir>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "zenzai_download_validation.h"

namespace {

/** @brief 検証済みディレクトリと一時ファイルの記述子を閉じるだけの保持用構造体 */
struct StreamedFile {
    int directoryFd = -1;
    int fd = -1;
    QString temporaryName;
    QString finalName;

    StreamedFile() = default;
    StreamedFile(const StreamedFile&) = delete;
    StreamedFile& operator=(const StreamedFile&) = delete;
    ~StreamedFile() {
        if (fd >= 0) {
            ::close(fd);
        }
        if (directoryFd >= 0) {
            ::close(directoryFd);
        }
    }
};

}  // namespace

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
    void testSizeLimitWithKnownExpectedBytes();
    void testSizeLimitWithUnknownExpectedBytes();
    void testFinalizeDoesNotFollowStaleTmpSymlink();
    void testStreamedFinalizeReplacesOldModelAtomically();
    void testStreamedFinalizeRejectsInPlaceRewriteOfSameInode();
    void testStreamedFinalizeRejectsSwappedRegularFile();
    void testStreamedFinalizeRejectsSwappedSymlink();
    void testStreamedFinalizeRejectsHardLinkedTemporary();
    void testStreamedFinalizeRejectsGroupWritableTemporary();
    void testStreamedFinalizeRejectsMissingDescriptor();
    void testStreamedFinalizeRejectsOversizedContent();
    void testOpenVerifiedModelDirectoryCreatesPrivateDirectory();
    void testOpenVerifiedModelDirectoryRejectsSymlink();
    void testOpenVerifiedModelDirectoryTightensLooseMode();
    void testCreatePrivateTemporaryFileIsOwnerOnlyAndReplacesSymlink();
    void testFinalizeModelDownloadRejectsUnsafeDirectory();

   private:
    QString modelDirectory() const;
    QString modelPath(const QString& key) const;
    QString sha256(const QByteArray& data) const;
    void writeFile(const QString& path, const QByteArray& data) const;
    QByteArray readFile(const QString& path) const;
    /** @brief 保存先を検証して開き、0600の一時ファイルへ本文を書き出して保持する */
    void openStream(const QString& key, const QByteArray& body, StreamedFile* stream) const;
    StreamedModelFinalization finalize(const StreamedFile& stream, qint64 expectedBytes,
                                       const QString& expectedSha256) const;

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

void ZenzaiDownloadValidationTest::openStream(const QString& key, const QByteArray& body,
                                               StreamedFile* stream) const {
    QString error;
    stream->directoryFd = openVerifiedModelDirectory(modelDirectory(), &error);
    QVERIFY2(stream->directoryFd >= 0, qPrintable(error));
    stream->finalName = key + ".gguf";
    stream->temporaryName = stream->finalName + ".tmp";
    stream->fd = createPrivateTemporaryFile(stream->directoryFd, stream->temporaryName, &error);
    QVERIFY2(stream->fd >= 0, qPrintable(error));
    QCOMPARE(::write(stream->fd, body.constData(), static_cast<size_t>(body.size())),
             static_cast<ssize_t>(body.size()));
}

StreamedModelFinalization ZenzaiDownloadValidationTest::finalize(
    const StreamedFile& stream, qint64 expectedBytes, const QString& expectedSha256) const {
    return finalizeStreamedModelDownload(stream.directoryFd, stream.temporaryName,
                                         stream.finalName, stream.fd, expectedBytes,
                                         expectedSha256);
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
    StreamedFile stream;
    openStream("streamed-accepted", streamedData, &stream);

    const StreamedModelFinalization result =
        finalize(stream, streamedData.size(), sha256(streamedData));

    QVERIFY2(result.committed, qPrintable(result.errorMessage));
    QCOMPARE(static_cast<int>(result.validation),
             static_cast<int>(ModelDownloadValidation::Accepted));
    QCOMPARE(result.diskBytes, qint64(streamedData.size()));
    QCOMPARE(result.diskSha256Hex, sha256(streamedData));
    QCOMPARE(readFile(modelPath("streamed-accepted")), streamedData);
    QVERIFY(!QFile::exists(modelPath("streamed-accepted") + ".tmp"));
}

void ZenzaiDownloadValidationTest::testStreamedSizeMismatchPrecedesChecksum() {
    const QByteArray streamedData("truncated");
    StreamedFile stream;
    openStream("streamed-size-mismatch", streamedData, &stream);

    const StreamedModelFinalization result = finalize(
        stream, streamedData.size() + 1,
        sha256(QByteArray("different body with a different checksum")));

    QVERIFY(!result.committed);
    QCOMPARE(static_cast<int>(result.validation),
             static_cast<int>(ModelDownloadValidation::SizeMismatch));
    QVERIFY(!QFile::exists(modelPath("streamed-size-mismatch")));
    QVERIFY(!QFile::exists(modelPath("streamed-size-mismatch") + ".tmp"));
}

void ZenzaiDownloadValidationTest::testStreamedChecksumMismatchLeavesNoArtifact() {
    const QByteArray streamedData("same-size payload");
    StreamedFile stream;
    openStream("streamed-checksum-mismatch", streamedData, &stream);

    const StreamedModelFinalization result = finalize(
        stream, streamedData.size(), sha256(QByteArray("other-payload-xx")));

    QVERIFY(!result.committed);
    QCOMPARE(static_cast<int>(result.validation),
             static_cast<int>(ModelDownloadValidation::ChecksumMismatch));
    QCOMPARE(result.diskSha256Hex, sha256(streamedData));
    QVERIFY(!QFile::exists(modelPath("streamed-checksum-mismatch")));
    QVERIFY(!QFile::exists(modelPath("streamed-checksum-mismatch") + ".tmp"));
}

void ZenzaiDownloadValidationTest::testStreamedUnknownExpectedBytesUsesShaOnly() {
    const QByteArray streamedData("legacy zenz body");

    QCOMPARE(static_cast<int>(validateStreamedModelDownload(
                 streamedData.size(), 0, sha256(streamedData), sha256(streamedData))),
             static_cast<int>(ModelDownloadValidation::Accepted));
    QCOMPARE(static_cast<int>(validateStreamedModelDownload(
                 streamedData.size(), -1, sha256(streamedData), sha256(streamedData))),
             static_cast<int>(ModelDownloadValidation::Accepted));

    // 期待サイズ不明でも、記述子から再計算したSHA256で受入できる
    StreamedFile stream;
    openStream("streamed-unknown-size", streamedData, &stream);
    const StreamedModelFinalization result = finalize(stream, 0, sha256(streamedData));
    QVERIFY2(result.committed, qPrintable(result.errorMessage));
    QCOMPARE(readFile(modelPath("streamed-unknown-size")), streamedData);
}

void ZenzaiDownloadValidationTest::testStreamedChecksumComparisonIsCaseInsensitive() {
    const QByteArray streamedData("uppercase expected SHA256");

    QCOMPARE(static_cast<int>(validateStreamedModelDownload(
                 streamedData.size(), streamedData.size(), sha256(streamedData),
                 sha256(streamedData).toUpper())),
             static_cast<int>(ModelDownloadValidation::Accepted));

    StreamedFile stream;
    openStream("streamed-uppercase", streamedData, &stream);
    const StreamedModelFinalization result =
        finalize(stream, streamedData.size(), sha256(streamedData).toUpper());
    QVERIFY2(result.committed, qPrintable(result.errorMessage));
}

void ZenzaiDownloadValidationTest::testStreamedRejectionClearsTmpAndPreservesExistingModel() {
    const QString path = modelPath("streamed-preserve-existing");
    const QByteArray existingData("previously verified managed model");
    writeFile(path, existingData);
    const QByteArray rejectedData("short");

    StreamedFile stream;
    openStream("streamed-preserve-existing", rejectedData, &stream);
    const StreamedModelFinalization result = finalize(
        stream, rejectedData.size() + 1, sha256(QByteArray("wrong checksum")));

    QVERIFY(!result.committed);
    QCOMPARE(static_cast<int>(result.validation),
             static_cast<int>(ModelDownloadValidation::SizeMismatch));
    QCOMPARE(readFile(path), existingData);
    QVERIFY(!QFile::exists(path + ".tmp"));
}

void ZenzaiDownloadValidationTest::testSizeLimitWithKnownExpectedBytes() {
    const qint64 expected = 1000;
    QVERIFY(!downloadExceedsSizeLimit(0, -1, expected));
    QVERIFY(!downloadExceedsSizeLimit(expected, expected, expected));
    QVERIFY(downloadExceedsSizeLimit(expected + 1, -1, expected));
    QVERIFY(downloadExceedsSizeLimit(10, expected + 1, expected));
    QVERIFY(!downloadExceedsSizeLimit(10, 0, expected));
}

void ZenzaiDownloadValidationTest::testSizeLimitWithUnknownExpectedBytes() {
    const qint64 limit = kUnknownSizeModelDownloadLimitBytes;
    // 配布中の最大モデル (jinen-v2-small f16, 219865856バイト) を余裕を持って受け入れ、4 GiB未満に抑える
    QCOMPARE(limit, Q_INT64_C(1) << 30);
    QVERIFY(limit > Q_INT64_C(219865856) * 4);
    QVERIFY(!downloadExceedsSizeLimit(Q_INT64_C(219865856), Q_INT64_C(219865856), 0));
    QVERIFY(downloadExceedsSizeLimit(Q_INT64_C(2) << 30, -1, 0));
    for (const qint64 expected : {qint64(0), qint64(-1)}) {
        QVERIFY(!downloadExceedsSizeLimit(limit, limit, expected));
        QVERIFY(downloadExceedsSizeLimit(limit + 1, -1, expected));
        QVERIFY(downloadExceedsSizeLimit(0, limit + 1, expected));
    }
}

void ZenzaiDownloadValidationTest::testFinalizeDoesNotFollowStaleTmpSymlink() {
    const QString path = modelPath("symlinked-tmp");
    const QString victim = tempDir_.path() + "/victim.txt";
    const QByteArray victimData("must stay untouched");
    writeFile(victim, victimData);
    QVERIFY(QDir().mkpath(modelDirectory()));
    QVERIFY(QFile::link(victim, path + ".tmp"));

    const QByteArray body("verified");
    const ModelDownloadValidation validation = validateModelDownload(
        body, body.size(), sha256(body));
    QVERIFY(finalizeModelDownload(path, body, validation));
    QCOMPARE(readFile(path), body);
    QCOMPARE(readFile(victim), victimData);
    QVERIFY(!QFileInfo(path).isSymLink());
}

void ZenzaiDownloadValidationTest::testStreamedFinalizeReplacesOldModelAtomically() {
    const QString path = modelPath("streamed-replace");
    const QByteArray oldData("previously verified managed model");
    const QByteArray newData("new verified streamed body");
    writeFile(path, oldData);
    QCOMPARE(readFile(path), oldData);

    StreamedFile stream;
    openStream("streamed-replace", newData, &stream);
    // 確定前は旧モデルがそのまま残る (先に削除しない)
    QCOMPARE(readFile(path), oldData);

    const StreamedModelFinalization result =
        finalize(stream, newData.size(), sha256(newData));
    QVERIFY2(result.committed, qPrintable(result.errorMessage));
    QCOMPARE(readFile(path), newData);
    QVERIFY(!QFile::exists(path + ".tmp"));

    struct stat info {};
    QVERIFY(::stat(QFile::encodeName(path).constData(), &info) == 0);
    QCOMPARE(static_cast<int>(info.st_mode & 0777), 0600);
}

void ZenzaiDownloadValidationTest::testStreamedFinalizeRejectsInPlaceRewriteOfSameInode() {
    const QString path = modelPath("streamed-inplace");
    const QByteArray existingData("previously verified managed model");
    const QByteArray receivedBody("body as received from the network");
    const QByteArray rewrittenBody("body rewritten in place by someone!");
    writeFile(path, existingData);

    StreamedFile stream;
    openStream("streamed-inplace", receivedBody, &stream);

    // 受信した本文のSHA256を期待値として、同じinodeの内容を別の記述子から書き換える
    const QString temporaryPath = path + ".tmp";
    const int rewriter = ::open(QFile::encodeName(temporaryPath).constData(),
                                O_WRONLY | O_TRUNC | O_CLOEXEC);
    QVERIFY(rewriter >= 0);
    QCOMPARE(::write(rewriter, rewrittenBody.constData(),
                     static_cast<size_t>(rewrittenBody.size())),
             static_cast<ssize_t>(rewrittenBody.size()));
    ::close(rewriter);

    const StreamedModelFinalization result =
        finalize(stream, rewrittenBody.size(), sha256(receivedBody));

    // dev/ino/uid/nlinkは同じでも、ディスク上の内容から再計算したSHA256で拒否される
    QVERIFY(!result.committed);
    QCOMPARE(static_cast<int>(result.validation),
             static_cast<int>(ModelDownloadValidation::ChecksumMismatch));
    QCOMPARE(result.diskSha256Hex, sha256(rewrittenBody));
    QCOMPARE(readFile(path), existingData);
    QVERIFY(!QFile::exists(temporaryPath));
}

void ZenzaiDownloadValidationTest::testStreamedFinalizeRejectsSwappedRegularFile() {
    const QString path = modelPath("streamed-swapped");
    const QString temporaryPath = path + ".tmp";
    const QByteArray existingData("previously verified managed model");
    const QByteArray swappedData("attacker supplied content");
    const QByteArray body("verified streamed body");
    writeFile(path, existingData);

    StreamedFile stream;
    openStream("streamed-swapped", body, &stream);

    QVERIFY(QFile::rename(temporaryPath, temporaryPath + ".moved"));
    writeFile(temporaryPath, swappedData);

    const StreamedModelFinalization result = finalize(stream, body.size(), sha256(body));
    QVERIFY(!result.committed);
    QVERIFY(!result.errorMessage.isEmpty());
    QCOMPARE(readFile(path), existingData);
    QCOMPARE(readFile(temporaryPath), swappedData);
}

void ZenzaiDownloadValidationTest::testStreamedFinalizeRejectsSwappedSymlink() {
    const QString path = modelPath("streamed-symlink-swap");
    const QString temporaryPath = path + ".tmp";
    const QString victim = tempDir_.path() + "/victim-swap.txt";
    const QByteArray victimData("must stay untouched");
    const QByteArray existingData("previously verified managed model");
    const QByteArray body("verified streamed body");
    writeFile(victim, victimData);
    writeFile(path, existingData);

    StreamedFile stream;
    openStream("streamed-symlink-swap", body, &stream);

    QVERIFY(QFile::remove(temporaryPath));
    QVERIFY(QFile::link(victim, temporaryPath));

    const StreamedModelFinalization result = finalize(stream, body.size(), sha256(body));
    QVERIFY(!result.committed);
    QCOMPARE(readFile(path), existingData);
    QCOMPARE(readFile(victim), victimData);
    QVERIFY(QFileInfo(temporaryPath).isSymLink());
}

void ZenzaiDownloadValidationTest::testStreamedFinalizeRejectsHardLinkedTemporary() {
    const QString path = modelPath("streamed-hardlink");
    const QString temporaryPath = path + ".tmp";
    const QString alias = tempDir_.path() + "/alias-of-tmp";
    const QByteArray existingData("previously verified managed model");
    const QByteArray body("verified streamed body");
    writeFile(path, existingData);

    StreamedFile stream;
    openStream("streamed-hardlink", body, &stream);
    QVERIFY(::link(QFile::encodeName(temporaryPath).constData(),
                   QFile::encodeName(alias).constData()) == 0);

    const StreamedModelFinalization result = finalize(stream, body.size(), sha256(body));
    QVERIFY(!result.committed);
    QVERIFY(!result.errorMessage.isEmpty());
    QCOMPARE(readFile(path), existingData);
}

void ZenzaiDownloadValidationTest::testStreamedFinalizeRejectsGroupWritableTemporary() {
    const QString path = modelPath("streamed-mode");
    const QByteArray existingData("previously verified managed model");
    const QByteArray body("verified streamed body");
    writeFile(path, existingData);

    StreamedFile stream;
    openStream("streamed-mode", body, &stream);
    QVERIFY(::fchmod(stream.fd, 0666) == 0);

    const StreamedModelFinalization result = finalize(stream, body.size(), sha256(body));
    QVERIFY(!result.committed);
    QVERIFY(!result.errorMessage.isEmpty());
    QCOMPARE(readFile(path), existingData);
}

void ZenzaiDownloadValidationTest::testStreamedFinalizeRejectsMissingDescriptor() {
    const QString path = modelPath("streamed-no-fd");
    const QString victim = tempDir_.path() + "/victim-fallback.txt";
    const QByteArray victimData("must stay untouched");
    const QByteArray existingData("previously verified managed model");
    const QByteArray body("verified streamed body");
    writeFile(victim, victimData);
    writeFile(path, existingData);
    QVERIFY(QFile::link(victim, path + ".tmp"));

    QString error;
    const int directoryFd = openVerifiedModelDirectory(modelDirectory(), &error);
    QVERIFY2(directoryFd >= 0, qPrintable(error));

    // 記述子が無い場合、パスを開き直して検証済みとみなす経路は存在しない
    const StreamedModelFinalization result = finalizeStreamedModelDownload(
        directoryFd, QStringLiteral("streamed-no-fd.gguf.tmp"),
        QStringLiteral("streamed-no-fd.gguf"), -1, body.size(), sha256(body));
    ::close(directoryFd);

    QVERIFY(!result.committed);
    QVERIFY(!result.errorMessage.isEmpty());
    QCOMPARE(readFile(path), existingData);
    QCOMPARE(readFile(victim), victimData);
    QVERIFY(QFileInfo(path + ".tmp").isSymLink());
}

void ZenzaiDownloadValidationTest::testStreamedFinalizeRejectsOversizedContent() {
    const QByteArray body("0123456789");
    StreamedFile stream;
    openStream("streamed-oversize", body, &stream);

    // 期待サイズより大きい内容は、読み切る前に上限で打ち切って拒否する
    const StreamedModelFinalization result = finalize(stream, 4, sha256(body));
    QVERIFY(!result.committed);
    QCOMPARE(static_cast<int>(result.validation),
             static_cast<int>(ModelDownloadValidation::SizeMismatch));
    QVERIFY(!QFile::exists(modelPath("streamed-oversize")));
    QVERIFY(!QFile::exists(modelPath("streamed-oversize") + ".tmp"));
}

void ZenzaiDownloadValidationTest::testOpenVerifiedModelDirectoryCreatesPrivateDirectory() {
    const QString directory = tempDir_.path() + "/fresh/models";
    QString error;
    const int fd = openVerifiedModelDirectory(directory, &error);
    QVERIFY2(fd >= 0, qPrintable(error));
    ::close(fd);

    struct stat info {};
    QVERIFY(::stat(QFile::encodeName(directory).constData(), &info) == 0);
    QVERIFY(S_ISDIR(info.st_mode));
    QCOMPARE(static_cast<int>(info.st_mode & 0777), 0700);
}

void ZenzaiDownloadValidationTest::testOpenVerifiedModelDirectoryRejectsSymlink() {
    const QString realDirectory = tempDir_.path() + "/real-models";
    const QString linkedDirectory = tempDir_.path() + "/linked-models";
    QVERIFY(QDir().mkpath(realDirectory));
    QVERIFY(::chmod(QFile::encodeName(realDirectory).constData(), 0700) == 0);
    QVERIFY(QFile::link(realDirectory, linkedDirectory));

    QString error;
    QCOMPARE(openVerifiedModelDirectory(linkedDirectory, &error), -1);
    QVERIFY(!error.isEmpty());
}

void ZenzaiDownloadValidationTest::testOpenVerifiedModelDirectoryTightensLooseMode() {
    // umask 002 などで作られた group/other 書込可のディレクトリは、拒否せず書込権限だけを外す
    for (const mode_t mode : {mode_t(0775), mode_t(0757), mode_t(0777)}) {
        const QString directory =
            tempDir_.path() + QStringLiteral("/mode-%1").arg(int(mode), 0, 8);
        QVERIFY(QDir().mkpath(directory));
        QVERIFY(::chmod(QFile::encodeName(directory).constData(), mode) == 0);

        QString error;
        const int fd = openVerifiedModelDirectory(directory, &error);
        QVERIFY2(fd >= 0, qPrintable(error));
        struct stat info {};
        QVERIFY(::fstat(fd, &info) == 0);
        ::close(fd);
        QCOMPARE(info.st_mode & (S_IWGRP | S_IWOTH), mode_t(0));
        QCOMPARE(info.st_mode & 0777, mode & 0755);
    }

    // group/otherに書込権限がなければ、読取・実行権限があっても受け入れる
    const QString readable = tempDir_.path() + "/mode-readable";
    QVERIFY(QDir().mkpath(readable));
    QVERIFY(::chmod(QFile::encodeName(readable).constData(), 0755) == 0);
    QString error;
    const int fd = openVerifiedModelDirectory(readable, &error);
    QVERIFY2(fd >= 0, qPrintable(error));
    ::close(fd);
}

void ZenzaiDownloadValidationTest::testCreatePrivateTemporaryFileIsOwnerOnlyAndReplacesSymlink() {
    const QString victim = tempDir_.path() + "/victim-create.txt";
    const QByteArray victimData("must stay untouched");
    writeFile(victim, victimData);
    QVERIFY(QDir().mkpath(modelDirectory()));
    QVERIFY(QFile::link(victim, modelDirectory() + "/create.gguf.tmp"));

    QString error;
    const int directoryFd = openVerifiedModelDirectory(modelDirectory(), &error);
    QVERIFY2(directoryFd >= 0, qPrintable(error));
    const int fd = createPrivateTemporaryFile(directoryFd, QStringLiteral("create.gguf.tmp"), &error);
    QVERIFY2(fd >= 0, qPrintable(error));

    struct stat info {};
    QVERIFY(::fstat(fd, &info) == 0);
    QVERIFY(S_ISREG(info.st_mode));
    QCOMPARE(static_cast<int>(info.st_mode & 0777), 0600);
    QCOMPARE(readFile(victim), victimData);
    QVERIFY(!QFileInfo(modelDirectory() + "/create.gguf.tmp").isSymLink());

    // ディレクトリ区切りや親参照を含む名前は受け付けない
    QCOMPARE(createPrivateTemporaryFile(directoryFd, QStringLiteral("../escape.tmp"), &error), -1);
    QCOMPARE(createPrivateTemporaryFile(directoryFd, QStringLiteral(".."), &error), -1);
    ::close(fd);
    ::close(directoryFd);
}

void ZenzaiDownloadValidationTest::testFinalizeModelDownloadRejectsUnsafeDirectory() {
    const QString realDirectory = tempDir_.path() + "/real-target";
    const QString linkedDirectory = tempDir_.path() + "/linked-target";
    QVERIFY(QDir().mkpath(realDirectory));
    QVERIFY(::chmod(QFile::encodeName(realDirectory).constData(), 0700) == 0);
    QVERIFY(QFile::link(realDirectory, linkedDirectory));

    const QByteArray body("verified");
    QString error;
    QVERIFY(!finalizeModelDownload(linkedDirectory + "/linked.gguf", body,
                                   validateModelDownload(body, body.size(), sha256(body)),
                                   &error));
    QVERIFY(!error.isEmpty());
    QVERIFY(!QFile::exists(realDirectory + "/linked.gguf"));

    // 書込権限の緩いディレクトリは、権限を外した上で保存する
    const QString looseDirectory = tempDir_.path() + "/loose-target";
    QVERIFY(QDir().mkpath(looseDirectory));
    QVERIFY(::chmod(QFile::encodeName(looseDirectory).constData(), 0777) == 0);
    QVERIFY2(finalizeModelDownload(looseDirectory + "/loose.gguf", body,
                                   validateModelDownload(body, body.size(), sha256(body)),
                                   &error),
             qPrintable(error));
    QCOMPARE(readFile(looseDirectory + "/loose.gguf"), body);
    QCOMPARE(QFileInfo(looseDirectory).permissions() &
                 (QFileDevice::WriteGroup | QFileDevice::WriteOther),
             QFileDevice::Permissions());
}

QTEST_MAIN(ZenzaiDownloadValidationTest)
#include "zenzai_download_validation_test.moc"
