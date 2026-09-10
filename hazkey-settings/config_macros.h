/**
 * @file config_macros.h
 * @brief Qtウィジェットと設定値の読み書きを補助するマクロ
 * @note マクロは呼び出し側のUIウィジェットを直接変更または参照する
 */
#ifndef CONFIG_MACROS_H
#define CONFIG_MACROS_H

#include <QtCore>

/**
 * @briefenum値をQComboBoxの選択インデックスへ設定する
 * @param ui_element 操作対象のQComboBox式
 * @param enum_value 変換元のenum値
 * @param default_index 対応するcaseがない場合に使うインデックス
 * @param ...enum値とインデックスを対応付ける ENUM_CASE 群
 * @note ui_elementの現在の選択をsetCurrentIndex()で変更する
 */
#define SET_COMBO(ui_element, enum_value, default_index, ...) \
    do {                                                      \
        int index = default_index;                            \
        switch (enum_value) { __VA_ARGS__ }                   \
        ui_element->setCurrentIndex(index);                   \
    } while (0)

/**
 * @brief QComboBoxの選択インデックスをenum値へ変換する
 * @param ui_element 読み取り対象のQComboBox式
 * @param enum_type ラムダが返すenum型 (protobuf enum adapter型)
 * @param default_enum 対応するcaseがない場合に返す値
 * @param ... インデックスとenum値を対応付けるINDEX_CASE群
 * @return 対応するenum値、またはdefault_enum
 * @note QComboBoxのcurrentIndex()を読み取るだけで、UIは変更しない
 */
#define GET_COMBO_ENUM(ui_element, enum_type, default_enum, ...) \
    [&]() -> enum_type {                                         \
        int idx = ui_element->currentIndex();                    \
        switch (idx) { __VA_ARGS__ }                             \
        return default_enum;                                     \
    }()

/**
 * @brief 真偽値をQCheckBoxのチェック状態へ設定する
 * @param ui_element 操作対象のQCheckBox式
 * @param bool_value Qt::Checked または Qt::Uncheckedに変換する真偽値
 * @param default_value 互換性のための引数で、現在のマクロ本体では評価されない
 * @note ui_elementの状態をsetCheckState()で変更する
 */
#define SET_CHECKBOX(ui_element, bool_value, default_value) \
    ui_element->setCheckState((bool_value) ? Qt::Checked : Qt::Unchecked)

/**
 * @brief QCheckBoxのチェック状態を真偽値として取得する
 * @param ui_element 読み取り対象のQCheckBox式
 * @return 状態がQt::Checkedの場合はtrue、それ以外はfalse
 */
#define GET_CHECKBOX_BOOL(ui_element) (ui_element->checkState() == Qt::Checked)

/**
 * @brief 整数値をQSpinBoxに設定する
 * @param ui_element 操作対象のQSpinBox式
 * @param int_value 設定する整数値
 * @param default_value 互換性のための引数で、現在のマクロ本体では評価されない
 * @note ui_elementの値をsetValue()で変更する
 */
#define SET_SPINBOX(ui_element, int_value, default_value) \
    ui_element->setValue(int_value)

/**
 * @brief QSpinBoxの値を取得する
 * @param ui_element 読み取り対象のQSpinBox式
 * @return 現在の整数値
 */
#define GET_SPINBOX_INT(ui_element) ui_element->value()

/**
 * @brief 標準文字列をQStringに変換して、QLineEditに設定する
 * @param ui_element 操作対象のQLineEdit式
 * @param string_value 設定するstd::string値
 * @param default_value 互換性のための引数で、現在のマクロ本体では評価されない
 * @note QString::fromStdString()とsetText()を通じて、ui_elementを変更する
 */
#define SET_LINEEDIT(ui_element, string_value, default_value) \
    ui_element->setText(QString::fromStdString(string_value))

/**
 * @brief QLineEditの文字列を標準文字列として取得する
 * @param ui_element 読み取り対象のQLineEdit式
 * @return 現在の入力文字列をstd::stringに変換した値
 */
#define GET_LINEEDIT_STRING(ui_element) ui_element->text().toStdString()

/**
 * @brief enum値からインデックスへの変換caseを生成する
 * @param enum_val 対応するenum値
 * @param index_val 設定するUIインデックス
 * @note SET_COMBOのswitch内で使用し、該当しない値では既定値は上書きされない
 */
#define ENUM_CASE(enum_val, index_val) \
    case enum_val:                     \
        index = index_val;             \
        break;

/**
 * @brief インデックスからenum値への変換 case を生成する
 * @param index_val 対応するUIインデックス
 * @param enum_val 返すenum値
 * @return 実際のreturnは、生成されたcaseが行う
 * @note GET_COMBO_ENUMのswitch内で使用し、該当しない値では既定enumを返す
 */
#define INDEX_CASE(index_val, enum_val) \
    case index_val:                     \
        return enum_val;

/**
 * @brief 設定構造体のenumアダプターを介して、QComboBoxを設定する
 * @param config_struct setFromEnum() を持つ設定構造体
 * @param ui_element 操作対象のQComboBox式
 * @param enum_value 設定するprotobuf enumの整数値
 * @note config_struct::setFromEnum()に処理を委譲し、対応外の値は構造体の既定値に従う
 */
#define SET_COMBO_FROM_CONFIG(config_struct, ui_element, enum_value) \
    config_struct::setFromEnum(ui_element, enum_value)

/**
 * @brief 設定構造体のenumアダプターを介して、QComboBoxの値を取得する
 * @param config_struct getEnum()を持つ設定構造体
 * @param ui_element 読み取り対象のQComboBox式
 * @return config_struct::getEnum()が返すprotobuf enum値
 * @note 対応外のインデックスでは、構造体が定めるDEFAULT_ENUMにフォールバックする
 */
#define GET_COMBO_TO_CONFIG(config_struct, ui_element) \
    config_struct::getEnum(ui_element)

// #define SET_CHECKBOX(ui_element, bool_value, default_value) \
// SET_CHECKBOX(ui_element, bool_value)

/**
 * @brief 既定値引数を受け取る形式で整数値をQSpinBoxに設定する
 * @param ui_element 操作対象のQSpinBox式
 * @param int_value 設定する整数値
 * @param default_value 互換性のために受け取る既定値で、委譲先を含め評価されない
 * @note 実際の設定処理はSET_SPINBOXに委譲される
 */
#define SET_SPINBOX_WITH_DEFAULT(ui_element, int_value, default_value) \
    SET_SPINBOX(ui_element, int_value)

#endif  // CONFIG_MACROS_H
