/**
 * @file zenzai_model_management_test.cpp
 * @brief Zenzaiモデル管理APIのQt Test
 *
 * 一時ディレクトリを環境変数XDG_DATA_HOMEとして使い、パス生成、SHA256計算、
 * シンボリックリンク操作、旧形式モデルの移行、削除、ラベル整形を実ファイルで確認する
 */

#include <QtTest/QtTest>
#include <QDir>
#include <QFile>
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
    QCOMPARE(zenzaiDir, tempDir.path() + "/hazkey/zenzai");
    
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
    
    // sha256 of "hello world"
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
    
    // Create a legacy regular file with correct SHA
    // We can't easily create a 74MB file with specific SHA here, 
    // but we can mock the SHA by using a small file if we were to change the catalog.
    // For testing, let's just use a dummy file and assume it doesn't match, 
    // OR we can use a known small model if available.
    // Actually, let's just test the logic by creating a file that DOES match one of our keys if we were to mock availableZenzaiModels.
    // Since availableZenzaiModels is static, we'll just test that it DOES NOT migrate if SHA doesn't match.
    
    QFile file(legacyPath);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("not a real model");
    file.close();
    
    ZenzaiModelManager::migrateLegacyModel();
    
    QFileInfo info(legacyPath);
    QVERIFY(info.exists());
    QVERIFY(!info.isSymLink()); // Should NOT have migrated
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
    // The legacy file should have been removed, and the existing model activated.
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
    QVERIFY(!info.isSymLink()); // Should NOT have migrated because existing managed file is mismatched
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
    
    // Delete inactive model
    QVERIFY(ZenzaiModelManager::deleteModel("model2"));
    QVERIFY(!QFile::exists(model2));
    QVERIFY(QFile::exists(ZenzaiModelManager::getSymlinkPath())); // Active remains
    
    // Delete active model
    QVERIFY(ZenzaiModelManager::deleteModel("model1"));
    QVERIFY(!QFile::exists(model1));
    QVERIFY(!QFile::exists(ZenzaiModelManager::getSymlinkPath())); // Symlink removed
}

void ZenzaiModelManagementTest::testExplicitActivation() {
    QDir().mkpath(ZenzaiModelManager::getModelsDir());
    QString model1 = ZenzaiModelManager::getModelPath("model1");
    QString model2 = ZenzaiModelManager::getModelPath("model2");
    
    QFile f1(model1); f1.open(QIODevice::WriteOnly); f1.write("m1"); f1.close();
    QFile f2(model2); f2.open(QIODevice::WriteOnly); f2.write("m2"); f2.close();
    
    // Activate model1
    QVERIFY(ZenzaiModelManager::activateModel("model1"));
    QCOMPARE(ZenzaiModelManager::getActiveModelKey(), QString("model1"));
    
    // Switch to model2
    QVERIFY(ZenzaiModelManager::activateModel("model2"));
    QCOMPARE(ZenzaiModelManager::getActiveModelKey(), QString("model2"));
    
    // Verify symlink target
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

void ZenzaiModelManagementTest::testJinenCatalogPresence() {
    // Failing-first probe: jinen-v2 families must be registered in the catalog.
    // 1. Families: exactly 5, in order.
    const QVector<ZenzaiModelFamily>& families = availableZenzaiModelFamilies();
    QCOMPARE(families.size(), 5);
    QCOMPARE(families[0].familyKey, QString("zenz-v3.2-small"));
    QCOMPARE(families[1].familyKey, QString("zenz-v3.2-xsmall"));
    QCOMPARE(families[2].familyKey, QString("zenz-v3.1-small"));
    QCOMPARE(families[3].familyKey, QString("jinen-v2-small"));
    QCOMPARE(families[4].familyKey, QString("jinen-v2-xsmall"));
    QCOMPARE(families[3].displayName, QString("jinen-v2-small"));
    QCOMPARE(families[4].displayName, QString("jinen-v2-xsmall"));

    // 2. Zenz single-variant families unchanged (byte-identical values).
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

    // 2b. Zenz families carry no attribution: the disclosure row is jinen-only.
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

    // 3. Flattened artifact catalog: exactly 11 entries in order.
    const QVector<ZenzaiModelOption>& models = availableZenzaiModels();
    QCOMPARE(models.size(), 11);
    QCOMPARE(models[0].key, QString("zenz-v3.2-small"));
    QCOMPARE(models[1].key, QString("zenz-v3.2-xsmall"));
    QCOMPARE(models[2].key, QString("zenz-v3.1-small"));

    // 4. Jinen families: 4 variants each in documented quant order.
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

    // 4b. Jinen families carry the CC-BY-SA-4.0 attribution the UI must disclose.
    // author + source repository + license name + clickable license/source URLs.
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

    // 4c. Every jinen variant URL lives under the family's attributed repository,
    // so the displayed source link is the artifact's actual origin.
    for (int i = 3; i < 5; ++i) {
        for (const ZenzaiModelOption& v : families[i].variants) {
            QVERIFY2(v.url.startsWith(families[i].sourceUrl + QString("/resolve/")),
                     qPrintable(QString("variant %1 must resolve from %2")
                                    .arg(v.key, families[i].sourceUrl)));
        }
    }

    // Table-driven check over every field; failure message names the key.
    // Also verifies uniqueness (no duplicate keys) and flattened order.
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
        // Family-local position: first 4 in small family, next 4 in xsmall.
        const ZenzaiModelOption& famVariant =
            (i < 4) ? families[3].variants[i] : families[4].variants[i - 4];
        QVERIFY2(famVariant.key == key,
                 qPrintable(QString("family order mismatch at index %1: got %2, want %3")
                                .arg(i).arg(famVariant.key, key)));
        QVERIFY2(famVariant.quantLabel == QString::fromLatin1(e.quant),
                 qPrintable(QString("quant label mismatch for %1: got %2, want %3")
                                .arg(key, famVariant.quantLabel, QString::fromLatin1(e.quant))));
        // Flattened catalog position: entries 3..10.
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

    // 5. Artifact lookup by key.
    const ZenzaiModelOption* found = findZenzaiModelByKey("jinen-v2-small-Q4_K_M");
    QVERIFY2(found != nullptr, "findZenzaiModelByKey must resolve jinen-v2-small-Q4_K_M");
    QCOMPARE(found->expectedBytes, qint64(72123008));
    QVERIFY(found->url.endsWith("/jinen-v2-small-Q4_K_M.gguf"));
    QCOMPARE(findZenzaiModelByKey("no-such-model-key"), nullptr);

    // 6. Family accessor stability: repeated calls return the same data.
    const QVector<ZenzaiModelFamily>& again = availableZenzaiModelFamilies();
    QCOMPARE(again.size(), families.size());
    QCOMPARE(again[4].variants.size(), 4);
    QCOMPARE(again[4].variants[2].key, QString("jinen-v2-xsmall-Q5_K_M"));
}

QTEST_MAIN(ZenzaiModelManagementTest)
#include "zenzai_model_management_test.moc"
