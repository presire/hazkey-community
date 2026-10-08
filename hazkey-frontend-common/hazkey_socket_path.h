#ifndef HAZKEY_SOCKET_PATH_H
#define HAZKEY_SOCKET_PATH_H

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <string>
#include <utility>
#include <unistd.h>

/** @brief fcitx5とIBusが共有するソケットパス規則 */
namespace hazkey::frontend {

/** @brief サーバソケットのパス解決結果 */
struct ServerSocketPath {
    std::string path;
    bool runtimeDirectoryTrusted;
    bool pathFits;
    bool usedFallback;
};

/** @brief UID専用の一時ランタイムディレクトリ名を返す */
inline std::string privateRuntimeDirectory(uid_t uid) {
    return "/tmp/hazkey-community-runtime-" + std::to_string(uid);
}

/** @brief ランタイムディレクトリとUIDからサーバソケットパスを組み立てる */
inline std::string serverSocketPath(const std::string& runtimeDirectory,
                                    uid_t uid) {
    return runtimeDirectory + "/hazkey-community-server." +
           std::to_string(uid) + ".sock";
}

/** @brief 信頼できるランタイムディレクトリかを検査して接続先候補を解決する */
inline ServerSocketPath resolveServerSocketPath(const char* xdgRuntimeDir,
                                                uid_t uid) {
    struct stat status {};
    if (xdgRuntimeDir != nullptr && xdgRuntimeDir[0] != '\0' &&
        stat(xdgRuntimeDir, &status) == 0 && S_ISDIR(status.st_mode) &&
        status.st_uid == uid && (status.st_mode & 0077) == 0) {
        std::string path = serverSocketPath(xdgRuntimeDir, uid);
        const bool pathFits = path.size() < sizeof(sockaddr_un{}.sun_path);
        return {std::move(path), true, pathFits, false};
    }

    const std::string runtimeDirectory = privateRuntimeDirectory(uid);
    const bool trusted =
        lstat(runtimeDirectory.c_str(), &status) == 0 &&
        S_ISDIR(status.st_mode) && status.st_uid == uid &&
        (status.st_mode & 0077) == 0;
    std::string path = serverSocketPath(runtimeDirectory, uid);
    const bool pathFits = path.size() < sizeof(sockaddr_un{}.sun_path);
    return {std::move(path), trusted, pathFits, true};
}

}  // namespace hazkey::frontend

#endif  // HAZKEY_SOCKET_PATH_H
