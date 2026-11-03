#include <aquamarine/backend/Backend.hpp>
#include <aquamarine/backend/Wsl.hpp>
#include <aquamarine/input/Input.hpp>
#include <cassert>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "wdp.h"
using namespace Hyprutils::Memory;
using namespace Aquamarine;

static_assert(sizeof(wdp_pointer_warp) == 20);

// No compositor or GPU: an isolated AF_UNIX backend and an authenticated fake viewer.
// Compile without NDEBUG, since assertions include the operations being tested.
int main() {
    char dir[] = "/tmp/womarchy-warp-smoke-XXXXXX";
    assert(mkdtemp(dir));
    std::string path = std::string(dir) + "/display.sock";
    setenv("WOMARCHY_TOKEN", std::string(64, 'a').c_str(), 1);
    setenv("WOMARCHY_LISTEN_UNIX", path.c_str(), 1);
    setenv("WOMARCHY_SHM_DIR", "", 1);
    setenv("WOMARCHY_ORPHAN_TIMEOUT", "0", 1);
    setenv("WOMARCHY_MONITORS", "1:0:0:1920:1080:60000:1250:1:primary;2:-1920:-507:1920:1080:60000:1000:0:secondary", 1);
    SBackendImplementationOptions impl;
    impl.backendType = AQ_BACKEND_WSL;
    impl.backendRequestMode = AQ_BACKEND_REQUEST_MANDATORY;
    auto backend = CBackend::create({impl}, SBackendOptions{});
    assert(backend);
    std::vector<CSharedPointer<IOutput>> outputs;
    auto listener = backend->events.newOutput.listen([&](auto o) { outputs.push_back(o); });
    Hyprutils::Signal::CHyprSignalListener motion;
    int motions = 0;
    auto pointerListener = backend->events.newPointer.listen([&](auto pointer) {
        motion = pointer->events.warp.listen([&](const IPointer::SWarpEvent&) {
            ++motions;
            for (auto& o : outputs) o->moveCursor({100, 200});
        });
    });
    assert(backend->start());
    auto pump = [&] {
        for (int n = 0; n < 10; ++n) {
            auto fds = backend->getPollFDs();
            std::vector<pollfd> polls;
            for (auto& fd : fds) polls.push_back({fd->fd, POLLIN, 0});
            assert(poll(polls.data(), polls.size(), 10) >= 0);
            for (size_t i = 0; i < polls.size(); ++i) if (polls[i].revents & POLLIN) fds[i]->onSignal();
        }
    };
    pump();
    assert(outputs.size() == 2);
    int client = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    assert(client >= 0);
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    assert(connect(client, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
    auto sendMessage = [&](uint32_t type, const auto& message) {
        wdp_header header{type, sizeof(message)};
        assert(send(client, &header, sizeof(header), MSG_NOSIGNAL) == sizeof(header));
        assert(send(client, &message, sizeof(message), MSG_NOSIGNAL) == sizeof(message));
    };
    wdp_hello hello{.version = WDP_VERSION, .transports = 1u << WDP_TRANSPORT_INLINE};
    memset(hello.proof, 0xaa, sizeof(hello.proof));
    sendMessage(WDP_HELLO, hello);
    pump();
    auto drain = [&] {
        std::vector<uint8_t> data;
        uint8_t bytes[4096];
        ssize_t n;
        while ((n = recv(client, bytes, sizeof(bytes), MSG_DONTWAIT)) > 0) data.insert(data.end(), bytes, bytes + n);
        assert(n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
        return data;
    };
    auto initial = drain();
    assert(initial.size() >= sizeof(wdp_header) + sizeof(wdp_welcome));
    wdp_header welcomeHeader;
    memcpy(&welcomeHeader, initial.data(), sizeof(welcomeHeader));
    assert(welcomeHeader.type == WDP_WELCOME);
    for (auto& output : outputs) {
        auto* wsl = dynamic_cast<CWslOutput*>(output.get());
        assert(wsl);
        wsl->moveCursor({20, 40});
        assert(drain().empty());
        wsl->warpCursor({1200.5, 800.25});
        auto data = drain();
        assert(data.size() == sizeof(wdp_header) + sizeof(wdp_pointer_warp));
        wdp_header header;
        wdp_pointer_warp warp;
        memcpy(&header, data.data(), sizeof(header));
        memcpy(&warp, data.data() + sizeof(header), sizeof(warp));
        assert(header.type == WDP_POINTER_WARP && header.size == sizeof(warp));
        assert(warp.output_id == wsl->monitorID && warp.x == 1200.5 && warp.y == 800.25);
        wdp_pointer_abs echo{.time_ms = 1, .output_id = wsl->monitorID, .x = warp.x, .y = warp.y};
        sendMessage(WDP_POINTER_ABS, echo);
        pump();
        assert(drain().empty());
    }
    assert(motions == 2);
    close(client);
    backend.reset();
    unlink(path.c_str());
    rmdir(dir);
    std::cout << "PASS: authenticated warps reach both outputs; ordinary motion and warp echoes send no warps\n";
}
