# MongoDBShellInstall v2.0.1 GA

This patch release completes the offline installation media promised by v2.0.0.

## Fixes

- Ships the actual `mongdb-offline-rpm.tar.gz` ISO supplement instead of treating its builder as the deliverable.
- The verified RHEL 8/9 and Rocky Linux 8/9 full DVD ISOs contain all 26 installer OS dependencies, so their ISO delta is empty.
- The verified CentOS 7 x86_64 DVD ISO lacks `sshpass`; the supplement contains only the signed `sshpass-1.06-2.el7.x86_64.rpm`. No manifests, checksum files, or other non-RPM files are stored inside the archive.
- Adds CentOS 7 yum-based ISO installation when dnf is unavailable.
- Imports the installed OS vendor key and verifies each offline RPM signature before installation.
- Adds `sshpass` to the maintainer rebuild tool's default dependency set.

## Validation

- 217 automated installer assertions pass on a Rocky Linux 8 real host.
- The supplement was generated from the CentOS 7 x86_64 lab repository, consumed by `MongoDB.sh`, installed successfully on CentOS 7, and passed archive SHA256 plus RPM signature verification.
- The CentOS 7 yum ISO path correctly installs ISO-provided dependencies and returns only `sshpass` to the supplement path.
