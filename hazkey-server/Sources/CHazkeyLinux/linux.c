#define _GNU_SOURCE
#include "CHazkeyLinux.h"
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>

int hazkey_accept_cloexec(int fd) {
    return accept4(fd, NULL, NULL, SOCK_CLOEXEC);
}

int hazkey_pipe_cloexec(int fds[2]) {
    return pipe2(fds, O_CLOEXEC);
}

int hazkey_peer_uid(int fd, uid_t *uid) {
    struct ucred peer;
    socklen_t size = sizeof(peer);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) != 0) return -1;
    if (size != sizeof(peer)) { errno = EINVAL; return -1; }
    *uid = peer.uid;
    return 0;
}
