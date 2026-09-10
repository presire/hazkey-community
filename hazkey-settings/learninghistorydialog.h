/**
 * @file learninghistorydialog.h
 * @brief 入力履歴を検索して選択削除するダイアログの宣言
 *
 * 現在の検索条件に対応する履歴をページ単位で表示し、
 * 表記単位のキーをServerConnectorへ渡して削除するQtダイアログを定義する
 */

#ifndef LEARNINGHISTORYDIALOG_H
#define LEARNINGHISTORYDIALOG_H

#include <QDialog>
#include <cstdint>
#include <string>
#include <vector>
#include "serverconnector.h"

class QDialogButtonBox;
class QLabel;
class QLineEdit;
class QPushButton;
class QTableWidget;

/**
 * @brief 入力履歴ダイアログが操作するプロファイルと履歴モード
 */
struct LearningHistoryDialogTarget {
    /** @brief 学習履歴 RPC に渡す対象プロファイルの識別子 */
    std::string profileId;
    /** @brief プロファイル独立履歴を使用する設定かどうか */
    bool useProfileIndependentHistory = false;
};

/**
 * @class LearningHistoryDialog
 * @brief 入力履歴をページング表示し、選択した表記を削除するモーダルダイアログ
 *
 * server_は、呼び出し元が所有する非所有ポインタであり、
 * このダイアログはServerConnectorを破棄しないため、ダイアログより長く有効である必要がある
 *
 * target_は、値として保持され、各RPCのプロファイル識別子と表示モードに使う
 *
 * ウィジェットはすべてこのダイアログを親にして生成されるため、Qtの親子所有権で管理される
 *
 * entries_は、現在ページの行データだけを保持し、ページ再読込時に置き換える
 *
 * 削除キーは読みと表記だけを持ち、同じ表記に統合されたCID別エントリをまとめて削除する
 */
class LearningHistoryDialog : public QDialog {
    Q_OBJECT

   public:
    /**
     * @brief 入力履歴ダイアログを構築して最初のページを取得する
     *
     * 検索欄、履歴表、ページング操作、削除操作を初期化し、コンストラクタ末尾で現在の検索欄と先頭オフセットを使って履歴を取得する
     * 取得に失敗した場合は警告を表示し、サーバ側の変更は行わない
     *
     * @param server 呼び出し元が所有する非所有のRPCコネクター
     * @param target 操作対象プロファイルと履歴モード
     * @param parent Qtの親ウィジェット。所有権を持つ場合はダイアログ破棄時に破棄される
     */
    LearningHistoryDialog(ServerConnector* server,
                          LearningHistoryDialogTarget target,
                          QWidget* parent = nullptr);

   private slots:
    /** @brief 検索欄の値で検索し、ページ位置を先頭へ戻して再読込する */
    void onSearch();
    /** @brief 前ページへ移動し、先頭を超えない範囲で現在ページを再読込する */
    void onPreviousPage();
    /** @brief 次ページがある場合だけ移動し、現在ページを再読込する */
    void onNextPage();
    /**
     * @brief 現在ページで選択された行を確認後に削除する
     *
     * 選択がなければ警告を表示し、確認を拒否した場合は何もしない
     * 削除RPCが失敗した場合は警告だけを表示し、成功した場合は現在の検索条件で再読込して削除件数を通知する
     */
    void onDeleteSelected();

   private:
    /** @brief 1回の履歴取得で表示する最大行数
     *         サーバの上限と同じ200件
     */
    static constexpr uint32_t kPageLimit = 200;

    /**
     * @brief 現在の検索条件とページ位置で履歴を取得する
     *
     * 通信失敗時は警告を表示して現在の表を維持する
     * オフセットが結果の末尾を越えた場合は最終ページへ補正して再試行し、成功時は現在ページの行を更新する
     */
    void reloadPage();
    /**
     * @brief RPC結果から現在ページの行とページ操作状態を再構築する
     *
     * entries_と総件数を結果で置き換え、表の各行を作り直してからページ表示を更新する
     *
     * @param result 現在の検索条件とページ位置に対応する履歴結果
     */
    void populateTable(const hazkey::config::GetLearningHistoryResult& result);
    /**
     * @brief 現在ページでチェックされた行から削除キーを作る
     *
     * キーにはreadingとwordだけを設定するため、
     * CIDは公開せず同じ読みと表記を持つ統合済みの全バリエーションが削除対象になる
     *
     * @return チェック済み行の表記単位削除キー
     */
    std::vector<hazkey::config::LearningEntryKey> checkedEntries() const;
    /** @brief 現在位置、総件数、前後ボタン、削除ボタンの表示状態を更新する */
    void updatePagination();

    /** @brief 呼び出し元が所有し、このダイアログより長く有効であるRPCコネクター (非所有) */
    ServerConnector* server_;
    /** @brief RPC対象プロファイルと履歴モードの値保持 */
    LearningHistoryDialogTarget target_;
    /** @brief 履歴モードを表示するラベル。Qtの親子所有権で管理 */
    QLabel* modeLabel_ = nullptr;
    /** @brief 検索文字列を編集する入力欄。Qtの親子所有権で管理 */
    QLineEdit* searchEdit_ = nullptr;
    /** @brief 検索を開始するボタン。Qtの親子所有権で管理 */
    QPushButton* searchButton_ = nullptr;
    /** @brief 現在ページの履歴行を表示する表。Qtの親子所有権で管理 */
    QTableWidget* historyTable_ = nullptr;
    /** @brief 前ページへ移動するボタン。Qtの親子所有権で管理 */
    QPushButton* previousPageButton_ = nullptr;
    /** @brief 次ページへ移動するボタン。Qtの親子所有権で管理 */
    QPushButton* nextPageButton_ = nullptr;
    /** @brief 現在の表示範囲と総件数を表示するラベル。Qtの親子所有権で管理 */
    QLabel* paginationLabel_ = nullptr;
    /** @brief 選択行の削除を開始するボタン。Qtの親子所有権で管理 */
    QPushButton* deleteButton_ = nullptr;
    /** @brief ダイアログを閉じるボタン箱。Qtの親子所有権で管理 */
    QDialogButtonBox* buttonBox_ = nullptr;
    /** @brief 現在ページに表示中の履歴行。サーバからのページ再取得で置き換える */
    std::vector<hazkey::config::LearningHistoryEntry> entries_;
    /** @brief 現在ページのゼロ始まり取得オフセット。検索時は0に戻る */
    uint32_t offset_ = 0;
    /** @brief 現在の検索条件に一致する履歴の総件数 */
    uint32_t totalCount_ = 0;
};

#endif  // LEARNINGHISTORYDIALOG_H
