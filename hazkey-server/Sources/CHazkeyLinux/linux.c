#define _GNU_SOURCE
#include "CHazkeyLinux.h"
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <spawn.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>

extern char **environ;

/**
 * @brief 古いヘッダでも[pidfd]のシステムコール番号を数値で指定できる既知のABIだけを列挙する
 *
 * [SYS_pidfd_open]が未定義の場合は434、[SYS_pidfd_send_signal]が未定義の場合は424を使う
 * MIPSやx32など番号体系が異なるABIや、この条件で列挙しないABIでは数値による代替を行わない
 * 対応する[SYS_*]が未定義の場合は[errno]を[ENOSYS]に設定して-1を返し、別のシステムコールを誤って実行しない
 */
#if (defined(__x86_64__) && !defined(__ILP32__)) || defined(__i386__) || \
    defined(__aarch64__) || defined(__arm__) || defined(__riscv) || \
    defined(__powerpc64__) || defined(__s390x__) || defined(__loongarch__) || defined(__sparc__)
#define HAZKEY_GENERIC_PIDFD_SYSCALL_ABI 1
#endif

int hazkey_accept_cloexec(int fd) {
    return accept4(fd, NULL, NULL, SOCK_CLOEXEC);
}

int hazkey_pipe_cloexec(int fds[2]) {
    return pipe2(fds, O_CLOEXEC | O_NONBLOCK);
}

int hazkey_peer_uid(int fd, uid_t *uid) {
    struct ucred peer;
    socklen_t size = sizeof(peer);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) != 0) return -1;
    if (size != sizeof(peer)) { errno = EINVAL; return -1; }
    *uid = peer.uid;
    return 0;
}

int hazkey_pidfd_open(pid_t pid) {
#ifdef SYS_pidfd_open
    return syscall(SYS_pidfd_open, pid, 0);
#elif defined(HAZKEY_GENERIC_PIDFD_SYSCALL_ABI)
    return syscall(434, pid, 0);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int hazkey_pidfd_send_signal(int fd, int signal) {
#ifdef SYS_pidfd_send_signal
    return syscall(SYS_pidfd_send_signal, fd, signal, NULL, 0);
#elif defined(HAZKEY_GENERIC_PIDFD_SYSCALL_ABI)
    return syscall(424, fd, signal, NULL, 0);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int hazkey_spawn_probe(const char *path, char *const argv[], pid_t *pid) {
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error != 0) return error;
    error = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    if (error == 0) error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    if (error == 0) error = posix_spawn(pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    return error;
}

int hazkey_wait_exit_code(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int hazkey_wait_signal(int status) {
    return WIFSIGNALED(status) ? WTERMSIG(status) : 0;
}

/* 内容を写したmemfdを作成し、縮小・拡大・書き込みを封印して返す
 * 封印後は他の記述子やパス (/proc/self/fd/N) から開いても内容を変更できないため、
 * 上限付きで読み込んだ内容を、URLから全体を読み直すライブラリへ安全に渡せる
 * 失敗時は-1を返し、errnoを保つ */
int hazkey_sealed_memfd(const char *name, const void *data, size_t length) {
    int fd = memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        return -1;
    }
    const char *bytes = data;
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, bytes + offset, length - offset);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            if (written == 0) {
                errno = EIO;
            }
            goto fail;
        }
        offset += (size_t)written;
    }
    if (fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE | F_SEAL_SEAL) != 0) {
        goto fail;
    }
    return fd;

fail: {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
}
}
