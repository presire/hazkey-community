#ifndef CHAZKEY_LINUX_H
#define CHAZKEY_LINUX_H
#include <stddef.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
int hazkey_accept_cloexec(int fd);
int hazkey_pipe_cloexec(int fds[2]);
int hazkey_peer_uid(int fd, uid_t *uid);
int hazkey_pidfd_open(pid_t pid);
int hazkey_pidfd_send_signal(int fd, int signal);
int hazkey_spawn_probe(const char *path, char *const argv[], pid_t *pid);
int hazkey_wait_exit_code(int status);
int hazkey_wait_signal(int status);
int hazkey_sealed_memfd(const char *name, const void *data, size_t length);
#ifdef __cplusplus
}
#endif
#endif
