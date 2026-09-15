#ifndef IBUS_HAZKEY_HAZKEY_UI_H
#define IBUS_HAZKEY_HAZKEY_UI_H

#include <ibus.h>

#include <cstdint>
#include <string>
#include <vector>

namespace hazkey::ibus {

// Main-loop-only rendering endpoint for one IBus input context.
//
// The IBus input state machine (HazkeyState) runs on a worker thread so a
// slow hazkey-server never blocks process_key_event. Everything that touches
// IBus/GObject state lives here instead, and every method MUST be called on
// the GLib main loop (the thread that owns the engine), via
// hazkey::frontend::postToMainLoop().
// Lookup-table number labels are page-local to the visible IBus page.
//
// Lifetime: HazkeyState and the frontend ladder hold shared_ptr<HazkeyUi>, so
// the object itself cannot be freed while a posted closure still references
// it. The raw IBus/GObject pointers it owns must be released on the main loop
// by retire(); if it is missed, ~HazkeyUi warns but must never unref them (it
// may run on the worker when the last shared_ptr is dropped after teardown).
class HazkeyUi {
   public:
    explicit HazkeyUi(IBusEngine* engine);
    ~HazkeyUi();
    HazkeyUi(const HazkeyUi&) = delete;
    HazkeyUi& operator=(const HazkeyUi&) = delete;

    // Releases every IBus/GObject owned here. Main loop only. Idempotent.
    // After this every render method is a no-op.
    void retire();

    // Preedit with a single highlighted/underlined segment of `selectionLen`
    // UTF-8 characters (candidate mode: the conversion target; empty
    // subHiragana: the whole string). Cursor pinned at 0.
    void updatePreeditSelection(const std::string& text, glong selectionLen);
    // Plain preedit with an explicit underline range and cursor position.
    void updatePreeditRange(const std::string& text, glong startChar,
                            glong endChar, guint cursorChar);
    // Whole-string highlighted preedit (direct conversion F6-F10).
    void updatePreeditHighlighted(const std::string& text);
    void hidePreedit();
    void commitText(const std::string& text);

    // Rebuilds and pushes the vertical lookup table. `generation` tags this
    // render so a later click can be resolved against exactly this snapshot.
    void updateLookupTable(const std::vector<std::string>& candidates,
                           int pageSize, int cursorIndex, int generation);
    void hideLookupTable(int generation);

    void updateAuxiliaryTextPlain(const std::string& text);
    void updateAuxiliaryTextWithCursor(const std::string& auxUp,
                                       glong underlineStart,
                                       glong underlineEnd,
                                       const std::string& auxDown);

    void registerProperties(bool directInput, bool zenzaiEnabled);
    void updateInputModeProperty(bool directInput);
    void updateZenzaiProperty(bool enabled);

    void requestSurroundingText();

    // Forwards a key the IME decided not to consume after a provisional
    // consume (see HazkeyFrontend). Main loop only. `keycode`/`state` are the
    // original IBus event values.
    void forwardKeyEvent(guint keyval, guint keycode, guint state);

    // What the panel's lookup table currently shows. Read by the main-loop
    // candidate_clicked handler to resolve a page-local index against the
    // exact render the user clicked.
    struct LookupSnapshot {
        int generation = 0;
        int pageSize = 0;
        int pageStart = 0;  // global index of the first visible candidate
        int total = 0;
        int cursorPos = 0;  // global cursor index (-1: unfocused)
        bool visible = false;
    };
    LookupSnapshot lookupSnapshot() const { return snapshot_; }

   private:
    IBusEngine* engine_;
    IBusLookupTable* lookupTable_ = nullptr;
    IBusPropList* propertyList_ = nullptr;
    IBusProperty* inputModeProperty_ = nullptr;
    IBusProperty* zenzaiProperty_ = nullptr;
    bool propertiesRegistered_ = false;
    bool zenzaiChecked_ = false;
    bool retired_ = false;
    LookupSnapshot snapshot_{};
};

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_HAZKEY_UI_H
