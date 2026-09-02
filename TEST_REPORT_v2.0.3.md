# MongoDBShellInstall v2.0.3 GA Test Report

- Test date: 2026-09-02
- Release: v2.0.3 GA
- `MongoDB.sh` SHA-256: `9a451adce45f821be66ab8c33afffacb56ab498aca9294041ffb8126a71dcb0f`
- Architecture: x86_64

## Automated regression matrix

Every run used the released `MongoDB.sh` through `tests/test_installer.sh`.

| Operating system | Bash | Passed | Failed |
|---|---:|---:|---:|
| CentOS 7 | 4.2.46 | 235 | 0 |
| RHEL 8.10 | 4.4.20 | 235 | 0 |
| RHEL 9.6 | 5.1.8 | 235 | 0 |
| Rocky Linux 8.10 | 4.4.20 | 235 | 0 |
| Rocky Linux 9.7 | 5.1.8 | 235 | 0 |

Matrix result: **1175 passed, 0 failed**.

## Live terminal and interruption checks

The following checks were executed on a real Rocky Linux 8.10 host:

| Check | Result |
|---|---|
| EOF during interactive mode selection | Exit 1, one prompt, no retry loop |
| Ctrl+C during interactive mode selection | Exit 130, no retry loop |
| Scroll-region restoration after Ctrl+C | Pass |
| `NO_COLOR` invalid-argument output | 0 ESC bytes |
| `bash -x` with a synthetic root-password marker | 0 marker occurrences |
| Ctrl+C during a managed child process | Exit 130; child process absent afterward |
| Fixed-top ANSI progress panel | Scroll region, absolute top-row rendering, cursor save/restore, and final reset all observed |

## Dependency and archive checks

- A controlled one-second package-manager timeout returned 124 and terminated the child process tree.
- DNF and YUM call sites are routed through the bounded runner.
- The offline dependency archive is read twice: one validated metadata scan and one extraction pass.
- Archives containing symbolic links are still rejected before extraction.
- Path traversal, out-of-tree entries, non-RPM files, OS-major mismatch, and architecture mismatch remain covered by regression tests.

## Static and document validation

- `bash -n MongoDB.sh`: pass on all five operating systems.
- `bash -n tools/build_offline_rpm_bundle.sh`: pass.
- `git diff --check`: pass.
- HTML structure and unique-ID validation for `index.html`, `docs.html`, and `generator.html`: pass.
- `SHA256SUMS` matches the released `MongoDB.sh`.

## Scope

This report validates the v2.0.3 control-flow and terminal-lifecycle fixes. It does not represent a repeat of every MongoDB 6.0/7.0/8.0/8.3 installation combination or the full replica-set functional matrix.
