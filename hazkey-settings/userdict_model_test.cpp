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
    // （直接書込フォールバックは無効）
    QCOMPARE(readFileBytes(path), original);
    QCOMPARE(QDir(dir).entryList(QDir::Files),
             QStringList{QStringLiteral("user_dictionary.tsv")});
#else
    QSKIP("Directory permission manipulation is only implemented for Unix.");
#endif
}

QTEST_MAIN(UserDictModelTest)
#include "userdict_model_test.moc"
