#include "zenzai_models.h"
#include <QCoreApplication>
#include <QFileInfo>

const QVector<ZenzaiModelOption>& availableZenzaiModels() {
    static const QVector<ZenzaiModelOption> options = {
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
    };
    return options;
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
