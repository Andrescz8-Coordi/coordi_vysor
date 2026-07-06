#include "socket_emitter.h"

#include <android/log.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>

namespace {

constexpr const char* kTag = "CoordiNetAgent";

std::mutex g_mutex;
int g_socketFd = -1;
std::atomic<bool> g_hiloIniciado{false};

void* hiloCliente(void* arg) {
    const int puerto = *static_cast<int*>(arg);
    delete static_cast<int*>(arg);

    for (int intento = 0; intento < 60; ++intento) {
        const int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            sleep(1);
            continue;
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(static_cast<uint16_t>(puerto));
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (g_socketFd >= 0) close(g_socketFd);
            g_socketFd = fd;
            __android_log_print(
                ANDROID_LOG_INFO, kTag,
                "Conectado al host vía adb reverse en 127.0.0.1:%d", puerto);
            return nullptr;
        }
        close(fd);
        sleep(1);
    }
    __android_log_print(
        ANDROID_LOG_WARN, kTag,
        "No se pudo conectar al host en puerto %d; solo Logcat", puerto);
    return nullptr;
}

}  // namespace

void iniciarSocket(int puerto) {
    if (g_hiloIniciado.exchange(true)) return;
    auto* puertoHeap = new int(puerto);
    pthread_t hilo;
    pthread_create(&hilo, nullptr, hiloCliente, puertoHeap);
    pthread_detach(hilo);
}

void emitirJson(const std::string& json) {
    __android_log_print(ANDROID_LOG_INFO, kTag, "FLOW %s", json.c_str());
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_socketFd < 0) return;

    // Frame: [uint32 big-endian payload_len][payload UTF-8]
    const uint32_t len = static_cast<uint32_t>(json.size());
    uint8_t header[4];
    header[0] = static_cast<uint8_t>((len >> 24) & 0xFF);
    header[1] = static_cast<uint8_t>((len >> 16) & 0xFF);
    header[2] = static_cast<uint8_t>((len >> 8) & 0xFF);
    header[3] = static_cast<uint8_t>(len & 0xFF);

    // Combinar header + payload en un solo buffer para minimizar writes parciales
    std::string frame(reinterpret_cast<const char*>(header), 4);
    frame += json;

    size_t enviadoTotal = 0;
    while (enviadoTotal < frame.size()) {
        const ssize_t n = send(
            g_socketFd,
            frame.data() + enviadoTotal,
            frame.size() - enviadoTotal,
            MSG_NOSIGNAL);
        if (n <= 0) {
            close(g_socketFd);
            g_socketFd = -1;
            return;
        }
        enviadoTotal += static_cast<size_t>(n);
    }
}

void emitirDiag(const std::string& mensaje) {
    __android_log_print(ANDROID_LOG_INFO, kTag, "DIAG %s", mensaje.c_str());
    std::string json = R"({"type":"diag","msg":")" + mensaje + R"("})";
    emitirJson(json);
}
