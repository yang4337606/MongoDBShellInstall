# MongoDBShellInstall v2.0.0 GA

This release turns the original installer into a version-aware standalone and replica-set deployment workflow with explicit security, offline, compatibility, and operability controls.

## Highlights

- Overall progress display with a live current-step spinner, elapsed time, in-place success/failure updates, and plain non-TTY output.
- Standalone and parallel replica-set deployment with independent DNS member names and SSH endpoints.
- Optional SCRAM-SHA-256 authentication, protected password-file inputs, `requireTLS`, and X.509 member authentication.
- Version-aware MongoDB configuration: journal, majority read concern, THP, OS-minor restrictions, and RHEL-family package compatibility are applied only to their relevant version ranges.
- Independent install, data, and backup directories, all owned by the selected runtime user and same-name group without ACL grants.
- Permanent firewall masking and SELinux disablement as required by this installer profile.
- Offline OS dependency bundle layout by exact OS ID, OS major version, and CPU architecture under `mongdb-offline-rpm/`.
- Dynamic CPU, memory, connection, file-limit, WiredTiger cache, oplog, NUMA, and readahead tuning.
- Parallel remote distribution, SSH connection multiplexing, and same-version application-fingerprint checks that skip duplicate binary transfer.
- Backup-only maintenance script, protected credentials, log redaction, and an installation summary that reports the chosen authentication mode.

## Validation

- 211 automated installer assertions pass on CentOS 7 Bash 4.2.
- 54 real standalone installations pass across RHEL 8/9, Rocky Linux 8/9, and CentOS 7.
- CentOS 7 rejects MongoDB 8.0 and 8.3 during compatibility preflight without changing the existing service or filesystem layout.
- Five three-node replica sets pass authentication, TLS/X.509, majority writes, replication reads, real primary failover and recovery, backup, isolated restore, permission, firewall, SELinux, and password-redaction checks.
- No unexpected validation failures remain for the GA scope.

## Compatibility notes

- RHEL 8/9 and Rocky Linux 8/9 were validated with MongoDB 6.0, 7.0, 8.0, and 8.3 patch lines.
- CentOS 7 is legacy-only and was validated with MongoDB 6.0 and 7.0; MongoDB 8.x is intentionally blocked.
- High-version removals never delete settings globally from older MongoDB versions that still support them.

## Upgrade notes

- Review generated commands before use because this installer profile permanently masks host firewall services and disables SELinux.
- Authentication remains opt-in; when enabled non-interactively, use `--admin-pass-file` and protect the file with mode 0600.
- For replica sets, use stable DNS member names with `--hosts` and provide separate SSH endpoints with `--remote-ips`.
- TLS certificates must be issued by an external PKI. The installer validates, backs up, installs, and distributes them but does not act as a CA.
