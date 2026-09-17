#ifndef ZENZAI_DIALOG_SELECTION_H
#define ZENZAI_DIALOG_SELECTION_H

#include <optional>

#include <QSet>
#include <QVector>

#include "zenzai_models.h"

/**
 * @brief ニューラル変換モデル管理ダイアログでチェック中の系列/バリアント
 */
struct ZenzaiDialogSelection {
    int familyIndex;
    int variantIndex;
};

/**
 * @brief モデル削除後にチェックすべき系列/バリアントを解決する
 *
 * @details
 * チェック中モデル、または有効化中モデルが削除されたときだけ選択を選び直す。
 * それ以外の削除では現在の選択を維持する。チェック中モデルが消えた場合は、
 * まず同一系列の残存バリアント、次にカタログ順で最初のダウンロード済み
 * バリアントへフォールバックする。
 *
 * @param families ダイアログの行と同じ順序の系列カタログ
 * @param downloadedKeys 削除反映後のダウンロード済みキー集合
 * @param deletedKey 削除されたモデルのキー
 * @param checkedSelection 削除前にチェックされていた選択。未チェックはnullopt
 * @param activeKey 削除前に有効化されていたモデルのキー。無効時は空文字列
 * @return チェックすべき選択。チェックを外す場合はnullopt
 */
std::optional<ZenzaiDialogSelection> reconcileZenzaiDialogSelection(
    const QVector<ZenzaiModelFamily>& families,
    const QSet<QString>& downloadedKeys,
    const QString& deletedKey,
    const std::optional<ZenzaiDialogSelection>& checkedSelection,
    const QString& activeKey);

/**
 * @brief チェック中の選択が有効化可能かどうかを判定する
 *
 * @details 選択が存在し、その系列/バリアントがカタログ内にあり、
 * かつダウンロード済みである場合のみtrueを返す。OKボタンの活性条件と
 * 同一の判定をUI非依存に切り出したもの。
 *
 * @param families 系列カタログ
 * @param downloadedKeys ダウンロード済みキー集合
 * @param selection 判定対象の選択。未チェックはnullopt
 * @return 有効化可能ならtrue
 */
bool isZenzaiSelectionActivatable(const QVector<ZenzaiModelFamily>& families,
                                  const QSet<QString>& downloadedKeys,
                                  const std::optional<ZenzaiDialogSelection>& selection);

#endif  // ZENZAI_DIALOG_SELECTION_H
