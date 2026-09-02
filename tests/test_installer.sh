#!/usr/bin/env bash
set -uo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${repo_dir}/MongoDB.sh"
generator="${repo_dir}/generator.html"
docs="${repo_dir}/docs.html"
builder="${repo_dir}/tools/build_offline_rpm_bundle.sh"

passes=0
failures=0

pass() {
  printf 'ok - %s\n' "$1"
  ((passes++))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  ((failures++))
}

assert_success() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

assert_failure() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

assert_file_contains() {
  local name="$1" file="$2" pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then pass "$name"; else fail "$name"; fi
}

assert_file_not_contains() {
  local name="$1" file="$2" pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then fail "$name"; else pass "$name"; fi
}

assert_cli_alias() {
  local short_option="$1" long_option="$2" line pattern token
  local found_short found_long
  local -a cli_tokens=()
  while IFS= read -r line; do
    [[ "$line" == *')' ]] || continue
    pattern=${line%%)*}
    pattern=${pattern#"${pattern%%[![:space:]]*}"}
    found_short=N
    found_long=N
    IFS='|' read -ra cli_tokens <<< "$pattern"
    for token in "${cli_tokens[@]}"; do
      [[ "$token" == "$short_option" ]] && found_short=Y
      [[ "$token" == "$long_option" ]] && found_long=Y
    done
    if [[ "$found_short" == Y && "$found_long" == Y ]]; then
      pass "$long_option has short alias $short_option"
      return
    fi
  done <<< "$cli_case_patterns"
  fail "$long_option has short alias $short_option"
}

assert_all_long_options_have_short_alias() {
  local line pattern token has_long has_short
  local -a cli_tokens=() missing=()
  while IFS= read -r line; do
    pattern=${line%%)*}
    pattern=${pattern#"${pattern%%[![:space:]]*}"}
    has_long=N
    has_short=N
    IFS='|' read -ra cli_tokens <<< "$pattern"
    for token in "${cli_tokens[@]}"; do
      [[ "$token" == --* ]] && has_long=Y
      [[ "$token" == -* && "$token" != --* ]] && has_short=Y
    done
    [[ "$has_long" == Y && "$has_short" == N ]] && missing+=("$pattern")
  done <<< "$cli_case_patterns"
  if (( ${#missing[@]} == 0 )); then
    pass "every long CLI option shares its parser branch with a short alias"
  else
    printf 'missing short aliases: %s\n' "${missing[*]}" >&2
    fail "every long CLI option shares its parser branch with a short alias"
  fi
}

if grep -q 'MONGO_INSTALL_LIB_ONLY' "$installer"; then
  export MONGO_INSTALL_LIB_ONLY=1
  # shellcheck source=../MongoDB.sh
  if source "$installer"; then
    pass "installer can be sourced without starting an installation"
  else
    fail "installer can be sourced without starting an installation"
  fi
else
  fail "installer can be sourced without starting an installation"
fi

if declare -F validate_safe_install_dir >/dev/null; then
  assert_failure "reject filesystem root as install directory" validate_safe_install_dir /
  assert_failure "reject /etc as install directory" validate_safe_install_dir /etc
  assert_failure "reject broad /data directory" validate_safe_install_dir /data
  assert_success "accept default /mongodb directory" validate_safe_install_dir /mongodb
  assert_success "accept nested MongoDB directory" validate_safe_install_dir /data/mongodb
else
  fail "safe install-directory validator exists"
fi

if declare -F paths_overlap >/dev/null && declare -F finalize_directory_layout >/dev/null; then
  assert_success "detect identical managed paths" paths_overlap /data/mongodb /data/mongodb
  assert_success "detect nested managed paths" paths_overlap /data/mongodb /data/mongodb/backup
  assert_failure "accept separate data and backup paths" paths_overlap /data/mongodb /backup/mongodb

  env_base_dir=/opt/mongodb-install
  mongo_data_dir_override=/data/mongodb-data
  mongo_backup_dir_override=/backup/mongodb
  if finalize_directory_layout \
    && [[ "$env_app_dir" == /opt/mongodb-install/app \
      && "$data_dir" == /data/mongodb-data \
      && "$backup_dir" == /backup/mongodb ]]; then
    pass "independent data and backup directories override install-root defaults"
  else
    fail "independent data and backup directories override install-root defaults"
  fi
  env_base_dir=/mongodb
  mongo_data_dir_override=''
  mongo_backup_dir_override=''
  finalize_directory_layout || fail "restore default directory layout"
else
  fail "directory-layout helpers exist"
fi

if declare -F validate_runtime_parent_access >/dev/null; then
  runuser() {
    return 1
  }
  assert_failure "reject restrictive unmanaged parents without adding ACLs" \
    validate_runtime_parent_access /restricted/mongodb
  unset -f runuser
else
  fail "runtime path-access helper exists"
fi
assert_file_not_contains "installer never manages directory access with ACLs" "$installer" '(^|[^[:alnum:]_])setfacl([^[:alnum:]_]|$)'

if declare -F validate_port >/dev/null; then
  assert_success "accept valid MongoDB port" validate_port 27017
  assert_failure "reject non-numeric MongoDB port" validate_port '27x17'
  assert_failure "reject out-of-range MongoDB port" validate_port 70000
else
  fail "numeric port validator exists"
fi

if declare -F validate_host >/dev/null; then
  assert_success "accept DNS replica-set member" validate_host db1.example.internal
  assert_success "accept IPv4 SSH endpoint" validate_host 10.0.1.11
  assert_failure "reject shell metacharacters in host" validate_host 'db1;reboot'
else
  fail "host validator exists"
fi

if declare -F validate_bind_ip_list >/dev/null; then
  assert_success "accept all-IPv4 bind address" validate_bind_ip_list 0.0.0.0
  assert_success "accept explicit IPv4 bind list" validate_bind_ip_list 127.0.0.1,10.20.0.10
  assert_failure "reject unsupported wildcard bind" validate_bind_ip_list '*'
else
  fail "bind-address validator exists"
fi

if declare -F build_install_hostname >/dev/null; then
  [[ "$(build_install_hostname mongodb single 10.20.1.12)" == "mongodb" ]] \
    && pass "single mode uses base hostname" || fail "single mode uses base hostname"
  [[ "$(build_install_hostname mongodb replicaset 10.20.1.12)" == "mongodb112" ]] \
    && pass "replica-set mode appends local IP suffix" || fail "replica-set mode appends local IP suffix"
  [[ "$(build_install_hostname mgr9- replicaset 192.0.2.99)" == "mgr9-299" ]] \
    && pass "replica-set hostname prefix may end with a separator" || fail "replica-set hostname prefix may end with a separator"
else
  fail "mode-aware hostname helper exists"
fi

if declare -F is_local_host >/dev/null; then
  getent() {
    [[ "$1" == ahostsv4 && "$2" == mongors987 ]] || return 2
    printf '192.0.2.87 STREAM mongors987\n192.0.2.87 DGRAM mongors987\n'
  }
  assert_success "recognize local DNS member when getent returns multiple rows" is_local_host mongors987 192.0.2.87
  unset -f getent
else
  fail "local replica-set member detector exists"
fi

[[ "$mongo_auth_enabled" == "N" ]] && pass "authentication is disabled by default" || fail "authentication is disabled by default"
[[ "$hostname" == "mongodb" ]] && pass "default hostname base is mongodb" || fail "default hostname base is mongodb"
mongo_install_mode=single
mongo_bind_ip=""
if validate_and_finalize_parameters >/dev/null 2>&1 && [[ "$mongo_bind_ip" == "0.0.0.0" ]]; then
  pass "single-mode parameters default to all IPv4 interfaces"
else
  fail "single-mode parameters default to all IPv4 interfaces"
fi

if declare -F read_secret_file >/dev/null; then
  secret_tmp=$(mktemp)
  printf '%s\n' 'twelve-char-secret' > "$secret_tmp"
  # MSYS/NTFS does not faithfully expose POSIX chmod bits, so mock only stat's
  # mode/owner responses while exercising the real file and symlink checks.
  secret_mode=600
  stat() {
    case "${2:-}" in
      '%a') printf '%s\n' "$secret_mode" ;;
      '%u') printf '%s\n' "$EUID" ;;
      *) command stat "$@" ;;
    esac
  }
  secret_value=''
  if read_secret_file "$secret_tmp" secret_value && [[ "$secret_value" == 'twelve-char-secret' ]]; then
    pass "accept root-owned private secret file"
  else
    fail "accept root-owned private secret file"
  fi
  secret_mode=640
  assert_failure "reject group-readable secret file" read_secret_file "$secret_tmp" secret_value
  secret_link="${secret_tmp}.link"
  ln -s "$secret_tmp" "$secret_link"
  assert_failure "reject symlink secret file" read_secret_file "$secret_link" secret_value
  rm -f "$secret_link" "$secret_tmp"
  unset -f stat
else
  fail "secret-file validator exists"
fi

if declare -F mongo_supports_journal_option >/dev/null; then
  assert_success "MongoDB 6.0 supports storage.journal.enabled" mongo_supports_journal_option 6 0
  assert_failure "MongoDB 6.1 removed storage.journal.enabled" mongo_supports_journal_option 6 1
  assert_failure "MongoDB 8.0 does not support storage.journal.enabled" mongo_supports_journal_option 8 0
else
  fail "journal compatibility helper exists"
fi

if declare -F mongo_supports_config_option >/dev/null; then
  assert_success "MongoDB 4.4 supports configurable majority read concern" \
    mongo_supports_config_option replication.enableMajorityReadConcern 4 4 31
  assert_failure "MongoDB 5.0 removes configurable majority read concern" \
    mongo_supports_config_option replication.enableMajorityReadConcern 5 0 34
  assert_success "MongoDB 8.3 keeps WiredTiger cacheSizeGB" \
    mongo_supports_config_option storage.wiredTiger.engineConfig.cacheSizeGB 8 3 8
  assert_failure "unknown config options are rejected instead of silently removed" \
    mongo_supports_config_option future.unknownOption 8 3 8
else
  fail "central MongoDB configuration capability map exists"
fi

if declare -F mongo_version_at_least >/dev/null; then
  assert_success "semantic patch comparison accepts RHEL 9 minimum" mongo_version_at_least 6 0 4 6 0 4
  assert_failure "semantic patch comparison rejects old RHEL 9 build" mongo_version_at_least 6 0 3 6 0 4
else
  fail "semantic MongoDB version comparison exists"
fi

if declare -F validate_mongo_os_version_matrix >/dev/null; then
  original_os_distro="$os_distro"
  original_os_distro_family="$os_distro_family"
  original_os_version="$os_version"
  original_os_version_id="$os_version_id"
  original_os_version_minor="$os_version_minor"
  original_mongo_major_ver="$mongo_major_ver"
  original_mongo_minor_ver="$mongo_minor_ver"
  original_mongo_patch_ver="$mongo_patch_ver"
  _matrix_case() {
    os_distro="$1"
    os_distro_family=rhel
    os_version="$2"
    os_version_id="$3"
    os_version_minor="$4"
    mongo_major_ver="$5"
    mongo_minor_ver="$6"
    mongo_patch_ver="$7"
    validate_mongo_os_version_matrix
  }
  assert_success "RHEL 8.10 supports MongoDB 8.3" _matrix_case rhel 8 8.10 10 8 3 8
  assert_failure "RHEL 8.7 rejects MongoDB 8.x" _matrix_case rhel 8 8.7 7 8 0 29
  assert_success "Rocky 8.10 supports MongoDB 8.x" _matrix_case rocky 8 8.10 10 8 0 29
  assert_success "RHEL 9 accepts MongoDB 6.0.4 minimum" _matrix_case rhel 9 9.6 6 6 0 4
  assert_failure "RHEL 9 rejects MongoDB 6.0.3" _matrix_case rhel 9 9.6 6 6 0 3
  assert_success "Rocky 9.7 supports MongoDB 8.3" _matrix_case rocky 9 9.7 7 8 3 8
  assert_failure "Rocky 9.2 rejects MongoDB 8.x" _matrix_case rocky 9 9.2 2 8 0 29
  assert_success "MongoDB 7 is not restricted by the 8.x OS-minor rule" _matrix_case rocky 9 9.2 2 7 0 40
  assert_success "CentOS 7 permits legacy MongoDB 7.0" _matrix_case centos 7 7.9 9 7 0 40
  assert_failure "CentOS 7 rejects MongoDB 8.0" _matrix_case centos 7 7.9 9 8 0 29
  unset -f _matrix_case
  os_distro="$original_os_distro"
  os_distro_family="$original_os_distro_family"
  os_version="$original_os_version"
  os_version_id="$original_os_version_id"
  os_version_minor="$original_os_version_minor"
  mongo_major_ver="$original_mongo_major_ver"
  mongo_minor_ver="$original_mongo_minor_ver"
  mongo_patch_ver="$original_mongo_patch_ver"
else
  fail "OS and MongoDB version matrix validator exists"
fi

if declare -F select_mongo_tarball >/dev/null; then
  package_tmp=$(mktemp -d)
  original_software_dir="$software_dir"
  original_package_choice="$mongo_package_choice"
  software_dir="$package_tmp"
  : > "${package_tmp}/mongodb-linux-x86_64-rhel80-8.0.29.tgz"
  mongo_package_choice=''
  selected_mongo_tarball=''
  selected=$(select_mongo_tarball)
  [[ "$selected" == *'mongodb-linux-x86_64-rhel80-8.0.29.tgz' ]] \
    && pass "single MongoDB Server package is selected automatically" \
    || fail "single MongoDB Server package is selected automatically"
  : > "${package_tmp}/mongodb-linux-x86_64-rhel80-7.0.40.tgz"
  _select_without_tty() { select_mongo_tarball </dev/null; }
  assert_failure "multiple packages require an explicit choice without a TTY" _select_without_tty
  mongo_package_choice='8.0.29'
  selected=$(select_mongo_tarball)
  [[ "$selected" == *'mongodb-linux-x86_64-rhel80-8.0.29.tgz' ]] \
    && pass "--mongo-package can select a dynamic patch version" \
    || fail "--mongo-package can select a dynamic patch version"
  unset -f _select_without_tty
  software_dir="$original_software_dir"
  mongo_package_choice="$original_package_choice"
  selected_mongo_tarball=''
  rm -rf "$package_tmp"
else
  fail "MongoDB package selector exists"
fi

if declare -F validate_os_package_bundle >/dev/null; then
  archive_fixture=$(mktemp -d)
  original_os_distro="$os_distro"
  original_os_version="$os_version"
  original_os_arch="$os_arch"
  fixture_dir="${archive_fixture}/source/mongdb-offline-rpm/centos/7/x86_64"
  mkdir -p "$fixture_dir"
  : > "${fixture_dir}/fixture-1.0-1.x86_64.rpm"
  rpm() {
    if [[ "$1" == "-qp" && "$2" == "--qf" && "$3" == '%{ARCH}' ]]; then
      printf 'x86_64'
      return 0
    fi
    command rpm "$@"
  }
  os_distro=centos
  os_version=7
  os_arch=x86_64
  assert_success "accept RPM-only bundle for matching OS-major and architecture" validate_os_package_bundle "$fixture_dir"
  : > "${fixture_dir}/unexpected.txt"
  assert_failure "reject non-RPM files inside an offline bundle" validate_os_package_bundle "$fixture_dir"
  rm -f "${fixture_dir}/unexpected.txt"
  os_version=8
  assert_failure "reject an offline bundle for another OS major" validate_os_package_bundle "$fixture_dir"
  os_distro=rocky
  os_version=7
  assert_failure "reject CentOS bundle on Rocky despite shared family" validate_os_package_bundle "$fixture_dir"

  tar -C "${archive_fixture}/source" -czf "${archive_fixture}/mongdb-offline-rpm.tar.gz" mongdb-offline-rpm
  original_os_packages_archive="$os_packages_archive"
  original_os_packages_root="$os_packages_root"
  original_os_packages_dir="$os_packages_dir"
  os_distro=centos
  os_version=7
  os_arch=x86_64
  os_packages_archive="${archive_fixture}/mongdb-offline-rpm.tar.gz"
  os_packages_root="${archive_fixture}/not-extracted"
  os_packages_dir=''
  tar_call_count=0
  tar() {
    ((tar_call_count++))
    command tar "$@"
  }
  if prepare_os_packages_root \
    && [[ "$os_packages_root" == */mongdb-offline-rpm ]] \
    && validate_os_package_bundle "${os_packages_root}/centos/7/x86_64" \
    && (( tar_call_count == 2 )); then
    pass "extract requested archive and resolve centos/7/x86_64 layout"
  else
    fail "extract requested archive and resolve centos/7/x86_64 layout"
  fi
  unset -f tar

  mkdir -p "${archive_fixture}/unsafe/mongdb-offline-rpm/centos/7/x86_64"
  ln -s /etc/passwd "${archive_fixture}/unsafe/mongdb-offline-rpm/centos/7/x86_64/link.rpm"
  command tar -C "${archive_fixture}/unsafe" -czf "${archive_fixture}/unsafe.tar.gz" mongdb-offline-rpm
  os_packages_archive="${archive_fixture}/unsafe.tar.gz"
  os_packages_root="${archive_fixture}/unsafe-not-extracted"
  assert_failure "reject links while using one archive metadata scan" prepare_os_packages_root
  os_packages_archive="$original_os_packages_archive"
  os_packages_root="$original_os_packages_root"
  os_packages_dir="$original_os_packages_dir"
  os_distro="$original_os_distro"
  os_version="$original_os_version"
  os_arch="$original_os_arch"
  unset -f rpm
  rm -rf "$archive_fixture"
else
  fail "OS offline bundle validator exists"
fi

if declare -F mongo_thp_mode >/dev/null; then
  [[ "$(mongo_thp_mode 8)" == "enable" ]] && pass "MongoDB 8 selects enabled THP" || fail "MongoDB 8 selects enabled THP"
  [[ "$(mongo_thp_mode 7)" == "disable" ]] && pass "MongoDB 7 selects disabled THP" || fail "MongoDB 7 selects disabled THP"
  [[ "$(mongo_thp_mode 0)" == "skip" ]] && pass "unknown MongoDB version leaves THP unchanged" || fail "unknown MongoDB version leaves THP unchanged"
else
  fail "THP compatibility helper exists"
fi

if declare -F calculate_resource_profile >/dev/null; then
  original_max_connections="$max_connections"
  max_connections=100000
  mongo_resource_profile_ready=0
  if calculate_resource_profile >/dev/null 2>&1 \
    && (( mongo_nofile_limit >= 254096 )) \
    && (( mongo_nproc_limit >= max_connections )); then
    pass "resource profile derives nofile and nproc from connection demand"
  else
    fail "resource profile derives nofile and nproc from connection demand"
  fi
  max_connections=2000000
  mongo_resource_profile_ready=0
  assert_failure "reject connection demand above kernel fs.nr_open capacity" calculate_resource_profile
  max_connections="$original_max_connections"
  mongo_resource_profile_ready=0
  calculate_resource_profile >/dev/null 2>&1 || true
else
  fail "resource-linked limits calculator exists"
fi

if declare -F format_duration >/dev/null && declare -F build_progress_bar >/dev/null; then
  [[ "$(format_duration 12)" == "00:12" ]] && pass "duration is formatted as MM:SS" || fail "duration is formatted as MM:SS"
  [[ "$(format_duration 3661)" == "01:01:01" ]] && pass "long duration is formatted as HH:MM:SS" || fail "long duration is formatted as HH:MM:SS"
  [[ "$(build_progress_bar 18 30 20)" == "[████████████░░░░░░░░]" ]] && pass "overall progress bar uses requested ratio" || fail "overall progress bar uses requested ratio"
  INSTALL_STARTED_EPOCH=$(($(date +%s) - 3))
  finish_install_timer
  (( INSTALL_ELAPSED_SECONDS >= 3 && INSTALL_ELAPSED_SECONDS <= 4 )) \
    && pass "installation timer remains in memory for final display" \
    || fail "installation timer remains in memory for final display"
else
  fail "progress formatting helpers exist"
fi

if declare -F color_printf >/dev/null && declare -F progress_terminal_prepare >/dev/null; then
  color_output=$(NO_COLOR=1 color_printf green "no-color" 2>&1)
  if [[ "$color_output" != *$'\033'* ]]; then
    pass "NO_COLOR suppresses color control sequences"
  else
    fail "NO_COLOR suppresses color control sequences"
  fi
  color_output=$(color_printf green "non-tty" 2>&1)
  if [[ "$color_output" != *$'\033'* ]]; then
    pass "non-TTY output suppresses color control sequences"
  else
    fail "non-TTY output suppresses color control sequences"
  fi

  tput() {
    [[ "${1:-}" == "lines" ]] && printf '40\n'
  }
  progress_terminal_output=$(
    MONGO_PROGRESS_MODE=ansi
    PROGRESS_TERMINAL_ACTIVE=0
    PROGRESS_CURSOR_HIDDEN=0
    PROGRESS_TOTAL=30
    PROGRESS_COMPLETED=18
    progress_terminal_prepare
    progress_render
    progress_terminal_restore
  )
  unset -f tput
  if [[ "$progress_terminal_output" == *$'\033[12;40r'* \
    && "$progress_terminal_output" == *$'\033[1;1H'* \
    && "$progress_terminal_output" == *$'\033[r'* ]]; then
    pass "ANSI progress reserves a fixed top panel and restores the scroll region"
  else
    fail "ANSI progress reserves a fixed top panel and restores the scroll region"
  fi
else
  fail "color and fixed progress helpers exist"
fi

if declare -F select_install_mode >/dev/null; then
  mode_output=$(select_install_mode </dev/null 2>&1)
  mode_status=$?
  if (( mode_status != 0 )) && [[ "$mode_output" == *"安装模式输入已结束"* ]] \
    && [[ "$mode_output" != *"无效输入，请重新选择"* ]]; then
    pass "interactive mode selection exits cleanly on EOF"
  else
    fail "interactive mode selection exits cleanly on EOF"
  fi
else
  fail "interactive mode selector exists"
fi

if declare -F run_package_manager >/dev/null; then
  package_wait_started=$(date +%s)
  package_wait_output=$(MONGO_PACKAGE_COMMAND_TIMEOUT=1 run_package_manager bash -c 'sleep 30' 2>&1)
  package_wait_status=$?
  package_wait_elapsed=$(($(date +%s) - package_wait_started))
  if (( package_wait_status == 124 && package_wait_elapsed < 8 )) \
    && [[ "$package_wait_output" == *"等待超过 1 秒"* ]]; then
    pass "package manager wait is bounded and reports timeout"
  else
    fail "package manager wait is bounded and reports timeout"
  fi
else
  fail "bounded package manager runner exists"
fi

if declare -F cleanup_on_exit >/dev/null; then
  process_test_dir=$(mktemp -d)
  process_pid_file="${process_test_dir}/child.pid"
  process_marker="MONGO_PROCESS_TREE_TEST_${$}"
  (
    MONGO_INSTALL_TMPFILES=()
    MONGO_INSTALL_TMPDIRS=()
    MONGO_REMOTE_DEPLOY_PIDS=()
    MONGO_REMOTE_DEPLOY_PGIDS=()
    MONGO_ACTIVE_COMMAND_PID=""
    MONGO_ACTIVE_COMMAND_PGID=""
    MONGO_CLEANUP_RUNNING=0
    set -m
    (
      bash -c 'printf "%s\n" "$$" > "$1"; exec -a "$2" sleep 30' \
        bash "$process_pid_file" "$process_marker"
    ) &
    process_worker_pid=$!
    set +m
    MONGO_REMOTE_DEPLOY_PIDS+=("$process_worker_pid")
    MONGO_REMOTE_DEPLOY_PGIDS+=("$process_worker_pid")
    for _ in {1..20}; do
      [[ -s "$process_pid_file" ]] && break
      sleep 0.05
    done
    [[ -s "$process_pid_file" ]] || exit 2
    process_child_pid=$(<"$process_pid_file")
    cleanup_on_exit
    ! kill -0 "$process_child_pid" 2>/dev/null
  )
  process_tree_status=$?
  if [[ -s "$process_pid_file" ]]; then
    process_child_pid=$(<"$process_pid_file")
    kill "$process_child_pid" 2>/dev/null || true
  fi
  rm -rf "$process_test_dir"
  if (( process_tree_status == 0 )); then
    pass "signal cleanup terminates a remote worker process tree"
  else
    fail "signal cleanup terminates a remote worker process tree"
  fi
else
  fail "process-tree cleanup helper exists"
fi

if declare -F calculate_app_fingerprint >/dev/null; then
  fingerprint_tmp=$(mktemp -d)
  mkdir -p "${fingerprint_tmp}/bin"
  printf 'alpha\n' > "${fingerprint_tmp}/bin/mongod"
  printf 'beta\n' > "${fingerprint_tmp}/bin/mongosh"
  fingerprint_before=$(calculate_app_fingerprint "$fingerprint_tmp")
  fingerprint_repeat=$(calculate_app_fingerprint "$fingerprint_tmp")
  printf 'changed\n' >> "${fingerprint_tmp}/bin/mongod"
  fingerprint_after=$(calculate_app_fingerprint "$fingerprint_tmp")
  if [[ -n "$fingerprint_before" && "$fingerprint_before" == "$fingerprint_repeat" \
    && "$fingerprint_before" != "$fingerprint_after" ]]; then
    pass "application fingerprint is stable and detects binary changes"
  else
    fail "application fingerprint is stable and detects binary changes"
  fi
  rm -rf "$fingerprint_tmp"
else
  fail "application fingerprint helper exists"
fi

if declare -F run_step >/dev/null; then
  progress_log=$(mktemp)
  MONGO_PROGRESS_MODE=plain
  progress_init 2 "$progress_log"
  progress_set_stage "测试阶段"
  _test_ok() { printf 'detail output\n'; }
  _test_fail() { printf 'failure detail\n' >&2; return 7; }

  success_output=$(run_step "成功步骤" _test_ok 2>&1)
  if [[ "$success_output" == *"✓ 成功步骤"* ]]; then pass "plain mode reports completed step"; else fail "plain mode reports completed step"; fi

  failure_output=$(run_step "失败步骤" _test_fail 2>&1)
  failure_rc=$?
  if (( failure_rc == 7 )) && [[ "$failure_output" == *"✗ 失败步骤失败"* ]] \
    && [[ "$failure_output" == *"退出码 7"* ]] && [[ "$failure_output" == *"安装已终止"* ]] \
    && [[ "$failure_output" == *"详细日志：${progress_log}"* ]]; then
    pass "failure stops animation and preserves exit code"
  else
    fail "failure stops animation and preserves exit code"
  fi

  mongo_admin_pass='log[*]?redaction-secret'
  _test_secret_output() { printf 'credential=%s\n' "$mongo_admin_pass"; }
  progress_init 1 "$progress_log"
  run_step "密码日志脱敏" _test_secret_output >/dev/null 2>&1
  if ! grep -Fq "$mongo_admin_pass" "$progress_log" && grep -Fq '[REDACTED]' "$progress_log"; then
    pass "detailed log redacts authentication password"
  else
    fail "detailed log redacts authentication password"
  fi
  mongo_admin_pass=''
  rm -f "$progress_log"
else
  fail "step runner exists"
fi

if declare -F conf_mongodb >/dev/null; then
  config_tmp=$(mktemp -d)
  env_base_dir="$config_tmp"
  env_app_dir="${config_tmp}/app"
  data_dir="${config_tmp}/data"
  log_dir="${config_tmp}/logs"
  backup_dir="${config_tmp}/backup"
  scripts_dir="${config_tmp}/scripts"
  pid_dir="${config_tmp}/run"
  mongo_keyfile="${config_tmp}/keyfile"
  mongo_tools_config="${config_tmp}/mongodb-tools.yml"
  mongo_auth_js="${config_tmp}/mongosh-auth.js"
  mongo_install_mode=single
  mongo_auth_enabled=Y
  mongo_bind_ip="127.0.0.1,10.20.0.10"
  mongo_admin_user=admin
  mongo_admin_pass="safe-admin-password"
  oplog_size_mb=1024
  mkdir -p "$env_app_dir/bin" "$data_dir/db" "$log_dir" "$backup_dir" "$scripts_dir" "$pid_dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$env_app_dir/bin/mongosh"
  chmod 0755 "$env_app_dir/bin/mongosh"
  chown() { return 0; }

  mongo_major_ver=6
  mongo_minor_ver=0
  mongo_patch_ver=30
  conf_mongodb >/dev/null 2>&1
  if grep -q '^  journal:$' "$config_tmp/mongod.conf"; then pass "MongoDB 6.0 config includes journal option"; else fail "MongoDB 6.0 config includes journal option"; fi
  if grep -q 'bindIp: "127.0.0.1,10.20.0.10"' "$config_tmp/mongod.conf"; then pass "generated config uses explicit private bind addresses"; else fail "generated config uses explicit private bind addresses"; fi
  if grep -q 'authorization: "enabled"' "$config_tmp/mongod.conf"; then pass "generated config enables access control"; else fail "generated config enables access control"; fi
  if grep -q "dbPath: \"${data_dir}/db\"" "$config_tmp/mongod.conf"; then pass "generated config uses selected data directory"; else fail "generated config uses selected data directory"; fi
  if grep -q 'tcmallocReleaseRate' "$config_tmp/mongod.conf"; then fail "generated config does not force tcmallocReleaseRate"; else pass "generated config does not force tcmallocReleaseRate"; fi

  mongo_install_mode=replicaset
  mongo_auth_enabled=N
  mongo_bind_ip="0.0.0.0"
  conf_mongodb >/dev/null 2>&1
  if grep -q 'authorization: "disabled"' "$config_tmp/mongod.conf" \
    && ! grep -q 'keyFile:' "$config_tmp/mongod.conf"; then
    pass "unauthenticated replica set omits keyFile"
  else
    fail "unauthenticated replica set omits keyFile"
  fi

  mongo_major_ver=8
  mongo_minor_ver=0
  mongo_patch_ver=29
  mongo_install_mode=replicaset
  mongo_auth_enabled=Y
  mongo_tls_enabled=Y
  mongo_cluster_auth_mode=x509
  mongo_tls_dir="${config_tmp}/tls"
  mongo_tls_ca_path="${mongo_tls_dir}/ca.pem"
  mongo_tls_cert_path="${mongo_tls_dir}/member.pem"
  conf_mongodb >/dev/null 2>&1
  if grep -q 'mode: requireTLS' "$config_tmp/mongod.conf" \
    && grep -q 'clusterAuthMode: x509' "$config_tmp/mongod.conf" \
    && grep -q "clusterFile: \"${mongo_tls_cert_path}\"" "$config_tmp/mongod.conf" \
    && ! grep -q 'keyFile:' "$config_tmp/mongod.conf"; then
    pass "TLS X.509 replica-set config uses version-supported settings"
  else
    fail "TLS X.509 replica-set config uses version-supported settings"
  fi
  mongo_tls_enabled=N
  mongo_cluster_auth_mode=keyFile

  mongo_major_ver=6
  mongo_minor_ver=1
  mongo_install_mode=single
  mongo_auth_enabled=Y
  mongo_bind_ip="127.0.0.1,10.20.0.10"
  conf_mongodb >/dev/null 2>&1
  if grep -q '^  journal:$' "$config_tmp/mongod.conf"; then fail "MongoDB 6.1 config omits removed journal option"; else pass "MongoDB 6.1 config omits removed journal option"; fi

  create_auth_material >/dev/null 2>&1
  if grep -q '^password: "safe-admin-password"$' "$mongo_tools_config" \
    && grep -Fq "auth('admin', 'safe-admin-password')" "$mongo_auth_js"; then
    pass "backup and shell credentials are stored in protected config files"
  else
    fail "backup and shell credentials are stored in protected config files"
  fi
  [[ "$(stat -c '%a' "$mongo_tools_config" 2>/dev/null)" == "640" ]] \
    && pass "credential config has mode 0640" || fail "credential config has mode 0640"
  printf '#!/usr/bin/env bash\n[[ "${1:-}" == "--help" ]] && echo --config\n' > "$env_app_dir/bin/mongodump"
  chmod 0755 "$env_app_dir/bin/mongodump"
  if create_backup_script >/dev/null 2>&1 \
    && grep -Fq "BACKUP_DIR=\"${backup_dir}\"" "$scripts_dir/mongo_backup.sh"; then
    pass "generated backup script uses selected backup directory"
  else
    fail "generated backup script uses selected backup directory"
  fi
  summary_output=$(print_summary 2>&1)
  if [[ "$summary_output" == *"管理员密码      : safe-admin-password"* \
    && "$summary_output" == *"SCRAM-SHA-256"* ]]; then
    pass "terminal summary shows requested authentication credentials"
  else
    fail "terminal summary shows requested authentication credentials"
  fi
  rm -rf "$config_tmp"
else
  fail "MongoDB config generator exists"
fi

assert_file_not_contains "step runner does not eval commands" "$installer" 'eval[[:space:]]+"\$cmd"'
assert_file_not_contains "SSH host-key verification is never disabled" "$installer" 'StrictHostKeyChecking=no'
assert_file_not_contains "base directory is never recursively chowned" "$installer" 'chown[[:space:]]+-R[^\n]*\$env_base_dir'
assert_file_contains "application binaries use the selected owner and group" "$installer" 'chown[[:space:]]+-R[[:space:]]+"\$\{mongo_owner\}:\$\{mongo_owner\}"[[:space:]]+"\$\{env_app_dir\}"'
assert_file_contains "runtime directories use the selected owner and group" "$installer" 'install[[:space:]]+-d[[:space:]]+-o[[:space:]]+"\$mongo_owner"[[:space:]]+-g[[:space:]]+"\$mongo_owner"'
assert_file_contains "existing runtime user is reassigned to the selected same-name primary group" "$installer" 'usermod[[:space:]]+-g[[:space:]]+"\$\{mongo_owner\}"'
assert_file_contains "systemd service uses the selected owner as User" "$installer" '^User=\$\{mongo_owner\}$'
assert_file_contains "systemd service uses the selected owner as Group" "$installer" '^Group=\$\{mongo_owner\}$'
assert_file_contains "systemd NUMA launcher uses the resolved absolute executable path" "$installer" 'exec_prefix="\$\{numactl_path\}[[:space:]]+--interleave=all[[:space:]]+"'
assert_file_contains "remote systemd NUMA launcher uses the resolved absolute executable path" "$installer" '_exec_prefix="\$\{_numactl_path\}[[:space:]]+--interleave=all[[:space:]]+"'
assert_file_contains "keyFile uses the selected owner and group" "$installer" 'chown[[:space:]]+"\$\{mongo_owner\}:\$\{mongo_owner\}"[[:space:]]+"\$mongo_keyfile"'
assert_file_contains "TLS files use the selected owner and group" "$installer" 'install[[:space:]]+-o[[:space:]]+"\$mongo_owner"[[:space:]]+-g[[:space:]]+"\$mongo_owner"[[:space:]]+-m[[:space:]]+0600'
assert_file_not_contains "MongoDB-managed files never use root as their selected-owner substitute" "$installer" 'chown([^\n]*)(root:\$\{mongo_owner\}|.root:\$\{mongo_owner\})'
assert_file_contains "application directories remain traversable by mongod service user" "$installer" 'chmod[[:space:]]+0755[[:space:]]+"\$\{env_app_dir\}"[[:space:]]+"\$\{env_app_dir\}/bin"'
assert_file_contains "custom owner falls back when preferred GID is occupied" "$installer" 'getent[[:space:]]+group[[:space:]]+60300.*groupadd[[:space:]]+-r'
assert_file_contains "custom owner falls back when preferred UID is occupied" "$installer" 'getent[[:space:]]+passwd[[:space:]]+60300.*useradd[[:space:]]+-r'
assert_file_not_contains "root spool crontab is not edited directly" "$installer" '/var/spool/cron'
assert_file_contains "installer stops and disables firewall services" "$installer" 'systemctl[[:space:]]+disable[[:space:]]+--now[[:space:]]+"\$\{service_name\}\.service"'
assert_file_contains "installer permanently masks firewall services" "$installer" 'systemctl[[:space:]]+mask[[:space:]]+"\$\{service_name\}\.service"'
assert_file_contains "installer disables SELinux at runtime" "$installer" 'setenforce[[:space:]]+0'
assert_file_contains "installer disables SELinux in persistent config" "$installer" 'SELINUX=disabled'
assert_file_contains "installer disables SELinux in every RHEL kernel entry" "$installer" 'grubby[[:space:]]+--update-kernel[[:space:]]+ALL[[:space:]]+--args[[:space:]]+selinux=0'
assert_file_contains "RHEL ISO installation imports the OS-provided vendor key" "$installer" 'rpm[[:space:]]+--import[[:space:]]+"\$key_file"'
assert_file_contains "RHEL ISO installation distinguishes absent packages with repoquery" "$installer" 'repoquery[[:space:]]+--available'
assert_file_not_contains "RHEL ISO installation never disables GPG verification" "$installer" 'gpgcheck=0|nogpgcheck'
assert_file_not_contains "top-level output is not piped through tee" "$installer" 'main[[:space:]]+"\$@".*tee'
assert_file_not_contains "installer avoids speculative TCP and dirty-page tuning" "$installer" 'vm\.dirty_ratio|vm\.dirty_expire_centisecs|tcp_tw_reuse|tcp_fin_timeout|netdev_max_backlog'
assert_file_contains "systemd file limits are resource-derived" "$installer" 'LimitNOFILE=\$\{mongo_nofile_limit\}'
assert_file_contains "systemd permits an external data directory" "$installer" 'ReadWritePaths=\$\{env_base_dir\}[[:space:]]+\$\{data_dir\}'
assert_file_contains "remote deployment restarts upgraded mongod" "$installer" 'systemctl[[:space:]]+restart[[:space:]]+mongod\.service'
assert_file_contains "remote nodes are deployed by background workers" "$installer" 'deploy_remote_node[^&]*&'
assert_file_contains "signal cleanup stops active remote deployment workers" "$installer" 'MONGO_REMOTE_DEPLOY_PIDS'
assert_file_contains "remote deployment workers have tracked process groups" "$installer" 'MONGO_REMOTE_DEPLOY_PGIDS'
assert_file_contains "progress panel uses absolute top-row rendering" "$installer" "printf '\\\\033\\[%d;1H"
assert_file_contains "progress cleanup restores the full scroll region" "$installer" "printf '\\\\033\\[r'"
assert_file_not_contains "DNF and YUM calls use the bounded runner" "$installer" '^[[:space:]]*(dnf|yum)[[:space:]]'
assert_file_contains "same-version binary transfer uses application fingerprint" "$installer" '应用指纹一致，跳过二进制传输与解压'
assert_file_contains "one application archive is reused by parallel workers" "$installer" '供 .* 个远程节点复用'
assert_file_contains "SSH connections are multiplexed through a private control directory" "$installer" 'ControlMaster=auto'
assert_file_contains "repeat replica-set initialization checks authenticated state first" "$installer" 'mongo_auth_enabled.*run_mongo_eval.*connectionStatus'
assert_file_contains "replica-set initialization uses a shell-version-independent success marker" "$installer" 'MONGO_INSTALL_RS_INIT_OK'
assert_file_contains "mongod starts after persistent storage and THP tuning" "$installer" 'After=.*mongodb-readahead\.service.*mongodb-thp\.service.*disable-thp\.service'
assert_file_contains "replica-set CLI accepts DNS hosts" "$installer" '--hosts'
assert_file_contains "replica-set SSH endpoints have an independent parser branch" "$installer" '^[[:space:]]*-ri\|--remote-ips\)'
assert_file_contains "cluster host mappings are backed up before editing" "$installer" '/etc/hosts\.bak\.\$\(date'
assert_file_contains "remote deployment pairs member names with SSH endpoints" "$installer" 'deploy_remote_node[[:space:]]+"\$host"[[:space:]]+"\$endpoint"'
assert_file_contains "admin secret file option is supported" "$installer" '--admin-pass-file'
assert_file_contains "SSH secret file option is supported" "$installer" '--root-pass-file'
assert_file_contains "network binding is configurable" "$installer" '--bind-ip'
assert_file_contains "install directory has an explicit alias" "$installer" '--install-dir'
assert_file_contains "data directory is independently configurable" "$installer" '--data-dir'
assert_file_contains "backup directory is independently configurable" "$installer" '--backup-dir'
cli_case_patterns=$(sed -n '/function main()/,/# ---- 开始安装 ----/p' "$installer" \
  | grep -E '^[[:space:]]+-[^[:space:]]*\)')
assert_all_long_options_have_short_alias
while read -r short_option long_option; do
  assert_cli_alias "$short_option" "$long_option"
done <<'ALIASES'
-m --mode
-n --hostname
-p --port
-d --dir
-d --install-dir
-dd --data-dir
-bd --backup-dir
-ou --owner
-H --hosts
-ri --remote-ips
-sk --ssh-key
-rpf --root-pass-file
-rp --root-pass
-ss --ssh-port
-kh --known-hosts
-rs --repl-set
-a --auth
-na --no-auth
-au --admin-user
-ap --admin-pass
-apf --admin-pass-file
-t --tls
-nt --no-tls
-tca --tls-ca-file
-tck --tls-cert-key-file
-tcd --tls-cert-dir
-cam --cluster-auth-mode
-bi --bind-ip
-as --allow-source
-op --oplog-size
-mc --max-connections
-j --remote-parallelism
-oo --os-only
-dbg --debug
-br --backup-days
-mv --mongo-version
-mp --mongo-package
-oir --os-iso-root
-opd --os-packages-dir
-np --no-progress
-y --yes
-h --help
ALIASES
assert_success "all short options are accepted by the real CLI parser" \
  bash "$installer" \
    -m rs -n mongodbtest -p 27019 -d /opt/mongodb-test \
    -dd /data/mongodb-test -bd /backup/mongodb-test -ou mongoops \
    -H db1.example.internal,db2.example.internal,db3.example.internal \
    -ri db1.example.internal,db2.example.internal,db3.example.internal \
    -sk /tmp/test-id -rpf /tmp/test-root-pass -rp dummy-root-password \
    -ss 22022 -kh /tmp/test-known-hosts -rs rsShort \
    -a -na -au opsadmin -ap dummy-admin-password -apf /tmp/test-admin-pass \
    -t -nt -tca /tmp/test-ca.pem -tck /tmp/test-member.pem \
    -tcd /tmp/test-members -cam x509 -bi 127.0.0.1 -as 10.0.0.0/8 \
    -op 2048 -mc 32768 -j 2 -oo -dbg -br 14 -mv 8.0.29 \
    -mp 8.0.29 -oir /mnt/rhel8 -opd /tmp/test-rpms -np -y -h
xtrace_secret="MONGO_XTRACE_SECRET_${$}_DO_NOT_PRINT"
xtrace_output=$(bash -x "$installer" -rp "$xtrace_secret" -h 2>&1)
if [[ "$xtrace_output" != *"$xtrace_secret"* ]]; then
  pass "caller xtrace is disabled before password argument parsing"
else
  fail "caller xtrace is disabled before password argument parsing"
fi
help_output=$(NO_COLOR=1 bash "$installer" -h 2>&1)
if [[ "$help_output" != *$'\033'* && "$help_output" != *'\E'* && "$help_output" != *'\033'* ]]; then
  pass "help output contains no ANSI or literal escape tokens"
else
  fail "help output contains no ANSI or literal escape tokens"
fi
assert_file_contains "hostname defaults to mongodb base" "$installer" '^hostname="mongodb"$'
assert_file_contains "authentication summary includes account password" "$installer" '管理员密码[[:space:]]*:.*mongo_admin_pass'
assert_file_contains "authentication summary includes mechanism" "$installer" '认证方式[[:space:]]*:.*mongo_auth_mechanism'
assert_file_contains "final summary shows ephemeral total duration" "$installer" '本次安装耗时[[:space:]]*:.*INSTALL_ELAPSED_SECONDS'
assert_file_not_contains "installer does not persist timing history" "$installer" 'install-history|mongo_install_history|record_install_metrics'
assert_file_contains "installer supports TLS" "$installer" '--tls-ca-file'
assert_file_contains "installer supports X.509 member authentication" "$installer" 'clusterAuthMode: x509'
assert_file_contains "generated maintenance scripts leave inaccessible root cwd" "$installer" 'cd "\$MONGO_BASE_DIR" \|\| exit 1'
assert_file_contains "cron jobs receive an accessible HOME" "$installer" 'HOME=\$\{env_base_dir\}'
assert_file_not_contains "logo does not hardcode a stale installer version" "$installer" 'One-Click Installer v1\.0\.0'
assert_file_contains "generator supports direct authentication password shorthand" "$generator" "flag: '-ap'"
assert_file_contains "generator emits short data-directory option" "$generator" "flag: '-dd'"
assert_file_contains "generator labels short and long TLS CA options" "$generator" '-tca / --tls-ca-file'
assert_file_contains "documentation lists short data-directory option" "$docs" '-dd, --data-dir'
assert_file_contains "documentation lists short remote-parallelism option" "$docs" '-j, --remote-parallelism'
assert_file_contains "documentation separates replica members from SSH endpoints" "$docs" '--remote-ips.*SSH'
assert_file_not_contains "generator does not put root passwords on command line" "$generator" '(-rp|--root-pass)[[:space:]]+\x27'
assert_file_not_contains "generator avoids dynamic innerHTML rendering" "$generator" 'cmdOutput.*innerHTML|innerHTML[[:space:]]*=[[:space:]]*html'
assert_file_contains "generator shell-quotes dynamic values" "$generator" 'function shellQuote\(value\)'
assert_file_contains "generator exposes all-interface bind configuration" "$generator" '0\.0\.0\.0'
assert_file_contains "generator warns about disabled firewall" "$generator" '停止并禁用防火墙'
assert_file_contains "generator exposes OS-only MongoDB version" "$generator" 'f-mongo-version'
assert_file_contains "generator exposes MongoDB package selection" "$generator" 'f-mongo-package'
assert_file_contains "generator exposes OS ISO source" "$generator" 'f-os-iso-root'
assert_file_contains "generator exposes TLS configuration" "$generator" 'f-tls-ca'
assert_file_contains "generator exposes remote parallelism" "$generator" 'f-remote-parallelism'
assert_file_contains "generator exposes separate SSH endpoint mapping" "$generator" 'f-remote-ips'
assert_file_contains "generator exposes independent data directory" "$generator" 'f-data-dir'
assert_file_contains "generator exposes independent backup directory" "$generator" 'f-backup-dir'
assert_file_contains "installer uses requested offline archive name" "$installer" 'mongdb-offline-rpm\.tar\.gz'
assert_file_contains "documentation uses requested offline archive layout" "$docs" 'mongdb-offline-rpm/rhel/9/x86_64/'
assert_file_contains "offline bundle builder emits requested top-level directory" "$builder" 'mongdb-offline-rpm/\$\{os_id\}/\$\{os_major\}/\$\{arch\}/'
assert_file_not_contains "installer has no sshpass runtime dependency" "$installer" 'SSHPASS=|sshpass[[:space:]]+-e|required_commands\+=\(sshpass\)'
assert_file_not_contains "offline bundle builder does not default to sshpass" "$builder" '^[[:space:]]*sshpass$'
assert_file_contains "password bootstrap uses native OpenSSH askpass" "$installer" 'SSH_ASKPASS_REQUIRE=force'
assert_file_contains "temporary askpass helper is removed on exit" "$installer" '/tmp/mongo-ssh-askpass\.\*'
assert_file_contains "password bootstrap generates an Ed25519 key" "$installer" "ssh-keygen -q -t ed25519"
assert_file_contains "password bootstrap installs authorized key idempotently" "$installer" 'grep -Fqx.*authorized_keys'
assert_file_contains "password bootstrap verifies key login before deployment" "$installer" 'SSH 公钥信任验证失败'
assert_file_contains "offline bundle selection is limited to requested package names" "$installer" 'package_name.*requested_name'
assert_file_contains "dependency installation passes the current missing package set" "$installer" 'install_os_offline_bundle "\$\{requested_packages\[@\]\}"'
assert_file_contains "CentOS 7 ISO path uses yum when dnf is unavailable" "$installer" 'command -v yum'
assert_file_contains "offline RPM signatures are verified" "$installer" 'rpm --checksig'
assert_file_contains "documentation records native password-to-key bootstrap" "$docs" 'SSH_ASKPASS.*Ed25519'
assert_file_not_contains "documentation commands do not comment after line continuations" "$docs" '\\[[:space:]]*<span class="c">'
assert_success "installer passes Bash syntax validation" bash -n "$installer"
assert_success "offline bundle builder passes Bash syntax validation" bash -n "$builder"

printf '\n%d passed, %d failed\n' "$passes" "$failures"
(( failures == 0 ))
