// Verifies that HazkeyServerConnector notices a server-side config revision
// change through ordinary responses and reports it exactly once, so the
// frontends can reload their cached profile as soon as settings are applied.
#include <arpa/inet.h>
#include <assert.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>

#include "hazkey_server_connector.h"

namespace {

bool readAll(int fd, void* data, size_t size) {
    auto* bytes = static_cast<char*>(data);
    size_t offset = 0;
    while (offset < size) {
        const ssize_t count = read(fd, bytes + offset, size - offset);
        if (count <= 0) {
            return false;
        }
        offset += static_cast<size_t>(count);
    }
    return true;
}

bool writeAll(int fd, const void* data, size_t size) {
    const auto* bytes = static_cast<const char*>(data);
    size_t offset = 0;
    while (offset < size) {
        const ssize_t count = write(fd, bytes + offset, size - offset);
        if (count <= 0) {
            return false;
        }
        offset += static_cast<size_t>(count);
    }
    return true;
}

class RevisionServer {
   public:
    explicit RevisionServer(const std::string& path) : path_(path) {
        listenFd_ = socket(AF_UNIX, SOCK_STREAM, 0);
        assert(listenFd_ >= 0);
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
        assert(bind(listenFd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
        assert(listen(listenFd_, 1) == 0);
        thread_ = std::thread([this] { serve(); });
    }

    ~RevisionServer() {
        if (listenFd_ >= 0) {
            close(listenFd_);
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        unlink(path_.c_str());
    }

    void setRevision(uint64_t revision) {
        std::lock_guard<std::mutex> lock(mutex_);
        revision_ = revision;
    }

   private:
    void serve() {
        const int clientFd = accept(listenFd_, nullptr, nullptr);
        if (clientFd < 0) {
            return;
        }
        timeval timeout = {2, 0};
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        while (true) {
            uint32_t networkLength = 0;
            if (!readAll(clientFd, &networkLength, sizeof(networkLength))) {
                break;
            }
            const uint32_t length = ntohl(networkLength);
            std::string wire(length, '\0');
            if (!readAll(clientFd, wire.data(), wire.size())) {
                break;
            }
            hazkey::RequestEnvelope request;
            assert(request.ParseFromString(wire));
            uint64_t revision = 0;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                revision = revision_;
            }
            hazkey::ResponseEnvelope response;
            response.set_status(hazkey::SUCCESS);
            response.mutable_current_config();
            response.set_config_revision(revision);
            std::string responseWire;
            assert(response.SerializeToString(&responseWire));
            const uint32_t responseLength = htonl(responseWire.size());
            if (!writeAll(clientFd, &responseLength, sizeof(responseLength))
                || !writeAll(clientFd, responseWire.data(), responseWire.size())) {
                break;
            }
        }
        close(clientFd);
    }

    int listenFd_ = -1;
    std::string path_;
    std::thread thread_;
    mutable std::mutex mutex_;
    uint64_t revision_ = 0;
};

}  // namespace

int main() {
    char directoryTemplate[] = "/tmp/hazkey-config-revision-XXXXXX";
    char* directory = mkdtemp(directoryTemplate);
    assert(directory != nullptr);
    const std::string root(directory);
    const std::string socketPath =
        root + "/hazkey-community-server." + std::to_string(getuid()) + ".sock";
    assert(setenv("XDG_RUNTIME_DIR", root.c_str(), 1) == 0);

    RevisionServer server(socketPath);
    server.setRevision(5);

    HazkeyServerConnector connector;

    // The first observed revision only establishes the baseline.
    assert(connector.getServerConfig().has_value());
    assert(connector.configRevision() == 5);
    assert(!connector.consumeConfigChanged());

    // A bump is reported exactly once.
    server.setRevision(6);
    assert(connector.getServerConfig().has_value());
    assert(connector.consumeConfigChanged());
    assert(!connector.consumeConfigChanged());

    // An unchanged revision is not reported.
    assert(connector.getServerConfig().has_value());
    assert(!connector.consumeConfigChanged());

    // A reset (server restart) is still a change.
    server.setRevision(0);
    assert(connector.getServerConfig().has_value());
    assert(connector.consumeConfigChanged());

    std::cout << "[PASS] config revision change detection\n";
    return 0;
}
