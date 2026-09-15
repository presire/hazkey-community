#include "hazkey_frontend.h"

#include <string>
#include <utility>

#include "hazkey_frontend_hooks.h"

namespace hazkey::ibus {

namespace {

// One executor per IBus process. HazkeyState instances share the single
// HazkeyServerConnector singleton, so serializing every state's work on one
// thread keeps the transport single-threaded and RPCs strictly FIFO.
//
// Intentionally leaked: the executor's worker may reference HazkeyState
// objects whose teardown is driven by the engine, and static destruction order
// at process exit is not controllable. Leaking one thread at exit is harmless.
hazkey::frontend::SerialTaskExecutor& sharedExecutor() {
    static hazkey::frontend::SerialTaskExecutor* executor =
        new hazkey::frontend::SerialTaskExecutor();
    return *executor;
}

constexpr guint kModifierPassthroughMask =
    IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_SUPER_MASK | IBUS_HYPER_MASK |
    IBUS_META_MASK | IBUS_MOD4_MASK;

// Keys the IME handles in preedit mode (mirrors HazkeyState::preeditKeyEvent).
bool isPreeditHandledKey(guint keyval) {
    switch (keyval) {
        case IBUS_KEY_Return:
        case IBUS_KEY_KP_Enter:
        case IBUS_KEY_ISO_Enter:
        case IBUS_KEY_BackSpace:
        case IBUS_KEY_Delete:
        case IBUS_KEY_F6:
        case IBUS_KEY_F7:
        case IBUS_KEY_F8:
        case IBUS_KEY_F9:
        case IBUS_KEY_F10:
        case IBUS_KEY_Muhenkan:
        case IBUS_KEY_Escape:
        case IBUS_KEY_space:
        case IBUS_KEY_Henkan:
        case IBUS_KEY_Up:
        case IBUS_KEY_Down:
        case IBUS_KEY_Tab:
        case IBUS_KEY_ISO_Left_Tab:
        case IBUS_KEY_Left:
        case IBUS_KEY_Right:
            return true;
        default:
            return false;
    }
}

// Keys the IME handles in candidate mode (mirrors
// HazkeyState::candidateKeyEvent before the digit/inputable fallbacks).
bool isCandidateHandledKey(guint keyval) {
    switch (keyval) {
        case IBUS_KEY_Right:
        case IBUS_KEY_Left:
        case IBUS_KEY_Return:
        case IBUS_KEY_KP_Enter:
        case IBUS_KEY_ISO_Enter:
        case IBUS_KEY_Escape:
        case IBUS_KEY_BackSpace:
        case IBUS_KEY_space:
        case IBUS_KEY_Tab:
        case IBUS_KEY_ISO_Left_Tab:
        case IBUS_KEY_Down:
        case IBUS_KEY_Up:
        case IBUS_KEY_F6:
        case IBUS_KEY_F7:
        case IBUS_KEY_F8:
        case IBUS_KEY_F9:
        case IBUS_KEY_F10:
            return true;
        default:
            return false;
    }
}

}  // namespace

HazkeyFrontend::HazkeyFrontend(IBusEngine* engine)
    : ui_(std::make_shared<HazkeyUi>(engine)),
      state_(std::make_shared<HazkeyState>(ui_, &sharedExecutor())) {
    // Seed the ingress hotkeys with the same defaults the state seeds, so the
    // very first key event can already recognize the built-in hotkeys.
    liveConvert_ = HazkeyState::parseHotkey("", "Control+Shift+L");
    zenzaiToggle_ = HazkeyState::parseHotkey("", "Control+Alt+Z");
    acceptPrediction_ = HazkeyState::parseHotkey("", "F5");
    deleteLearning_ = HazkeyState::parseHotkey("", "Control+D");
}

HazkeyFrontend::~HazkeyFrontend() = default;

void HazkeyFrontend::retire() {
    if (retired_) {
        return;
    }
    // Stop accepting new work first (every vfunc checks retired_), then let
    // the already-submitted worker tasks finish and run the UI commands they
    // posted (notably a focus-out commit) while the engine and renderer are
    // still valid. drainAndWait() waits only for tasks already submitted; the
    // bounded iteration below dispatches only sources that are already ready.
    retired_ = true;
    sharedExecutor().drainAndWait();
    for (int i = 0; i < 1000 && g_main_context_pending(nullptr); ++i) {
        g_main_context_iteration(nullptr, FALSE);
    }
    if (ui_) {
        ui_->retire();
    }
}

void HazkeyFrontend::enqueue(
    std::function<void(const std::shared_ptr<HazkeyState>&)> task) {
    auto self = shared_from_this();
    auto state = state_;
    ++pendingOps_;
    const hazkey::frontend::SerialTaskExecutor::Token token =
        sharedExecutor().submit([self, state, task = std::move(task)]() mutable {
            task(state);
            const auto snapshot = state->ingressSnapshot();
            hazkey::frontend::postToMainLoop([self, snapshot] {
                self->applyIngress(snapshot);
                if (self->pendingOps_ > 0) {
                    --self->pendingOps_;
                }
            });
        });
    if (token == hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        // The executor rejected the task (stopping): undo the bookkeeping so
        // pendingOps_ cannot stick above zero forever.
        if (pendingOps_ > 0) {
            --pendingOps_;
        }
    }
}

void HazkeyFrontend::enqueueKeyOp(guint keyval, guint keycode, guint state,
                                  gboolean consume) {
    auto self = shared_from_this();
    auto logic = state_;
    auto ui = ui_;
    ++pendingOps_;
    const hazkey::frontend::SerialTaskExecutor::Token token =
        sharedExecutor().submit(
            [self, logic, ui, keyval, keycode, state, consume] {
                const gboolean handled =
                    logic->processKeyEvent(keyval, keycode, state);
                const auto snapshot = logic->ingressSnapshot();
                hazkey::frontend::postToMainLoop(
                    [self, ui, snapshot, handled, consume, keyval, keycode,
                     state] {
                        self->applyIngress(snapshot);
                        if (self->pendingOps_ > 0) {
                            --self->pendingOps_;
                        }
                        // A provisional consume the worker did not handle is
                        // forwarded, in FIFO order, so no key is lost and the
                        // release cannot overtake its press.
                        if (consume && !handled && !self->retired_) {
                            ui->forwardKeyEvent(keyval, keycode, state);
                        }
                    });
            });
    if (token == hazkey::frontend::SerialTaskExecutor::kInvalidToken) {
        if (pendingOps_ > 0) {
            --pendingOps_;
        }
    }
}

void HazkeyFrontend::applyIngress(
    const HazkeyState::IngressSnapshot& snapshot) {
    if (retired_) {
        return;
    }
    specComposing_ = snapshot.composing;
    specListFocused_ = snapshot.listFocused;
    profileLoaded_ = snapshot.profileLoaded;
    liveConvert_ = snapshot.liveConvert;
    zenzaiToggle_ = snapshot.zenzaiToggle;
    acceptPrediction_ = snapshot.acceptPrediction;
    deleteLearning_ = snapshot.deleteLearning;
}

gboolean HazkeyFrontend::decideConsumeKey(guint keyval, guint state,
                                          const DecisionInput& in) {
    // Release events and the Shift key itself are never consumed by the IME
    // (the worker handles Shift state, but the key is not swallowed).
    if ((state & IBUS_RELEASE_MASK) != 0) {
        return FALSE;
    }
    if (keyval == IBUS_KEY_Shift_L || keyval == IBUS_KEY_Shift_R) {
        return FALSE;
    }

    // Global hotkeys are matched before anything else, exactly like
    // HazkeyState::processKeyEvent().
    if (HazkeyState::hotkeyMatches(keyval, state, in.liveConvert) ||
        HazkeyState::hotkeyMatches(keyval, state, in.zenzaiToggle)) {
        return TRUE;
    }

    const bool hasModifierPassthrough =
        (state & kModifierPassthroughMask) != 0;
    // Before the server profile is loaded the configured hotkeys are unknown,
    // so any modifier combo is provisionally consumed (and forwarded later if
    // the worker does not handle it). Returning FALSE here could let the app
    // act on a configured hazkey hotkey.
    if (!in.profileLoaded && hasModifierPassthrough) {
        return TRUE;
    }

    if (in.listFocused) {
        if (HazkeyState::hotkeyMatches(keyval, state, in.acceptPrediction) ||
            HazkeyState::hotkeyMatches(keyval, state, in.deleteLearning)) {
            return TRUE;
        }
        if (HazkeyState::isAltDigitKey(keyval, state) ||
            HazkeyState::isAltShiftSpaceOrTab(keyval, state)) {
            return TRUE;
        }
        // Non-hotkey Alt/Super/Meta/Hyper combos belong to the application.
        if ((state & (IBUS_MOD1_MASK | IBUS_SUPER_MASK | IBUS_MOD4_MASK |
                      IBUS_META_MASK | IBUS_HYPER_MASK)) != 0) {
            return FALSE;
        }
        // The worker's candidateKeyEvent handles these keys BEFORE its Control
        // branch, so e.g. Ctrl+Return / Ctrl+BackSpace / Ctrl+F6 are handled
        // while Ctrl+<letter> is not. Keep the same order here.
        if (isCandidateHandledKey(keyval)) {
            return TRUE;
        }
        // An exact Ctrl combo consumes the direct-conversion shortcuts and
        // forwards every other Ctrl key.
        if ((state & IBUS_CONTROL_MASK) != 0) {
            return HazkeyState::isDirectConversionShortcut(keyval, state) ? TRUE
                                                                          : FALSE;
        }
        if (keyval >= IBUS_KEY_0 && keyval <= IBUS_KEY_9) {
            return TRUE;
        }
        return HazkeyState::isInputableKey(keyval) ? TRUE : FALSE;
    }

    if (in.composing) {
        if (HazkeyState::isAltDigitKey(keyval, state) ||
            HazkeyState::isDirectConversionShortcut(keyval, state)) {
            return TRUE;
        }
        if (hasModifierPassthrough) {
            return FALSE;
        }
        if (isPreeditHandledKey(keyval)) {
            return TRUE;
        }
        return HazkeyState::isInputableKey(keyval) ? TRUE : FALSE;
    }

    // Idle: only Space / printable keys (and modifier combos already handled
    // above) are IME keys; everything else belongs to the application.
    if (hasModifierPassthrough) {
        return FALSE;
    }
    if (keyval == IBUS_KEY_space) {
        return TRUE;
    }
    return HazkeyState::isInputableKey(keyval) ? TRUE : FALSE;
}

gboolean HazkeyFrontend::processKeyEvent(guint keyval, guint keycode,
                                         guint state) {
    if (retired_) {
        return FALSE;
    }
    const bool isRelease = (state & IBUS_RELEASE_MASK) != 0;
    const bool shiftKey =
        keyval == IBUS_KEY_Shift_L || keyval == IBUS_KEY_Shift_R;

    // While any operation is still outstanding, or before the server profile
    // (and therefore the configured hotkeys) is known, the synchronous
    // decision cannot be trusted to be a superset of the worker's handled set
    // (e.g. a custom unmodified hotkey, or a candidate that a queued key is
    // about to focus). In that window every event -- releases included, so a
    // later-forwarded press cannot overtake its own release -- is consumed
    // provisionally; enqueueKeyOp() forwards whatever the worker does not
    // handle, preserving order.
    const bool barrier = pendingOps_ > 0 || !profileLoaded_;
    if (barrier) {
        enqueueKeyOp(keyval, keycode, state, TRUE);
        return TRUE;
    }

    if (isRelease || shiftKey) {
        enqueue([keyval, keycode, state](const std::shared_ptr<HazkeyState>& s) {
            s->processKeyEvent(keyval, keycode, state);
        });
        return FALSE;
    }

    // Optimistically assume an inputable key opens a composition, so an
    // immediately following Return/Escape/arrow is still recognized as
    // IME-owned. Corrected by applyIngress() and the forward fallback.
    if (HazkeyState::isInputableKey(keyval)) {
        specComposing_ = true;
    }

    DecisionInput in;
    in.composing = specComposing_;
    in.listFocused = specListFocused_;
    in.profileLoaded = profileLoaded_;
    in.liveConvert = liveConvert_;
    in.zenzaiToggle = zenzaiToggle_;
    in.acceptPrediction = acceptPrediction_;
    in.deleteLearning = deleteLearning_;
    const gboolean consume = decideConsumeKey(keyval, state, in);
    enqueueKeyOp(keyval, keycode, state, consume);
    return consume;
}

void HazkeyFrontend::focusIn() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->focusIn(); });
}

void HazkeyFrontend::focusOut() {
    if (retired_) return;
    specComposing_ = false;
    specListFocused_ = false;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->focusOut(); });
}

void HazkeyFrontend::reset() {
    if (retired_) return;
    specComposing_ = false;
    specListFocused_ = false;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->reset(); });
}

void HazkeyFrontend::enable() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->enable(); });
}

void HazkeyFrontend::disable() {
    if (retired_) return;
    specComposing_ = false;
    specListFocused_ = false;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->disable(); });
}

void HazkeyFrontend::setCapabilities(guint caps) {
    if (retired_) return;
    enqueue([caps](const std::shared_ptr<HazkeyState>& s) {
        s->setCapabilities(caps);
    });
}

bool HazkeyFrontend::activateProperty(const gchar* propName,
                                      guint propState) {
    if (retired_ || propName == nullptr) {
        return false;
    }
    if (g_strcmp0(propName, "InputMode") == 0) {
        // Static storage: safe to capture across the worker hop.
        enqueue([](const std::shared_ptr<HazkeyState>& s) {
            s->activateProperty("InputMode", 0);
        });
        return true;
    }
    if (g_strcmp0(propName, "Zenzai") == 0) {
        enqueue([](const std::shared_ptr<HazkeyState>& s) {
            s->activateProperty("Zenzai", 0);
        });
        return true;
    }
    (void)propState;
    return false;
}

void HazkeyFrontend::setCursorLocation(gint x, gint y, gint w, gint h) {
    if (retired_) return;
    enqueue([x, y, w, h](const std::shared_ptr<HazkeyState>& s) {
        s->setCursorLocation(x, y, w, h);
    });
}

void HazkeyFrontend::setSurroundingText(IBusText* text, guint cursorIndex,
                                        guint anchorPos) {
    if (retired_) return;
    // Copy to a plain string on the main loop; the IBusText is not retained.
    const std::string surrounding =
        (text != nullptr && ibus_text_get_text(text) != nullptr)
            ? ibus_text_get_text(text)
            : "";
    enqueue([surrounding, cursorIndex, anchorPos](
                const std::shared_ptr<HazkeyState>& s) {
        s->setSurroundingText(surrounding, cursorIndex, anchorPos);
    });
}

void HazkeyFrontend::pageUp() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->pageUp(); });
}

void HazkeyFrontend::pageDown() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->pageDown(); });
}

void HazkeyFrontend::cursorUp() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->cursorUp(); });
}

void HazkeyFrontend::cursorDown() {
    if (retired_) return;
    enqueue([](const std::shared_ptr<HazkeyState>& s) { s->cursorDown(); });
}

void HazkeyFrontend::candidateClicked(guint index, guint button, guint state) {    (void)button;
    (void)state;
    if (retired_) return;
    // Resolve the page-local index against exactly the render the user saw,
    // on the main loop where that snapshot lives.
    const HazkeyUi::LookupSnapshot snapshot = ui_->lookupSnapshot();
    if (!snapshot.visible || snapshot.pageSize <= 0) {
        return;
    }
    const int global = HazkeyState::pageLocalToGlobalIndex(
        snapshot.pageSize, snapshot.total,
        snapshot.cursorPos >= 0 ? snapshot.cursorPos : 0,
        static_cast<int>(index));
    if (global < 0) {
        return;
    }
    const int generation = snapshot.generation;
    enqueue([global, generation](const std::shared_ptr<HazkeyState>& s) {
        s->candidateClickedGlobal(global, generation);
    });
}

void shutdownSharedExecutor() { sharedExecutor().shutdown(); }

}  // namespace hazkey::ibus
