#include "zenzai_dialog_selection.h"

namespace {

/**
 * @brief 選択が指すカタログ上のモデルキーを返す
 * @return 範囲外なら空文字列
 */
QString selectionKey(const QVector<ZenzaiModelFamily>& families,
                     const ZenzaiDialogSelection& selection) {
    if (selection.familyIndex < 0 || selection.familyIndex >= families.size()) {
        return {};
    }

    const ZenzaiModelFamily& family = families.at(selection.familyIndex);
    if (selection.variantIndex < 0 || selection.variantIndex >= family.variants.size()) {
        return {};
    }

    return family.variants.at(selection.variantIndex).key;
}

}  // namespace

std::optional<ZenzaiDialogSelection> reconcileZenzaiDialogSelection(
    const QVector<ZenzaiModelFamily>& families,
    const QSet<QString>& downloadedKeys,
    const QString& deletedKey,
    const std::optional<ZenzaiDialogSelection>& checkedSelection,
    const QString& activeKey) {
    const bool checkedModelWasDeleted = checkedSelection.has_value() &&
                                        selectionKey(families, *checkedSelection) == deletedKey;
    const bool activeModelWasDeleted = !activeKey.isEmpty() && activeKey == deletedKey;

    // 削除がチェック中モデルにも有効化中モデルにも無関係なら、選択をそのまま維持する
    if (!checkedModelWasDeleted && !activeModelWasDeleted) {
        return checkedSelection;
    }

    if (checkedModelWasDeleted) {
        // チェック中の系列に残っている別バリアントをまず選ぶ
        const int familyIndex = checkedSelection->familyIndex;
        if (familyIndex >= 0 && familyIndex < families.size()) {
            const ZenzaiModelFamily& family = families.at(familyIndex);
            for (int variantIndex = 0; variantIndex < family.variants.size(); ++variantIndex) {
                const QString& candidateKey = family.variants.at(variantIndex).key;
                if (candidateKey != deletedKey && downloadedKeys.contains(candidateKey)) {
                    return ZenzaiDialogSelection{familyIndex, variantIndex};
                }
            }
        }
    }
    else if (checkedSelection.has_value()) {
        // 有効化中モデルだけが消えた場合は、残っているチェックを維持する
        return checkedSelection;
    }

    // フォールバック: カタログ順で最初のダウンロード済みバリアント
    for (int familyIndex = 0; familyIndex < families.size(); ++familyIndex) {
        const ZenzaiModelFamily& family = families.at(familyIndex);
        for (int variantIndex = 0; variantIndex < family.variants.size(); ++variantIndex) {
            if (downloadedKeys.contains(family.variants.at(variantIndex).key)) {
                return ZenzaiDialogSelection{familyIndex, variantIndex};
            }
        }
    }

    return std::nullopt;
}

bool isZenzaiSelectionActivatable(const QVector<ZenzaiModelFamily>& families,
                                  const QSet<QString>& downloadedKeys,
                                  const std::optional<ZenzaiDialogSelection>& selection) {
    if (!selection.has_value()) {
        return false;
    }

    const QString key = selectionKey(families, *selection);
    return !key.isEmpty() && downloadedKeys.contains(key);
}
