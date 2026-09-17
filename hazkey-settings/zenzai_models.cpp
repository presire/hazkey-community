/**
 * @file zenzai_models.cpp
 * @brief Zenzaiモデルカタログとローカル管理処理の実装
 *
 * 固定カタログのメタデータを提供し、XDGのデータディレクトリ配下で
 * 管理対象モデルとアクティブモデル用シンボリックリンクを操作する
 */

#include "zenzai_models.h"
#include <QCoreApplication>
#include <QFileInfo>

const QVector<ZenzaiModelFamily>& availableZenzaiModelFamilies() {
    /**
     * @brief アプリケーションが提供する固定モデル系列カタログ
     *
     * @details 各エントリのURL、SHA256、表示サイズ、推奨フラグ、旧世代フラグ、期待バイト数は
     *          アプリケーションデータ契約の一部であり、実行時には変更されない
     *          先頭3件は単一バリアントのzenz系列 (推奨の現行small、小容量のxsmall、旧世代small) であり、
     *          末尾2件はjinen-v2 small/xsmall系列 (各4量子化バリアント) である
     *          zenz系列のexpectedBytesは0 (未知) で従来の動作を保つ
     *          zenz系列の帰属フィールド (author/sourceUrl/licenseName/licenseUrl) は空のままで、
     *          帰属を要求するjinen系列のみtogatogahとCC-BY-SA-4.0の情報を保持する
     */
    static const QVector<ZenzaiModelFamily> families = {
        /** @brief 推奨される現行small系列 (単一バリアント、約74[MB]) */
        {
            QStringLiteral("zenz-v3.2-small"),
            QStringLiteral("zenz-v3.2-small"),
            QCoreApplication::translate("MainWindow",
                              "Recommended: Latest version. Best conversion accuracy."),
            {
                {
                    QStringLiteral("zenz-v3.2-small"),
                    QStringLiteral("zenz-v3.2-small (Q5_K_M)"),
                    QCoreApplication::translate("MainWindow",
                                      "Recommended: Latest version. Best conversion accuracy."),
                    QStringLiteral(
                        "https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/resolve/"
                        "main/ggml-model-Q5_K_M.gguf"),
                    QStringLiteral(
                        "29c223d4c23327b80fd13ebb5ab2555057a46317997d5da391584ffbef0db"
                        "673"),
                    QStringLiteral("~74 MB"),
                    true,
                    false,
                },
            },
        },
        /** @brief 小容量でCPU上の高速動作を意図したxsmall系列 (単一バリアント、約21[MB]) */
        {
            QStringLiteral("zenz-v3.2-xsmall"),
            QStringLiteral("zenz-v3.2-xsmall"),
            QCoreApplication::translate("MainWindow",
                              "Smaller size. Faster on CPU, slightly lower accuracy."),
            {
                {
                    QStringLiteral("zenz-v3.2-xsmall"),
                    QStringLiteral("zenz-v3.2-xsmall (Q5_K_M)"),
                    QCoreApplication::translate("MainWindow",
                                      "Smaller size. Faster on CPU, slightly lower accuracy."),
                    QStringLiteral(
                        "https://huggingface.co/Miwa-Keita/zenz-v3.2-xsmall-gguf/resolve/"
                        "main/ggml-model-Q5_K_M.gguf"),
                    QStringLiteral(
                        "00c64b3d318045a708d0cad5434faccab10f5481a49e6362864551fd0995fa"
                        "58"),
                    QStringLiteral("~21 MB"),
                    false,
                    false,
                },
            },
        },
        /** @brief 旧世代との互換性を担うsmall系列 (単一バリアント、約74[MB]) */
        {
            QStringLiteral("zenz-v3.1-small"),
            QStringLiteral("zenz-v3.1-small"),
            QCoreApplication::translate("MainWindow",
                              "Previous version. Legacy compatibility."),
            {
                {
                    QStringLiteral("zenz-v3.1-small"),
                    QStringLiteral("zenz-v3.1-small (Q5_K_M)"),
                    QCoreApplication::translate("MainWindow",
                                      "Previous version. Legacy compatibility."),
                    QStringLiteral(
                        "https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf/resolve/"
                        "main/ggml-model-Q5_K_M.gguf"),
                    QStringLiteral(
                        "4de930c06bef8c263aa1aa40684af206db4ce1b96375b3b8ed0ea508e0b14f"
                        "6c"),
                    QStringLiteral("~74 MB"),
                    false,
                    true,
                },
            },
        },
        /** @brief jinen-v2 small系列 (4量子化バリアント) */
        {
            QStringLiteral("jinen-v2-small"),
            QStringLiteral("jinen-v2-small"),
            QCoreApplication::translate("MainWindow",
                              "Jinen v2 small model. Choose a quantization."),
            {
                {
                    QStringLiteral("jinen-v2-small-f16"),
                    QStringLiteral("jinen-v2-small (f16)"),
                    QCoreApplication::translate("MainWindow",
                                      "Jinen v2 small model. Choose a quantization."),
                    QStringLiteral(
                        "https://huggingface.co/togatogah/jinen-v2-small.gguf/resolve/"
                        "main/jinen-v2-small-f16.gguf"),
                    QStringLiteral(
                        "904c40debcf04e6189d63c046425051bfa4c999ca22962c50dd01a7776af6820"),
                    QStringLiteral("~210 MB"),
                    false,
                    false,
                    219865856,
                    QStringLiteral("f16"),
                },
                {
                    QStringLiteral("jinen-v2-small-Q8_0"),
                    QStringLiteral("jinen-v2-small (Q8_0)"),
                    QCoreApplication::translate("MainWindow",
                                      "Jinen v2 small model. Choose a quantization."),
                    QStringLiteral(
                        "https://huggingface.co/togatogah/jinen-v2-small.gguf/resolve/"
                        "main/jinen-v2-small-Q8_0.gguf"),
                    QStringLiteral(
                        "215fe5a513fffdc7c9570a8bf1ad45439d80dc7db2b2f43a1c55f28ffc9fba99"),
                    QStringLiteral("~112 MB"),
                    false,
                    false,
                    117197472,
                    QStringLiteral("Q8_0"),
                },
                {
                    QStringLiteral("jinen-v2-small-Q5_K_M"),
                    QStringLiteral("jinen-v2-small (Q5_K_M)"),
                    QCoreApplication::translate("MainWindow",
                                      "Jinen v2 small model. Choose a quantization."),
                    QStringLiteral(
                        "https://huggingface.co/togatogah/jinen-v2-small.gguf/resolve/"
                        "main/jinen-v2-small-Q5_K_M.gguf"),
                    QStringLiteral(
                        "80482707513d6b67dafc31774371cf95d765542abf8d74eebf5f32f92d788bd3"),
                    QStringLiteral("~77 MB"),
                    false,
                    false,
                    81117824,
                    QStringLiteral("Q5_K_M"),
                },
                {
                    QStringLiteral("jinen-v2-small-Q4_K_M"),
                    QStringLiteral("jinen-v2-small (Q4_K_M)"),
                    QCoreApplication::translate("MainWindow",
                                      "Jinen v2 small model. Choose a quantization."),
                    QStringLiteral(
                        "https://huggingface.co/togatogah/jinen-v2-small.gguf/resolve/"
                        "main/jinen-v2-small-Q4_K_M.gguf"),
                    QStringLiteral(
                        "26a6a71020a8d12908615d6ed2541ad6d6d9b73fc179d8d5472eb1c709bb1300"),
                    QStringLiteral("~69 MB"),
                    false,
                    false,
                    72123008,
                    QStringLiteral("Q4_K_M"),
                },
            },
            QStringLiteral("togatogah"),
            QStringLiteral("https://huggingface.co/togatogah/jinen-v2-small.gguf"),
            QStringLiteral("CC-BY-SA-4.0"),
            QStringLiteral("https://creativecommons.org/licenses/by-sa/4.0/"),
        },
        /** @brief jinen-v2 xsmall系列 (4量子化バリアント) */
        {
            QStringLiteral("jinen-v2-xsmall"),
            QStringLiteral("jinen-v2-xsmall"),
            QCoreApplication::translate("MainWindow",
                              "Jinen v2 xsmall model. Choose a quantization."),
            {
                {
                    QStringLiteral("jinen-v2-xsmall-f16"),
                    QStringLiteral("jinen-v2-xsmall (f16)"),
                    QCoreApplication::translate("MainWindow",
                                      "Jinen v2 xsmall model. Choose a quantization."),
                    QStringLiteral(
                        "https://huggingface.co/togatogah/jinen-v2-xsmall.gguf/resolve/"
                        "main/jinen-v2-xsmall-f16.gguf"),
                    QStringLiteral(
                        "1010735eed3794d116d572edc51080abb0e1a59c94bc6f6865429637f4d6f7f3"),
                    QStringLiteral("~69 MB"),
                    false,
                    false,
                    72089024,
                    QStringLiteral("f16"),
                },
                {
                    QStringLiteral("jinen-v2-xsmall-Q8_0"),
                    QStringLiteral("jinen-v2-xsmall (Q8_0)"),
                    QCoreApplication::translate("MainWindow",
                                      "Jinen v2 xsmall model. Choose a quantization."),
                    QStringLiteral(
                        "https://huggingface.co/togatogah/jinen-v2-xsmall.gguf/resolve/"
                        "main/jinen-v2-xsmall-Q8_0.gguf"),
                    QStringLiteral(
                        "bc75a02512bdbb2a4786fec281a57d4d58ac3c2f118c3a29c2a9b41f2a4898b7"),
                    QStringLiteral("~37 MB"),
                    false,
                    false,
                    38664224,
                    QStringLiteral("Q8_0"),
                },
                {
                    QStringLiteral("jinen-v2-xsmall-Q5_K_M"),
                    QStringLiteral("jinen-v2-xsmall (Q5_K_M)"),
                    QCoreApplication::translate("MainWindow",
                                      "Jinen v2 xsmall model. Choose a quantization."),
                    QStringLiteral(
                        "https://huggingface.co/togatogah/jinen-v2-xsmall.gguf/resolve/"
                        "main/jinen-v2-xsmall-Q5_K_M.gguf"),
                    QStringLiteral(
                        "24ff3af5db712fbbb4aa9254ee28ec4d731207134471ab68b06c1828726284c2"),
                    QStringLiteral("~27 MB"),
                    false,
                    false,
                    28261056,
                    QStringLiteral("Q5_K_M"),
                },
                {
                    QStringLiteral("jinen-v2-xsmall-Q4_K_M"),
                    QStringLiteral("jinen-v2-xsmall (Q4_K_M)"),
                    QCoreApplication::translate("MainWindow",
                                      "Jinen v2 xsmall model. Choose a quantization."),
                    QStringLiteral(
                        "https://huggingface.co/togatogah/jinen-v2-xsmall.gguf/resolve/"
                        "main/jinen-v2-xsmall-Q4_K_M.gguf"),
                    QStringLiteral(
                        "1783be74e4bf0eaadcd6f217ec6dea06cecb0833b94c24b417b93d93fbe01d4e"),
                    QStringLiteral("~25 MB"),
                    false,
                    false,
                    26278592,
                    QStringLiteral("Q4_K_M"),
                },
            },
            QStringLiteral("togatogah"),
            QStringLiteral("https://huggingface.co/togatogah/jinen-v2-xsmall.gguf"),
            QStringLiteral("CC-BY-SA-4.0"),
            QStringLiteral("https://creativecommons.org/licenses/by-sa/4.0/"),
        },
    };
    return families;
}

const QVector<ZenzaiModelOption>& availableZenzaiModels() {
    /**
     * @brief 系列カタログを平坦化したアーティファクト一覧
     *
     * @details availableZenzaiModelFamilies()の各系列のvariantsを順に連結したもので、
     *          従来の呼び出し側 (mainwindow.cpp等) との互換性を保つ
     *          先頭3件はzenz単一バリアントで従来と同一の順序・値である
     */
    static const QVector<ZenzaiModelOption> options = []() {
        QVector<ZenzaiModelOption> flat;
        for (const auto& family : availableZenzaiModelFamilies()) {
            flat += family.variants;
        }
        return flat;
    }();
    return options;
}

const ZenzaiModelOption* findZenzaiModelByKey(const QString& key) {
    for (const auto& m : availableZenzaiModels()) {
        if (m.key == key) {
            return &m;
        }
    }
    return nullptr;
}

QString ZenzaiModelManager::getZenzaiDir() {
    QString dataHome = qEnvironmentVariable("XDG_DATA_HOME");
    if (dataHome.isEmpty()) {
        dataHome = QDir::homePath() + "/.local/share";
    }
    return dataHome + "/hazkey/zenzai";
}

QString ZenzaiModelManager::getModelsDir() {
    return getZenzaiDir() + "/models";
}

QString ZenzaiModelManager::getSymlinkPath() {
    return getZenzaiDir() + "/zenzai.gguf";
}

QString ZenzaiModelManager::getModelPath(const QString& key) {
    return getModelsDir() + "/" + key + ".gguf";
}

QString ZenzaiModelManager::calculateSHA256(const QString& filePath) {
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) {
        return QString();
    }

    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file)) {
        file.close();
        return QString();
    }

    file.close();
    return QString(hash.result().toHex());
}

bool ZenzaiModelManager::isModelDownloaded(const ZenzaiModelOption& model) {
    QString path = getModelPath(model.key);
    if (!QFile::exists(path)) {
        return false;
    }
    return calculateSHA256(path).compare(model.sha256, Qt::CaseInsensitive) == 0;
}

bool ZenzaiModelManager::activateModel(const QString& key) {
    QString target = getModelPath(key);
    if (!QFile::exists(target)) {
        return false;
    }

    QString link = getSymlinkPath();
    QFileInfo info(link);
    // Use isSymLink() to handle dangling symlinks.
    if (info.isSymLink()) {
        if (!QFile::remove(link)) {
            return false;
        }
    } else if (info.exists()) {
        // Never replace a regular legacy/custom file implicitly.
        return false;
    }

    QDir().mkpath(getZenzaiDir());
    return QFile::link(target, link);
}

bool ZenzaiModelManager::deactivateModel() {
    QString link = getSymlinkPath();
    QFileInfo info(link);
    // Use isSymLink() to handle dangling symlinks.
    if (info.isSymLink()) {
        return QFile::remove(link);
    }
    // If it's a regular file, we don't deactivate it here to avoid accidental deletion
    // of custom models. deactivateModel is intended for managed symlinks.
    return !info.exists();
}

bool ZenzaiModelManager::deleteModel(const QString& key) {
    QString path = getModelPath(key);
    if (!QFile::exists(path)) {
        return false;
    }

    // If this model is active, remove the symlink first
    if (getActiveModelKey() == key) {
        deactivateModel();
    }

    return QFile::remove(path);
}

void ZenzaiModelManager::migrateLegacyModel() {
    migrateLegacyModel(availableZenzaiModels());
}

void ZenzaiModelManager::migrateLegacyModel(
    const QVector<ZenzaiModelOption>& models) {
    QString legacyPath = getSymlinkPath();
    QFileInfo info(legacyPath);
    if (!info.exists() || info.isSymLink()) {
        return;
    }

    // It's a regular file. Check if it matches any known model.
    QString sha = calculateSHA256(legacyPath);
    if (sha.isEmpty()) return;

    for (const auto& m : models) {
        if (m.sha256.compare(sha, Qt::CaseInsensitive) == 0) {
            // Match found! Move it to models/ and symlink it.
            QDir().mkpath(getModelsDir());
            QString newPath = getModelPath(m.key);
            if (QFile::exists(newPath)) {
                // Duplicate found in models/. 
                // ONLY remove the legacy file if the existing managed file's SHA256 also matches.
                QString existingSha = calculateSHA256(newPath);
                if (existingSha.compare(m.sha256, Qt::CaseInsensitive) == 0) {
                    if (QFile::remove(legacyPath)) {
                        activateModel(m.key);
                    }
                } else {
                    // Corrupt/mismatched existing managed file.
                    // Leave legacy zenzai.gguf intact and return.
                    return;
                }
            } else {
                if (QFile::rename(legacyPath, newPath)) {
                    activateModel(m.key);
                }
            }
            return;
        }
    }
    // If no match, we leave it alone as per "unknown custom files are never deleted or overwritten without an explicit GUI confirmation"
}

QString ZenzaiModelManager::getActiveModelKey() {
    QString link = getSymlinkPath();
    QFileInfo info(link);
    if (!info.exists() || !info.isSymLink()) {
        return QString();
    }

    QString target = info.symLinkTarget();
    QFileInfo targetInfo(target);
    QString filename = targetInfo.fileName();
    if (filename.endsWith(".gguf")) {
        return filename.left(filename.length() - 5);
    }
    return QString();
}

QString ZenzaiModelManager::formatModelLabel(const ZenzaiModelOption& model, bool downloaded) {
    QString radioText = model.displayName;
    if (model.recommended) {
        radioText = QCoreApplication::translate("MainWindow", "Recommended: %1").arg(model.displayName);
    }
    if (downloaded) {
        radioText += QCoreApplication::translate("MainWindow", " (downloaded)");
    }
    return QString("%1 : %2").arg(radioText, model.sizeDisplay);
}
