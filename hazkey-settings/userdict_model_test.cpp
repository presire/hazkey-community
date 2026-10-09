/**
 * @file userdict_model_test.cpp
 * @brief ユーザ辞書TSV保存処理のQtテスト
 */

#include <QtTest/QtTest>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIODevice>
#include <QStringList>
#include <QTemporaryDir>

#ifdef Q_OS_UNIX
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#endif

#include "userdict_model.h"

namespace {

/**
 * @brief ファイルをバイト列として読み込むテスト用ヘルパー
 *
 * @param path 読み込むファイルのパス
 * @return 読込に失敗した場合、または空のファイルを読み込んだ場合は空のQByteArray、それ以外はファイル全体のバイト列
 */
QByteArray readFileBytes(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return QByteArray();
    return file.readAll();
}

/**
 * @brief ディレクトリを一時的に読み取り専用にするテスト用ガード
 *
 * 生成時に所有者の読込・実行権限だけを設定し、設定に成功した場合は破棄時に所有者の読込・書込・実行権限へ戻す
 * これにより、テストがQSKIPや失敗したQVERIFYで早期終了しても一時ディレクトリを後処理できる
 */
class ReadOnlyDirGuard {
   public:
    /**
     * @brief 指定ディレクトリを読み取り専用として設定する
     * @param dir ガード対象のディレクトリ
     */
    explicit ReadOnlyDirGuard(const QString& dir) : dir_(dir) {
        QFile file(dir);
        active_ = file.setPermissions(
            QFile::Permissions(QFile::ReadOwner | QFile::ExeOwner));
    }

    /**
     * @brief 設定に成功している場合、所有者の読込・書込・実行権限へ戻す
     */
    ~ReadOnlyDirGuard() {
        if (active_) {
            QFile(dir_).setPermissions(QFile::Permissions(
                QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
        }
    }

    /**
     * @brief 読み取り専用権限の設定に成功したかを返す
     * @return setPermissionsが成功していればtrue
     */
    bool isActive() const { return active_; }

   private:
    /** @brief 復元対象のディレクトリパス */
    QString dir_;
    /** @brief 生成時の権限設定に成功したか */
    bool active_ = false;
};

}  // namespace

/**
 * @brief ユーザ辞書TSV保存処理のQtテストフィクスチャ
 *
 * 各テストは共有の一時ディレクトリへファイルを作成し、保存結果または保存失敗時の既存ファイル保持を直接確認する
 */
class UserDictModelTest : public QObject {
    Q_OBJECT

private slots:
    /** @brief 正規TSVの全列形式、UTF-8、LF終端、空辞書を確認する */
    void testExactOutput();
    /** @brief 既存のより長いファイルが完全に置き換わることを確認する */
    void testReplacesExistingLongerFile();
    /** @brief 保存失敗時に既存ファイルと一時ファイル状態が保持されることを確認する */
    void testFailureRetainsExistingFile();
    /** @brief umask 022でも新規作成・置換後のファイル権限が0600になることを確認する */
    void testWrittenFileIsOwnerOnlyUnderPermissiveUmask();
    /** @brief タブ・CR・LFを含むフィールドを持つエントリが保存拒否され、既存ファイルが不変であることを確認する */
    void testWriteRejectsControlCharactersAndKeepsExistingFile_data();
    void testWriteRejectsControlCharactersAndKeepsExistingFile();
    /** @brief [isValidUserDictEntry] がフィールド種別ごとに判定することを確認する */
    void testIsValidUserDictEntry();
    /** @brief 単独の'\r'をサーバと同じ行区切りとして分割することを確認する */
    void testSplitUserDictionaryRecordsTreatsCarriageReturnAsSeparator();

private:
    /** @brief テスト間で利用する自動削除対象の一時ディレクトリ */
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

    // ヘルパーを呼び出さず、形式仕様から手作業で期待バイト列を構成する
    // ヘッダ、エントリ順、noun / 空POSで空コメント列を省略する規則、非nounで4列目のPOSを常に保持する規則、各行の末尾改行、UTF-8、LFを確認する
    const QString expected =
        QStringLiteral("# reading<TAB>word<TAB>comment[<TAB>pos]\n"
                       "にほん\t日本\tにっぽん\n"
                       "さとう\t佐藤\n"
                       "ひらがな\t平仮名\tcomment\n"
                       "しずおか\t静岡\tしゅう\tplace\n"
                       "えいご\t英語\t\tperson\n"
                       "かんがえる\t考える\tじてん\tverb\n");
    QCOMPARE(readFileBytes(path), expected.toUtf8());

    // commit済みのQSaveFileが一時ファイルを残さないことを確認する
    QCOMPARE(QDir(tempDir_.path()).entryList(QDir::Files),
             QStringList{QStringLiteral("exact.tsv")});

    // 空の辞書ではヘッダ行だけが書き込まれることを確認する
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

    // 既存ファイルがバイト単位で保持され、一時ファイルも残らないことを確認する
    // (直接書込フォールバックは無効)
    QCOMPARE(readFileBytes(path), original);
    QCOMPARE(QDir(dir).entryList(QDir::Files),
             QStringList{QStringLiteral("user_dictionary.tsv")});
#else
    QSKIP("Directory permission manipulation is only implemented for Unix.");
#endif
}

void UserDictModelTest::testWrittenFileIsOwnerOnlyUnderPermissiveUmask() {
#ifdef Q_OS_UNIX
    const mode_t previousUmask = ::umask(022);
    struct UmaskRestore {
        mode_t previous;
        ~UmaskRestore() { ::umask(previous); }
    } restore{previousUmask};

    QVector<UserDictEntry> entries;
    entries.append({QStringLiteral("あ"), QStringLiteral("亜"), QString(),
                    QStringLiteral("noun")});
    // QFileInfo::permissions() はOwnerとUserの同義ビットを両方立てて返す
    const QFile::Permissions ownerOnly =
        QFileDevice::ReadOwner | QFileDevice::WriteOwner |
        QFileDevice::ReadUser | QFileDevice::WriteUser;

    // 新規作成: umaskが022でも0644にならない
    const QString created = tempDir_.path() + "/mode-created.tsv";
    QVERIFY2(writeUserDictionaryFile(created, entries), "create must succeed");
    QCOMPARE(QFileInfo(created).permissions(), ownerOnly);

    // 置換: 緩い権限(0644)で存在する既存ファイルも0600へ締め直す
    const QString replaced = tempDir_.path() + "/mode-replaced.tsv";
    {
        QFile seed(replaced);
        QVERIFY2(seed.open(QIODevice::WriteOnly), "seed existing file");
        seed.write("old\n");
    }
    QVERIFY(QFile::setPermissions(
        replaced, ownerOnly | QFileDevice::ReadGroup | QFileDevice::ReadOther));
    QVERIFY(QFileInfo(replaced).permissions().testFlag(QFileDevice::ReadOther));
    QVERIFY2(writeUserDictionaryFile(replaced, entries), "replace must succeed");
    QCOMPARE(QFileInfo(replaced).permissions(), ownerOnly);
#else
    QSKIP("File mode checks are only implemented for Unix.");
#endif
}

void UserDictModelTest::testWriteRejectsControlCharactersAndKeepsExistingFile_data() {
    QTest::addColumn<QString>("reading");
    QTest::addColumn<QString>("word");
    QTest::addColumn<QString>("comment");
    QTest::addColumn<QString>("pos");

    const QString ok = QStringLiteral("あ");
    QTest::newRow("cr-in-reading") << QStringLiteral("a\rb") << ok << ok << QStringLiteral("noun");
    QTest::newRow("cr-in-word") << ok << QStringLiteral("a\rb") << ok << QStringLiteral("noun");
    QTest::newRow("cr-in-comment") << ok << ok << QStringLiteral("a\rb") << QStringLiteral("noun");
    QTest::newRow("cr-in-pos") << ok << ok << ok << QStringLiteral("no\run");
    QTest::newRow("lf-in-comment") << ok << ok << QStringLiteral("a\nb") << QStringLiteral("noun");
    QTest::newRow("crlf-in-comment") << ok << ok << QStringLiteral("a\r\nb") << QStringLiteral("noun");
    QTest::newRow("lf-in-reading") << QStringLiteral("a\nb") << ok << ok << QStringLiteral("noun");
    QTest::newRow("lf-in-word") << ok << QStringLiteral("a\nb") << ok << QStringLiteral("noun");
    QTest::newRow("tab-in-comment") << ok << ok << QStringLiteral("a\tb") << QStringLiteral("noun");
}

void UserDictModelTest::testWriteRejectsControlCharactersAndKeepsExistingFile() {
    QFETCH(QString, reading);
    QFETCH(QString, word);
    QFETCH(QString, comment);
    QFETCH(QString, pos);

    const QString path = tempDir_.path() + "/reject.tsv";
    const QByteArray original("# reading<TAB>word<TAB>comment[<TAB>pos]\n"
                              "きぞん\t既存\n");
    {
        QFile file(path);
        QVERIFY2(file.open(QIODevice::WriteOnly), "seed pre-existing file");
        file.write(original);
    }

    QVector<UserDictEntry> entries;
    entries.append({QStringLiteral("せいじょう"), QStringLiteral("正常"), QString(),
                    QStringLiteral("noun")});
    entries.append({reading, word, comment, pos});

    QVERIFY2(!writeUserDictionaryFile(path, entries),
             "an entry with a TSV separator character must be rejected");
    QCOMPARE(readFileBytes(path), original);
    QCOMPARE(QDir(tempDir_.path()).entryList({QStringLiteral("reject.tsv*")}, QDir::Files),
             QStringList{QStringLiteral("reject.tsv")});
}

void UserDictModelTest::testIsValidUserDictEntry() {
    const UserDictEntry valid{QStringLiteral("あ"), QStringLiteral("亜"),
                              QStringLiteral("comment"), QStringLiteral("noun")};
    QVERIFY(isValidUserDictEntry(valid));

    UserDictEntry e = valid;
    e.comment = QStringLiteral("x\ry");
    QVERIFY(!isValidUserDictEntry(e));
    e.comment = QStringLiteral("x\ny");
    QVERIFY(!isValidUserDictEntry(e));
    e = valid;
    e.reading = QStringLiteral("x\ry");
    QVERIFY(!isValidUserDictEntry(e));
    e = valid;
    e.word = QStringLiteral("x\ty");
    QVERIFY(!isValidUserDictEntry(e));
}

void UserDictModelTest::testSplitUserDictionaryRecordsTreatsCarriageReturnAsSeparator() {
    QCOMPARE(splitUserDictionaryRecords(QStringLiteral("a\tb")),
             QStringList{QStringLiteral("a\tb")});
    QCOMPARE(splitUserDictionaryRecords(QStringLiteral("a\tb\rc\td")),
             (QStringList{QStringLiteral("a\tb"), QStringLiteral("c\td")}));
    QCOMPARE(splitUserDictionaryRecords(QStringLiteral("\ra\tb\r\r")),
             QStringList{QStringLiteral("a\tb")});
    QVERIFY(splitUserDictionaryRecords(QString()).isEmpty());
    QVERIFY(splitUserDictionaryRecords(QStringLiteral("\r")).isEmpty());
}

QTEST_MAIN(UserDictModelTest)
#include "userdict_model_test.moc"
