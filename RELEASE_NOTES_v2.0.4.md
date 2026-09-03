# MongoDBShellInstall v2.0.4 GA

This release completes the source-and-runtime audit fixes requested after v2.0.3. It deliberately keeps the existing cluster transfer integrity behavior and does not add a post-copy SHA-256 check.

## Changes

- Terminal restoration now writes directly to the controlling TTY, so normal completion, returned failures, direct `exit`, Ctrl+C, and TERM all restore the cursor and scroll region.
- RHEL-family installations automatically reuse mounted `iso9660` media or detect `/dev/sr0`, `/dev/cdrom`, and `/dev/dvd` with `blkid` and mount valid OS media read-only. Only installer-created temporary mounts are removed on exit.
- MongoDB Server, mongosh, and MongoDB Database Tools are executed during compatibility preflight before hostname or system configuration changes.
- Unused `net-tools`, `sysstat`, and `lsof` dependencies were removed. `numactl` is required only on multi-NUMA systems; `logrotate` remains the sole optional operational dependency.
- Parameter/topology validation and dependency-media detection are explicit progress steps. Replica sets without keyFile authentication no longer display or count a no-op keyFile step.
- Parallel remote deployment stops before starting the next batch after a failure and returns the first original worker exit code.

## Validation

- Automated regression: **253 passed, 0 failed** on each of CentOS 7, RHEL 8, RHEL 9, Rocky Linux 8, and Rocky Linux 9 (x86_64).
- Live PTY direct-exit and Ctrl+C checks passed on all five operating systems with zero residual child processes and complete terminal restoration.
- Attached-but-unmounted optical media was detected, mounted read-only, and cleaned up on RHEL 8, RHEL 9, and Rocky Linux 9. Existing administrator mounts on CentOS 7 and Rocky Linux 8 were reused and preserved.
- A deliberately incompatible mongosh returned its original exit code 42 during preflight before the hostname changed.
- Single online/offline and replica-set no-auth/X.509 progress paths completed at exactly 100% with no password leakage.

This patch validates the repaired installer control paths. It does not claim a repeat of every MongoDB server-version installation combination or the full replica-set functional matrix.
