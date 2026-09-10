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

QTEST_MAIN(ZenzaiModelManagementTest)
#include "zenzai_model_management_test.moc"
