#include "hazkey_ui.h"

#include <algorithm>

// See hazkey_state.cpp for the rationale: IBUS_ATTR_TYPE_HINT exists only
// since IBus 1.5.33 and is applied opportunistically next to the
// unconditional underline.
#if IBUS_CHECK_VERSION(1, 5, 33)
#define HAZKEY_IBUS_HAS_ATTR_TYPE_HINT 1
#else
#define HAZKEY_IBUS_HAS_ATTR_TYPE_HINT 0
#endif

namespace hazkey::ibus {

namespace {

// gettext lookup in the engine's own domain, same as the state machine.
const char* tr(const char* messageId) {
    return g_dgettext("ibus-hazkey", messageId);
}

// Fcitx defaultSelectionKeys (1..9, 0) for IBus lookup-table slots; other
// slots deliberately have no label. Mirrors
// HazkeyState::selectionLabelForIndex() (kept local so this rendering layer
// does not depend on the logic class).
std::string selectionLabelForIndex(int localIndex) {
    if (localIndex >= 0 && localIndex <= 8) {
        return std::to_string(localIndex + 1);
    }
    if (localIndex == 9) {
        return "0";
    }
    return "";
}

// Mirrors HazkeyState::joinAuxiliaryText(): one space only when both parts
// are non-empty.
std::string joinAuxiliaryText(const std::string& auxUp,
                              const std::string& auxDown) {
    if (auxUp.empty()) {
        return auxDown;
    }
    if (auxDown.empty()) {
        return auxUp;
    }
    return auxUp + " " + auxDown;
}

}  // namespace

HazkeyUi::HazkeyUi(IBusEngine* engine) : engine_(engine) {}


HazkeyUi::~HazkeyUi() {
    // Deliberately does NOT unref the IBus/GObject members: this object may be
    // destroyed on the worker thread when the last shared_ptr is dropped.
    // retire() (main loop) is responsible for releasing them.
}

void HazkeyUi::retire() {
    retired_ = true;
    propertiesRegistered_ = false;
    g_clear_object(&lookupTable_);
    g_clear_object(&inputModeProperty_);
    g_clear_object(&zenzaiProperty_);
    g_clear_object(&propertyList_);
}

void HazkeyUi::updatePreeditSelection(const std::string& text,
                                      glong selectionLen) {
    if (retired_) {
        return;
    }
    IBusText* t = ibus_text_new_from_string(text.c_str());
    if (selectionLen > 0) {
#if HAZKEY_IBUS_HAS_ATTR_TYPE_HINT
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_HINT,
                                   IBUS_ATTR_PREEDIT_SELECTION, 0,
                                   static_cast<guint>(selectionLen));
#endif
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE, 0,
                                   static_cast<guint>(selectionLen));
    }
    ibus_engine_update_preedit_text(engine_, t, 0, TRUE);
}

void HazkeyUi::updatePreeditRange(const std::string& text, glong startChar,
                                  glong endChar, guint cursorChar) {
    if (retired_) {
        return;
    }
    IBusText* t = ibus_text_new_from_string(text.c_str());
    if (endChar > startChar) {
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE,
                                   static_cast<guint>(startChar),
                                   static_cast<guint>(endChar));
    }
    ibus_engine_update_preedit_text(engine_, t, cursorChar, TRUE);
}

void HazkeyUi::updatePreeditHighlighted(const std::string& text) {
    if (retired_) {
        return;
    }
    IBusText* t = ibus_text_new_from_string(text.c_str());
    const glong charLen = g_utf8_strlen(text.c_str(), -1);
    if (charLen > 0) {
#if HAZKEY_IBUS_HAS_ATTR_TYPE_HINT
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_HINT,
                                   IBUS_ATTR_PREEDIT_SELECTION, 0,
                                   static_cast<guint>(charLen));
#endif
        ibus_text_append_attribute(t, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE, 0,
                                   static_cast<guint>(charLen));
    }
    ibus_engine_update_preedit_text(engine_, t, 0, TRUE);
}

void HazkeyUi::hidePreedit() {
    if (retired_) {
        return;
    }
    ibus_engine_hide_preedit_text(engine_);
}

void HazkeyUi::commitText(const std::string& text) {
    if (retired_) {
        return;
    }
    IBusText* t = ibus_text_new_from_string(text.c_str());
    ibus_engine_commit_text(engine_, t);
}

void HazkeyUi::updateLookupTable(const std::vector<std::string>& candidates,
                                 int pageSize, int cursorIndex, int generation) {
    if (retired_) {
        return;
    }
    g_clear_object(&lookupTable_);
    if (candidates.empty() || pageSize <= 0) {
        snapshot_ = LookupSnapshot{};
        snapshot_.generation = generation;
        ibus_engine_hide_lookup_table(engine_);
        return;
    }
    IBusLookupTable* table = ibus_lookup_table_new(
        static_cast<guint>(pageSize), 0, FALSE, FALSE);
    ibus_lookup_table_set_orientation(table, IBUS_ORIENTATION_VERTICAL);
    for (const auto& c : candidates) {
        ibus_lookup_table_append_candidate(
            table, ibus_text_new_from_string(c.c_str()));
    }
    const int labelCount =
        std::min(static_cast<int>(candidates.size()), 10);
    for (int index = 0; index < labelCount; ++index) {
        const std::string label = selectionLabelForIndex(index);
        ibus_lookup_table_set_label(
            table, static_cast<guint>(index),
            ibus_text_new_from_string(label.c_str()));
    }
    g_object_ref_sink(table);
    lookupTable_ = table;

    const guint n = static_cast<guint>(candidates.size());
    guint pos = 0;
    if (cursorIndex >= 0 && static_cast<guint>(cursorIndex) < n) {
        pos = static_cast<guint>(cursorIndex);
    }
    ibus_lookup_table_set_cursor_pos(table, pos);
    ibus_lookup_table_set_cursor_visible(table, cursorIndex >= 0);
    ibus_engine_update_lookup_table(engine_, table, TRUE);

    const int effectiveCursor = cursorIndex >= 0 ? cursorIndex : 0;
    snapshot_ = LookupSnapshot{};
    snapshot_.generation = generation;
    snapshot_.pageSize = pageSize;
    snapshot_.total = static_cast<int>(n);
    snapshot_.cursorPos = cursorIndex;
    snapshot_.visible = true;
    snapshot_.pageStart = (effectiveCursor / pageSize) * pageSize;
}

void HazkeyUi::hideLookupTable(int generation) {
    if (retired_) {
        return;
    }
    g_clear_object(&lookupTable_);
    snapshot_ = LookupSnapshot{};
    snapshot_.generation = generation;
    ibus_engine_hide_lookup_table(engine_);
}

void HazkeyUi::updateAuxiliaryTextPlain(const std::string& text) {
    if (retired_) {
        return;
    }
    IBusText* aux = ibus_text_new_from_string(text.c_str());
    ibus_engine_update_auxiliary_text(engine_, aux, !text.empty());
}

void HazkeyUi::updateAuxiliaryTextWithCursor(const std::string& auxUp,
                                             glong underlineStart,
                                             glong underlineEnd,
                                             const std::string& auxDown) {
    if (retired_) {
        return;
    }
    const std::string text = joinAuxiliaryText(auxUp, auxDown);
    IBusText* aux = ibus_text_new_from_string(text.c_str());
    if (underlineStart >= 0 && underlineEnd > underlineStart) {
        ibus_text_append_attribute(aux, IBUS_ATTR_TYPE_UNDERLINE,
                                   IBUS_ATTR_UNDERLINE_SINGLE,
                                   static_cast<guint>(underlineStart),
                                   static_cast<guint>(underlineEnd));
    }
    ibus_engine_update_auxiliary_text(engine_, aux, !text.empty());
}

void HazkeyUi::registerProperties(bool directInput, bool zenzaiEnabled) {
    if (retired_) {
        return;
    }
    if (propertyList_ == nullptr) {
        propertyList_ = ibus_prop_list_new();
        g_object_ref_sink(propertyList_);
        inputModeProperty_ = ibus_property_new(
            "InputMode", PROP_TYPE_NORMAL, ibus_text_new_from_string(tr("あ")),
            nullptr, ibus_text_new_from_string(tr("Hiragana input")), TRUE, TRUE,
            PROP_STATE_UNCHECKED, nullptr);
        zenzaiProperty_ = ibus_property_new(
            "Zenzai", PROP_TYPE_TOGGLE,
            ibus_text_new_from_string(tr("Zenzai")), nullptr,
            ibus_text_new_from_string(tr("Zenzai disabled")), TRUE, TRUE,
            PROP_STATE_UNCHECKED, nullptr);
        g_object_ref_sink(inputModeProperty_);
        g_object_ref_sink(zenzaiProperty_);
        ibus_prop_list_append(propertyList_, inputModeProperty_);
        ibus_prop_list_append(propertyList_, zenzaiProperty_);
    }
    ibus_engine_register_properties(engine_, propertyList_);
    propertiesRegistered_ = true;
    updateInputModeProperty(directInput);
    updateZenzaiProperty(zenzaiEnabled);
}

void HazkeyUi::updateInputModeProperty(bool directInput) {
    if (retired_ || inputModeProperty_ == nullptr) {
        return;
    }
    ibus_property_set_label(
        inputModeProperty_,
        ibus_text_new_from_string(tr(directInput ? "A" : "あ")));
    ibus_property_set_tooltip(
        inputModeProperty_,
        ibus_text_new_from_string(
            tr(directInput ? "[Direct Input]" : "Hiragana input")));
    ibus_engine_update_property(engine_, inputModeProperty_);
}

void HazkeyUi::updateZenzaiProperty(bool enabled) {
    zenzaiChecked_ = enabled;
    if (retired_ || zenzaiProperty_ == nullptr) {
        return;
    }
    ibus_property_set_state(zenzaiProperty_,
                            enabled ? PROP_STATE_CHECKED
                                    : PROP_STATE_UNCHECKED);
    ibus_property_set_tooltip(
        zenzaiProperty_,
        ibus_text_new_from_string(
            tr(enabled ? "Zenzai enabled" : "Zenzai disabled")));
    ibus_engine_update_property(engine_, zenzaiProperty_);
}

void HazkeyUi::requestSurroundingText() {
    if (retired_) {
        return;
    }
    ibus_engine_get_surrounding_text(engine_, nullptr, nullptr, nullptr);
}

void HazkeyUi::forwardKeyEvent(guint keyval, guint keycode, guint state) {
    if (retired_) {
        return;
    }
    ibus_engine_forward_key_event(engine_, keyval, keycode, state);
}

}  // namespace hazkey::ibus
