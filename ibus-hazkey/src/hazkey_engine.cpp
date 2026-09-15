#include "hazkey_engine.h"

#include "hazkey_frontend_glib.h"
#include "hazkey_state.h"

typedef struct _IBusHazkeyEngine IBusHazkeyEngine;
typedef struct _IBusHazkeyEngineClass IBusHazkeyEngineClass;

struct _IBusHazkeyEngine {
    IBusEngineSimple parent;
    hazkey::ibus::HazkeyState* state;
};

struct _IBusHazkeyEngineClass {
    IBusEngineSimpleClass parent;
};

G_DEFINE_TYPE(IBusHazkeyEngine, ibus_hazkey_engine, IBUS_TYPE_ENGINE_SIMPLE)

static gboolean ibusHazkeyEngineProcessKeyEvent(IBusEngine* engine,
                                                guint keyval, guint keycode,
                                                guint state) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state == nullptr) {
        return FALSE;
    }
    return hazkeyEngine->state->processKeyEvent(keyval, keycode, state);
}

static void ibusHazkeyEngineFocusIn(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->focusIn();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->focus_in != nullptr) {
        parent->focus_in(engine);
    }
}

static void ibusHazkeyEngineFocusOut(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->focusOut();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->focus_out != nullptr) {
        parent->focus_out(engine);
    }
}

static void ibusHazkeyEngineReset(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->reset();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->reset != nullptr) {
        parent->reset(engine);
    }
}

static void ibusHazkeyEngineEnable(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->enable();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->enable != nullptr) {
        parent->enable(engine);
    }
}

static void ibusHazkeyEngineSetCapabilities(IBusEngine* engine, guint caps) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->setCapabilities(caps);
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->set_capabilities != nullptr) {
        parent->set_capabilities(engine, caps);
    }
}

static void ibusHazkeyEnginePropertyActivate(IBusEngine* engine,
                                             const gchar* propName,
                                             guint propState) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    const bool handled = hazkeyEngine->state != nullptr &&
                         hazkeyEngine->state->activateProperty(propName, propState);
    if (!handled) {
        IBusEngineClass* parent =
            IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
        if (parent->property_activate != nullptr) {
            parent->property_activate(engine, propName, propState);
        }
    }
}

static void ibusHazkeyEngineDisable(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->disable();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->disable != nullptr) {
        parent->disable(engine);
    }
}

static void ibusHazkeyEngineSetCursorLocation(IBusEngine* engine, gint x,
                                              gint y, gint width, gint height) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->setCursorLocation(x, y, width, height);
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->set_cursor_location != nullptr) {
        parent->set_cursor_location(engine, x, y, width, height);
    }
}

static void ibusHazkeyEngineSetSurroundingText(IBusEngine* engine,
                                               IBusText* text,
                                               guint cursorIndex,
                                               guint anchorPos) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->setSurroundingText(text, cursorIndex, anchorPos);
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->set_surrounding_text != nullptr) {
        parent->set_surrounding_text(engine, text, cursorIndex, anchorPos);
    }
}

static void ibusHazkeyEnginePageUp(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->pageUp();
    }
}

static void ibusHazkeyEnginePageDown(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->pageDown();
    }
}

static void ibusHazkeyEngineCursorUp(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->cursorUp();
    }
}

static void ibusHazkeyEngineCursorDown(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->cursorDown();
    }
}

static void ibusHazkeyEngineCandidateClicked(IBusEngine* engine, guint index,
                                             guint button, guint state) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->state != nullptr) {
        hazkeyEngine->state->candidateClicked(index, button, state);
    }
}

static void ibusHazkeyEngineDestroy(IBusObject* object) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(object);
    delete hazkeyEngine->state;
    hazkeyEngine->state = nullptr;
    IBUS_OBJECT_CLASS(ibus_hazkey_engine_parent_class)->destroy(object);
}

static void ibus_hazkey_engine_class_init(IBusHazkeyEngineClass* engineClass) {
    IBusEngineClass* engine = IBUS_ENGINE_CLASS(engineClass);
    engine->process_key_event = ibusHazkeyEngineProcessKeyEvent;
    engine->focus_in = ibusHazkeyEngineFocusIn;
    engine->focus_out = ibusHazkeyEngineFocusOut;
    engine->reset = ibusHazkeyEngineReset;
    engine->enable = ibusHazkeyEngineEnable;
    engine->disable = ibusHazkeyEngineDisable;
    engine->set_capabilities = ibusHazkeyEngineSetCapabilities;
    engine->property_activate = ibusHazkeyEnginePropertyActivate;
    engine->set_cursor_location = ibusHazkeyEngineSetCursorLocation;
    engine->set_surrounding_text = ibusHazkeyEngineSetSurroundingText;
    engine->page_up = ibusHazkeyEnginePageUp;
    engine->page_down = ibusHazkeyEnginePageDown;
    engine->cursor_up = ibusHazkeyEngineCursorUp;
    engine->cursor_down = ibusHazkeyEngineCursorDown;
    engine->candidate_clicked = ibusHazkeyEngineCandidateClicked;
    IBusObjectClass* objectClass = IBUS_OBJECT_CLASS(engineClass);
    objectClass->destroy = ibusHazkeyEngineDestroy;
}

static void ibus_hazkey_engine_init(IBusHazkeyEngine* engine) {
    hazkey::ibus::installGlibFrontendHooks();
    engine->state = new hazkey::ibus::HazkeyState(IBUS_ENGINE(engine));
    g_debug("hazkey: IBus engine initialized");
}
