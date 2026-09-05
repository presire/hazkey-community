#include <QtTest/QtTest>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIODevice>
#include <QStringList>
#include <QTemporaryDir>

#ifdef Q_OS_UNIX
#include <sys/types.h>
#include <unistd.h>
#endif

#include "userdict_model.h"

namespace {

QByteArray readFileBytes(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return QByteArray();
    return file.readAll();
}

// Removes the write permission of a directory for the guarded scope and
// always restores it on destruction, so cleanup (QTemporaryDir) works even
// when the test returns early (QSKIP / failing QVERIFY).
class ReadOnlyDirGuard {
   public:
    explicit ReadOnlyDirGuard(const QString& dir) : dir_(dir) {
        QFile file(dir);
        active_ = file.setPermissions(
            QFile::Permissions(QFile::ReadOwner | QFile::ExeOwner));
    }
    ~ReadOnlyDirGuard() {
        if (active_) {
            QFile(dir_).setPermissions(QFile::Permissions(
                QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
        }
    }
    bool isActive() const { return active_; }

   private:
    QString dir_;
    bool active_ = false;
};

}  // namespace

class UserDictModelTest : public QObject {
    Q_OBJECT

private slots:
    void testExactOutput();
    void testReplacesExistingLongerFile();
    void testFailureRetainsExistingFile();

private:
    QTemporaryDir tempDir_;
};

void UserDictModelTest::testExactOutput() {
    QVector<UserDictEntry> entries;
    entries.append({QStringLiteral("にほん"), QStringLiteral("日本"),
                    QStringLiteral("にっぽん"), QStringLiteral("noun")});
    entries.append({QStringLiteral("さとう"), QStringLiteral("佐藤"),
                    QString(), QStringLiteral("noun")});
    entries.append({QStringLiteral("ひらがな"), QStringLiteral("平仮名"),
                    QStringLiteral("comment"), QString()});
    entries.append({QStringLiteral("しずおか"), QStringLiteral("静岡"),
                    QStringLiteral("しゅう"), QStringLiteral("place")});
    entries.append({QStringLiteral("えいご"), QStringLiteral("英語"),
                    QString(), QStringLiteral("person")});
    entries.append({QStringLiteral("かんがえる"), QStringLiteral("考える"),
                    QStringLiteral("じてん"), QStringLiteral("verb")});

    const QString path = tempDir_.path() + "/exact.tsv";
    QVERIFY2(writeUserDictionaryFile(path, entries), "helper must succeed");

    // Canonical bytes derived by hand from the format spec, not by calling
    // the helper: header line, entry order, noun/empty-pos comment column
    // omitted when empty, non-noun always keeps the fourth POS column, one
    // trailing newline per row, UTF-8, LF line endings.
    const QString expected =
        QStringLiteral("# reading<TAB>word<TAB>comment[<TAB>pos]\n"
                       "にほん\t日本\tにっぽん\n"
                       "さとう\t佐藤\n"
                       "ひらがな\t平仮名\tcomment\n"
                       "しずおか\t静岡\tしゅう\tplace\n"
                       "えいご\t英語\t\tperson\n"
                       "かんがえる\t考える\tじてん\tverb\n");
    QCOMPARE(readFileBytes(path), expected.toUtf8());

    // A committed QSaveFile leaves no temporary files behind.
    QCOMPARE(QDir(tempDir_.path()).entryList(QDir::Files),
             QStringList{QStringLiteral("exact.tsv")});

    // An empty dictionary writes the header line only.
    const QString emptyPath = tempDir_.path() + "/empty.tsv";
    QVERIFY2(writeUserDictionaryFile(emptyPath, {}),
             "empty dictionary write must succeed");
    QCOMPARE(readFileBytes(emptyPath),
             QByteArray("# reading<TAB>word<TAB>comment[<TAB>pos]\n"));
}

void UserDictModelTest::testReplacesExistingLongerFile() {
    const QString path = tempDir_.path() + "/replace.tsv";
    {
        QFile file(path);
        QVERIFY2(file.open(QIODevice::WriteOnly), "seed a longer file");
        file.write(QByteArray(4096, 'x'));
    }
    QCOMPARE(QFileInfo(path).size(), qint64(4096));

    QVector<UserDictEntry> entries;
    entries.append({QStringLiteral("さいご"), QStringLiteral("最後"),
                    QString(), QStringLiteral("noun")});
    QVERIFY2(writeUserDictionaryFile(path, entries), "helper must succeed");

    const QString expected =
        QStringLiteral("# reading<TAB>word<TAB>comment[<TAB>pos]\n"
                       "さいご\t最後\n");
    const QByteArray actual = readFileBytes(path);
    QCOMPARE(actual, expected.toUtf8());
    QVERIFY2(actual.size() < 4096,
             "old, longer content must be fully replaced, not truncated");
}

void UserDictModelTest::testFailureRetainsExistingFile() {
#ifdef Q_OS_UNIX
    if (::geteuid() == 0) {
        QSKIP("Running as root: directory write permissions are not "
              "enforced.");
    }
    const QString dir = tempDir_.path() + "/readonly";
    QVERIFY2(QDir().mkpath(dir), "create target directory");
    const QString path = dir + "/user_dictionary.tsv";
    const QByteArray original("# reading<TAB>word<TAB>comment[<TAB>pos]\n"
                              "きぞん\t既存\n");
    {
        QFile file(path);
        QVERIFY2(file.open(QIODevice::WriteOnly), "seed pre-existing file");
        file.write(original);
    }

    ReadOnlyDirGuard guard(dir);
    if (!guard.isActive() || QFileInfo(dir).isWritable()) {
        QSKIP("Platform or filesystem does not honor directory write "
              "permissions.");
    }

    QVector<UserDictEntry> entries;
    entries.append({QStringLiteral("あたら"), QStringLiteral("新"),
                    QString(), QStringLiteral("noun")});
    QVERIFY2(!writeUserDictionaryFile(path, entries),
             "write into a read-only directory must fail");

    // The pre-existing file must survive byte-for-byte with no temporary
    // leftovers (direct-write fallback is disabled).
    QCOMPARE(readFileBytes(path), original);
    QCOMPARE(QDir(dir).entryList(QDir::Files),
             QStringList{QStringLiteral("user_dictionary.tsv")});
#else
    QSKIP("Directory permission manipulation is only implemented for Unix.");
#endif
}

QTEST_MAIN(UserDictModelTest)
#include "userdict_model_test.moc"
