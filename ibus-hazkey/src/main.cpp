#include <ibus.h>
#include <glib.h>

#include "engine_description.h"
#include "hazkey_engine.h"
#include "hazkey_frontend.h"
#include "hazkey_frontend_glib.h"

#include <cstring>
#include <locale.h>

namespace {

constexpr const char* kEngineName = "hazkey";
constexpr const char* kComponentBusName = "org.freedesktop.IBus.Hazkey";


typedef struct _IBusHazkeyFactory IBusHazkeyFactory;
typedef struct _IBusHazkeyFactoryClass IBusHazkeyFactoryClass;

struct _IBusHazkeyFactory {
    IBusFactory parent;
};

struct _IBusHazkeyFactoryClass {
    IBusFactoryClass parent;
};

G_DEFINE_TYPE(IBusHazkeyFactory, ibus_hazkey_factory, IBUS_TYPE_FACTORY)

#define IBUS_TYPE_HAZKEY_FACTORY (ibus_hazkey_factory_get_type())

static void ibus_hazkey_factory_class_init(
    [[maybe_unused]] IBusHazkeyFactoryClass* factoryClass) {}

static void ibus_hazkey_factory_init(IBusHazkeyFactory* factory) {
    ibus_factory_add_engine(IBUS_FACTORY(factory), kEngineName,
                            IBUS_TYPE_HAZKEY_ENGINE);
}

static IBusFactory* ibusHazkeyFactoryNew(GDBusConnection* connection) {
    return IBUS_FACTORY(g_object_new(IBUS_TYPE_HAZKEY_FACTORY, "object-path",
                                     IBUS_PATH_FACTORY, "connection", connection,
                                     nullptr));
}

static void onBusDisconnected([[maybe_unused]] IBusBus* bus,
                              [[maybe_unused]] gpointer userData) {
    g_debug("hazkey: disconnected from IBus");
    ibus_quit();
}

}  // namespace

int main(int argc, char* argv[]) {
    // Required for g_dgettext("ibus-hazkey", ...) in hazkey_state.cpp (and
    // the panel's dgettext of <longname>/<description>) to return Japanese:
    // without this, gettext always falls back to the English msgid.
    setlocale(LC_ALL, "");
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--xml") == 0) {
            g_print("%s", hazkey::ibus::kEngineDescriptionXml);
            return 0;
        }
    }

    ibus_init();

    IBusBus* bus = ibus_bus_new();
    if (bus != nullptr) {
        g_object_ref_sink(bus);
    }
    if (bus == nullptr || !ibus_bus_is_connected(bus)) {
        g_warning("hazkey: unable to connect to IBus");
        if (bus != nullptr) {
            g_object_unref(bus);
        }
        return 1;
    }

    g_signal_connect(bus, "disconnected", G_CALLBACK(onBusDisconnected), nullptr);
    hazkey::ibus::installGlibFrontendHooks();

    IBusFactory* factory = ibusHazkeyFactoryNew(ibus_bus_get_connection(bus));
    const guint32 result = ibus_bus_request_name(
        bus, kComponentBusName,
        IBUS_BUS_NAME_FLAG_REPLACE_EXISTING | IBUS_BUS_NAME_FLAG_ALLOW_REPLACEMENT);
    // A non-zero reply is not necessarily success: IN_QUEUE/EXISTS mean this
    // process does not own the component name, so only continue as owner.
    if (result != IBUS_BUS_REQUEST_NAME_REPLY_PRIMARY_OWNER &&
        result != IBUS_BUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
        g_warning("hazkey: unable to acquire IBus component name (reply %u)",
                  result);
        g_object_unref(factory);
        g_object_unref(bus);
        return 1;
    }

    ibus_main();

    // Join the async worker before the process tears down the function-static
    // hooks/connector it uses (see shutdownSharedExecutor()).
    hazkey::ibus::shutdownSharedExecutor();

    g_object_unref(factory);
    g_object_unref(bus);
    return 0;
}
