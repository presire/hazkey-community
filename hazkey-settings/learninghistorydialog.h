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
#include <optional>
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

   protected:
    /**
     * @brief サーバ呼び出しの待機中は、閉じる操作を無視する
     *
     * 待機中に破棄されると、呼び出し元のメンバー参照が無効になるため、
     * 待機が終わるまでEscキーやウィンドウの閉じるボタンによる終了を保留する
     */
    void reject() override;

   private slots:
    /** @brief 検索欄の値で、先頭ページを取得する。サーバ呼び出しの待機中は何もしない */
    void onSearch();
    /** @brief 表示中の検索条件で、先頭を超えない範囲の前ページを取得する。待機中は何もしない */
    void onPreviousPage();
    /** @brief 表示中の検索条件で、次ページがある場合だけ取得する。待機中は何もしない */
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
     * @brief 指定した検索条件とページ位置で履歴を取得する
     *
     * 待機中は検索欄・検索ボタン・履歴表・ページ移動・削除の操作を無効にする
     * 取得に成功した時だけquery_とoffset_を更新して現在ページの行を置き換えるため、
     * 通信失敗・他の呼び出しの実行中・終了中は、表示中の行とページ表示、以後のページ移動の基準を変えない
     * 通信失敗時は警告を表示する
     * オフセットが結果の末尾を越えた場合は最終ページへ補正して再試行する
     *
     * @param query 検索文字列
     * @param offset ゼロ始まりの取得オフセット
     */
    void reloadPage(const std::string& query, uint32_t offset);
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
    /** @brief 表示中のページを取得した検索文字列。前後のページ移動と削除後の再読込に使う */
    std::string query_;
    /** @brief 表示中のページのゼロ始まり取得オフセット。取得に成功した時だけ更新する */
    uint32_t offset_ = 0;
    /** @brief 現在の検索条件に一致する履歴の総件数 */
    uint32_t totalCount_ = 0;
    /** @brief サーバ呼び出しの待機中に増えるカウンタ。0より大きい間は閉じる操作を保留する */
    int busyDepth_ = 0;
};

#endif  // LEARNINGHISTORYDIALOG_H
