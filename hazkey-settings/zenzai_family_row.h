/**
 * @file zenzai_family_row.h
 * @brief モデル管理ダイアログの系列行ウィジェットを宣言する
 *
 * 単一バリアント系列 (zenz) と複数量子化系列 (jinen-v2) を同じ行ウィジェットで表し、
 * 選択中バリアントの決定とディスク状態の反映を1か所に集約する
 */

#ifndef ZENZAI_FAMILY_ROW_H
#define ZENZAI_FAMILY_ROW_H

#include <QComboBox>
#include <QLabel>
#include <QPushButton>
#include <QRadioButton>
#include <QString>
#include <QWidget>

#include "zenzai_models.h"

/**
 * @class ZenzaiFamilyRow
 * @brief Zenzaiモデル系列1件分の選択・ダウンロード・削除UIをまとめた行ウィジェット
 *
 * @details 単一バリアント系列では従来どおりラジオボタンとダウンロード/削除ボタンだけを提示し、
 *          複数バリアント系列では量子化を選ぶQComboBoxを追加する
 *          選択中のバリアントは常にartifact()が返し、ラジオボタン・ダウンロードボタン・削除ボタンの
 *          objectNameは選択中バリアントのキーに追従するため、キー起点の検索と互換である
 *          ダウンロード済みかどうかはZenzaiModelManager::isModelDownloadedに委譲し、
 *          ダイアログ表示中に変化したディスク状態はrefreshState()で再反映する
 *
 *          帰属情報 (author/licenseName/sourceUrl) を持つ系列では、説明の下に
 *          著作者・ライセンス・配布元へのリンクと「重みは同梱せず遠隔ダウンロードである」旨の
 *          帰属ラベルを追加する 帰属情報を持たない系列ではラベルを追加しない
 *
 *          コンストラクタに渡すfamilyは、このウィジェットより長く生存する必要がある
 *          (アプリケーションの固定カタログか、テスト側で保持した系列を想定する)
 */
class ZenzaiFamilyRow : public QWidget {
    Q_OBJECT

   public:
    /**
     * @brief 系列の行ウィジェットを構築する
     * @param family 表示対象の系列 このウィジェットより長く生存すること
     * @param parent 親ウィジェット、なければnullptr
     */
    explicit ZenzaiFamilyRow(const ZenzaiModelFamily& family, QWidget* parent = nullptr);

    /** @brief 表示対象の系列を返す */
    const ZenzaiModelFamily& family() const;
    /** @brief 現在束縛中のバリアントの系列内インデックスを返す */
    int variantIndex() const;
    /** @brief 現在束縛中のアーティファクトを返す */
    const ZenzaiModelOption& artifact() const;

    /** @brief 選択に使うラジオボタンを返す */
    QRadioButton* radioButton() const;
    /** @brief 量子化選択コンボを返す 単一バリアント系列ではnullptr */
    QComboBox* quantizationCombo() const;
    /** @brief ダウンロードボタンを返す */
    QPushButton* downloadButton() const;
    /** @brief 削除ボタンを返す */
    QPushButton* deleteButton() const;
    /** @brief 帰属表示ラベルを返す 帰属情報を持たない系列ではnullptr */
    QLabel* attributionLabel() const;

    /** @brief 系列が複数の量子化バリアントを持つかどうかを返す */
    bool multiVariant() const;
    /** @brief 束縛中アーティファクトが最後にrefreshState()へ渡されたアクティブモデルかどうかを返す */
    bool artifactIsActive() const;
    /** @brief 束縛中アーティファクトがディスク上に存在しSHA256が一致するかどうかを返す */
    bool artifactIsDownloaded() const;

    /**
     * @brief 束縛するバリアントを切り替える
     *
     * @details 範囲外の値は最寄りのバリアントへ丸める
     *          実際に変化した場合だけboundVariantChangedを発行する
     *
     * @param index 系列内のバリアントインデックス
     */
    void setVariantIndex(int index);

    /**
     * @brief ディスク状態とダウンロード状態からこの行の表示と有効状態を再計算する
     *
     * @details ダウンロード済みのバリアントだけがラジオボタンと削除ボタンを使え、
     *          未ダウンロードのバリアントはダウンロードボタンだけを使える
     *          ラジオボタンのチェック状態は変更しない (選択はダイアログが所有する)
     *
     * @param downloadInProgress ダウンロード中ならtrue (全操作を無効化する)
     * @param activeKey 現在アクティブなモデルのキー 空でもよい
     */
    void refreshState(bool downloadInProgress, const QString& activeKey);

   signals:
    /** @brief 束縛中アーティファクトのダウンロードが要求された */
    void downloadRequested(const QString& key);
    /** @brief 束縛中アーティファクトの削除が要求された */
    void deleteRequested(const QString& key);
    /** @brief 束縛するバリアントが変更された */
    void boundVariantChanged(const QString& key);

   private:
    /** @brief objectName、コンボ選択、表示状態を現在のバリアントへ反映する */
    void applyBoundVariant();

    /** @brief 表示対象の系列への参照 呼び出し側が寿命を保証する */
    const ZenzaiModelFamily& family_;
    /** @brief 現在束縛中のバリアントインデックス */
    int variantIndex_;
    /** @brief 最後にrefreshState()へ渡されたアクティブモデルキー */
    QString activeKey_;
    /** @brief 最後にrefreshState()へ渡されたダウンロード中フラグ */
    bool downloadInProgress_;
    /** @brief コンボのcurrentIndexChangedによる再入を防ぐガード */
    bool updatingCombo_;
    /** @brief 系列選択用ラジオボタン */
    QRadioButton* radio_;
    /** @brief 量子化選択コンボ 単一バリアント系列ではnullptr */
    QComboBox* quantizationCombo_;
    /** @brief ダウンロード操作用ボタン */
    QPushButton* downloadButton_;
    /** @brief 削除操作用ボタン */
    QPushButton* deleteButton_;
    /** @brief 系列の説明を表示するラベル */
    QLabel* descriptionLabel_;
    /** @brief 帰属・ライセンス・配布元を表示するラベル 帰属情報を持たない系列ではnullptr */
    QLabel* attributionLabel_;
};

#endif  // ZENZAI_FAMILY_ROW_H
