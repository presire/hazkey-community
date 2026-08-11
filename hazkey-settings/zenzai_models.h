#ifndef ZENZAI_MODELS_H
#define ZENZAI_MODELS_H

#include <QString>
#include <QVector>
#include <QDir>
#include <QFile>
#include <QCryptographicHash>

struct ZenzaiModelOption {
    QString key;
    QString displayName;
    QString description;
    QString url;
    QString sha256;
    QString sizeDisplay;
    bool recommended;
    bool isLegacyGen;
};

const QVector<ZenzaiModelOption>& availableZenzaiModels();

class ZenzaiModelManager {
public:
    static QString getZenzaiDir();
    static QString getModelsDir();
    static QString getSymlinkPath();
    static QString getModelPath(const QString& key);
    
    static QString calculateSHA256(const QString& filePath);
    static bool isModelDownloaded(const ZenzaiModelOption& model);
    
    static bool activateModel(const QString& key);
    static bool deactivateModel();
    static bool deleteModel(const QString& key);
    
    static void migrateLegacyModel();
    static void migrateLegacyModel(const QVector<ZenzaiModelOption>& catalog);
    
    static QString getActiveModelKey();

    static QString formatModelLabel(const ZenzaiModelOption& model, bool downloaded);
};

#endif // ZENZAI_MODELS_H
