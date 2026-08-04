#ifndef HARC_IPC_SYSTEM_H
#define HARC_IPC_SYSTEM_H

#include <stdint.h>
#include <sys/types.h>

typedef struct HarcIPCAuditToken {
    uint32_t values[8];
} HarcIPCAuditToken;

typedef struct HarcIPCSocketIdentity {
    uint64_t device;
    uint64_t inode;
} HarcIPCSocketIdentity;

int harc_ipc_secure_listen(
    const char *socket_path,
    uid_t expected_uid,
    int *out_descriptor,
    HarcIPCSocketIdentity *out_identity
);

int harc_ipc_connect(
    const char *socket_path,
    int *out_descriptor
);

int harc_ipc_accept(
    int listener_descriptor,
    int *out_descriptor
);

int harc_ipc_copy_peer_identity(
    int connected_descriptor,
    uid_t *out_effective_uid,
    gid_t *out_effective_gid,
    HarcIPCAuditToken *out_audit_token
);

int harc_ipc_unlink_socket_if_matches(
    const char *socket_path,
    uid_t expected_uid,
    HarcIPCSocketIdentity expected_identity
);

#endif
