#ifndef IBUS_HAZKEY_HAZKEY_FRONTEND_H
#define IBUS_HAZKEY_HAZKEY_FRONTEND_H

#include <ibus.h>

#include <cstdint>
#include <functional>
#include <memory>

#include "hazkey_state.h"
#include "hazkey_ui.h"
#include "serial_task_executor.h"

namespace hazkey::ibus {

// Main-loop facade for one IBus input context.
//
// Every IBus vfunc target is routed here. The facade:
//   * decides SYNCHRONOUSLY whether process_key_event consumes a key. It may
//     not block, so the decision uses only plain values the worker posted
//     after each operation (never an RPC);
//   * enqueues the real work (RPCs + IME state) onto one process-wide
//     SerialTaskExecutor worker, preserving FIFO order;
//   * keeps the worker logic (HazkeyState) and the main-loop renderer
//     (HazkeyUi) alive through shared_ptr. Worker tasks capture the state and
//     posted UI closures capture the ui, so teardown never drains the
//     executor and no closure can touch a destroyed object.
class HazkeyFrontend : public std::enable_shared_from_this<HazkeyFrontend> {
   public:
    explicit HazkeyFrontend(IBusEngine* engine);
    ~HazkeyFrontend();
    HazkeyFrontend(const HazkeyFrontend&) = delete;
    HazkeyFrontend& operator=(const HazkeyFrontend&) = delete;

    // Main loop only. Retires the UI (releases every GObject) and stops
    // forwarding. Idempotent. Called from the engine's destroy vfunc before
    // the engine is finalized.
    void retire();

    gboolean processKeyEvent(guint keyval, guint keycode, guint state);
    void focusIn();
    void focusOut();
    void reset();
    void enable();
    void disable();
    void setCapabilities(guint caps);
    bool activateProperty(const gchar* propName, guint propState);
    void setCursorLocation(gint x, gint y, gint w, gint h);
    void setSurroundingText(IBusText* text, guint cursorIndex, guint anchorPos);
    void pageUp();
    void pageDown();
    void cursorUp();
    void cursorDown();
    void candidateClicked(guint index, guint button, guint state);

    // Pure synchronous consume decision, exposed for tests. `in` carries only
    // plain values. Returns TRUE when the key may be IME-owned: a provisional
    // TRUE that the worker turns out not to handle is forwarded to the
    // application (see enqueueKeyOp), so TRUE is always safe; FALSE is only
    // returned for keys no pending state could handle.
    struct DecisionInput {
        bool composing = false;
        bool listFocused = false;
        bool profileLoaded = false;
        HazkeyState::HotkeySpec liveConvert{};
        HazkeyState::HotkeySpec zenzaiToggle{};
        HazkeyState::HotkeySpec acceptPrediction{};
        HazkeyState::HotkeySpec deleteLearning{};
    };
    static gboolean decideConsumeKey(guint keyval, guint state,
                                     const DecisionInput& in);

   private:
    void enqueue(std::function<void(const std::shared_ptr<HazkeyState>&)> task);
    void enqueueKeyOp(guint keyval, guint keycode, guint state, gboolean consume);
    void applyIngress(const HazkeyState::IngressSnapshot& snapshot);

    std::shared_ptr<HazkeyUi> ui_;
    std::shared_ptr<HazkeyState> state_;
    bool retired_ = false;

    // Main-loop-owned speculative ingress state. processKeyEvent() updates it
    // eagerly; worker completions reconcile it via applyIngress().
    size_t pendingOps_ = 0;
    bool specComposing_ = false;
    bool specListFocused_ = false;
    bool profileLoaded_ = false;
    HazkeyState::HotkeySpec liveConvert_{};
    HazkeyState::HotkeySpec zenzaiToggle_{};
    HazkeyState::HotkeySpec acceptPrediction_{};
    HazkeyState::HotkeySpec deleteLearning_{};
};

// Stops accepting new work on the process-wide executor and joins its worker.
// Call once after the GLib main loop has exited, so the worker cannot race the
// destruction of the function-static hooks/connector at process exit.
void shutdownSharedExecutor();

}  // namespace hazkey::ibus

#endif  // IBUS_HAZKEY_HAZKEY_FRONTEND_H
