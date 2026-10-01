/**
 * @file zenzai_model_management_test.cpp
 * @brief Zenzaiモデル管理APIのQt Test
 *
 * 一時ディレクトリを環境変数XDG_DATA_HOMEとして使い、パス生成、SHA256計算、
 * シンボリックリンク操作、旧形式モデルの移行、削除、ラベル整形を実ファイルで確認する
 */

#include <QtTest/QtTest>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QSet>
#include <QTemporaryDir>
#include "zenzai_models.h"

/**
 * @brief Zenzaiモデル管理のファイルシステム動作を検証するテストクラス
 *
 * @details テスト全体では、環境変数XDG_DATA_HOMEを一時ディレクトリに差し替え、各テストの開始時にその内容を削除して再作成し、
 *          モデル移行の既定カタログに依存しないケースでは、catalog引数付きオーバーロードに小さなテスト用カタログを渡す
 */
class ZenzaiModelManagementTest : public QObject {
    Q_OBJECT

private slots:
    /**
     * @brief テスト全体の開始時に環境変数を保存して一時ディレクトリを設定する
     */
    void initTestCase();
    /**
     * @brief テスト全体の終了時に環境変数XDG_DATA_HOMEを元の状態へ戻す
     */
    void cleanupTestCase();
    /**
     * @brief 各テストの開始時に一時ディレクトリの内容を初期化する
     */
    void init();
    /**
     * @brief 各テストの終了処理を行う (現在は空のfixtureフック)
     */
    void cleanup();

    /** @brief XDGデータディレクトリから導出される4種類のパスを検証する */
    void testPaths();
    /** @brief 固定データのSHA256が期待する16進文字列になることを検証する */
    void testSHA256();
    /** @brief 管理対象モデルのアクティベーションでリンクとキーが設定されることを検証する */
    void testSymlinkPromotion();
    /** @brief 管理対象のシンボリックリンクだけが解除されることを検証する */
    void testSymlinkRemoval();
    /** @brief 既定カタログでは未知の旧形式ファイルを移行しないことを検証する */
    void testLegacyMigration();
    /** @brief SHA256が一致する注入カタログの旧形式ファイルを移行することを検証する */
    void testKnownLegacyMigration();
    /** @brief 同一内容の管理対象ファイルがある場合に旧形式ファイルを整理して有効化することを検証する */
    void testKnownLegacyMigrationExisting();
    /** @brief 移動先のSHA256が異なる場合に旧形式ファイルを保持することを検証する */
    void testKnownLegacyMigrationExistingMismatched();
    /** @brief 既定カタログにないカスタム旧形式ファイルを保持することを検証する */
    void testUnknownPreservation();
    /** @brief 非アクティブモデルの削除とアクティブモデル削除時のリンク解除を検証する */
    void testDeletionMechanics();
    /** @brief 既存モデルの明示的なアクティベーションと切り替えを検証する */
    void testExplicitActivation();
    /** @brief 推奨・ダウンロード済みフラグを含むラベル整形結果を検証する */
    void testLabelFormatting();
    /** @brief jinen-v2ファミリがカタログに存在することを検証する (failing-first用) */
    void testJinenCatalogPresence();
    /** @brief 条件付け対応フラグとその判定フォールバックを検証する */
    void testConditioningSupport();
    /** @brief 右文脈対応フラグとその判定フォールバックを検証する */
    void testRightContextSupport();
    /** @brief カタログ検査結果がディスク変更まで不変であることを検証する */
    void testDownloadedModelKeysSnapshot();
    /** @brief 変更のないスナップショット再取得が再ハッシュしないことを検証する */
    void testSha256CacheAvoidsRehash();
    /** @brief deleteModelがSHA256キャッシュを無効化することを検証する */
    void testDeleteModelInvalidatesCache();

private:
    /** @brief 全テストでファイルを作成する一時ディレクトリ */
    QTemporaryDir tempDir;
    /** @brief initTestCase()前の環境変数XDG_DATA_HOME値 空の場合は未設定を表す */
    QString originalXdgDataHome;
};

void ZenzaiModelManagementTest::initTestCase() {
    originalXdgDataHome = qEnvironmentVariable("XDG_DATA_HOME");
    qputenv("XDG_DATA_HOME", tempDir.path().toUtf8());
}

void ZenzaiModelManagementTest::cleanupTestCase() {
    if (originalXdgDataHome.isEmpty()) {
        qunsetenv("XDG_DATA_HOME");
    } else {
        qputenv("XDG_DATA_HOME", originalXdgDataHome.toUtf8());
    }
}

void ZenzaiModelManagementTest::init() {
    QDir(tempDir.path()).removeRecursively();
    QDir().mkpath(tempDir.path());
}

void ZenzaiModelManagementTest::cleanup() {
}

void ZenzaiModelManagementTest::testPaths() {
    QString zenzaiDir = ZenzaiModelManager::getZenzaiDir();
    QCOMPARE(zenzaiDir, tempDir.path() + "/hazkey-community/zenzai");
    
    QString modelsDir = ZenzaiModelManager::getModelsDir();
    QCOMPARE(modelsDir, zenzaiDir + "/models");
    
    QString symlinkPath = ZenzaiModelManager::getSymlinkPath();
    QCOMPARE(symlinkPath, zenzaiDir + "/zenzai.gguf");
    
    QString modelPath = ZenzaiModelManager::getModelPath("test-key");
    QCOMPARE(modelPath, modelsDir + "/test-key.gguf");
}

void ZenzaiModelManagementTest::testSHA256() {
    QString testFile = tempDir.path() + "/test.txt";
    QFile file(testFile);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("hello world");
    file.close();
    
    // "hello world" のSHA256
    QString expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
    QCOMPARE(ZenzaiModelManager::calculateSHA256(testFile), expected);
}

void ZenzaiModelManagementTest::testSymlinkPromotion() {
    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QString modelPath = ZenzaiModelManager::getModelPath("test-model");
    QFile file(modelPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("dummy model data");
    file.close();
    
    QVERIFY(ZenzaiModelManager::activateModel("test-model"));
    
    QString symlinkPath = ZenzaiModelManager::getSymlinkPath();
    QFileInfo info(symlinkPath);
    QVERIFY(info.exists());
    QVERIFY(info.isSymLink());
    QCOMPARE(info.symLinkTarget(), modelPath);
    QCOMPARE(ZenzaiModelManager::getActiveModelKey(), QString("test-model"));
}

void ZenzaiModelManagementTest::testSymlinkRemoval() {
    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QString modelPath = ZenzaiModelManager::getModelPath("test-model");
    QFile file(modelPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("dummy");
    file.close();
    
    ZenzaiModelManager::activateModel("test-model");
    QVERIFY(QFile::exists(ZenzaiModelManager::getSymlinkPath()));
    
    QVERIFY(ZenzaiModelManager::deactivateModel());
    QVERIFY(!QFile::exists(ZenzaiModelManager::getSymlinkPath()));
}

void ZenzaiModelManagementTest::testLegacyMigration() {
    const auto& models = availableZenzaiModels();
    QVERIFY(!models.isEmpty());
    const auto& m = models[0];
    
    QDir().mkpath(ZenzaiModelManager::getZenzaiDir());
    QString legacyPath = ZenzaiModelManager::getSymlinkPath();
    
    // SHA256が一致する旧形式の通常ファイルを用意する
    // 特定SHAを持つ74[MB]の実ファイルはここでは作れないため、
    // カタログを差し替えれば小さいファイルでもSHA照合を模擬できる
    // ここではダミーファイルで不一致の場合だけを確認する
    // (小さい既知モデルがあればそれを使う手もある)
    // 本来は availableZenzaiModels のいずれかのキーに一致するファイルで
    // 移行可否の分岐を検証したいが、availableZenzaiModels は固定値のため、
    // SHA不一致なら移行しないことだけを検証する
    
    QFile file(legacyPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("not a real model");
    file.close();
    
    ZenzaiModelManager::migrateLegacyModel();
    
    QFileInfo info(legacyPath);
    QVERIFY(info.exists());
    QVERIFY(!info.isSymLink()); // 移行せず通常ファイルのままのはず
}

void ZenzaiModelManagementTest::testKnownLegacyMigration() {
    QDir().mkpath(ZenzaiModelManager::getZenzaiDir());
    QString legacyPath = ZenzaiModelManager::getSymlinkPath();
    
    QFile file(legacyPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("mock model data");
    file.close();
    
    QString sha = ZenzaiModelManager::calculateSHA256(legacyPath);
    
    ZenzaiModelOption mockModel;
    mockModel.key = "mock-model";
    mockModel.sha256 = sha;
    
    QVector<ZenzaiModelOption> catalog = { mockModel };
    
    ZenzaiModelManager::migrateLegacyModel(catalog);
    
    QFileInfo info(legacyPath);
    QVERIFY(info.exists());
    QVERIFY(info.isSymLink());
    QCOMPARE(ZenzaiModelManager::getActiveModelKey(), QString("mock-model"));
    QVERIFY(QFile::exists(ZenzaiModelManager::getModelPath("mock-model")));
}

void ZenzaiModelManagementTest::testKnownLegacyMigrationExisting() {
    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QString modelPath = ZenzaiModelManager::getModelPath("mock-model");
    QFile f(modelPath);
    QVERIFY(f.open(QIODevice::WriteOnly));
    f.write("identical model data");
    f.close();

    QString legacyPath = ZenzaiModelManager::getSymlinkPath();
    QFile fl(legacyPath);
    QVERIFY(fl.open(QIODevice::WriteOnly));
    fl.write("identical model data");
    fl.close();
    
    QString sha = ZenzaiModelManager::calculateSHA256(legacyPath);
    
    ZenzaiModelOption mockModel;
    mockModel.key = "mock-model";
    mockModel.sha256 = sha;
    
    QVector<ZenzaiModelOption> catalog = { mockModel };
    
    ZenzaiModelManager::migrateLegacyModel(catalog);
    
    QFileInfo info(legacyPath);
    QVERIFY(info.exists());
    QVERIFY(info.isSymLink());
    // 旧形式ファイルは削除され、既存の管理対象モデルが有効化されるはず
    QVERIFY(QFile::exists(modelPath));
}

void ZenzaiModelManagementTest::testKnownLegacyMigrationExistingMismatched() {
    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QString modelPath = ZenzaiModelManager::getModelPath("mock-model");
    QFile f(modelPath);
    QVERIFY(f.open(QIODevice::WriteOnly));
    f.write("mismatched existing model data");
    f.close();

    QString legacyPath = ZenzaiModelManager::getSymlinkPath();
    QFile fl(legacyPath);
    QVERIFY(fl.open(QIODevice::WriteOnly));
    fl.write("valid legacy model data");
    fl.close();
    
    QString sha = ZenzaiModelManager::calculateSHA256(legacyPath);
    
    ZenzaiModelOption mockModel;
    mockModel.key = "mock-model";
    mockModel.sha256 = sha;
    
    QVector<ZenzaiModelOption> catalog = { mockModel };
    
    ZenzaiModelManager::migrateLegacyModel(catalog);
    
    QFileInfo info(legacyPath);
    QVERIFY(info.exists());
    QVERIFY(!info.isSymLink()); // 移動先の管理対象ファイルが不一致のため移行しないはず
    QCOMPARE(ZenzaiModelManager::calculateSHA256(legacyPath), sha);
}

void ZenzaiModelManagementTest::testUnknownPreservation() {
    QDir().mkpath(ZenzaiModelManager::getZenzaiDir());
    QString legacyPath = ZenzaiModelManager::getSymlinkPath();
    QFile file(legacyPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("custom model");
    file.close();
    
    ZenzaiModelManager::migrateLegacyModel();
    
    QVERIFY(QFile::exists(legacyPath));
    QVERIFY(!QFileInfo(legacyPath).isSymLink());
}

void ZenzaiModelManagementTest::testDeletionMechanics() {
    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QString model1 = ZenzaiModelManager::getModelPath("model1");
    QString model2 = ZenzaiModelManager::getModelPath("model2");
    
    QFile f1(model1); f1.open(QIODevice::WriteOnly); f1.write("m1"); f1.close();
    QFile f2(model2); f2.open(QIODevice::WriteOnly); f2.write("m2"); f2.close();
    
    ZenzaiModelManager::activateModel("model1");
    
    // 非アクティブなモデルを削除する
    QVERIFY(ZenzaiModelManager::deleteModel("model2"));
    QVERIFY(!QFile::exists(model2));
    QVERIFY(QFile::exists(ZenzaiModelManager::getSymlinkPath())); // 有効化中のリンクは残る
    
    // 有効化中のモデルを削除する
    QVERIFY(ZenzaiModelManager::deleteModel("model1"));
    QVERIFY(!QFile::exists(model1));
    QVERIFY(!QFile::exists(ZenzaiModelManager::getSymlinkPath())); // シンボリックリンクも外れる
}

void ZenzaiModelManagementTest::testExplicitActivation() {
    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QString model1 = ZenzaiModelManager::getModelPath("model1");
    QString model2 = ZenzaiModelManager::getModelPath("model2");
    
    QFile f1(model1); f1.open(QIODevice::WriteOnly); f1.write("m1"); f1.close();
    QFile f2(model2); f2.open(QIODevice::WriteOnly); f2.write("m2"); f2.close();
    
    // model1を有効化する
    QVERIFY(ZenzaiModelManager::activateModel("model1"));
    QCOMPARE(ZenzaiModelManager::getActiveModelKey(), QString("model1"));
    
    // model2へ切り替える
    QVERIFY(ZenzaiModelManager::activateModel("model2"));
    QCOMPARE(ZenzaiModelManager::getActiveModelKey(), QString("model2"));
    
    // シンボリックリンクの指し先を確認する
    QFileInfo info(ZenzaiModelManager::getSymlinkPath());
    QCOMPARE(info.symLinkTarget(), model2);
}

void ZenzaiModelManagementTest::testLabelFormatting() {
    ZenzaiModelOption m;
    m.displayName = "Test Model";
    m.sizeDisplay = "100 MB";
    m.recommended = false;
    
    QString label = ZenzaiModelManager::formatModelLabel(m, false);
    QCOMPARE(label, QString("Test Model : 100 MB"));
    
    label = ZenzaiModelManager::formatModelLabel(m, true);
    QVERIFY(label.contains(" (downloaded)"));
    QVERIFY(label.contains(" : "));
    
    m.recommended = true;
    label = ZenzaiModelManager::formatModelLabel(m, false);
    QVERIFY(label.contains("Recommended:"));
}

void ZenzaiModelManagementTest::testDownloadedModelKeysSnapshot() {
    const QByteArray validData("snapshot-valid");
    const QByteArray invalidData("snapshot-invalid");
    ZenzaiModelOption valid;
    valid.key = QStringLiteral("snapshot-valid");
    valid.sha256 = QString::fromLatin1(
        QCryptographicHash::hash(validData, QCryptographicHash::Sha256).toHex());
    ZenzaiModelOption invalid;
    invalid.key = QStringLiteral("snapshot-invalid");
    invalid.sha256 = QStringLiteral("not-a-matching-hash");

    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QFile validFile(ZenzaiModelManager::getModelPath(valid.key));
    QVERIFY(validFile.open(QIODevice::WriteOnly));
    validFile.write(validData);
    validFile.close();
    QFile invalidFile(ZenzaiModelManager::getModelPath(invalid.key));
    QVERIFY(invalidFile.open(QIODevice::WriteOnly));
    invalidFile.write(invalidData);
    invalidFile.close();

    const QVector<ZenzaiModelOption> catalog = {valid, invalid, valid};
    const QSet<QString> snapshot = ZenzaiModelManager::downloadedModelKeys(catalog);
    QCOMPARE(snapshot, QSet<QString>({valid.key}));

    QVERIFY(QFile::remove(ZenzaiModelManager::getModelPath(valid.key)));
    QVERIFY(snapshot.contains(valid.key));
    const QSet<QString> refreshed = ZenzaiModelManager::downloadedModelKeys(catalog);
    QVERIFY(!refreshed.contains(valid.key));
}

void ZenzaiModelManagementTest::testSha256CacheAvoidsRehash() {
    const QByteArray data("cache-probe-model-payload");
    ZenzaiModelOption model;
    model.key = QStringLiteral("cache-probe-model");
    model.sha256 = QString::fromLatin1(
        QCryptographicHash::hash(data, QCryptographicHash::Sha256).toHex());

    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QFile file(ZenzaiModelManager::getModelPath(model.key));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(data);
    file.close();

    const QVector<ZenzaiModelOption> catalog = {model};
    ZenzaiModelManager::resetSha256ActualComputeCount();
    const QSet<QString> first = ZenzaiModelManager::downloadedModelKeys(catalog);
    QVERIFY(first.contains(model.key));
    QCOMPARE(ZenzaiModelManager::sha256ActualComputeCount(), 1);

    // 変更なしのファイルは2回目の取得でstatキャッシュから返すこと
    const QSet<QString> second = ZenzaiModelManager::downloadedModelKeys(catalog);
    QCOMPARE(second, first);
    QCOMPARE(ZenzaiModelManager::sha256ActualComputeCount(), 1);

    // 内容を書き換えた場合 (サイズ違い) は検出して再ハッシュすること
    const QByteArray tampered = data + "x";
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(tampered);
    file.close();
    const QSet<QString> third = ZenzaiModelManager::downloadedModelKeys(catalog);
    QVERIFY(!third.contains(model.key));
    QCOMPARE(ZenzaiModelManager::sha256ActualComputeCount(), 2);
}

void ZenzaiModelManagementTest::testDeleteModelInvalidatesCache() {
    const QByteArray good("cache-invalidate-good!");
    const QByteArray bad("cache-invalidate-bad!_");
    ZenzaiModelOption model;
    model.key = QStringLiteral("cache-invalidate-model");
    model.sha256 = QString::fromLatin1(
        QCryptographicHash::hash(good, QCryptographicHash::Sha256).toHex());

    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    const QString path = ZenzaiModelManager::getModelPath(model.key);
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(good);
    file.close();
    const QDateTime originalMtime = QFileInfo(path).lastModified();

    const QVector<ZenzaiModelOption> catalog = {model};
    QVERIFY(ZenzaiModelManager::downloadedModelKeys(catalog).contains(model.key));

    QVERIFY(ZenzaiModelManager::deleteModel(model.key));
    QVERIFY(!ZenzaiModelManager::downloadedModelKeys(catalog).contains(model.key));

    // 元の更新時刻に固定した同サイズの壊れたデータを再配置する
    // キャッシュが残ったままだと誤って「ダウンロード済み」と判定されるケース
    QVERIFY(bad.size() == good.size());
    QVERIFY(bad != good);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(bad);
    file.close();
    QVERIFY(file.open(QIODevice::ReadWrite));
    QVERIFY(file.setFileTime(originalMtime, QFileDevice::FileModificationTime));
    file.close();

    ZenzaiModelManager::resetSha256ActualComputeCount();
    const QSet<QString> afterRedownload = ZenzaiModelManager::downloadedModelKeys(catalog);
    QVERIFY(!afterRedownload.contains(model.key));
    QCOMPARE(ZenzaiModelManager::sha256ActualComputeCount(), 1);
}

void ZenzaiModelManagementTest::testJinenCatalogPresence() {
    // 先行失敗検出用: jinen-v2系列がカタログに登録されていること
    // 1. 系列はちょうど5件で順序固定
    const QVector<ZenzaiModelFamily>& families = availableZenzaiModelFamilies();
    QCOMPARE(families.size(), 5);
    QCOMPARE(families[0].familyKey, QString("zenz-v3.2-small"));
    QCOMPARE(families[1].familyKey, QString("zenz-v3.2-xsmall"));
    QCOMPARE(families[2].familyKey, QString("zenz-v3.1-small"));
    QCOMPARE(families[3].familyKey, QString("jinen-v2-small"));
    QCOMPARE(families[4].familyKey, QString("jinen-v2-xsmall"));
    QCOMPARE(families[3].displayName, QString("jinen-v2-small"));
    QCOMPARE(families[4].displayName, QString("jinen-v2-xsmall"));

    // 2. zenzの単一バリアント系列は変更なし (値がバイト単位で一致)
    struct ExpectedZenz {
        const char* key;
        const char* displayName;
        const char* description;
        const char* url;
        const char* sha256;
        const char* sizeDisplay;
        bool recommended;
        bool isLegacyGen;
    };
    const ExpectedZenz expectedZenz[3] = {
        {"zenz-v3.2-small", "zenz-v3.2-small (Q5_K_M)",
         "Recommended: Latest version. Best conversion accuracy.",
         "https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf",
         "29c223d4c23327b80fd13ebb5ab2555057a46317997d5da391584ffbef0db673",
         "~74 MB", true, false},
        {"zenz-v3.2-xsmall", "zenz-v3.2-xsmall (Q5_K_M)",
         "Smaller size. Faster on CPU, slightly lower accuracy.",
         "https://huggingface.co/Miwa-Keita/zenz-v3.2-xsmall-gguf/resolve/main/ggml-model-Q5_K_M.gguf",
         "00c64b3d318045a708d0cad5434faccab10f5481a49e6362864551fd0995fa58",
         "~21 MB", false, false},
        {"zenz-v3.1-small", "zenz-v3.1-small (Q5_K_M)",
         "Previous version. Legacy compatibility.",
         "https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf",
         "4de930c06bef8c263aa1aa40684af206db4ce1b96375b3b8ed0ea508e0b14f6c",
         "~74 MB", false, true},
    };
    for (int i = 0; i < 3; ++i) {
        QCOMPARE(families[i].variants.size(), 1);
        const ZenzaiModelOption& v = families[i].variants[0];
        QCOMPARE(v.key, QString(expectedZenz[i].key));
        QCOMPARE(v.displayName, QString(expectedZenz[i].displayName));
        QCOMPARE(v.description, QString(expectedZenz[i].description));
        QCOMPARE(v.url, QString(expectedZenz[i].url));
        QCOMPARE(v.sha256, QString(expectedZenz[i].sha256));
        QCOMPARE(v.sizeDisplay, QString(expectedZenz[i].sizeDisplay));
        QCOMPARE(v.recommended, expectedZenz[i].recommended);
        QCOMPARE(v.isLegacyGen, expectedZenz[i].isLegacyGen);
        QCOMPARE(v.expectedBytes, qint64(0));
        QVERIFY2(v.quantLabel.isEmpty(),
                 qPrintable(QString("zenz variant %1 must have empty quantLabel").arg(v.key)));
    }

    // 2b. zenz系列は帰属情報を持たない。帰属表示行はjinen専用
    for (int i = 0; i < 3; ++i) {
        QVERIFY2(families[i].author.isEmpty(),
                 qPrintable(QString("zenz family %1 must not declare an author")
                                .arg(families[i].familyKey)));
        QVERIFY2(families[i].sourceUrl.isEmpty(),
                 qPrintable(QString("zenz family %1 must not declare a source URL")
                                .arg(families[i].familyKey)));
        QVERIFY2(families[i].licenseName.isEmpty(),
                 qPrintable(QString("zenz family %1 must not declare a license name")
                                .arg(families[i].familyKey)));
        QVERIFY2(families[i].licenseUrl.isEmpty(),
                 qPrintable(QString("zenz family %1 must not declare a license URL")
                                .arg(families[i].familyKey)));
    }

    // 3. 平坦化したアーティファクトカタログはちょうど11件で順序固定
    const QVector<ZenzaiModelOption>& models = availableZenzaiModels();
    QCOMPARE(models.size(), 11);
    QCOMPARE(models[0].key, QString("zenz-v3.2-small"));
    QCOMPARE(models[1].key, QString("zenz-v3.2-xsmall"));
    QCOMPARE(models[2].key, QString("zenz-v3.1-small"));

    // 4. jinen系列は各4バリアントで量子化の順序固定
    struct ExpectedArtifact {
        const char* key;
        const char* repo;
        const char* quant;
        qint64 expectedBytes;
        const char* sha256;
    };
    const ExpectedArtifact expectedJinen[8] = {
        {"jinen-v2-small-f16", "togatogah/jinen-v2-small.gguf", "f16", 219865856,
         "904c40debcf04e6189d63c046425051bfa4c999ca22962c50dd01a7776af6820"},
        {"jinen-v2-small-Q8_0", "togatogah/jinen-v2-small.gguf", "Q8_0", 117197472,
         "215fe5a513fffdc7c9570a8bf1ad45439d80dc7db2b2f43a1c55f28ffc9fba99"},
        {"jinen-v2-small-Q5_K_M", "togatogah/jinen-v2-small.gguf", "Q5_K_M", 81117824,
         "80482707513d6b67dafc31774371cf95d765542abf8d74eebf5f32f92d788bd3"},
        {"jinen-v2-small-Q4_K_M", "togatogah/jinen-v2-small.gguf", "Q4_K_M", 72123008,
         "26a6a71020a8d12908615d6ed2541ad6d6d9b73fc179d8d5472eb1c709bb1300"},
        {"jinen-v2-xsmall-f16", "togatogah/jinen-v2-xsmall.gguf", "f16", 72089024,
         "1010735eed3794d116d572edc51080abb0e1a59c94bc6f6865429637f4d6f7f3"},
        {"jinen-v2-xsmall-Q8_0", "togatogah/jinen-v2-xsmall.gguf", "Q8_0", 38664224,
         "bc75a02512bdbb2a4786fec281a57d4d58ac3c2f118c3a29c2a9b41f2a4898b7"},
        {"jinen-v2-xsmall-Q5_K_M", "togatogah/jinen-v2-xsmall.gguf", "Q5_K_M", 28261056,
         "24ff3af5db712fbbb4aa9254ee28ec4d731207134471ab68b06c1828726284c2"},
        {"jinen-v2-xsmall-Q4_K_M", "togatogah/jinen-v2-xsmall.gguf", "Q4_K_M", 26278592,
         "1783be74e4bf0eaadcd6f217ec6dea06cecb0833b94c24b417b93d93fbe01d4e"},
    };
    QCOMPARE(families[3].variants.size(), 4);
    QCOMPARE(families[4].variants.size(), 4);

    // 4b. jinen系列はUI表示に必要なCC-BY-SA-4.0の帰属情報を保持する
    // 作成者 + 配布元リポジトリ + ライセンス名 + クリック可能なライセンス/配布元URL
    struct ExpectedAttribution {
        const char* familyKey;
        const char* repo;
    };
    const ExpectedAttribution expectedAttribution[2] = {
        {"jinen-v2-small", "togatogah/jinen-v2-small.gguf"},
        {"jinen-v2-xsmall", "togatogah/jinen-v2-xsmall.gguf"},
    };
    for (int i = 0; i < 2; ++i) {
        const ZenzaiModelFamily& fam = families[3 + i];
        const QString expectedSourceUrl =
            QString("https://huggingface.co/%1").arg(QString::fromLatin1(expectedAttribution[i].repo));
        QVERIFY2(fam.familyKey == QString::fromLatin1(expectedAttribution[i].familyKey),
                 qPrintable(QString("attribution row %1 has unexpected family").arg(i)));
        QVERIFY2(fam.author == QString("togatogah"),
                 qPrintable(QString("family %1 must credit togatogah").arg(fam.familyKey)));
        QVERIFY2(fam.sourceUrl == expectedSourceUrl,
                 qPrintable(QString("family %1 source URL mismatch: got %2, want %3")
                                .arg(fam.familyKey, fam.sourceUrl, expectedSourceUrl)));
        QVERIFY2(fam.licenseName == QString("CC-BY-SA-4.0"),
                 qPrintable(QString("family %1 must disclose CC-BY-SA-4.0").arg(fam.familyKey)));
        QVERIFY2(fam.licenseUrl.startsWith(QString("https://")),
                 qPrintable(QString("family %1 must expose a clickable license URL")
                                .arg(fam.familyKey)));
        QVERIFY2(fam.licenseUrl.contains(QString("by-sa")),
                 qPrintable(QString("family %1 license URL must point at the by-sa deed")
                                .arg(fam.familyKey)));
    }

    // 4c. 各jinenバリアントのURLは系列の帰属リポジトリ配下にあり、
    // 表示上の配布元リンクが成果物の実際の取得元と一致すること
    for (int i = 3; i < 5; ++i) {
        for (const ZenzaiModelOption& v : families[i].variants) {
            QVERIFY2(v.url.startsWith(families[i].sourceUrl + QString("/resolve/")),
                     qPrintable(QString("variant %1 must resolve from %2")
                                    .arg(v.key, families[i].sourceUrl)));
        }
    }

    // 全項目を表駆動で検査する。失敗メッセージにはキー名を出す
    // キーの一意性 (重複なし) と平坦化後の順序も合わせて検証する
    QSet<QString> seenKeys;
    for (const auto& m : models) {
        QVERIFY2(!seenKeys.contains(m.key),
                 qPrintable(QString("duplicate catalog key: %1").arg(m.key)));
        seenKeys.insert(m.key);
    }
    QCOMPARE(seenKeys.size(), 11);

    for (int i = 0; i < 8; ++i) {
        const ExpectedArtifact& e = expectedJinen[i];
        const QString key = QString::fromLatin1(e.key);
        const QString expectedUrl = QString("https://huggingface.co/%1/resolve/main/%2.gguf")
                                        .arg(QString::fromLatin1(e.repo), key);
        // 系列内での位置: 前半4件はsmall系列、後半4件はxsmall系列
        const ZenzaiModelOption& famVariant =
            (i < 4) ? families[3].variants[i] : families[4].variants[i - 4];
        QVERIFY2(famVariant.key == key,
                 qPrintable(QString("family order mismatch at index %1: got %2, want %3")
                                .arg(i).arg(famVariant.key, key)));
        QVERIFY2(famVariant.quantLabel == QString::fromLatin1(e.quant),
                 qPrintable(QString("quant label mismatch for %1: got %2, want %3")
                                .arg(key, famVariant.quantLabel, QString::fromLatin1(e.quant))));
        // 平坦化カタログ内での位置: 4件目から10件目 (0始まりで3..10)
        const ZenzaiModelOption& flat = models[3 + i];
        for (const ZenzaiModelOption* cand : {&famVariant, &flat}) {
            QVERIFY2(cand->key == key,
                     qPrintable(QString("key mismatch: got %1, want %2").arg(cand->key, key)));
            QVERIFY2(cand->url == expectedUrl,
                     qPrintable(QString("url mismatch for %1: got %2").arg(key, cand->url)));
            QVERIFY2(cand->expectedBytes == e.expectedBytes,
                     qPrintable(QString("bytes mismatch for %1: got %2, want %3")
                                    .arg(key).arg(cand->expectedBytes).arg(e.expectedBytes)));
            QVERIFY2(cand->sha256 == QString::fromLatin1(e.sha256),
                     qPrintable(QString("sha mismatch for %1").arg(key)));
            QVERIFY2(cand->sha256 == cand->sha256.toLower(),
                     qPrintable(QString("sha not lowercase for %1").arg(key)));
            QVERIFY2(!cand->recommended,
                     qPrintable(QString("jinen %1 must not be recommended").arg(key)));
            QVERIFY2(!cand->isLegacyGen,
                     qPrintable(QString("jinen %1 must not be legacy").arg(key)));
            QVERIFY2(cand->expectedBytes > 0,
                     qPrintable(QString("jinen %1 must have positive expectedBytes").arg(key)));
            QVERIFY2(!cand->sha256.isEmpty(),
                     qPrintable(QString("jinen %1 must have non-empty sha256").arg(key)));
        }
    }

    // 5. キー指定でのアーティファクト検索
    const ZenzaiModelOption* found = findZenzaiModelByKey("jinen-v2-small-Q4_K_M");
    QVERIFY2(found != nullptr, "findZenzaiModelByKey must resolve jinen-v2-small-Q4_K_M");
    QCOMPARE(found->expectedBytes, qint64(72123008));
    QVERIFY(found->url.endsWith("/jinen-v2-small-Q4_K_M.gguf"));
    QCOMPARE(findZenzaiModelByKey("no-such-model-key"), nullptr);

    // 6. 系列取得の安定性: 繰り返し呼んでも同じ内容が返ること
    const QVector<ZenzaiModelFamily>& again = availableZenzaiModelFamilies();
    QCOMPARE(again.size(), families.size());
    QCOMPARE(again[4].variants.size(), 4);
    QCOMPARE(again[4].variants[2].key, QString("jinen-v2-xsmall-Q5_K_M"));
}

void ZenzaiModelManagementTest::testConditioningSupport() {
    // 1. カタログのフラグ: zenz3系列は条件付け対応、jinen-v2の2系列は非対応
    const QVector<ZenzaiModelFamily>& families = availableZenzaiModelFamilies();
    QVERIFY2(families[0].supportsConditioning, "zenz must support conditioning");
    QVERIFY2(families[1].supportsConditioning, "zenz-xsmall must support conditioning");
    QVERIFY2(families[2].supportsConditioning, "legacy zenz must support conditioning");
    QVERIFY2(!families[3].supportsConditioning, "jinen-v2-small must not support conditioning");
    QVERIFY2(!families[4].supportsConditioning, "jinen-v2-xsmall must not support conditioning");

    // 2. 系列検索は系列キーとバリアントキーの両方で解決できる
    const ZenzaiModelFamily* zenz = findZenzaiFamilyByKey("zenz-v3.2-small");
    QVERIFY2(zenz != nullptr, "findZenzaiFamilyByKey must resolve zenz-v3.2-small");
    QVERIFY(zenz->supportsConditioning);
    const ZenzaiModelFamily* jinenVariant = findZenzaiFamilyByKey("jinen-v2-xsmall-Q5_K_M");
    QVERIFY2(jinenVariant != nullptr, "findZenzaiFamilyByKey must resolve jinen variant key");
    QCOMPARE(jinenVariant->familyKey, QString("jinen-v2-xsmall"));
    QVERIFY(!jinenVariant->supportsConditioning);
    QCOMPARE(findZenzaiFamilyByKey("no-such-model-key"), nullptr);

    // 3. カタログ判定: zenzは有効、jinenバリアントは無効
    QVERIFY(zenzaiModelSupportsConditioning("zenz-v3.2-small"));
    QVERIFY(zenzaiModelSupportsConditioning("zenz-v3.1-small"));
    QVERIFY(!zenzaiModelSupportsConditioning("jinen-v2-small-Q4_K_M"));
    QVERIFY(!zenzaiModelSupportsConditioning("jinen-v2-xsmall-f16"));

    // 4. カタログ外の代替処理: jinenを含むファイル名は無効、不明な名前は有効のまま
    QVERIFY(!zenzaiModelSupportsConditioning("/path/to/jinen-v2-small-Q4_K_M.gguf"));
    QVERIFY(zenzaiModelSupportsConditioning("my-custom-model"));
    QVERIFY(zenzaiModelSupportsConditioning(QString()));

    // 5. パス判定はファイル名部分で大文字小文字を区別しない
    QVERIFY(isJinenModelPath("JINEN-V2-SMALL.gguf"));
    QVERIFY(isJinenModelPath("/models/jinen-v2-xsmall-Q5_K_M.gguf"));
    QVERIFY(!isJinenModelPath("zenz-v3.2-small.gguf"));
    QVERIFY(!isJinenModelPath(QString()));
}

void ZenzaiModelManagementTest::testRightContextSupport() {
    // 1. カタログのフラグ: zenz-v3.2の2系列のみ右文脈対応
    const QVector<ZenzaiModelFamily>& families = availableZenzaiModelFamilies();
    QCOMPARE(families.size(), 5);
    QVERIFY2(families[0].supportsRightContext, "zenz-v3.2-small must support right context");
    QVERIFY2(families[1].supportsRightContext, "zenz-v3.2-xsmall must support right context");
    QVERIFY2(!families[2].supportsRightContext, "legacy zenz must not support right context");
    QVERIFY2(!families[3].supportsRightContext, "jinen-v2-small must not support right context");
    QVERIFY2(!families[4].supportsRightContext, "jinen-v2-xsmall must not support right context");

    // 2. 系列キーでフラグを引けるため、順序変更があっても検査が壊れない
    const ZenzaiModelFamily* v32Small = findZenzaiFamilyByKey("zenz-v3.2-small");
    const ZenzaiModelFamily* v32Xsmall = findZenzaiFamilyByKey("zenz-v3.2-xsmall");
    const ZenzaiModelFamily* v31Small = findZenzaiFamilyByKey("zenz-v3.1-small");
    QVERIFY2(v32Small != nullptr, "findZenzaiFamilyByKey must resolve zenz-v3.2-small");
    QVERIFY2(v32Xsmall != nullptr, "findZenzaiFamilyByKey must resolve zenz-v3.2-xsmall");
    QVERIFY2(v31Small != nullptr, "findZenzaiFamilyByKey must resolve zenz-v3.1-small");
    QVERIFY(v32Small->supportsRightContext);
    QVERIFY(v32Xsmall->supportsRightContext);
    QVERIFY(!v31Small->supportsRightContext);

    // 3. 系列キーとバリアントキーでのカタログ判定
    QVERIFY(zenzaiModelSupportsRightContext("zenz-v3.2-small"));
    QVERIFY(zenzaiModelSupportsRightContext("zenz-v3.2-xsmall"));
    QVERIFY(!zenzaiModelSupportsRightContext("zenz-v3.1-small"));
    QVERIFY(!zenzaiModelSupportsRightContext("jinen-v2-small-Q5_K_M"));
    QVERIFY(!zenzaiModelSupportsRightContext("jinen-v2-xsmall-Q4_K_M"));
    QVERIFY(!zenzaiModelSupportsRightContext("jinen-v2-small-f16"));

    // 4. カタログ外の代替処理: ファイル名から世代を推定する
    QVERIFY(zenzaiModelSupportsRightContext("my-custom"));
    QVERIFY(zenzaiModelSupportsRightContext("/x/y/ZENZ-V3.2-Foo.gguf"));
    QVERIFY(!zenzaiModelSupportsRightContext("/x/y/zenz-v3.1-foo.gguf"));
    QVERIFY(!zenzaiModelSupportsRightContext("zenz-v3-small.gguf"));
    QVERIFY(!zenzaiModelSupportsRightContext("zenz-v2-small.gguf"));
    QVERIFY(zenzaiModelSupportsRightContext("zenz-v4.0-small.gguf"));
    QVERIFY(!zenzaiModelSupportsRightContext("/path/to/jinen-v2-small-Q4_K_M.gguf"));
    QVERIFY(zenzaiModelSupportsRightContext("zenzai.gguf"));

    // 5. 不正・境界値入力: 大文字の拡張子、カスタム重み、空キー
    QVERIFY(zenzaiModelSupportsRightContext("ZENZ-V3.2-SMALL.GGUF"));
    QVERIFY(zenzaiModelSupportsRightContext("my-custom-model.gguf"));
    QVERIFY(zenzaiModelSupportsRightContext(QString()));
}

QTEST_MAIN(ZenzaiModelManagementTest)
#include "zenzai_model_management_test.moc"
