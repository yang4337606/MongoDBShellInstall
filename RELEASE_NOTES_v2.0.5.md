# MongoDBShellInstall v2.0.5 GA

This maintenance release applies the focused fixes found during the post-v2.0.4 source audit. It preserves the requested cluster transfer behavior and does not add post-copy SHA-256 verification.

## Changes

- OS-only and remote-node flows validate the target MongoDB version against the real OS major version, CPU architecture, and CPU requirements.
- Remote deployment executes the packaged `mongod --version` before replacing an existing application directory, preserves the preflight exit code, and removes failed probe artifacts.
- Offline RPM supplements install and distribute the complete dependency closure for the exact OS ID, OS major version, and CPU architecture. The archive remains RPM-only with no manifest or SHA-256 file.
- SSH/SCP, package operations, extraction, and application copies use managed process trees so interruption cleanup also terminates child processes.
- Password-based SSH bootstrap no longer places the password in an external `env` or `setsid` argument list.
- Failed `mongodump` runs retain their working directory and never publish a normal `.tar.gz` archive.
- Replica-set DNS member aliases may differ from the mode-generated operating-system hostname when the aliases resolve correctly.

## Validation

- Automated regression: **269 passed, 0 failed** on RHEL 8.10, RHEL 9.6, and CentOS 7 x86_64.
- Bash syntax, HTML structure, and Git whitespace validation passed.
- Behavior tests cover the complete RPM closure, RPM-only remote dependency archive, SSH password argument isolation, remote binary preflight failure, preserved exit status, application replacement prevention, and failed-backup publication rules.

This is a focused maintenance release. Per release scope, the full MongoDB version and five-operating-system installation matrix was not repeated.
