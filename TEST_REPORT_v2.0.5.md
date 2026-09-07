# MongoDBShellInstall v2.0.5 GA Test Report

- Test date: 2026-09-07
- Release: v2.0.5 GA
- `MongoDB.sh` SHA-256: `625c15549f1b4eb379f5cc27ded94b17eb9ac6629a725654381a01b5bdd80af5`
- Architecture: x86_64

## Automated regression

The release candidate was exercised through `tests/test_installer.sh` on the available target systems.

| Operating system | Passed | Failed |
|---|---:|---:|
| RHEL 8.10 | 269 | 0 |
| RHEL 9.6 | 269 | 0 |
| CentOS 7 | 269 | 0 |

Result: **807 passed, 0 failed**.

## Focused behavior coverage

| Check | Result |
|---|---|
| Complete offline RPM dependency closure | Passed |
| Remote dependency archive contains only matching-platform RPMs | Passed |
| SSH password absent from external transport argument list | Passed |
| SSH/SCP and major extraction/copy processes are managed | Passed |
| Remote OS/major/architecture equality preflight | Passed |
| Remote packaged `mongod` execution before application replacement | Passed; original failure code retained |
| Failed `mongodump` publication | No normal `.tar.gz`; working directory retained |
| Replica-set DNS alias independent from generated OS hostname | Passed |
| Cluster post-copy SHA-256 | Not added, per requirement |

## Static validation

- `bash -n MongoDB.sh`: passed
- `bash -n tests/test_installer.sh`: passed
- `node tests/validate_html.js`: passed
- `git diff --check`: passed

## Scope

This report validates the focused v2.0.5 changes. At the user's direction, it does not repeat the complete MongoDB 6.0/7.0/8.0/8.3 patch-version installation matrix or all five operating-system replica-set scenarios.
