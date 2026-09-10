#include <QApplication>
#include <QLocale>
#include <QLibraryInfo>
#include <QTranslator>
#include "mainwindow.h"

/**
 * @file main.cpp
 * @brief hazkey-settingsアプリケーションの起動処理を定義する
 *
 * Qt標準翻訳とリソースに埋め込んだアプリケーション翻訳を優先言語順に導入してからMainWindowを表示し、
 * Qtのイベントループへ制御を渡す
 */

/**
 * @brief hazkey-settingsを初期化してイベントループを実行する
 *
 * QApplicationを生成後、標準ウィジェット用のqtbase翻訳と、
 * `:/i18n` に埋め込まれたアプリケーション翻訳を読み込む利用可能な最初のUIロケールを採用してMainWindowを表示し、
 * イベントループの終了コードをそのまま返す
 *
 * @param argc コマンドライン引数の個数
 * @param argv コマンドライン引数の配列
 * @return QApplication のイベントループが返した終了コード
 */
int main(int argc, char *argv[]) {
    QApplication a(argc, argv);

    // Load Qt base translations for standard widgets (e.g., file dialogs)
    QTranslator qtTranslator;
    if (qtTranslator.load(QLocale::system(), "qtbase", "_",
                          QLibraryInfo::path(QLibraryInfo::TranslationsPath))) {
        a.installTranslator(&qtTranslator);
    }

    // Load application translations embedded in resources (:/i18n)
    QTranslator appTranslator;
    const QStringList uiLanguages = QLocale::system().uiLanguages();
    for (const QString &locale : uiLanguages) {
        const QString baseName = "hazkey-settings_" + QLocale(locale).name();
        if (appTranslator.load(":/i18n/" + baseName)) {
            a.installTranslator(&appTranslator);
            break;
        }
    }

    MainWindow w;
    w.show();
    return a.exec();
}
