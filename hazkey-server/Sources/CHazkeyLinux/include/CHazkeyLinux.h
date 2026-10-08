#ifndef CHAZKEY_LINUX_H
#define CHAZKEY_LINUX_H
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
int hazkey_accept_cloexec(int fd);
int hazkey_pipe_cloexec(int fds[2]);
int hazkey_peer_uid(int fd, uid_t *uid);
#ifdef __cplusplus
}
#endif
#endif
