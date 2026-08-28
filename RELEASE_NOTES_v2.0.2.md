# MongoDBShellInstall v2.0.2 GA

This patch removes the final external OS dependency from password-based replica-set bootstrap.

## Changes

- Removes the `sshpass` runtime dependency and the CentOS 7 `sshpass` supplement RPM.
- Uses native OpenSSH `SSH_ASKPASS` with the protected root password already held in memory for the first connection.
- Generates a dedicated root-owned Ed25519 key at `/root/.ssh/mongodb_install_ed25519` when no `--ssh-key` is supplied.
- Installs the public key idempotently in each remote root account's `authorized_keys`, verifies key authentication, then uses the key for all SSH/SCP deployment operations.
- Keeps `StrictHostKeyChecking=yes`; fresh controllers must still receive a verified `known_hosts` file because password automation must not silently trust an unverified host key.
- Keeps the optional `mongdb-offline-rpm.tar.gz` mechanism for a future ISO with a real package gap, but the currently verified full DVD ISO matrix requires no supplement archive.

## Validation

- Automated installer regression passes on Rocky Linux 8: 222 passed, 0 failed.
- Native ASKPASS password authentication, idempotent Ed25519 bootstrap, SSH command execution, and SCP transfer are validated between real Rocky Linux 8 nodes.
- Bash 4.2 syntax validation passes on a real CentOS 7 node.
- Passwords remain absent from command arguments and installer logs.
