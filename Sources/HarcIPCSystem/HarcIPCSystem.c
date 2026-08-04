#include "HarcIPCSystem.h"

#include <bsm/libbsm.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <mach/message.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static pthread_mutex_t harc_umask_lock = PTHREAD_MUTEX_INITIALIZER;

static int harc_set_descriptor_policy(int descriptor) {
    if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1) return -1;
    int enabled = 1;
    if (setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                   &enabled, sizeof(enabled)) == -1) return -1;
    struct timeval timeout = { .tv_sec = 10, .tv_usec = 0 };
    if (setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, sizeof(timeout)) == -1) return -1;
    if (setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO,
                   &timeout, sizeof(timeout)) == -1) return -1;
    return 0;
}

static int harc_make_address(const char *path, struct sockaddr_un *address) {
    size_t length = strlen(path);
    if (length == 0 || length >= sizeof(address->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    address->sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path)
        + length + 1);
    memcpy(address->sun_path, path, length + 1);
    return 0;
}

static int harc_open_parent(
    const char *socket_path,
    uid_t expected_uid,
    int *out_parent,
    char **out_name
) {
    char *directory_copy = strdup(socket_path);
    char *name_copy = strdup(socket_path);
    if (directory_copy == NULL || name_copy == NULL) {
        free(directory_copy);
        free(name_copy);
        errno = ENOMEM;
        return -1;
    }
    char *directory = dirname(directory_copy);
    char *name = basename(name_copy);
    if (name[0] == '\0' || strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        free(directory_copy);
        free(name_copy);
        errno = EINVAL;
        return -1;
    }
    int parent = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parent == -1) {
        free(directory_copy);
        free(name_copy);
        return -1;
    }
    struct stat status;
    if (fstat(parent, &status) == -1 || !S_ISDIR(status.st_mode)
        || status.st_uid != expected_uid || (status.st_mode & 0777) != 0700) {
        int saved = errno == 0 ? EPERM : errno;
        close(parent);
        free(directory_copy);
        free(name_copy);
        errno = saved;
        return -1;
    }
    *out_parent = parent;
    *out_name = strdup(name);
    free(directory_copy);
    free(name_copy);
    if (*out_name == NULL) {
        close(parent);
        errno = ENOMEM;
        return -1;
    }
    return 0;
}

static int harc_connect_descriptor(const char *socket_path) {
    struct sockaddr_un address;
    if (harc_make_address(socket_path, &address) == -1) return -1;
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor == -1) return -1;
    if (harc_set_descriptor_policy(descriptor) == -1) {
        int saved = errno;
        close(descriptor);
        errno = saved;
        return -1;
    }
    if (connect(descriptor, (struct sockaddr *)&address, address.sun_len) == -1) {
        int saved = errno;
        close(descriptor);
        errno = saved;
        return -1;
    }
    return descriptor;
}

static int harc_same_socket(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev
        && left->st_ino == right->st_ino
        && left->st_uid == right->st_uid
        && (left->st_mode & 07777) == (right->st_mode & 07777)
        && (left->st_mode & S_IFMT) == (right->st_mode & S_IFMT);
}

int harc_ipc_secure_listen(
    const char *socket_path,
    uid_t expected_uid,
    int *out_descriptor,
    HarcIPCSocketIdentity *out_identity
) {
    if (socket_path == NULL || out_descriptor == NULL || out_identity == NULL) {
        errno = EINVAL;
        return -1;
    }
    *out_descriptor = -1;
    int parent = -1;
    char *name = NULL;
    if (harc_open_parent(socket_path, expected_uid, &parent, &name) == -1) return -1;

    struct stat first;
    if (fstatat(parent, name, &first, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISSOCK(first.st_mode) || first.st_uid != expected_uid
            || (first.st_mode & 0777) != 0600) {
            close(parent);
            free(name);
            errno = EPERM;
            return -1;
        }
        int probe = harc_connect_descriptor(socket_path);
        if (probe >= 0) {
            close(probe);
            close(parent);
            free(name);
            errno = EADDRINUSE;
            return -1;
        }
        if (errno != ECONNREFUSED) {
            int saved = errno;
            close(parent);
            free(name);
            errno = saved;
            return -1;
        }
        struct stat second;
        if (fstatat(parent, name, &second, AT_SYMLINK_NOFOLLOW) == -1
            || !harc_same_socket(&first, &second)
            || unlinkat(parent, name, 0) == -1) {
            int saved = errno == 0 ? EPERM : errno;
            close(parent);
            free(name);
            errno = saved;
            return -1;
        }
    } else if (errno != ENOENT) {
        int saved = errno;
        close(parent);
        free(name);
        errno = saved;
        return -1;
    }

    struct sockaddr_un address;
    if (harc_make_address(socket_path, &address) == -1) {
        int saved = errno;
        close(parent);
        free(name);
        errno = saved;
        return -1;
    }
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor == -1 || harc_set_descriptor_policy(descriptor) == -1) {
        int saved = errno;
        if (descriptor >= 0) close(descriptor);
        close(parent);
        free(name);
        errno = saved;
        return -1;
    }

    pthread_mutex_lock(&harc_umask_lock);
    mode_t previous_umask = umask(077);
    int bind_result = bind(
        descriptor,
        (struct sockaddr *)&address,
        address.sun_len
    );
    umask(previous_umask);
    pthread_mutex_unlock(&harc_umask_lock);
    if (bind_result == -1 || fchmodat(parent, name, 0600, 0) == -1) {
        int saved = errno;
        close(descriptor);
        unlinkat(parent, name, 0);
        close(parent);
        free(name);
        errno = saved;
        return -1;
    }

    struct stat bound;
    if (fstatat(parent, name, &bound, AT_SYMLINK_NOFOLLOW) == -1
        || !S_ISSOCK(bound.st_mode) || bound.st_uid != expected_uid
        || (bound.st_mode & 0777) != 0600 || listen(descriptor, 16) == -1) {
        int saved = errno == 0 ? EPERM : errno;
        close(descriptor);
        unlinkat(parent, name, 0);
        close(parent);
        free(name);
        errno = saved;
        return -1;
    }

    out_identity->device = (uint64_t)bound.st_dev;
    out_identity->inode = (uint64_t)bound.st_ino;
    *out_descriptor = descriptor;
    close(parent);
    free(name);
    return 0;
}

int harc_ipc_connect(const char *socket_path, int *out_descriptor) {
    if (socket_path == NULL || out_descriptor == NULL) {
        errno = EINVAL;
        return -1;
    }
    int descriptor = harc_connect_descriptor(socket_path);
    if (descriptor == -1) return -1;
    *out_descriptor = descriptor;
    return 0;
}

int harc_ipc_accept(int listener_descriptor, int *out_descriptor) {
    if (out_descriptor == NULL) {
        errno = EINVAL;
        return -1;
    }
    int descriptor = accept(listener_descriptor, NULL, NULL);
    if (descriptor == -1) return -1;
    if (harc_set_descriptor_policy(descriptor) == -1) {
        int saved = errno;
        close(descriptor);
        errno = saved;
        return -1;
    }
    *out_descriptor = descriptor;
    return 0;
}

int harc_ipc_copy_peer_identity(
    int connected_descriptor,
    uid_t *out_effective_uid,
    gid_t *out_effective_gid,
    HarcIPCAuditToken *out_audit_token
) {
    if (out_effective_uid == NULL || out_effective_gid == NULL
        || out_audit_token == NULL) {
        errno = EINVAL;
        return -1;
    }
    uid_t euid;
    gid_t egid;
    if (getpeereid(connected_descriptor, &euid, &egid) == -1) return -1;
    audit_token_t token;
    socklen_t token_length = sizeof(token);
    if (getsockopt(connected_descriptor, SOL_LOCAL, LOCAL_PEERTOKEN,
                   &token, &token_length) == -1
        || token_length != sizeof(token)) {
        return -1;
    }
    if (audit_token_to_euid(token) != euid) {
        errno = EPERM;
        return -1;
    }
    _Static_assert(sizeof(HarcIPCAuditToken) == sizeof(audit_token_t),
                   "audit token size mismatch");
    memcpy(out_audit_token, &token, sizeof(token));
    *out_effective_uid = euid;
    *out_effective_gid = egid;
    return 0;
}

int harc_ipc_unlink_socket_if_matches(
    const char *socket_path,
    uid_t expected_uid,
    HarcIPCSocketIdentity expected_identity
) {
    int parent = -1;
    char *name = NULL;
    if (harc_open_parent(socket_path, expected_uid, &parent, &name) == -1) return -1;
    struct stat status;
    if (fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == -1) {
        int saved = errno;
        close(parent);
        free(name);
        if (saved == ENOENT) return 0;
        errno = saved;
        return -1;
    }
    if (!S_ISSOCK(status.st_mode) || status.st_uid != expected_uid
        || (status.st_mode & 0777) != 0600
        || (uint64_t)status.st_dev != expected_identity.device
        || (uint64_t)status.st_ino != expected_identity.inode) {
        close(parent);
        free(name);
        errno = EPERM;
        return -1;
    }
    int result = unlinkat(parent, name, 0);
    int saved = errno;
    close(parent);
    free(name);
    errno = saved;
    return result;
}
