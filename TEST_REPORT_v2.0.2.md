# MongoDBShellInstall v2.0.2 GA Test Report

- Test date: 2026-08-28
- Release: v2.0.2 GA
- Commit: `aa197e608e0f0308747895d766cb1e036b94b3b0`
- `MongoDB.sh` SHA-256: `d3233f0068662b1f35b243bb24bf15706a293bf470f51b2551abcd7239f41b03`
- Architecture: x86_64

## Native SSH trust matrix

The password-to-key bootstrap was tested between two real hosts for each operating system. Both hosts in every pair had no `sshpass` package installed before or after the test.

| Operating system | Native password bootstrap | Repeated bootstrap | Authorized-key count | SSH | SCP | Password log check | Cleanup |
|---|---|---|---:|---|---|---|---|
| RHEL 8.10 | Pass | Pass | 1 | Pass | Pass | Pass | Pass |
| RHEL 9.6 | Pass | Pass | 1 | Pass | Pass | Pass | Pass |
| Rocky Linux 8.10 | Pass | Pass | 1 | Pass | Pass | Pass | Pass |
| Rocky Linux 9.7 | Pass | Pass | 1 | Pass | Pass | Pass | Pass |

Matrix result: **4 passed, 0 failed**.

## Validation procedure

1. Confirmed `rpm -q sshpass` failed on both hosts before testing.
2. Loaded the released `MongoDB.sh` implementation and used its `bootstrap_ssh_key_trust` function.
3. Used native OpenSSH `SSH_ASKPASS` for the first password authentication.
4. Generated an Ed25519 test key and installed the public key in the remote root account's `authorized_keys`.
5. Repeated the bootstrap and confirmed the exact public key still occurred only once.
6. Executed a remote command and transferred a test file using key-only SSH/SCP authentication.
7. Confirmed the bootstrap output did not contain the password read from the protected password file.
8. Removed the exact test public key, copied file, private key, protected password copy, SSH control directory, and ASKPASS helper directory.
9. Confirmed `sshpass` remained absent on both hosts.

## Automated regression

- Installer tests on Rocky Linux 8: **222 passed, 0 failed**.
- Bash 4.2 syntax validation on CentOS 7: pass.
- HTML validation for `index.html`, `docs.html`, and `generator.html`: pass.

This report covers the v2.0.2 native SSH trust change. It does not represent a rerun of every MongoDB server-version installation combination.
