#include <QtTest/QtTest>

#include <QDialogButtonBox>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QLabel>
#include <QLineEdit>
#include <QLocalSocket>
#include <QMessageBox>
#include <QProcess>
#include <QProcessEnvironment>
#include <QPushButton>
#include <QTableWidget>
#include <QTemporaryDir>
#include <QTimer>

#include <QtEndian>

#include <optional>

#include <unistd.h>

#include "learninghistorydialog.h"

namespace {

class ProtocolClient {
   public:
    explicit ProtocolClient(QString socketPath) : socketPath_(std::move(socketPath)) {}

    std::optional<hazkey::ResponseEnvelope> transact(
        const hazkey::RequestEnvelope& request) const {
        std::string serialized;
        if (!request.SerializeToString(&serialized)) return std::nullopt;

        QLocalSocket socket;
        socket.connectToServer(socketPath_);
        if (!socket.waitForConnected(5000)) return std::nullopt;

        const quint32 size = qToBigEndian<quint32>(serialized.size());
        if (socket.write(reinterpret_cast<const char*>(&size), sizeof(size)) !=
                sizeof(size) ||
            socket.write(serialized.data(), serialized.size()) !=
                static_cast<qint64>(serialized.size()) ||
            !socket.waitForBytesWritten(5000)) {
            return std::nullopt;
        }

        if (!waitForBytes(socket, sizeof(quint32))) return std::nullopt;
        const QByteArray prefix = socket.read(sizeof(quint32));
        const quint32 responseSize = qFromBigEndian<quint32>(
            reinterpret_cast<const uchar*>(prefix.constData()));
        if (!waitForBytes(socket, responseSize)) return std::nullopt;
        const QByteArray response = socket.read(responseSize);
        hazkey::ResponseEnvelope envelope;
        if (!envelope.ParseFromArray(response.constData(), response.size())) {
            return std::nullopt;
        }
        return envelope;
    }

   private:
    static bool waitForBytes(QLocalSocket& socket, qint64 size) {
        QElapsedTimer timer;
        timer.start();
        while (socket.bytesAvailable() < size) {
            const int remaining = 5000 - static_cast<int>(timer.elapsed());
            if (remaining <= 0 || !socket.waitForReadyRead(remaining)) return false;
        }
        return true;
    }

    QString socketPath_;
};

}  // namespace

class LearningHistoryDialogTest : public QObject {
    Q_OBJECT

   private slots:
    void initTestCase();
    void cleanupTestCase();
    void testSelectiveDeleteAndDisconnectedFailure();

   private:
    void setIsolatedEnvironment();
    bool startIsolatedServer();
    void stopIsolatedServer();
    bool seedEntry(const QString& input);
    QString socketPath() const;
    void dismissMessageBoxes(int count);

    QTemporaryDir temporaryDirectory_;
    QProcess serverProcess_;
    ServerConnector connector_;
    QByteArray originalPath_;
    QByteArray originalRuntimeDirectory_;
    QByteArray originalStateDirectory_;
    QByteArray originalDataDirectory_;
    QByteArray originalConfigDirectory_;
    QByteArray originalDictionary_;
    QByteArray originalLlamaLibraryPath_;
    int dismissedMessageBoxes_ = 0;
};

void LearningHistoryDialogTest::setIsolatedEnvironment() {
    const QString root = temporaryDirectory_.path();
    for (const QString& name : {"runtime", "state", "data", "config", "bin"}) {
        QVERIFY(QDir().mkpath(root + "/" + name));
    }

    originalPath_ = qgetenv("PATH");
    originalRuntimeDirectory_ = qgetenv("XDG_RUNTIME_DIR");
    originalStateDirectory_ = qgetenv("XDG_STATE_HOME");
    originalDataDirectory_ = qgetenv("XDG_DATA_HOME");
    originalConfigDirectory_ = qgetenv("XDG_CONFIG_HOME");
    originalDictionary_ = qgetenv("HAZKEY_DICTIONARY");
    originalLlamaLibraryPath_ = qgetenv("LD_LIBRARY_PATH");
    qputenv("PATH", (root + "/bin").toUtf8());
    qputenv("XDG_RUNTIME_DIR", (root + "/runtime").toUtf8());
    qputenv("XDG_STATE_HOME", (root + "/state").toUtf8());
    qputenv("XDG_DATA_HOME", (root + "/data").toUtf8());
    qputenv("XDG_CONFIG_HOME", (root + "/config").toUtf8());
    qputenv("HAZKEY_DICTIONARY",
            (QStringLiteral(HAZKEY_SOURCE_DIR) +
             "/hazkey-server/azooKey_dictionary_storage/Dictionary")
                .toUtf8());
    qputenv("LD_LIBRARY_PATH",
            (QStringLiteral(HAZKEY_LLAMA_LIBRARY_DIR) + ":" +
             QString::fromUtf8(originalLlamaLibraryPath_))
                .toUtf8());

    QFile fallbackServer(root + "/bin/hazkey-server");
    QVERIFY(fallbackServer.open(QIODevice::WriteOnly | QIODevice::Truncate));
    fallbackServer.write("#!/bin/sh\nexit 0\n");
    fallbackServer.close();
    QVERIFY(fallbackServer.setPermissions(
        QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
}

QString LearningHistoryDialogTest::socketPath() const {
    return temporaryDirectory_.path() + "/runtime/hazkey-server." +
           QString::number(::getuid()) + ".sock";
}

bool LearningHistoryDialogTest::startIsolatedServer() {
    serverProcess_.setProgram(QStringLiteral(HAZKEY_SERVER_BINARY));
    serverProcess_.setProcessEnvironment(QProcessEnvironment::systemEnvironment());
    serverProcess_.start();
    if (!serverProcess_.waitForStarted(5000)) return false;

    QElapsedTimer timer;
    timer.start();
    while (!QFile::exists(socketPath()) && timer.elapsed() < 30000) {
        QTest::qWait(50);
    }
    return QFile::exists(socketPath());
}

void LearningHistoryDialogTest::stopIsolatedServer() {
    if (serverProcess_.state() == QProcess::NotRunning) return;
    serverProcess_.terminate();
    if (!serverProcess_.waitForFinished(5000)) {
        serverProcess_.kill();
        serverProcess_.waitForFinished(5000);
    }
}

bool LearningHistoryDialogTest::seedEntry(const QString& input) {
    ProtocolClient client(socketPath());
    hazkey::RequestEnvelope request;
    request.mutable_new_composing_text();
    const auto started = client.transact(request);
    if (!started || started->status() != hazkey::SUCCESS) return false;

    for (const QChar character : input) {
        request.Clear();
        request.mutable_input_char()->set_text(QString(character).toStdString());
        const auto entered = client.transact(request);
        if (!entered || entered->status() != hazkey::SUCCESS) return false;
    }

    request.Clear();
    request.mutable_get_candidates()->set_is_suggest(false);
    const auto candidates = client.transact(request);
    if (!candidates || candidates->status() != hazkey::SUCCESS ||
        !candidates->has_candidates() || candidates->candidates().candidates_size() == 0) {
        return false;
    }
    const int index = candidates->candidates().live_text_index() >= 0
                          ? candidates->candidates().live_text_index()
                          : 0;
    request.Clear();
    request.mutable_prefix_complete()->set_index(index);
    const auto completed = client.transact(request);
    if (!completed || completed->status() != hazkey::SUCCESS) return false;

    request.Clear();
    request.mutable_save_learning_data();
    const auto saved = client.transact(request);
    return saved && saved->status() == hazkey::SUCCESS;
}

void LearningHistoryDialogTest::dismissMessageBoxes(int count) {
    dismissedMessageBoxes_ = 0;
    auto* timer = new QTimer(this);
    auto* remaining = new int(count);
    connect(timer, &QTimer::timeout, this, [this, timer, remaining]() {
        auto* box = qobject_cast<QMessageBox*>(QApplication::activeModalWidget());
        if (!box) return;
        auto* button = box->button(
            box->standardButtons().testFlag(QMessageBox::Yes) ? QMessageBox::Yes
                                                               : QMessageBox::Ok);
        if (!button) return;
        button->click();
        ++dismissedMessageBoxes_;
        if (--*remaining == 0) {
            timer->stop();
            timer->deleteLater();
            delete remaining;
        }
    });
    timer->start(1);
}

void LearningHistoryDialogTest::initTestCase() {
    QVERIFY2(temporaryDirectory_.isValid(), "temporary XDG root must exist");
    setIsolatedEnvironment();
    QVERIFY2(startIsolatedServer(), "isolated server did not create its socket within 30 seconds");

    auto config = connector_.getConfig();
    QVERIFY(config.has_value());
    auto* profile = config->mutable_profiles(0);
    profile->set_profile_id("isolated-profile");
    profile->set_use_profile_independent_history(true);
    connector_.setCurrentConfig(*config);

    QVERIFY2(seedEntry(QStringLiteral("ai")), "first learning entry must seed");
    QVERIFY2(seedEntry(QStringLiteral("ue")), "second learning entry must seed");
    const auto history = connector_.getLearningHistory("isolated-profile", "", 0, 200);
    QVERIFY(history.has_value());
    QVERIFY(history->entries_size() >= 2);
}

void LearningHistoryDialogTest::cleanupTestCase() {
    stopIsolatedServer();
    qputenv("PATH", originalPath_);
    qputenv("XDG_RUNTIME_DIR", originalRuntimeDirectory_);
    qputenv("XDG_STATE_HOME", originalStateDirectory_);
    qputenv("XDG_DATA_HOME", originalDataDirectory_);
    qputenv("XDG_CONFIG_HOME", originalConfigDirectory_);
    qputenv("HAZKEY_DICTIONARY", originalDictionary_);
    qputenv("LD_LIBRARY_PATH", originalLlamaLibraryPath_);
}

void LearningHistoryDialogTest::testSelectiveDeleteAndDisconnectedFailure() {
    LearningHistoryDialog dialog(
        &connector_, {"isolated-profile", true});
    dialog.show();

    auto* modeLabel = dialog.findChild<QLabel*>("learningHistoryModeLabel");
    auto* searchEdit = dialog.findChild<QLineEdit*>("learningHistorySearchEdit");
    auto* searchButton = dialog.findChild<QPushButton*>("learningHistorySearchButton");
    auto* table = dialog.findChild<QTableWidget*>("learningHistoryTable");
    auto* deleteButton = dialog.findChild<QPushButton*>("learningHistoryDeleteButton");
    QVERIFY(modeLabel && modeLabel->text().contains(QStringLiteral("分離モード")));
    QVERIFY(searchEdit && searchButton && table && deleteButton);
    QVERIFY(table->rowCount() >= 2);

    const auto unfiltered =
        connector_.getLearningHistory("isolated-profile", "", 0, 200);
    QVERIFY(unfiltered.has_value());
    QString searchTerm;
    int expectedRows = unfiltered->entries_size();
    for (const auto& entry : unfiltered->entries()) {
        for (const QString& value : {QString::fromStdString(entry.reading()),
                                     QString::fromStdString(entry.word())}) {
            for (const QChar character : value) {
                int matches = 0;
                for (const auto& candidate : unfiltered->entries()) {
                    if (QString::fromStdString(candidate.reading()).contains(character) ||
                        QString::fromStdString(candidate.word()).contains(character)) {
                        ++matches;
                    }
                }
                if (matches < expectedRows) {
                    searchTerm = character;
                    expectedRows = matches;
                }
            }
        }
    }
    QVERIFY(!searchTerm.isEmpty());
    QVERIFY(expectedRows < unfiltered->entries_size());
    searchEdit->setText(searchTerm);
    searchEdit->setFocus();
    QTest::keyClick(searchEdit, Qt::Key_Return);
    QTRY_COMPARE(table->rowCount(), expectedRows);

    table->item(0, 0)->setCheckState(Qt::Checked);
    dismissMessageBoxes(2);
    QTest::mouseClick(deleteButton, Qt::LeftButton);
    QTRY_COMPARE(table->rowCount(), expectedRows - 1);
    QTRY_COMPARE(dismissedMessageBoxes_, 2);

    stopIsolatedServer();
    dismissMessageBoxes(1);
    QTest::mouseClick(searchButton, Qt::LeftButton);
    QTRY_COMPARE(dismissedMessageBoxes_, 1);
    QTRY_VERIFY(dialog.isVisible());
}

QTEST_MAIN(LearningHistoryDialogTest)
#include "learninghistorydialog_test.moc"
