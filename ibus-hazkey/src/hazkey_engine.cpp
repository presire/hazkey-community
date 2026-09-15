#include "hazkey_engine.h"

#include <memory>

#include "hazkey_frontend.h"
#include "hazkey_frontend_glib.h"

typedef struct _IBusHazkeyEngine IBusHazkeyEngine;
typedef struct _IBusHazkeyEngineClass IBusHazkeyEngineClass;

struct _IBusHazkeyEngine {
    IBusEngineSimple parent;
    // Pointer to shared_ptr: GObject instances are allocated without running
    // C++ constructors, so a non-trivial member cannot live directly in this
    // struct. The facade is shared so worker tasks can keep it alive until
    // they finish (see HazkeyFrontend).
    std::shared_ptr<hazkey::ibus::HazkeyFrontend>* frontend;
};

struct _IBusHazkeyEngineClass {
    IBusEngineSimpleClass parent;
};

G_DEFINE_TYPE(IBusHazkeyEngine, ibus_hazkey_engine, IBUS_TYPE_ENGINE_SIMPLE)

namespace {
hazkey::ibus::HazkeyFrontend* frontendOf(IBusEngine* engine) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(engine);
    if (hazkeyEngine->frontend == nullptr) {
        return nullptr;
    }
    return hazkeyEngine->frontend->get();
}
}  // namespace

static gboolean ibusHazkeyEngineProcessKeyEvent(IBusEngine* engine,
                                                guint keyval, guint keycode,
                                                guint state) {
    auto* frontend = frontendOf(engine);
    if (frontend == nullptr) {
        return FALSE;
    }
    return frontend->processKeyEvent(keyval, keycode, state);
}

static void ibusHazkeyEngineFocusIn(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->focusIn();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->focus_in != nullptr) {
        parent->focus_in(engine);
    }
}

static void ibusHazkeyEngineFocusOut(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->focusOut();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->focus_out != nullptr) {
        parent->focus_out(engine);
    }
}

static void ibusHazkeyEngineReset(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->reset();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->reset != nullptr) {
        parent->reset(engine);
    }
}

static void ibusHazkeyEngineEnable(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->enable();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->enable != nullptr) {
        parent->enable(engine);
    }
}

static void ibusHazkeyEngineSetCapabilities(IBusEngine* engine, guint caps) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->setCapabilities(caps);
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->set_capabilities != nullptr) {
        parent->set_capabilities(engine, caps);
    }
}

static void ibusHazkeyEnginePropertyActivate(IBusEngine* engine,
                                             const gchar* propName,
                                             guint propState) {
    auto* frontend = frontendOf(engine);
    const bool handled =
        frontend != nullptr && frontend->activateProperty(propName, propState);
    if (!handled) {
        IBusEngineClass* parent =
            IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
        if (parent->property_activate != nullptr) {
            parent->property_activate(engine, propName, propState);
        }
    }
}

static void ibusHazkeyEngineDisable(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->disable();
    }
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->disable != nullptr) {
        parent->disable(engine);
    }
}

static void ibusHazkeyEngineSetCursorLocation(IBusEngine* engine, gint x,
                                              gint y, gint width, gint height) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->setCursorLocation(x, y, width, height);
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
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->setSurroundingText(text, cursorIndex, anchorPos);
    }
    // Keep IBus's own surrounding-text cache in sync (it owns the text via
    // g_object_ref_sink). Our frontend copies the text to a plain string, so
    // this only affects IBus_engine_get_surrounding_text()/delete_surrounding_text().
    IBusEngineClass* parent = IBUS_ENGINE_CLASS(ibus_hazkey_engine_parent_class);
    if (parent->set_surrounding_text != nullptr) {
        parent->set_surrounding_text(engine, text, cursorIndex, anchorPos);
    }
}

static void ibusHazkeyEnginePageUp(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->pageUp();
    }
}

static void ibusHazkeyEnginePageDown(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->pageDown();
    }
}

static void ibusHazkeyEngineCursorUp(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->cursorUp();
    }
}

static void ibusHazkeyEngineCursorDown(IBusEngine* engine) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->cursorDown();
    }
}

static void ibusHazkeyEngineCandidateClicked(IBusEngine* engine, guint index,
                                             guint button, guint state) {
    if (auto* frontend = frontendOf(engine); frontend != nullptr) {
        frontend->candidateClicked(index, button, state);
    }
}

static void ibusHazkeyEngineDestroy(IBusObject* object) {
    auto* hazkeyEngine = reinterpret_cast<IBusHazkeyEngine*>(object);
    if (hazkeyEngine->frontend != nullptr) {
        // Release every IBus/GObject owned by the renderer on this (main)
        // thread before the engine is finalized; worker tasks that still hold
        // the facade/state finish harmlessly because the UI is retired.
        hazkeyEngine->frontend->get()->retire();
        delete hazkeyEngine->frontend;
        hazkeyEngine->frontend = nullptr;
    }
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
    engine->frontend = new std::shared_ptr<hazkey::ibus::HazkeyFrontend>(
        std::make_shared<hazkey::ibus::HazkeyFrontend>(IBUS_ENGINE(engine)));
    g_debug("hazkey: IBus engine initialized");
}
