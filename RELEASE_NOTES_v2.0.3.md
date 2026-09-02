# MongoDBShellInstall v2.0.3 GA

This release hardens terminal rendering, interruption handling, secret protection, and dependency installation without changing MongoDB version-specific configuration rules.

## Changes

- Interactive mode selection now exits cleanly on EOF; Ctrl+C and TERM retain their conventional exit codes.
- Package-manager commands and password-based SSH commands run as tracked process groups. Remote parallel workers also receive dedicated process groups, with TERM followed by bounded KILL escalation during cleanup.
- Persistent OpenSSH control connections are closed explicitly on exit.
- Caller-enabled `bash -x` tracing is disabled before password-bearing CLI arguments are parsed.
- `NO_COLOR` and non-TTY output no longer contain ANSI color sequences.
- The ANSI progress panel uses a reserved fixed region at the top of the terminal. Normal completion, failure, and interruption restore the full scroll region and cursor.
- DNF/YUM operations have a 900-second default upper bound, configurable through `MONGO_PACKAGE_COMMAND_TIMEOUT`.
- `mongdb-offline-rpm.tar.gz` processing keeps path and entry-type validation while reducing the archive from three full reads to one metadata scan plus extraction.
- Parallel deployment no longer risks skipping a node when a completed batch reaches the configured concurrency limit.

## Validation

- Automated installer regression: **235 passed, 0 failed** on each of CentOS 7, RHEL 8, RHEL 9, Rocky Linux 8, and Rocky Linux 9 (x86_64).
- Bash compatibility: 4.2, 4.4, and 5.1.
- Live PTY checks confirmed EOF, Ctrl+C exit status, fixed-top rendering, terminal restoration, process-tree cleanup, `NO_COLOR`, and xtrace secret suppression.
- HTML validation passed for `index.html`, `docs.html`, and `generator.html`.

The validation in this patch targets the repaired installer control paths. It does not claim a new full MongoDB server-version installation matrix run.
