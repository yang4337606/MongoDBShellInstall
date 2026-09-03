# MongoDBShellInstall v2.0.4 GA Test Report

- Test date: 2026-09-03
- Release: v2.0.4 GA
- `MongoDB.sh` SHA-256: `5c18804931fcd0c97617137fabcf4d397f5201466ce9319abf3d09af722553fc`
- Architecture: x86_64

## Automated regression matrix

Every run used the release candidate `MongoDB.sh` through `tests/test_installer.sh`.

| Operating system | Bash | Passed | Failed |
|---|---:|---:|---:|
| CentOS 7 | 4.2.46 | 253 | 0 |
| RHEL 8.10 | 4.4.20 | 253 | 0 |
| RHEL 9.6 | 5.1.8 | 253 | 0 |
| Rocky Linux 8.10 | 4.4.20 | 253 | 0 |
| Rocky Linux 9.7 | 5.1.8 | 253 | 0 |

Matrix result: **1265 passed, 0 failed**.

## Runtime behavior

| Check | Result |
|---|---|
| Normal progress completion and returned failure | Cursor and scroll region restored |
| Direct `exit 23` from a running step | Exit 23 and complete terminal restoration on all five OSes |
| Ctrl+C during a managed process tree | Exit 130, complete terminal restoration, no residual child on all five OSes |
| TERM during a managed process tree | Exit 143, complete terminal restoration, no residual child |
| Non-TTY, outer pipeline, and `NO_COLOR` | No ANSI escape output |
| Remote worker returns 42 with parallelism 2 | Only the current two-node batch launched; aggregate returned 42 |
| Invalid port | Logged parameter-validation step returned 1 before system changes |
| Deliberately incompatible mongosh | Preflight returned 42 before hostname changes |

## Optical-media behavior

- CentOS 7 and Rocky Linux 8 reused their existing valid DVD mounts and left them mounted.
- RHEL 8, RHEL 9, and Rocky Linux 9 detected unmounted `iso9660` media with `blkid`, mounted it read-only beneath `/run/mongodb-installer-os-iso.*`, validated repository metadata, and removed the temporary mount during cleanup.
- No NFS or CIFS discovery or mount path was introduced.

## Progress matrix

| Mode | Completed | Total | Empty keyFile step | Password leak |
|---|---:|---:|---:|---:|
| Single, online | 26 | 26 | 0 | 0 |
| Single, explicit offline sources | 26 | 26 | 0 | 0 |
| Replica set, no authentication | 29 | 29 | 0 | 0 |
| Replica set, TLS/X.509 | 32 | 32 | 0 | 0 |

## Dependency selection

- Single-node/single-NUMA simulation selected only `logrotate` as an optional package.
- `net-tools`, `sysstat`, and `lsof` are no longer selected.
- `numactl` remains required when the detected NUMA node count is greater than one.
- Cluster post-copy SHA-256 verification was intentionally not added per release requirements.

## Scope

This report validates the v2.0.4 audit fixes and regression behavior. It does not represent a repeat of every MongoDB 6.0/7.0/8.0/8.3 installation combination or the complete replica-set functional matrix.
