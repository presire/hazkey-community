/**
 * @file config_definitions.h
 * @brief 設定画面で使用する列挙値変換と既定値の定義
 * @note Qtウィジェットの値とprotobufの設定列挙値を対応付ける
 */
#ifndef CONFIG_DEFINITIONS_H
#define CONFIG_DEFINITIONS_H

#include <QCheckBox>
#include <QComboBox>
#include <QtCore>
#include "base.pb.h"
#include "config_macros.h"

/**
 * @brief コンボボックス用の列挙値変換アダプターを定義する
 * @param name 生成する設定構造体の名前
 * @param default_index enumValueまたはコンボボックスの値が未対応の場合に使う
 *                      コンボボックスのインデックス
 * @param ... ENUM_CASEまたはINDEX_CASEに変換できる列挙値とインデックスの対応
 * @note 生成されるアダプターは、呼び出し側が指定するEnumTypeとその既定値を使用して、protobuf列挙型との変換を行う
 */
#define CONFIG_COMBO_DEFINITION(name, default_index, ...)                      \
    struct name##_Config {                                                     \
        static constexpr int DEFAULT_INDEX = default_index;                    \
        static void setFromEnum(QComboBox* combo, int enumValue) {             \
            SET_COMBO_WITH_DEFAULT(combo, enumValue, DEFAULT_INDEX,            \
                                   __VA_ARGS__)                                \
        }                                                                      \
        template <typename EnumType>                                           \
        static EnumType getEnum(QComboBox* combo, EnumType defaultEnum) {      \
            return GET_COMBO_ENUM_WITH_DEFAULT(combo, EnumType, defaultEnum,   \
                                               MAKE_INDEX_CASES(__VA_ARGS__)); \
        }                                                                      \
    };

/**
 * @brief enum値からコンボボックスのインデックスへ変換するswitch caseを生成する
 * @param enum_val 対応するprotobuf列挙値
 * @param index_val 対応するコンボボックスのインデックス
 * @note SET_COMBOのswitch内で使用し、対象外の値はSET_COMBOの既定値を保持する
 */
#define ENUM_CASE(enum_val, index_val) \
    case enum_val:                     \
        index = index_val;             \
        break;

/**
 * @brief コンボボックスのインデックスからenum値へ変換するswitch caseを生成する
 * @param index_val 対応するコンボボックスのインデックス
 * @param enum_val 返すprotobuf列挙値
 * @return 対応するenum_val - 実際のreturnは生成されたswitch caseが行う
 * @note 対象外のインデックスでは、呼び出し側のGETマクロが指定した既定値を返す
 */
#define INDEX_CASE(index_val, enum_val) \
    case index_val:                     \
        return enum_val;

/**
 * @brief ENUM_CASE群をINDEX_CASE群へ変換する
 * @param ... 変換対象のENUM_CASE群
 * @return 対応するINDEX_CASE群のマクロ展開
 * @note CONFIG_COMBO_DEFINITIONのgetEnumで、コンボボックスからenum値を取得する
 *       ために使用する
 */
#define MAKE_INDEX_CASES(...) CONVERT_ENUM_CASES_TO_INDEX_CASES(__VA_ARGS__)

namespace ConfigDefs {
/**
 * @brief 自動変換モードとUIのコンボボックスを対応付ける
 * @note EnumTypeは、hazkey::config::Profile_AutoConvertMode であり、
 *       未知の値や未対応のインデックスは、DEFAULT_INDEXまたはDEFAULT_ENUMにフォールバックする
 */
struct AutoConvertMode {
    /** @brief 未知のprotobuf値または未対応のUI値に使うインデックス */
    static constexpr int DEFAULT_INDEX = 1;  // AUTO_CONVERT_FOR_MULTIPLE_CHARS
    /** @brief この設定が扱うprotobuf列挙型 */
    using EnumType = hazkey::config::Profile_AutoConvertMode;
    /** @brief 未対応のコンボボックス値に返すprotobuf列挙値 */
    static constexpr EnumType DEFAULT_ENUM =
        hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS;

    /**
     * @brief protobufのenum値をコンボボックスへ設定する
     * @param combo 対象のQComboBox
     * @param enumValue 設定するprotobufenum値
     * @note 対応表にないenumValueでは、DEFAULT_INDEXを選択する
     */
    static void setFromEnum(QComboBox* combo, int enumValue) {
        SET_COMBO(
            combo, enumValue, DEFAULT_INDEX,
            ENUM_CASE(
                hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS, 0)
                ENUM_CASE(
                    hazkey::config::
                        Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS,
                    1)
                    ENUM_CASE(hazkey::config::
                                  Profile_AutoConvertMode_AUTO_CONVERT_DISABLED,
                              2));
    }

    /**
     * @brief コンボボックスの選択をprotobufのenum値へ変換する
     * @param combo 対象のQComboBox
     * @return 対応するprotobuf enum値、未知のインデックスではDEFAULT_ENUM
     */
    static EnumType getEnum(QComboBox* combo) {
        return GET_COMBO_ENUM(
            combo, EnumType, DEFAULT_ENUM,
            INDEX_CASE(
                0, hazkey::config::Profile_AutoConvertMode_AUTO_CONVERT_ALWAYS)
                INDEX_CASE(
                    1,
                    hazkey::config::
                        Profile_AutoConvertMode_AUTO_CONVERT_FOR_MULTIPLE_CHARS)
                    INDEX_CASE(
                        2, hazkey::config::
                               Profile_AutoConvertMode_AUTO_CONVERT_DISABLED));
    }
};

/**
 * @brief 補助テキスト表示モードとUIのコンボボックスを対応付ける
 * @note EnumTypeは、hazkey::config::Profile_AuxTextModeであり、
 *       未知の値や未対応のインデックスは、DEFAULT_INDEXまたはDEFAULT_ENUMにフォールバックする
 */
struct AuxTextMode {
    /** @brief 未知のprotobuf値または未対応のUI値に使うインデックス */
    static constexpr int DEFAULT_INDEX =
        1;  // AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END
    /** @brief この設定が扱うprotobuf列挙型 */
    using EnumType = hazkey::config::Profile_AuxTextMode;
    /** @brief 未対応のコンボボックス値に返すprotobuf列挙値 */
    static constexpr EnumType DEFAULT_ENUM = hazkey::config::
        Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END;

    /**
     * @brief protobufのenum値をコンボボックスへ設定する
     * @param combo 対象のQComboBox
     * @param enumValue 設定するprotobuf enum値
     * @note 対応表にないenumValueでは、DEFAULT_INDEXを選択する
     */
    static void setFromEnum(QComboBox* combo, int enumValue) {
        SET_COMBO(
            combo, enumValue, DEFAULT_INDEX,
            ENUM_CASE(hazkey::config::Profile_AuxTextMode_AUX_TEXT_SHOW_ALWAYS,
                      0)
                ENUM_CASE(
                    hazkey::config::
                        Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END,
                    1)
                    ENUM_CASE(
                        hazkey::config::Profile_AuxTextMode_AUX_TEXT_DISABLED,
                        2));
    }

    /**
     * @brief コンボボックスの選択をprotobufのenum値へ変換する
     * @param combo 対象のQComboBox
     * @return 対応するprotobuf enum値、未知のインデックスではDEFAULT_ENUM
     */
    static EnumType getEnum(QComboBox* combo) {
        return GET_COMBO_ENUM(
            combo, EnumType, DEFAULT_ENUM,
            INDEX_CASE(0,
                       hazkey::config::Profile_AuxTextMode_AUX_TEXT_SHOW_ALWAYS)
                INDEX_CASE(
                    1,
                    hazkey::config::
                        Profile_AuxTextMode_AUX_TEXT_SHOW_WHEN_CURSOR_NOT_AT_END)
                    INDEX_CASE(
                        2,
                        hazkey::config::Profile_AuxTextMode_AUX_TEXT_DISABLED));
    }
};

/**
 * @brief 候補リスト表示モードとUIのコンボボックスを対応付ける
 * @note EnumTypeは、hazkey::config::Profile_SuggestionListModeであり、
 *       未知の値や未対応のインデックスは、DEFAULT_INDEXまたはDEFAULT_ENUMにフォールバックする
 */
struct SuggestionListMode {
    /** @brief 未知のprotobuf値または未対応のUI値に使うインデックス */
    static constexpr int DEFAULT_INDEX =
        1;  // SUGGESTION_LIST_SHOW_PREDICTIVE_RESULTS
    /** @brief この設定が扱うprotobuf列挙型 */
    using EnumType = hazkey::config::Profile_SuggestionListMode;
    /** @brief 未対応のコンボボックス値に返すprotobuf列挙値 */
    static constexpr EnumType DEFAULT_ENUM = hazkey::config::
        Profile_SuggestionListMode_SUGGESTION_LIST_SHOW_PREDICTIVE_RESULTS;

    /**
     * @brief protobufのenum値をコンボボックスへ設定する
     * @param combo 対象のQComboBox
     * @param enumValue 設定するprotobuf enum値
     * @note 対応表にないenumValueでは、DEFAULT_INDEXを選択する
     */
    static void setFromEnum(QComboBox* combo, int enumValue) {
        SET_COMBO(
            combo, enumValue, DEFAULT_INDEX,
            ENUM_CASE(
                hazkey::config::
                    Profile_SuggestionListMode_SUGGESTION_LIST_SHOW_NORMAL_RESULTS,
                0)
                ENUM_CASE(
                    hazkey::config::
                        Profile_SuggestionListMode_SUGGESTION_LIST_SHOW_PREDICTIVE_RESULTS,
                    1)
                    ENUM_CASE(
                        hazkey::config::
                            Profile_SuggestionListMode_SUGGESTION_LIST_DISABLED,
                        2));
    }

    /**
     * @brief コンボボックスの選択をprotobufのenum値へ変換する
     * @param combo 対象のQComboBox
     * @return 対応するprotobuf enum値、未知のインデックスではDEFAULT_ENUM
     */
    static EnumType getEnum(QComboBox* combo) {
        return GET_COMBO_ENUM(
            combo, EnumType, DEFAULT_ENUM,
            INDEX_CASE(
                0,
                hazkey::config::
                    Profile_SuggestionListMode_SUGGESTION_LIST_SHOW_NORMAL_RESULTS)
                INDEX_CASE(
                    1,
                    hazkey::config::
                        Profile_SuggestionListMode_SUGGESTION_LIST_SHOW_PREDICTIVE_RESULTS)
                    INDEX_CASE(
                        2,
                        hazkey::config::
                            Profile_SuggestionListMode_SUGGESTION_LIST_DISABLED));
    }
};

/**
 * @brief 候補選択中の数字キーの動作とUIのコンボボックスを対応付ける
 * @note EnumTypeは、hazkey::config::Profile_CandidateDigitKeyActionであり、
 *       未設定 (UNSPECIFIED) や未知の値、未対応のインデックスは、
 *       DEFAULT_INDEXまたはDEFAULT_ENUM (選択して確定) にフォールバックする
 */
struct CandidateDigitKeyAction {
    /** @brief 未知のprotobuf値または未対応のUI値に使うインデックス */
    static constexpr int DEFAULT_INDEX = 0;  // CANDIDATE_DIGIT_SELECT_AND_COMMIT
    /** @brief この設定が扱うprotobuf列挙型 */
    using EnumType = hazkey::config::Profile_CandidateDigitKeyAction;
    /** @brief 未対応のコンボボックス値に返すprotobuf列挙値 */
    static constexpr EnumType DEFAULT_ENUM = hazkey::config::
        Profile_CandidateDigitKeyAction_CANDIDATE_DIGIT_SELECT_AND_COMMIT;

    /**
     * @brief protobufのenum値をコンボボックスへ設定する
     * @param combo 対象のQComboBox
     * @param enumValue 設定するprotobuf enum値
     * @note UNSPECIFIEDを含む対応表にないenumValueでは、DEFAULT_INDEXを選択する
     */
    static void setFromEnum(QComboBox* combo, int enumValue) {
        SET_COMBO(
            combo, enumValue, DEFAULT_INDEX,
            ENUM_CASE(
                hazkey::config::
                    Profile_CandidateDigitKeyAction_CANDIDATE_DIGIT_SELECT_AND_COMMIT,
                0)
                ENUM_CASE(
                    hazkey::config::
                        Profile_CandidateDigitKeyAction_CANDIDATE_DIGIT_MOVE_CURSOR,
                    1));
    }

    /**
     * @brief コンボボックスの選択をprotobufのenum値へ変換する
     * @param combo 対象のQComboBox
     * @return 対応するprotobuf enum値、未知のインデックスではDEFAULT_ENUM
     */
    static EnumType getEnum(QComboBox* combo) {
        return GET_COMBO_ENUM(
            combo, EnumType, DEFAULT_ENUM,
            INDEX_CASE(
                0,
                hazkey::config::
                    Profile_CandidateDigitKeyAction_CANDIDATE_DIGIT_SELECT_AND_COMMIT)
                INDEX_CASE(
                    1,
                    hazkey::config::
                        Profile_CandidateDigitKeyAction_CANDIDATE_DIGIT_MOVE_CURSOR));
    }
};

/**
 * @brief テンキー入力の動作と、UIのチェックボックスおよびコンボボックスを対応付ける
 * @note EnumTypeは、hazkey::config::Profile_KeypadInputModeであり、
 *       1つの列挙値を[IMEを素通りする]チェックボックスと[全角/半角]コンボボックスの2つへ分けて表す
 *       未設定 (UNSPECIFIED) や未知の値は、DEFAULT_ENUM (素通り) にフォールバックする
 *       素通りの間はコンボボックスの選択を保持するが、実効値には影響しない
 */
struct KeypadInputMode {
    /** @brief この設定が扱うprotobuf列挙型 */
    using EnumType = hazkey::config::Profile_KeypadInputMode;
    /** @brief 未設定や未知の値に使うprotobuf列挙値 */
    static constexpr EnumType DEFAULT_ENUM =
        hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_PASSTHROUGH;
    /** @brief 半角を表すコンボボックスのインデックス */
    static constexpr int HALFWIDTH_INDEX = 0;
    /** @brief 全角を表すコンボボックスのインデックス */
    static constexpr int FULLWIDTH_INDEX = 1;
    /** @brief 素通りの値を読み込んだときに選ぶコンボボックスのインデックス */
    static constexpr int DEFAULT_WIDTH_INDEX = HALFWIDTH_INDEX;

    /**
     * @brief protobufのenum値が素通りを表すかを判定する
     * @param enumValue 判定するprotobuf enum値
     * @return 半角・全角のどちらでもない場合はtrue (UNSPECIFIEDや未知の値を含む)
     */
    static bool isPassthrough(int enumValue) {
        return enumValue !=
                   hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_HALFWIDTH &&
               enumValue !=
                   hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_FULLWIDTH;
    }

    /**
     * @brief protobufのenum値をコンボボックスのインデックスへ変換する
     * @param enumValue 変換するprotobuf enum値
     * @return 全角ではFULLWIDTH_INDEX、それ以外 (素通りを含む) ではHALFWIDTH_INDEX
     */
    static int widthIndexFromEnum(int enumValue) {
        return enumValue ==
                       hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_FULLWIDTH
                   ? FULLWIDTH_INDEX
                   : DEFAULT_WIDTH_INDEX;
    }

    /**
     * @brief UIの2つの値から実効のprotobuf enum値を求める
     * @param passthrough [IMEを素通りする]チェックボックスの状態
     * @param widthIndex [全角/半角]コンボボックスのインデックス
     * @return passthroughがtrueならコンボボックスに依らずKEYPAD_INPUT_PASSTHROUGH
     *         それ以外は、FULLWIDTH_INDEXならKEYPAD_INPUT_FULLWIDTH、他のインデックスはKEYPAD_INPUT_HALFWIDTH
     */
    static EnumType fromUi(bool passthrough, int widthIndex) {
        if (passthrough) {
            return hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_PASSTHROUGH;
        }
        return widthIndex == FULLWIDTH_INDEX
                   ? hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_FULLWIDTH
                   : hazkey::config::Profile_KeypadInputMode_KEYPAD_INPUT_HALFWIDTH;
    }

    /**
     * @brief protobufのenum値をチェックボックスとコンボボックスへ設定する
     * @param passthrough [IMEを素通りする]チェックボックス
     * @param width [全角/半角]コンボボックス
     * @param enumValue 設定するprotobuf enum値
     * @note 有効/無効の切り替えは呼び出し側が行う
     */
    static void setToUi(QCheckBox* passthrough, QComboBox* width,
                        int enumValue) {
        passthrough->setChecked(isPassthrough(enumValue));
        width->setCurrentIndex(widthIndexFromEnum(enumValue));
    }

    /**
     * @brief チェックボックスとコンボボックスの状態から実効のprotobuf enum値を求める
     * @param passthrough [IMEを素通りする]チェックボックス
     * @param width [全角/半角]コンボボックス
     * @return fromUi()と同じ規則で求めたprotobuf enum値
     */
    static EnumType getFromUi(const QCheckBox* passthrough,
                              const QComboBox* width) {
        return fromUi(passthrough->isChecked(), width->currentIndex());
    }
};

/**
 * @brief チェックボックス設定のフォールバック値をまとめる
 * @note protobufのフィールドが未設定の場合にUIへ反映する値を表す
 */
struct CheckboxDefaults {
    /** @brief 入力履歴を使用しない既定値 */
    static constexpr bool USE_HISTORY = false;
    /** @brief 新しい入力履歴の保存を停止しない既定値 */
    static constexpr bool STOP_STORE_NEW_HISTORY = false;
    /** @brief プロファイル独立履歴を使用しない既定値 */
    static constexpr bool USE_PROFILE_INDEPENDENT_HISTORY = false;
    /** @brief リッチ候補表示を使用しない既定値 */
    static constexpr bool USE_RICH_SUGGESTION = false;
    /** @brief リッチ候補リストを使用しない既定値 */
    static constexpr bool USE_RICH_CANDIDATES = false;
    /** @brief Zenzaiを有効にしない既定値 */
    static constexpr bool ENABLE_ZENZAI = false;
    /** @brief Zenzaiの文脈依存変換を使用しない既定値 */
    static constexpr bool ZENZAI_CONTEXTUAL = false;
    /** @brief Zenzaiの右文脈を使用しない既定値 */
    static constexpr bool ZENZAI_RIGHT_CONTEXT = false;
    /** @brief Zenzaiのアラインメント区切りを使用しない既定値 */
    static constexpr bool ZENZAI_ALIGNMENT_SEPARATOR = false;
    /** @brief Zenzaiのカスタム重みを使用しない既定値 */
    static constexpr bool USE_ZENZAI_CUSTOM_WEIGHT = false;
    /** @brief 半角カタカナ変換を使用しない既定値 */
    static constexpr bool HALFWIDTH_KATAKANA = false;
    /** @brief 拡張絵文字変換を使用する既定値 */
    static constexpr bool EXTENDED_EMOJI = true;
    /** @brief 記号変換を使用しない既定値 */
    static constexpr bool SYMBOL = false;
    /** @brief 住所辞書を使用しない既定値 */
    static constexpr bool ADDRESS_DICTIONARY = false;
    /** @brief 工学用語辞書を使用しない既定値 */
    static constexpr bool ENGINEERING_DICTIONARY = false;
    /** @brief 郵便番号変換を使用しない既定値 */
    static constexpr bool POSTAL_CODE_CONVERSION = false;
    /** @brief 誤字の訂正候補を表示しない既定値 */
    static constexpr bool TYPO_CORRECTION = false;
    /** @brief 桁区切り数字変換を使用しない既定値 */
    static constexpr bool COMMA_SEPARATED_NUMBER = false;
    /** @brief カレンダー変換を使用しない既定値 */
    static constexpr bool CALENDER = false;
    /** @brief 時刻変換を使用しない既定値 */
    static constexpr bool TIME = false;
    /** @brief メールドメイン変換を使用しない既定値 */
    static constexpr bool MAIL_DOMAIN = false;
    /** @brief Unicodeコードポイント変換を使用しない既定値 */
    static constexpr bool UNICODE_CODEPOINT = false;
    /** @brief ローマ字表記変換を使用しない既定値 */
    static constexpr bool ROMAN_TYPOGRAPHY = false;
    /** @brief hazkey バージョン表記変換を使用しない既定値 */
    static constexpr bool HAZKEY_VERSION = false;
    /** @brief 相対日付変換を使用しない既定値 */
    static constexpr bool RELATIVE_DATE = false;
};

/**
 * @brief スピンボックス設定のフォールバック値をまとめる
 * @note protobufのフィールドが未設定の場合にUIへ反映する値を表す
 */
struct SpinboxDefaults {
    /** @brief 1ページに表示する予測候補数の既定値 */
    static constexpr int NUM_SUGGESTIONS = 5;
    /** @brief 自動変換を開始する最小文字数の既定値 */
    static constexpr int AUTO_CONVERT_MIN_CHARS = 2;
    /** @brief 1ページに表示する候補数の既定値 */
    static constexpr int NUM_CANDIDATES_PER_PAGE = 10;
    /** @brief Zenzai推論制限の既定値 */
    static constexpr int ZENZAI_INFERENCE_LIMIT = 100;
};
}  // namespace ConfigDefs

#endif  // CONFIG_DEFINITIONS_H
