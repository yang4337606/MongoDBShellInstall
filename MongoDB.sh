#!/bin/bash
#==============================================================#
# 脚本名     :   MongoDBShellInstall
# 创建时间   :   2026-04-24 00:00:00
# 描述      :   MongoDB 一键安装脚本（单机/副本集 双模式）
# 路径      :   /soft/MongoDBShellInstall
# 版本      :   2.0.1
# 借鉴      :   KafkaShellInstall
# 兼容      :   RHEL/CentOS/Rocky/Alma 7-9, Debian 10-13, Ubuntu 18.04-24.04,
#               openSUSE/SLES 12-15, Arch Linux, Fedora, Amazon Linux 2/2023
#               (MongoDB 官方支持平台: RHEL 8/9, Debian 11/12, Ubuntu 22.04/24.04,
#                SLES 15, Amazon Linux 2023)
#==============================================================#
set -o pipefail
umask 027

# 清理临时文件与终端状态
MONGO_INSTALL_TMPFILES=()
MONGO_INSTALL_TMPDIRS=()
MONGO_REMOTE_DEPLOY_PIDS=()
_ACTIVE_SPINNER_PID=""
PROGRESS_CURSOR_HIDDEN=0
mongo_ssh_control_dir=""
cleanup_on_exit() {
  if [[ -n "$_ACTIVE_SPINNER_PID" ]]; then
    kill "$_ACTIVE_SPINNER_PID" 2>/dev/null
    wait "$_ACTIVE_SPINNER_PID" 2>/dev/null
    _ACTIVE_SPINNER_PID=""
  fi
  if (( PROGRESS_CURSOR_HIDDEN )); then
    printf '\033[?25h' 2>/dev/null
    PROGRESS_CURSOR_HIDDEN=0
  fi
  local deploy_pid
  # Bash 4.2 (CentOS 7) treats an empty array expansion as an unbound
  # variable under `set -u`. The + guard keeps cleanup safe when no worker
  # or temporary path was registered.
  for deploy_pid in ${MONGO_REMOTE_DEPLOY_PIDS[@]+"${MONGO_REMOTE_DEPLOY_PIDS[@]}"}; do
    if kill -0 "$deploy_pid" 2>/dev/null; then
      kill "$deploy_pid" 2>/dev/null || true
    fi
    wait "$deploy_pid" 2>/dev/null || true
  done
  for tmpf in ${MONGO_INSTALL_TMPFILES[@]+"${MONGO_INSTALL_TMPFILES[@]}"}; do
    [[ -f "$tmpf" ]] && rm -f "$tmpf"
  done
  for tmpd in ${MONGO_INSTALL_TMPDIRS[@]+"${MONGO_INSTALL_TMPDIRS[@]}"}; do
    case "$tmpd" in
      /tmp/mongo_install.*|/tmp/mongosh_install.*|/tmp/mongotools_install.*|/tmp/mongo-os-packages.*|/tmp/mongo-ssh-control.*)
        [[ -d "$tmpd" || -L "$tmpd" ]] && rm -rf -- "$tmpd"
        ;;
    esac
  done
}

handle_signal() {
  local signal_name="$1" exit_code="$2"
  cleanup_on_exit "$exit_code"
  printf '\n安装已被信号 %s 中断\n详细日志：%s\n' "$signal_name" "$Mongoinstalllog" >&2
  trap - EXIT
  exit "$exit_code"
}

trap 'cleanup_on_exit $?' EXIT
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

#==============================================================#
#                         全局变量定义                         #
#==============================================================#
MONGO_INSTALL_VERSION="2.0.1"

software_dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
script_name=$(basename "${BASH_SOURCE[0]}")
current=$(date +%Y%m%d%H%M%S)
Mongoinstalllog="$software_dir/print_mongo_install_$current.log"
INSTALL_STARTED_EPOCH=0
INSTALL_ELAPSED_SECONDS=0

# 操作系统信息
os_distro="unknown"
os_distro_family="unknown"
os_version_id="0"
if [[ -f /etc/os-release ]]; then
  os_distro=$(. /etc/os-release && echo "${ID:-unknown}")
  os_version_id=$(. /etc/os-release && echo "${VERSION_ID:-0}")
  os_version=${os_version_id%%.*}
  os_version=${os_version:-0}
elif [[ -f /etc/redhat-release ]]; then
  os_distro="centos"
  os_version_id=$(grep -oE '[0-9]+([.][0-9]+)?' /etc/redhat-release 2>/dev/null | head -n1)
  os_version=${os_version_id%%.*}
else
  os_version="0"
fi
os_version_id=${os_version_id:-${os_version:-0}}
os_version_minor=0
if [[ "$os_version_id" =~ ^[0-9]+\.([0-9]+) ]]; then
  os_version_minor="${BASH_REMATCH[1]}"
fi
os_arch=$(uname -m 2>/dev/null || echo unknown)

case "$os_distro" in
  centos|rhel|rocky|alma|ol|fedora|amzn|anolis|openEuler|tencentos|alinux)
    os_distro_family="rhel" ;;
  debian|ubuntu|linuxmint|pop|kali|raspbian|deepin|uos)
    os_distro_family="debian" ;;
  opensuse*|sles|suse)
    os_distro_family="suse" ;;
  arch|manjaro|endeavouros)
    os_distro_family="arch" ;;
  *)
    if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
      os_distro_family="rhel"
    elif command -v apt-get &>/dev/null; then
      os_distro_family="debian"
    elif command -v zypper &>/dev/null; then
      os_distro_family="suse"
    elif command -v pacman &>/dev/null; then
      os_distro_family="arch"
    fi
    ;;
esac

HAS_SYSTEMD=0
if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
  HAS_SYSTEMD=1
fi

NOLOGIN_PATH="/sbin/nologin"
if [[ ! -f "$NOLOGIN_PATH" ]]; then
  if [[ -f /usr/sbin/nologin ]]; then
    NOLOGIN_PATH="/usr/sbin/nologin"
  elif command -v nologin &>/dev/null; then
    NOLOGIN_PATH=$(command -v nologin)
  else
    NOLOGIN_PATH="/bin/false"
  fi
fi
os_memory_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
# 容器中以 cgroup 限额为准，避免按宿主机内存生成过大的 WiredTiger 缓存。
for _memory_limit_file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
  if [[ -f "$_memory_limit_file" ]]; then
    _memory_limit_bytes=$(<"$_memory_limit_file")
    if [[ "$_memory_limit_bytes" =~ ^[0-9]+$ && ${#_memory_limit_bytes} -le 18 ]]; then
      _memory_limit_kb=$((10#$_memory_limit_bytes / 1024))
      if (( _memory_limit_kb > 0 && _memory_limit_kb < os_memory_total )); then
        os_memory_total=$_memory_limit_kb
      fi
    fi
  fi
done
unset _memory_limit_file _memory_limit_bytes _memory_limit_kb
os_memory_mb=$((${os_memory_total:-0} / 1024))
os_core=$(grep -c '^processor' /proc/cpuinfo)

# MongoDB 安装默认值
# 单机直接使用该名称；副本集节点在名称后追加本机 IPv4 的第三、四段。
hostname="mongodb"
mongo_owner=mongod
mongo_port=27017
debug_flag=N
assume_yes=N

# 目录结构
env_base_dir=/mongodb
env_app_dir=${env_base_dir}/app
data_dir=${env_base_dir}/data
log_dir=${env_base_dir}/logs
backup_dir=${env_base_dir}/backup
scripts_dir=${env_base_dir}/scripts
pid_dir=${env_base_dir}/run
mongo_data_dir_override=""
mongo_backup_dir_override=""

# 安装模式: single / replicaset (空=交互选择)
declare -l mongo_install_mode=""
# 仅配置操作系统
declare -u only_conf_os=N
# 副本集成员主机数组（MongoDB 5.0+ 要求 DNS 主机名）
declare -a hosts_array=()
# 与 hosts_array 按位置对应的 SSH 端点；可使用 IP 或独立管理域名。
declare -a remote_ips_array=()
declare -a cluster_endpoint_ips_array=()
# SSH 端口
export serverport=22
# 远程 SSH 凭据；优先使用密钥，密码仅作为兼容回退
remote_root_pass=""
remote_root_pass_file=""
ssh_identity_file=""
ssh_known_hosts_file="${HOME:-/root}/.ssh/known_hosts"

# 副本集名称
repl_set_name="rs0"

# MongoDB 版本号 (安装时检测填充)
mongo_major_ver=0
mongo_minor_ver=0
mongo_patch_ver=0
selected_mongo_tarball=""
mongo_package_choice=""

# OS 依赖离线来源。默认补充包目录按 OS 主版本和架构隔离，避免跨版本混装。
os_packages_archive="${software_dir}/mongdb-offline-rpm.tar.gz"
os_packages_root="${software_dir}/mongdb-offline-rpm"
os_packages_dir=""
os_iso_root=""

# WiredTiger 缓存大小 (自动计算，单位 GB)
wt_cache_size_gb=0
wt_cache_size_mb=0
mongo_memory_reserve_mb=0

# 认证相关（默认关闭；通过 --auth 显式启用）
mongo_auth_enabled=N
mongo_admin_user="admin"
mongo_admin_pass=""
mongo_admin_pass_file=""
mongo_auth_mechanism="SCRAM-SHA-256"
# keyFile 路径 (副本集模式认证)
mongo_keyfile="${env_base_dir}/keyfile"
mongo_tools_config="${env_base_dir}/mongodb-tools.yml"
mongo_auth_js="${env_base_dir}/mongosh-auth.js"

# 可选 TLS 与副本集内部认证。TLS 证书由外部 CA 预先签发，脚本只校验、安装和分发。
mongo_tls_enabled=N
mongo_tls_ca_file=""
mongo_tls_cert_dir=""
mongo_tls_cert_key_file=""
mongo_tls_dir="${env_base_dir}/tls"
mongo_tls_ca_path="${mongo_tls_dir}/ca.pem"
mongo_tls_cert_path="${mongo_tls_dir}/member.pem"
mongo_cluster_auth_mode="keyFile"

# 网络暴露：默认监听全部 IPv4 地址，可通过 --bind-ip 收敛。
mongo_bind_ip=""
declare -a firewall_sources=()

# 可配置运维参数
backup_retention_days=7
# oplog 大小 (MB, 0=自动)
oplog_size_mb=0
# 最大连接数
max_connections=65536
# 远程节点分批并行部署，默认最多同时处理 4 个节点。
mongo_remote_parallelism=4
# 根据连接数、CPU 和内核上限计算，供 limits、systemd、sysctl 与摘要共用。
mongo_nofile_limit=64000
mongo_nproc_limit=64000
mongo_file_max_target=2097152
mongo_somaxconn_target=4096
mongo_numa_nodes=1
mongo_resource_profile_ready=0
mongo_data_device=""
mongo_readahead_sectors=32
# journal: MongoDB 6.1+ 移除了 storage.journal.enabled 选项 (journal 始终开启)
# 此变量仅用于 MongoDB 4.x/5.x/6.0 的兼容
#==============================================================#
#                          工具函数                            #
#==============================================================#
function upper() { echo "${1^^}"; }
function lower() { echo "${1,,}"; }

function get_local_ip() {
  local lip
  lip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')
  if [[ -z "$lip" ]]; then
    lip=$(ip -4 addr show scope global 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
  fi
  echo "${lip:-127.0.0.1}"
}

function port_is_listening() {
  local port="$1" socket_list
  socket_list=$(ss -tln 2>/dev/null) || return 1
  [[ "$socket_list" == *":${port} "* ]]
}

function is_local_host() {
  local target="$1"
  local local_ip="$2"
  [[ "$target" == "$local_ip" || "$target" == "127.0.0.1" || "$target" == "localhost" ]] && return 0
  local resolved
  while IFS= read -r resolved; do
    [[ "$resolved" == "$local_ip" || "$resolved" == "127.0.0.1" ]] && return 0
  done < <(getent ahostsv4 "$target" 2>/dev/null | awk '{print $1}' | sort -u)
  if ip -4 addr show 2>/dev/null | grep -qw "$target"; then
    return 0
  fi
  return 1
}

function create_mongo_symlinks() {
  local app_dir="${1:-$env_app_dir}"
  for cmd in mongod mongos mongosh mongo; do
    if [[ -x "${app_dir}/bin/${cmd}" ]]; then
      ln -sf "${app_dir}/bin/${cmd}" "/usr/local/bin/${cmd}" || return 1
    fi
  done
  # mongodump / mongorestore / mongostat / mongotop
  for tool in mongodump mongorestore mongoexport mongoimport mongostat mongotop; do
    if [[ -x "${app_dir}/bin/${tool}" ]]; then
      ln -sf "${app_dir}/bin/${tool}" "/usr/local/bin/${tool}" || return 1
    fi
  done
}
#==============================================================#
#                         颜色打印                             #
#==============================================================#
function color_printf() {
  declare -u con_flag
  local text_primary="${2:-}" text_secondary="${3:-}" text_tertiary="${4:-}"
  declare -A color_map=(
    ["red"]='\E[1;31m'
    ["green"]='\E[1;32m'
    ["blue"]='\E[1;34m'
    ["yellow"]='\E[1;33m'
    ["light_blue"]='\E[1;94m'
    ["purple"]='\033[35m'
  )
  local res='\E[0m' default_color='\E[1;32m'
  local color=${color_map[$1]:-"$default_color"}
  case "$1" in
  "red")
    printf "\n${color}%-20s %-30s %-50s\n${res}\n" "$text_primary" "$text_secondary" "$text_tertiary" >&2
    return 1
    ;;
  "green" | "light_blue")
    printf "${color}%-20s %-30s %-50s\n${res}" "$text_primary" "$text_secondary" "$text_tertiary"
    ;;
  "purple")
    printf "${color}%-s${res}" "$text_primary" "$text_secondary"
    if ! read -r con_flag; then
      printf '\n错误: 未读取到确认输入\n' >&2
      exit 1
    fi
    if [[ -z $con_flag ]]; then con_flag=Y; fi
    if [[ $con_flag != "Y" ]]; then echo; exit 1; fi
    ;;
  *)
    printf "${color}%-20s %-30s %-50s\n${res}\n" "$text_primary" "$text_secondary" "$text_tertiary"
    ;;
  esac
}
#==============================================================#
#              总体进度、当前步骤动画与详细日志                 #
#==============================================================#
PROGRESS_TOTAL=0
PROGRESS_COMPLETED=0
PROGRESS_STAGE="准备"
PROGRESS_CURRENT_NAME=""
PROGRESS_CURRENT_ICON=""
PROGRESS_CURRENT_DURATION=0
PROGRESS_CURRENT_STATE="idle"
PROGRESS_FAILURE_CODE=0
PROGRESS_RENDERED_LINES=0
PROGRESS_LOG_FILE=""
declare -a PROGRESS_HISTORY_ICON=()
declare -a PROGRESS_HISTORY_NAME=()
declare -a PROGRESS_HISTORY_DURATION=()

format_duration() {
  local seconds="${1:-0}"
  (( seconds < 0 )) && seconds=0
  if (( seconds >= 3600 )); then
    printf '%02d:%02d:%02d' "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
  else
    printf '%02d:%02d' "$((seconds / 60))" "$((seconds % 60))"
  fi
}

begin_install_timer() {
  INSTALL_STARTED_EPOCH=$(date +%s)
  INSTALL_ELAPSED_SECONDS=0
}

finish_install_timer() {
  local finished_epoch
  finished_epoch=$(date +%s)
  INSTALL_ELAPSED_SECONDS=$((finished_epoch - INSTALL_STARTED_EPOCH))
  (( INSTALL_ELAPSED_SECONDS < 0 )) && INSTALL_ELAPSED_SECONDS=0
}

build_progress_bar() {
  local current="${1:-0}" total="${2:-0}" width="${3:-20}"
  local filled=0 empty=0 bar="" i
  if (( total > 0 )); then
    filled=$((current * width / total))
  fi
  (( filled > width )) && filled=$width
  (( filled < 0 )) && filled=0
  empty=$((width - filled))
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  printf '[%s]' "$bar"
}

progress_pad() {
  local text="$1" target="${2:-34}" length padding char_length byte_length extra_width
  char_length=${#text}
  # Bash 的字符数不等于终端列宽；中文/常见宽字符通常占两列。
  local LC_ALL=C
  byte_length=${#text}
  extra_width=$(((byte_length - char_length) / 2))
  length=$((char_length + extra_width))
  padding=$((target - length))
  (( padding < 1 )) && padding=1
  printf '%s%*s' "$text" "$padding" ''
}

progress_set_stage() {
  PROGRESS_STAGE="$1"
}

progress_init() {
  PROGRESS_TOTAL="${1:-0}"
  PROGRESS_LOG_FILE="${2:-$Mongoinstalllog}"
  PROGRESS_COMPLETED=0
  PROGRESS_STAGE="准备"
  PROGRESS_CURRENT_NAME=""
  PROGRESS_CURRENT_ICON=""
  PROGRESS_CURRENT_DURATION=0
  PROGRESS_CURRENT_STATE="idle"
  PROGRESS_FAILURE_CODE=0
  PROGRESS_RENDERED_LINES=0
  PROGRESS_HISTORY_ICON=()
  PROGRESS_HISTORY_NAME=()
  PROGRESS_HISTORY_DURATION=()

  if [[ -z "${MONGO_PROGRESS_MODE:-}" ]]; then
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" && "$debug_flag" != "Y" ]]; then
      MONGO_PROGRESS_MODE="ansi"
    else
      MONGO_PROGRESS_MODE="plain"
    fi
  fi
  case "$MONGO_PROGRESS_MODE" in
    ansi|plain) ;;
    *) MONGO_PROGRESS_MODE="plain" ;;
  esac

  if [[ -L "$PROGRESS_LOG_FILE" || ( -e "$PROGRESS_LOG_FILE" && ! -f "$PROGRESS_LOG_FILE" ) ]]; then
    printf '错误: 日志路径不是安全的普通文件: %s\n' "$PROGRESS_LOG_FILE" >&2
    return 1
  fi
  if [[ -e "$PROGRESS_LOG_FILE" ]]; then
    [[ "$(stat -c '%u' "$PROGRESS_LOG_FILE" 2>/dev/null)" == "$EUID" ]] || {
      printf '错误: 拒绝覆盖不属于当前用户的日志文件: %s\n' "$PROGRESS_LOG_FILE" >&2
      return 1
    }
    : > "$PROGRESS_LOG_FILE" || return 1
  else
    ( set -o noclobber; : > "$PROGRESS_LOG_FILE" ) 2>/dev/null || {
      printf '错误: 无法安全创建日志文件: %s\n' "$PROGRESS_LOG_FILE" >&2
      return 1
    }
  fi
  chmod 0600 "$PROGRESS_LOG_FILE" 2>/dev/null || {
    printf '错误: 无法收紧日志文件权限: %s\n' "$PROGRESS_LOG_FILE" >&2
    return 1
  }
  {
    printf 'MongoDBShellInstall v%s\n' "$MONGO_INSTALL_VERSION"
    printf '开始时间: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } >> "$PROGRESS_LOG_FILE"

  if [[ "$MONGO_PROGRESS_MODE" == "plain" ]]; then
    printf 'MongoDB 自动安装\n'
  else
    printf '\033[?25l'
    PROGRESS_CURSOR_HIDDEN=1
  fi
}

progress_render() {
  [[ "$MONGO_PROGRESS_MODE" == "ansi" ]] || return 0

  local display_current="$PROGRESS_COMPLETED" percent=0 bar duration line
  local -a lines=()
  if [[ "$PROGRESS_CURRENT_STATE" == "running" || "$PROGRESS_CURRENT_STATE" == "failed" ]]; then
    display_current=$((PROGRESS_COMPLETED + 1))
  fi
  (( display_current > PROGRESS_TOTAL )) && display_current=$PROGRESS_TOTAL
  if (( PROGRESS_TOTAL > 0 )); then
    percent=$((display_current * 100 / PROGRESS_TOTAL))
  fi
  bar=$(build_progress_bar "$display_current" "$PROGRESS_TOTAL" 20)
  duration=$(format_duration "$PROGRESS_CURRENT_DURATION")

  lines+=("MongoDB 自动安装")
  lines+=("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  printf -v line '总体进度  %s  %d/%d  %3d%%' "$bar" "$display_current" "$PROGRESS_TOTAL" "$percent"
  lines+=("$line")
  lines+=("当前阶段  ${PROGRESS_STAGE}")
  if [[ -n "$PROGRESS_CURRENT_NAME" ]]; then
    if [[ "$PROGRESS_CURRENT_STATE" == "failed" ]]; then
      printf -v line '当前操作  ✗ %s失败  退出码 %d' "$PROGRESS_CURRENT_NAME" "$PROGRESS_FAILURE_CODE"
    else
      printf -v line '当前操作  %s %s%s' "$PROGRESS_CURRENT_ICON" "$(progress_pad "$PROGRESS_CURRENT_NAME" 34)" "$duration"
    fi
  else
    line="当前操作  等待开始"
  fi
  lines+=("$line")
  lines+=("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

  local count=${#PROGRESS_HISTORY_NAME[@]} start=0 i
  (( count > 5 )) && start=$((count - 5))
  for ((i=start; i<count; i++)); do
    printf -v line '%s %s%s' "${PROGRESS_HISTORY_ICON[$i]}" \
      "$(progress_pad "${PROGRESS_HISTORY_NAME[$i]}" 38)" \
      "$(format_duration "${PROGRESS_HISTORY_DURATION[$i]}")"
    lines+=("$line")
  done

  if (( PROGRESS_RENDERED_LINES > 0 )); then
    printf '\033[%dA' "$PROGRESS_RENDERED_LINES"
  fi
  for line in "${lines[@]}"; do
    printf '\033[2K\r%s\n' "$line"
  done
  if (( PROGRESS_RENDERED_LINES > ${#lines[@]} )); then
    for ((i=${#lines[@]}; i<PROGRESS_RENDERED_LINES; i++)); do
      printf '\033[2K\r\n'
    done
    printf '\033[%dA' "$((PROGRESS_RENDERED_LINES - ${#lines[@]}))"
  fi
  PROGRESS_RENDERED_LINES=${#lines[@]}
}

progress_stop_spinner() {
  if [[ -n "$_ACTIVE_SPINNER_PID" ]]; then
    kill "$_ACTIVE_SPINNER_PID" 2>/dev/null
    wait "$_ACTIVE_SPINNER_PID" 2>/dev/null
    _ACTIVE_SPINNER_PID=""
  fi
}

progress_start_spinner() {
  local start_time="$1"
  [[ "$MONGO_PROGRESS_MODE" == "ansi" ]] || return 0
  (
    local spinner_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local spinner_index=0 now
    while true; do
      now=$(date +%s)
      PROGRESS_CURRENT_ICON="${spinner_chars[$spinner_index]}"
      PROGRESS_CURRENT_DURATION=$((now - start_time))
      progress_render
      spinner_index=$(((spinner_index + 1) % ${#spinner_chars[@]}))
      sleep 0.1
    done
  ) &
  _ACTIVE_SPINNER_PID=$!
}

progress_close() {
  progress_stop_spinner
  if (( PROGRESS_CURSOR_HIDDEN )); then
    printf '\033[?25h'
    PROGRESS_CURSOR_HIDDEN=0
  fi
  [[ "$MONGO_PROGRESS_MODE" == "ansi" ]] && printf '\n'
}

escape_glob_pattern() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\*/\\*}
  value=${value//\?/\\?}
  value=${value//\[/\\[}
  value=${value//\]/\\]}
  printf '%s' "$value"
}

redact_sensitive_output() {
  local line admin_pattern="" root_pattern=""
  [[ -z "${mongo_admin_pass:-}" ]] || admin_pattern=$(escape_glob_pattern "$mongo_admin_pass")
  [[ -z "${remote_root_pass:-}" ]] || root_pattern=$(escape_glob_pattern "$remote_root_pass")
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$admin_pattern" ]]; then
      line=${line//$admin_pattern/[REDACTED]}
    fi
    if [[ -n "$root_pattern" ]]; then
      line=${line//$root_pattern/[REDACTED]}
    fi
    printf '%s\n' "$line"
  done
}

run_step() {
  if [[ $# -lt 2 ]]; then
    printf '错误: run_step 需要步骤名称和可执行函数\n' >&2
    return 2
  fi

  local step_name="$1"
  shift
  local command_name="${1:-unknown}"
  local start_time end_time execution_time status tmp_output
  start_time=$(date +%s)
  tmp_output=$(mktemp /tmp/mongo_install_step.XXXXXX) || return 1
  MONGO_INSTALL_TMPFILES+=("$tmp_output")

  PROGRESS_CURRENT_NAME="$step_name"
  PROGRESS_CURRENT_ICON="⠋"
  PROGRESS_CURRENT_DURATION=0
  PROGRESS_CURRENT_STATE="running"
  PROGRESS_FAILURE_CODE=0

  {
    printf '==========================================\n'
    printf '时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '阶段: %s\n' "$PROGRESS_STAGE"
    printf '任务: %s\n' "$step_name"
    printf '执行单元: %s\n' "$command_name"
    printf '%s\n' '------------------------------------------'
  } >> "$PROGRESS_LOG_FILE"

  if [[ "$MONGO_PROGRESS_MODE" == "ansi" ]]; then
    progress_render
    progress_start_spinner "$start_time"
  else
    printf '→ [%s] %s\n' "$PROGRESS_STAGE" "$step_name"
  fi

  "$@" > "$tmp_output" 2>&1
  status=$?
  end_time=$(date +%s)
  execution_time=$((end_time - start_time))
  progress_stop_spinner
  redact_sensitive_output < "$tmp_output" >> "$PROGRESS_LOG_FILE"
  if [[ "$debug_flag" == "Y" && -s "$tmp_output" ]]; then
    redact_sensitive_output < "$tmp_output" | sed 's/^/  /'
  fi
  rm -f "$tmp_output"

  {
    printf '执行结果: 退出码=%d, 耗时=%d秒\n' "$status" "$execution_time"
    printf '==========================================\n\n'
  } >> "$PROGRESS_LOG_FILE"

  PROGRESS_CURRENT_DURATION=$execution_time
  if (( status == 0 || status == 3 )); then
    ((PROGRESS_COMPLETED++))
    if (( status == 0 )); then
      PROGRESS_CURRENT_ICON="✓"
      PROGRESS_CURRENT_STATE="success"
      PROGRESS_HISTORY_ICON+=("✓")
    else
      PROGRESS_CURRENT_ICON="⚠"
      PROGRESS_CURRENT_STATE="warning"
      PROGRESS_HISTORY_ICON+=("⚠")
    fi
    PROGRESS_HISTORY_NAME+=("$step_name")
    PROGRESS_HISTORY_DURATION+=("$execution_time")
    if [[ "$MONGO_PROGRESS_MODE" == "ansi" ]]; then
      progress_render
    elif (( status == 0 )); then
      printf '✓ %s%s\n' "$(progress_pad "$step_name" 40)" "$(format_duration "$execution_time")"
    else
      printf '⚠ %s%s\n' "$(progress_pad "$step_name" 40)" "$(format_duration "$execution_time")"
    fi
    return 0
  fi

  PROGRESS_CURRENT_ICON="✗"
  PROGRESS_CURRENT_STATE="failed"
  PROGRESS_FAILURE_CODE=$status
  if [[ "$MONGO_PROGRESS_MODE" == "ansi" ]]; then
    progress_render
    progress_close
  else
    printf '✗ %s失败  退出码 %d\n' "$step_name" "$status" >&2
  fi
  printf '安装已终止\n详细日志：%s\n' "$PROGRESS_LOG_FILE" >&2
  return "$status"
}

function execute_and_log() {
  run_step "$@"
}
#==============================================================#
#                          日志打印                            #
#==============================================================#
function log_print() {
  echo
  color_printf green "#==============================================================#"
  color_printf light_blue "$1"
  color_printf green "#==============================================================#"
  echo
}
#==============================================================#
#                          LOGO                                #
#==============================================================#
function logo_print() {
  cat <<-'EOF'
  ███╗   ███╗ ██████╗ ███╗   ██╗ ██████╗  ██████╗ ██████╗ ██████╗
  ████╗ ████║██╔═══██╗████╗  ██║██╔════╝ ██╔═══██╗██╔══██╗██╔══██╗
  ██╔████╔██║██║   ██║██╔██╗ ██║██║  ███╗██║   ██║██║  ██║██████╔╝
  ██║╚██╔╝██║██║   ██║██║╚██╗██║██║   ██║██║   ██║██║  ██║██╔══██╗
  ██║ ╚═╝ ██║╚██████╔╝██║ ╚████║╚██████╔╝╚██████╔╝██████╔╝██████╔╝
  ╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝  ╚═════╝ ╚═════╝ ╚═════╝
EOF
  printf '  MongoDB One-Click Installer v%s (Standalone + ReplicaSet)\n' "$MONGO_INSTALL_VERSION"
}
#==============================================================#
#                       参数验证函数                           #
#==============================================================#
function checkpara_NULL() {
  if [[ -z "$2" || "$2" == -* ]]; then
    color_printf red "错误: 参数 $1 的值不能为空或以 - 开头"
    exit 1
  fi
}

function checkpara_YN() {
  local val
  val=$(upper "$2")
  if [[ "$val" != "Y" && "$val" != "N" ]]; then
    color_printf red "错误: 参数 $1 的值必须为 Y 或 N"
    exit 1
  fi
}

function check_ip() {
  local ip="$1" o
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi
  local IFS='.'
  local -a octets=()
  read -ra octets <<< "$ip"
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    if (( 10#$o > 255 )); then return 1; fi
  done
  return 0
}

function validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

function validate_positive_integer() {
  local value="$1" minimum="${2:-1}" maximum="${3:-2147483647}"
  [[ "$value" =~ ^[0-9]{1,10}$ ]] || return 1
  (( 10#$value >= minimum && 10#$value <= maximum ))
}

function validate_host() {
  local host="$1" label
  [[ -n "$host" && ${#host} -le 253 ]] || return 1
  if check_ip "$host"; then return 0; fi
  [[ "$host" =~ ^[0-9.]+$ ]] && return 1
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$host" != *..* ]] || return 1
  local IFS='.'
  read -ra _host_labels <<< "$host"
  for label in "${_host_labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" != -* && "$label" != *- ]] || return 1
  done
  return 0
}

function validate_safe_install_dir() {
  local requested="$1" normalized relative
  [[ -n "$requested" && "$requested" == /* && "$requested" != *$'\n'* ]] || return 1
  [[ "$requested" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  normalized=$(readlink -m -- "$requested" 2>/dev/null) || return 1
  case "$normalized" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/data)
      return 1
      ;;
  esac
  [[ "$normalized" == "/mongodb" ]] && return 0
  relative=${normalized#/}
  [[ "$relative" == */* ]]
}

function paths_overlap() {
  local first second
  first=$(readlink -m -- "$1" 2>/dev/null) || return 2
  second=$(readlink -m -- "$2" 2>/dev/null) || return 2
  [[ "$first" == "$second" || "$first" == "${second}/"* || "$second" == "${first}/"* ]]
}

function finalize_directory_layout() {
  env_base_dir=$(readlink -m -- "$env_base_dir" 2>/dev/null) || return 1
  env_app_dir="${env_base_dir}/app"
  data_dir="${env_base_dir}/data"
  log_dir="${env_base_dir}/logs"
  backup_dir="${env_base_dir}/backup"
  scripts_dir="${env_base_dir}/scripts"
  pid_dir="${env_base_dir}/run"
  [[ -z "$mongo_data_dir_override" ]] || data_dir=$(readlink -m -- "$mongo_data_dir_override" 2>/dev/null) || return 1
  [[ -z "$mongo_backup_dir_override" ]] || backup_dir=$(readlink -m -- "$mongo_backup_dir_override" 2>/dev/null) || return 1
  mongo_keyfile="${env_base_dir}/keyfile"
  mongo_tools_config="${env_base_dir}/mongodb-tools.yml"
  mongo_auth_js="${env_base_dir}/mongosh-auth.js"
  mongo_tls_dir="${env_base_dir}/tls"
  mongo_tls_ca_path="${mongo_tls_dir}/ca.pem"
  mongo_tls_cert_path="${mongo_tls_dir}/member.pem"
}

function validate_bind_ip_list() {
  local value="$1" item
  local IFS=','
  local -a bind_items=()
  read -ra bind_items <<< "$value"
  (( ${#bind_items[@]} > 0 )) || return 1
  for item in "${bind_items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "$item" && "$item" != "::" && "$item" != "*" ]] || return 1
    validate_host "$item" || [[ "$item" == "localhost" ]] || return 1
  done
}

function build_install_hostname() {
  local base_name="$1" install_mode="$2" local_ip="${3:-}" ip_short=""
  if [[ "$install_mode" == "single" ]]; then
    printf '%s' "$base_name"
    return 0
  fi
  if check_ip "$local_ip"; then
    ip_short=$(awk -F. '{print $3 $4}' <<< "$local_ip")
  fi
  printf '%s%s' "$base_name" "$ip_short"
}

function bind_is_loopback_only() {
  local value="$1" item
  local IFS=','
  local -a bind_items=()
  read -ra bind_items <<< "$value"
  for item in "${bind_items[@]}"; do
    item="${item//[[:space:]]/}"
    case "$item" in
      127.*|localhost) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

function validate_firewall_source() {
  local value="$1" ip prefix
  if [[ "$value" == */* ]]; then
    ip=${value%/*}
    prefix=${value#*/}
    check_ip "$ip" && [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix >= 0 && 10#$prefix <= 32 ))
  else
    check_ip "$value"
  fi
}

function mongo_version_at_least() {
  local major="$1" minor="$2" patch="$3"
  local required_major="$4" required_minor="$5" required_patch="$6"
  (( major > required_major )) && return 0
  (( major < required_major )) && return 1
  (( minor > required_minor )) && return 0
  (( minor < required_minor )) && return 1
  (( patch >= required_patch ))
}

# Validate only version boundaries that are defined by the MongoDB platform
# matrix.  Keep this separate from binary probing so tests can prove that a
# newer MongoDB rule does not accidentally remove support from older branches.
function validate_mongo_os_version_matrix() {
  local platform="${os_distro}-${os_version_id}"

  if [[ "$os_distro" == "centos" && "$os_version" == "7" && "$mongo_major_ver" -ge 8 ]]; then
    echo "错误: CentOS 7 仅支持 MongoDB 6.0/7.0 遗留安装，不支持 MongoDB ${mongo_major_ver}.${mongo_minor_ver}" >&2
    return 1
  fi

  if [[ "$os_distro_family" == "rhel" && "$mongo_major_ver" -ge 8 ]]; then
    if (( 10#${os_version:-0} < 8 )); then
      echo "错误: MongoDB 8.x 不支持 ${platform}" >&2
      return 1
    fi
    if (( 10#${os_version:-0} == 8 && 10#${os_version_minor:-0} < 8 )); then
      echo "错误: MongoDB 8.x 要求 RHEL 兼容平台 8.8+，当前为 ${platform}" >&2
      return 1
    fi
    if (( 10#${os_version:-0} == 9 && 10#${os_version_minor:-0} < 3 )); then
      echo "错误: MongoDB 8.x 要求 RHEL 兼容平台 9.3+，当前为 ${platform}" >&2
      return 1
    fi
  fi

  if [[ "$os_distro_family" == "rhel" && "$os_version" == "9" && "$mongo_major_ver" == "6" ]] \
    && ! mongo_version_at_least "$mongo_major_ver" "$mongo_minor_ver" "$mongo_patch_ver" 6 0 4; then
    echo "错误: RHEL 兼容平台 9 仅支持 MongoDB 6.0.4+，当前为 ${mongo_major_ver}.${mongo_minor_ver}.${mongo_patch_ver}" >&2
    return 1
  fi
}

# 配置能力统一按 MongoDB 版本判断。某个版本移除参数时，只跳过该参数的
# 对应版本区间，绝不为兼容高版本而从所有版本配置中全局删除。
function mongo_supports_config_option() {
  local option="$1" major="$2" minor="$3" patch="${4:-0}"
  case "$option" in
    storage.journal.enabled)
      (( major < 6 || (major == 6 && minor < 1) ))
      ;;
    replication.enableMajorityReadConcern)
      (( major < 5 ))
      ;;
    storage.wiredTiger.engineConfig.cacheSizeGB|\
    storage.wiredTiger.engineConfig.journalCompressor|\
    storage.wiredTiger.engineConfig.directoryForIndexes|\
    storage.wiredTiger.collectionConfig.blockCompressor|\
    storage.wiredTiger.indexConfig.prefixCompression|\
    setParameter.enableLocalhostAuthBypass)
      (( major >= 4 ))
      ;;
    *)
      printf '错误: 未登记的 MongoDB 配置能力: %s\n' "$option" >&2
      return 2
      ;;
  esac
}

function mongo_supports_journal_option() {
  mongo_supports_config_option storage.journal.enabled "$1" "$2" "${3:-0}"
}

function detect_numa_node_count() {
  local -a nodes=()
  shopt -s nullglob
  nodes=(/sys/devices/system/node/node[0-9]*)
  shopt -u nullglob
  if (( ${#nodes[@]} == 0 )); then
    printf '1'
  else
    printf '%d' "${#nodes[@]}"
  fi
}

# MongoDB 每个客户端连接通常占用两个文件描述符和一个线程；Linux 上
# maxIncomingConnections 还不得超过 (RLIMIT_NOFILE / 2) * 0.8。
# 因此从连接数反推 limits，而不是在所有机器上写死 1048576。
function calculate_resource_profile() {
  local nr_open current_somaxconn required_nofile required_nproc rounded
  local connection_capacity

  nr_open=$(< /proc/sys/fs/nr_open 2>/dev/null) || nr_open=1048576
  [[ "$nr_open" =~ ^[0-9]+$ ]] || nr_open=1048576
  current_somaxconn=$(< /proc/sys/net/core/somaxconn 2>/dev/null) || current_somaxconn=128
  [[ "$current_somaxconn" =~ ^[0-9]+$ ]] || current_somaxconn=128

  # 2.5 × connections 满足官方 0.4 × RLIMIT_NOFILE 上限，再预留 4096
  # 个描述符给数据文件、journal、日志和副本集内部连接。
  required_nofile=$(((max_connections * 5 + 1) / 2 + 4096))
  rounded=$((((required_nofile + 1023) / 1024) * 1024))
  (( rounded < 64000 )) && rounded=64000
  if (( rounded > nr_open )); then
    connection_capacity=$((((nr_open - 4096) * 2) / 5))
    (( connection_capacity < 100 )) && connection_capacity=100
    printf '错误: --max-connections=%d 需要 RLIMIT_NOFILE 至少 %d，但内核 fs.nr_open=%d；当前安全上限约为 %d\n' \
      "$max_connections" "$rounded" "$nr_open" "$connection_capacity" >&2
    return 1
  fi
  mongo_nofile_limit=$rounded

  # 每连接一个线程，并为 CPU 工作线程、复制和后台任务保留空间。
  required_nproc=$((max_connections + os_core * 128 + 4096))
  rounded=$((((required_nproc + 1023) / 1024) * 1024))
  (( rounded < 64000 )) && rounded=64000
  mongo_nproc_limit=$rounded

  mongo_file_max_target=$((mongo_nofile_limit * 2))
  (( mongo_file_max_target < 2097152 )) && mongo_file_max_target=2097152
  mongo_somaxconn_target=$current_somaxconn
  (( mongo_somaxconn_target < 4096 )) && mongo_somaxconn_target=4096
  mongo_numa_nodes=$(detect_numa_node_count)
  mongo_resource_profile_ready=1

  printf '资源画像: maxConns=%d, nofile=%d, nproc=%d, fs.file-max>=%d, CPU=%d, NUMA节点=%d\n' \
    "$max_connections" "$mongo_nofile_limit" "$mongo_nproc_limit" \
    "$mongo_file_max_target" "$os_core" "$mongo_numa_nodes"
}

function list_mongo_tarballs() {
  local file
  for file in \
    "${software_dir}"/mongodb-linux-*.tgz \
    "${software_dir}"/mongodb-linux-*.tar.gz \
    "${software_dir}"/mongodb-*.tgz \
    "${software_dir}"/mongodb-*.tar.gz; do
    [[ -f "$file" ]] || continue
    case "$(basename "$file")" in
      *database-tools*|mongosh-*) continue ;;
    esac
    printf '%s\n' "$file"
  done | sort -u
}

function select_mongo_tarball() {
  local -a packages=() matches=()
  local package index selection
  mapfile -t packages < <(list_mongo_tarballs)
  if (( ${#packages[@]} == 0 )); then
    printf '错误: 未找到 MongoDB 安装包\n' >&2
    return 1
  fi
  if [[ -n "$mongo_package_choice" ]]; then
    for package in "${packages[@]}"; do
      if [[ "$package" == "$mongo_package_choice" \
        || "$(basename "$package")" == "$mongo_package_choice" \
        || "$(basename "$package")" == *"-${mongo_package_choice}.tgz" \
        || "$(basename "$package")" == *"-${mongo_package_choice}.tar.gz" ]]; then
        matches+=("$package")
      fi
    done
    if (( ${#matches[@]} != 1 )); then
      printf '错误: --mongo-package 必须唯一匹配一个安装包 (当前匹配 %d 个): %s\n' \
        "${#matches[@]}" "$mongo_package_choice" >&2
      return 1
    fi
    selected_mongo_tarball="${matches[0]}"
    printf '%s' "$selected_mongo_tarball"
    return 0
  fi
  if (( ${#packages[@]} > 1 )); then
    if [[ ! -t 0 ]]; then
      printf '错误: 检测到多个 MongoDB Server 安装包；非交互安装必须使用 --mongo-package 指定文件名或版本:\n' >&2
      printf '  %s\n' "${packages[@]}" >&2
      return 1
    fi
    printf '检测到多个 MongoDB Server 安装包，请选择:\n' >/dev/tty
    for index in "${!packages[@]}"; do
      printf '  [%d] %s\n' "$((index + 1))" "$(basename "${packages[$index]}")" >/dev/tty
    done
    while true; do
      printf '请输入编号 [1-%d]: ' "${#packages[@]}" >/dev/tty
      IFS= read -r selection </dev/tty || return 1
      if [[ "$selection" =~ ^[0-9]+$ ]] \
        && (( 10#$selection >= 1 && 10#$selection <= ${#packages[@]} )); then
        selected_mongo_tarball="${packages[$((10#$selection - 1))]}"
        printf '%s' "$selected_mongo_tarball"
        return 0
      fi
      printf '无效编号，请重新输入。\n' >/dev/tty
    done
  fi
  selected_mongo_tarball="${packages[0]}"
  printf '%s' "$selected_mongo_tarball"
}

function mongo_thp_mode() {
  local major="$1"
  if (( major <= 0 )); then
    printf 'skip'
  elif (( major >= 8 )); then
    printf 'enable'
  else
    printf 'disable'
  fi
}

function read_secret_file() {
  local path="$1" variable_name="$2" permissions owner_uid permission_value secret
  [[ -f "$path" && ! -L "$path" ]] || {
    printf '错误: 密码文件不存在或是符号链接: %s\n' "$path" >&2
    return 1
  }
  permissions=$(stat -c '%a' "$path" 2>/dev/null) || {
    printf '错误: 无法读取密码文件权限: %s\n' "$path" >&2
    return 1
  }
  owner_uid=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  [[ "$owner_uid" == "$EUID" ]] || {
    printf '错误: 密码文件必须属于当前 root 用户: %s\n' "$path" >&2
    return 1
  }
  [[ "$permissions" =~ ^[0-7]{3,4}$ ]] || {
    printf '错误: 无法识别密码文件权限: %s\n' "$path" >&2
    return 1
  }
  permission_value=$((8#$permissions))
  if (( (permission_value & 077) != 0 )); then
    printf '错误: 密码文件必须禁止组用户和其他用户访问（建议 chmod 600）: %s\n' "$path" >&2
    return 1
  fi
  IFS= read -r secret < "$path" || true
  [[ -n "$secret" && "$secret" != *$'\r'* && "$secret" != *$'\n'* ]] || {
    printf '错误: 密码文件第一行不能为空或包含控制字符: %s\n' "$path" >&2
    return 1
  }
  printf -v "$variable_name" '%s' "$secret"
}

function ensure_admin_password() {
  [[ "$mongo_auth_enabled" == "Y" ]] || return 0
  if [[ -n "$mongo_admin_pass_file" ]]; then
    read_secret_file "$mongo_admin_pass_file" mongo_admin_pass || return 1
  elif [[ -z "$mongo_admin_pass" ]]; then
    if [[ -t 0 ]]; then
      local first second
      read -r -s -p '请输入 MongoDB 管理员密码: ' first
      printf '\n'
      read -r -s -p '请再次输入管理员密码: ' second
      printf '\n'
      [[ "$first" == "$second" ]] || {
        printf '错误: 两次输入的管理员密码不一致\n' >&2
        return 1
      }
      mongo_admin_pass="$first"
    else
      printf '错误: 非交互安装启用认证时必须指定 --admin-pass-file\n' >&2
      return 1
    fi
  fi
  (( ${#mongo_admin_pass} >= 12 )) || {
    printf '错误: MongoDB 管理员密码至少需要 12 个字符\n' >&2
    return 1
  }
  if [[ "$mongo_admin_pass" =~ [[:cntrl:]] || "$mongo_admin_pass" == *$'\u2028'* || "$mongo_admin_pass" == *$'\u2029'* ]]; then
    printf '错误: MongoDB 管理员密码不能包含控制字符或 Unicode 行分隔符\n' >&2
    return 1
  fi
}

function tls_cert_source_for_host() {
  local member_host="$1"
  if [[ -n "$mongo_tls_cert_dir" ]]; then
    printf '%s/%s.pem' "${mongo_tls_cert_dir%/}" "$member_host"
  else
    printf '%s' "$mongo_tls_cert_key_file"
  fi
}

function validate_tls_private_file() {
  local path="$1" permissions owner_uid permission_value
  [[ "$path" == /* && -f "$path" && ! -L "$path" ]] || {
    printf '错误: TLS 证书私钥必须是绝对路径下的普通文件: %s\n' "$path" >&2
    return 1
  }
  permissions=$(stat -c '%a' "$path" 2>/dev/null) || return 1
  owner_uid=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  [[ "$owner_uid" == "$EUID" && "$permissions" =~ ^[0-7]{3,4}$ ]] || {
    printf '错误: TLS 证书私钥必须属于当前 root 用户: %s\n' "$path" >&2
    return 1
  }
  permission_value=$((8#$permissions))
  (( (permission_value & 077) == 0 )) || {
    printf '错误: TLS 证书私钥禁止组用户和其他用户访问（chmod 600）: %s\n' "$path" >&2
    return 1
  }
}

function tls_certificate_identity_attributes() {
  local pem_file="$1"
  openssl x509 -in "$pem_file" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed 's/^subject=//' | tr ',' '\n' | grep -E '^(O|OU|DC)=' | LC_ALL=C sort | paste -sd, -
}

function validate_tls_material() {
  [[ "$mongo_tls_enabled" == "Y" ]] || return 0
  command -v openssl >/dev/null 2>&1 || {
    echo "错误: TLS 证书校验需要 openssl" >&2
    return 1
  }
  [[ "$mongo_tls_ca_file" == /* && -f "$mongo_tls_ca_file" && ! -L "$mongo_tls_ca_file" ]] || {
    echo "错误: --tls-ca-file 必须是绝对路径下的普通 CA PEM 文件" >&2
    return 1
  }
  openssl x509 -in "$mongo_tls_ca_file" -noout >/dev/null 2>&1 || {
    echo "错误: 无法解析 TLS CA 证书" >&2
    return 1
  }

  local -a certificate_hosts=()
  local member_host cert_file cert_pubkey private_pubkey identity expected_identity=""
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    [[ -n "$mongo_tls_cert_dir" && -d "$mongo_tls_cert_dir" && ! -L "$mongo_tls_cert_dir" ]] || {
      echo "错误: 副本集 TLS 必须通过 --tls-cert-dir 提供 <成员主机名>.pem" >&2
      return 1
    }
    certificate_hosts=("${hosts_array[@]}")
  else
    certificate_hosts+=("$(build_install_hostname "$hostname" single "$(get_local_ip)")")
    [[ -n "$mongo_tls_cert_key_file" || -n "$mongo_tls_cert_dir" ]] || {
      echo "错误: 单机 TLS 必须指定 --tls-cert-key-file 或 --tls-cert-dir" >&2
      return 1
    }
  fi

  for member_host in "${certificate_hosts[@]}"; do
    cert_file=$(tls_cert_source_for_host "$member_host")
    validate_tls_private_file "$cert_file" || return 1
    openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null 2>&1 || {
      echo "错误: TLS 证书无效或将在 24 小时内过期: ${cert_file}" >&2
      return 1
    }
    openssl verify -purpose sslserver -CAfile "$mongo_tls_ca_file" "$cert_file" >/dev/null 2>&1 || {
      echo "错误: TLS 证书未通过 CA/serverAuth 校验: ${cert_file}" >&2
      return 1
    }
    openssl verify -purpose sslclient -CAfile "$mongo_tls_ca_file" "$cert_file" >/dev/null 2>&1 || {
      echo "错误: TLS 证书未通过 CA/clientAuth 校验: ${cert_file}" >&2
      return 1
    }
    openssl x509 -in "$cert_file" -noout -checkhost "$member_host" >/dev/null 2>&1 || {
      echo "错误: TLS 证书 SAN 不包含成员主机名 ${member_host}: ${cert_file}" >&2
      return 1
    }
    openssl x509 -in "$cert_file" -noout -checkip 127.0.0.1 >/dev/null 2>&1 || {
      echo "错误: TLS 证书 SAN 必须包含本机引导地址 127.0.0.1: ${cert_file}" >&2
      return 1
    }
    cert_pubkey=$(openssl x509 -in "$cert_file" -pubkey -noout 2>/dev/null | sha256sum | awk '{print $1}')
    private_pubkey=$(openssl pkey -in "$cert_file" -pubout 2>/dev/null </dev/null | sha256sum | awk '{print $1}')
    [[ -n "$cert_pubkey" && "$cert_pubkey" == "$private_pubkey" ]] || {
      echo "错误: TLS 证书与私钥不匹配或私钥已加密: ${cert_file}" >&2
      return 1
    }
    if [[ "$mongo_cluster_auth_mode" == "x509" ]]; then
      identity=$(tls_certificate_identity_attributes "$cert_file")
      [[ -n "$identity" ]] || {
        echo "错误: X.509 成员证书必须包含至少一个 O、OU 或 DC 属性: ${cert_file}" >&2
        return 1
      }
      if [[ -z "$expected_identity" ]]; then
        expected_identity="$identity"
      elif [[ "$identity" != "$expected_identity" ]]; then
        printf '错误: X.509 成员证书的 O/OU/DC 属性不一致: %s\n' "$cert_file" >&2
        return 1
      fi
    fi
  done
  echo "TLS 证书校验通过 (${#certificate_hosts[@]} 个节点, clusterAuth=${mongo_cluster_auth_mode})"
}

function install_tls_material() {
  [[ "$mongo_tls_enabled" == "Y" ]] || {
    echo "TLS 未启用，跳过证书安装"
    return 0
  }
  local effective_hostname cert_source
  effective_hostname=$(build_install_hostname "$hostname" "$mongo_install_mode" "$(get_local_ip)") || return 1
  cert_source=$(tls_cert_source_for_host "$effective_hostname")
  install -d -o "$mongo_owner" -g "$mongo_owner" -m 0750 "$mongo_tls_dir" || return 1
  install -o "$mongo_owner" -g "$mongo_owner" -m 0640 "$mongo_tls_ca_file" "$mongo_tls_ca_path" || return 1
  install -o "$mongo_owner" -g "$mongo_owner" -m 0600 "$cert_source" "$mongo_tls_cert_path" || return 1
  echo "TLS 证书已安装: ${mongo_tls_dir}"
}

function check_file() {
  if [[ ! -f "$1" ]]; then
    color_printf red "错误: 文件不存在: $1"
    exit 1
  fi
}
#==============================================================#
#                     备份文件再修改                           #
#==============================================================#
function bak_file() {
  local target_file="$1"
  local marker="# MongoBegin"
  if [[ ! -f "$target_file" ]]; then return 0; fi
  if grep -q "$marker" "$target_file" 2>/dev/null; then
    sed -i "/${marker}/,/# MongoEnd/d" "$target_file"
  else
    cp -f "$target_file" "${target_file}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}
#==============================================================#
#                   检测 MongoDB 版本                          #
#==============================================================#
function detect_mongo_version() {
  log_print "检测 MongoDB 版本"

  local mongo_tarball
  mongo_tarball=$(select_mongo_tarball) || {
    color_printf red "错误: 未找到 MongoDB 安装包" "请将 mongodb-linux-*.tgz 放在: ${software_dir}"
    return 1
  }
  selected_mongo_tarball="$mongo_tarball"

  echo "使用安装包: $(basename "$mongo_tarball")"

  local ver_str
  ver_str=$(basename "$mongo_tarball" | grep -oP '\d+\.\d+\.\d+')
  if [[ -z "$ver_str" ]]; then
    color_printf red "错误: 无法从安装包文件名提取版本号"
    return 1
  fi

  mongo_major_ver=$(echo "$ver_str" | cut -d. -f1)
  mongo_minor_ver=$(echo "$ver_str" | cut -d. -f2)
  mongo_patch_ver=$(echo "$ver_str" | cut -d. -f3)
  mongo_major_ver=${mongo_major_ver:-0}
  mongo_minor_ver=${mongo_minor_ver:-0}
  mongo_patch_ver=${mongo_patch_ver:-0}

  echo "MongoDB 版本: ${ver_str} (major=${mongo_major_ver}, minor=${mongo_minor_ver}, patch=${mongo_patch_ver})"

  if (( mongo_major_ver < 4 )); then
    color_printf red "错误: MongoDB ${ver_str} 版本过旧 (< 4.0)" "本脚本要求 MongoDB >= 4.0"
    return 1
  fi

  # 版本提示
  if (( mongo_major_ver == 4 && mongo_minor_ver < 4 )); then
    color_printf yellow "警告: MongoDB ${ver_str} 已 EOL，建议升级到 7.0 或 8.0"
  fi
  if (( mongo_major_ver == 5 )); then
    color_printf yellow "警告: MongoDB 5.x 已 EOL，建议升级到 7.0 或 8.0"
  fi
  if (( mongo_major_ver == 6 )); then
    color_printf yellow "警告: MongoDB 6.0 已于 2025-07 EOL，建议升级到 7.0 或 8.0"
  fi
  if (( mongo_major_ver >= 8 )); then
    echo "MongoDB 8.0+: 使用 TCMalloc，THP 将被启用"
  fi

  if [[ "$mongo_install_mode" == "replicaset" && "$mongo_major_ver" -ge 5 ]]; then
    local member
    for member in "${hosts_array[@]}"; do
      if check_ip "$member"; then
        echo "错误: MongoDB 5.0+ 副本集成员必须使用可解析的 DNS 主机名，不能只使用 IP: ${member}" >&2
        return 1
      fi
    done
  fi
}

function validate_mongo_platform_compatibility() {
  log_print "验证 OS、CPU 与 MongoDB 二进制兼容性"
  local mongo_tarball="${selected_mongo_tarball:-}" package_name package_rhel_major=""
  local probe_dir probe_root probe_binary probe_output probe_status=0

  [[ -n "$mongo_tarball" && -f "$mongo_tarball" ]] || {
    mongo_tarball=$(select_mongo_tarball) || return 1
    selected_mongo_tarball="$mongo_tarball"
  }
  package_name=$(basename "$mongo_tarball")

  validate_mongo_os_version_matrix || return 1

  case "$os_arch" in
    x86_64|aarch64|ppc64le|s390x) ;;
    *)
      echo "错误: 不支持的 CPU 架构: ${os_arch}" >&2
      return 1
      ;;
  esac

  if [[ "$os_arch" == "x86_64" && "$mongo_major_ver" -ge 5 ]]; then
    grep -qm1 -w avx /proc/cpuinfo 2>/dev/null || {
      echo "错误: MongoDB 5.0+ 的 x86_64 官方二进制要求 CPU 支持 AVX" >&2
      return 1
    }
  fi

  # 包文件名携带平台时，先阻止明显的跨发行版/跨架构误装。
  if [[ "$package_name" == *-aarch64-* && "$os_arch" != "aarch64" ]] \
    || [[ "$package_name" == *-x86_64-* && "$os_arch" != "x86_64" ]]; then
    echo "错误: 安装包架构与系统不匹配: package=${package_name}, os=${os_arch}" >&2
    return 1
  fi
  if [[ "$package_name" =~ rhel([0-9]+) ]]; then
    package_rhel_major="${BASH_REMATCH[1]:0:1}"
    if [[ "$os_distro_family" != "rhel" || "$os_version" != "$package_rhel_major" ]]; then
      echo "错误: RHEL 安装包与系统主版本不匹配: package=${package_name}, os=${os_distro}-${os_version_id}" >&2
      return 1
    fi
  fi

  # 最终以目标机真实执行结果为准，可直接捕获 glibc/OpenSSL/CPU 指令不兼容。
  probe_dir=$(mktemp -d /tmp/mongo_install.XXXXXX) || return 1
  MONGO_INSTALL_TMPDIRS+=("$probe_dir")
  if ! tar xzf "$mongo_tarball" -C "$probe_dir"; then
    echo "错误: MongoDB 安装包无法解压: ${package_name}" >&2
    return 1
  fi
  probe_root=$(find "$probe_dir" -mindepth 1 -maxdepth 1 -type d -name 'mongodb-*' -print -quit)
  probe_binary="${probe_root}/bin/mongod"
  [[ -x "$probe_binary" ]] || {
    echo "错误: 安装包内缺少可执行的 bin/mongod" >&2
    return 1
  }
  probe_output=$("$probe_binary" --version 2>&1) || probe_status=$?
  if (( probe_status != 0 )); then
    printf '错误: MongoDB 二进制无法在当前系统执行 (exit=%d):\n%s\n' "$probe_status" "$probe_output" >&2
    return "$probe_status"
  fi
  if [[ "$probe_output" != *"v${mongo_major_ver}.${mongo_minor_ver}.${mongo_patch_ver}"* ]]; then
    echo "错误: 文件名版本与二进制版本不一致: ${package_name}" >&2
    printf '%s\n' "$probe_output" >&2
    return 1
  fi
  rm -rf -- "$probe_dir"
  echo "兼容性通过: ${os_distro}-${os_version_id}/${os_arch} × MongoDB ${mongo_major_ver}.${mongo_minor_ver}.${mongo_patch_ver}"
}
#==============================================================#
#                   检查安装包                                 #
#==============================================================#
function check_packages() {
  log_print "检查安装包"

  local mongo_tarball="${selected_mongo_tarball:-}"
  if [[ -z "$mongo_tarball" || ! -f "$mongo_tarball" ]]; then
    mongo_tarball=$(select_mongo_tarball) || {
    color_printf red "错误: 未找到 MongoDB 安装包 (mongodb-linux-*.tgz / mongodb-*.tar.gz)" \
                     "请将安装包放在: ${software_dir}"
    return 1
    }
    selected_mongo_tarball="$mongo_tarball"
  fi

  echo "MongoDB 安装包: $(basename "$mongo_tarball")"

  # 检查 mongosh 安装包 (可选, 支持多种包名格式)
  local mongosh_tarball
  mongosh_tarball=$(ls -1 "${software_dir}"/mongosh-*.tgz "${software_dir}"/mongosh-*.tar.gz 2>/dev/null | head -n1)
  if [[ -n "$mongosh_tarball" ]]; then
    echo "mongosh 安装包: $(basename "$mongosh_tarball")"
  else
    if (( mongo_major_ver >= 6 )); then
      echo "错误: MongoDB ${mongo_major_ver}.${mongo_minor_ver} 安装与验证需要独立的 mongosh 安装包" >&2
      echo "请下载后放入 ${software_dir}: https://www.mongodb.com/try/download/shell" >&2
      return 1
    fi
    echo "提示: 未找到独立 mongosh，将使用 MongoDB 安装包自带的 legacy mongo shell"
  fi

  # 检查 MongoDB Database Tools 安装包 (可选)
  local tools_tarball
  tools_tarball=$(ls -1 "${software_dir}"/mongodb-database-tools-*.tgz "${software_dir}"/mongodb-database-tools-*.tar.gz 2>/dev/null | head -n1)
  if [[ -n "$tools_tarball" ]]; then
    echo "Database Tools 安装包: $(basename "$tools_tarball")"
  else
    echo "提示: 未找到 Database Tools 安装包 (mongodump/mongorestore 等)"
    echo "      推荐下载: https://www.mongodb.com/try/download/database-tools"
  fi
}
#==============================================================#
#                   安装依赖包                                 #
#==============================================================#
function prepare_os_packages_root() {
  local extract_dir entry archive_list
  [[ -d "$os_packages_root" ]] && return 0
  [[ -f "$os_packages_archive" && ! -L "$os_packages_archive" ]] || return 3
  archive_list=$(mktemp /tmp/mongo-os-packages.list.XXXXXX) || return 1
  MONGO_INSTALL_TMPFILES+=("$archive_list")
  tar tzf "$os_packages_archive" > "$archive_list" || {
    echo "错误: 无法读取 mongdb-offline-rpm.tar.gz" >&2
    return 1
  }
  while IFS= read -r entry; do
    case "$entry" in
      mongdb-offline-rpm|mongdb-offline-rpm/*) ;;
      *)
        printf '错误: mongdb-offline-rpm.tar.gz 包含越界路径: %s\n' "$entry" >&2
        return 1
        ;;
    esac
    [[ "/${entry}/" != *"/../"* && "$entry" != /* ]] || {
      printf '错误: mongdb-offline-rpm.tar.gz 包含不安全路径: %s\n' "$entry" >&2
      return 1
    }
  done < "$archive_list"
  tar tvzf "$os_packages_archive" | awk '
    substr($1,1,1) != "-" && substr($1,1,1) != "d" { bad=1 }
    END { exit bad }
  ' || {
    echo "错误: mongdb-offline-rpm.tar.gz 不允许包含符号链接、硬链接或设备文件" >&2
    return 1
  }
  extract_dir=$(mktemp -d /tmp/mongo-os-packages.XXXXXX) || return 1
  MONGO_INSTALL_TMPDIRS+=("$extract_dir")
  tar --no-same-owner --no-same-permissions -xzf "$os_packages_archive" -C "$extract_dir" || return 1
  [[ -d "${extract_dir}/mongdb-offline-rpm" ]] || {
    echo "错误: mongdb-offline-rpm.tar.gz 缺少顶层 mongdb-offline-rpm/ 目录" >&2
    return 1
  }
  os_packages_root="${extract_dir}/mongdb-offline-rpm"
}

function resolve_os_packages_dir() {
  local candidate
  if [[ -z "$os_packages_dir" ]]; then
    prepare_os_packages_root || return $?
  fi
  candidate="${os_packages_dir:-${os_packages_root}/${os_distro}/${os_version}/${os_arch}}"
  [[ -d "$candidate" ]] || return 3
  printf '%s' "$(readlink -f -- "$candidate")"
}

function validate_os_package_bundle() {
  local bundle_dir="$1" bundle_arch bundle_major bundle_os package_file package_arch
  local bundle_entry_count=0
  bundle_dir=$(readlink -f -- "$bundle_dir") || return 1
  bundle_arch=$(basename -- "$bundle_dir")
  bundle_major=$(basename -- "$(dirname -- "$bundle_dir")")
  bundle_os=$(basename -- "$(dirname -- "$(dirname -- "$bundle_dir")")")
  if [[ "$bundle_os" != "$os_distro" || "$bundle_major" != "$os_version" || "$bundle_arch" != "$os_arch" ]]; then
    printf '错误: OS 离线包目录平台不匹配: bundle=%s/%s/%s, host=%s/%s/%s\n' \
      "$bundle_os" "$bundle_major" "$bundle_arch" "$os_distro" "$os_version" "$os_arch" >&2
    return 1
  fi
  while IFS= read -r -d '' package_file; do
    ((bundle_entry_count++))
    [[ -f "$package_file" && ! -L "$package_file" \
      && "$(basename -- "$package_file")" =~ ^[A-Za-z0-9_.+~-]+\.rpm$ ]] || {
      printf '错误: OS 离线补充包只能包含 RPM 文件: %s\n' "$package_file" >&2
      return 1
    }
    package_arch=$(rpm -qp --qf '%{ARCH}' "$package_file" 2>/dev/null) || {
      printf '错误: 无法读取 OS 离线 RPM: %s\n' "$package_file" >&2
      return 1
    }
    [[ "$package_arch" == "$os_arch" || "$package_arch" == "noarch" ]] || {
      printf '错误: OS 离线 RPM 架构不匹配: %s (%s != %s)\n' \
        "$package_file" "$package_arch" "$os_arch" >&2
      return 1
    }
  done < <(find "$bundle_dir" -mindepth 1 -maxdepth 1 -print0)
  (( bundle_entry_count > 0 )) || {
    echo "错误: OS 离线包目录为空: ${bundle_dir}" >&2
    return 1
  }
}

function install_os_offline_bundle() {
  local bundle_dir package_file
  local -a package_files=()
  bundle_dir=$(resolve_os_packages_dir) || return $?
  validate_os_package_bundle "$bundle_dir" || return 1
  case "$os_distro_family" in
    rhel|suse)
      mapfile -t package_files < <(find "$bundle_dir" -maxdepth 1 -type f -name '*.rpm' -print | sort)
      ;;
    debian)
      mapfile -t package_files < <(find "$bundle_dir" -maxdepth 1 -type f -name '*.deb' -print | sort)
      ;;
    arch)
      mapfile -t package_files < <(find "$bundle_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
      ;;
  esac
  (( ${#package_files[@]} > 0 )) || {
    echo "错误: OS 离线包目录中没有当前平台的软件包: ${bundle_dir}" >&2
    return 1
  }
  echo "使用 OS 离线补充包: ${bundle_dir} (${#package_files[@]} 个)"
  case "$os_distro_family" in
    rhel)
      import_system_rpm_signing_key || return 1
      for package_file in "${package_files[@]}"; do
        rpm --checksig "$package_file" >/dev/null 2>&1 || {
          printf '错误: OS 离线补充包 RPM 签名校验失败: %s\n' "$package_file" >&2
          return 1
        }
      done
      if command -v dnf >/dev/null 2>&1; then
        dnf --disablerepo='*' install -y -q "${package_files[@]}"
      elif command -v yum >/dev/null 2>&1; then
        yum --disablerepo='*' localinstall -y -q "${package_files[@]}"
      else
        rpm -Uvh --replacepkgs "${package_files[@]}"
      fi
      ;;
    debian) dpkg -i "${package_files[@]}" ;;
    suse) zypper --no-refresh --non-interactive install "${package_files[@]}" ;;
    arch) pacman -U --noconfirm "${package_files[@]}" ;;
    *) return 3 ;;
  esac
}

function import_system_rpm_signing_key() {
  local -a key_candidates=()
  local key_file owner_id mode_value
  command -v rpm >/dev/null 2>&1 || return 0
  case "$os_distro" in
    rhel) key_candidates=(/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release) ;;
    rocky) key_candidates=(/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-* /etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial) ;;
    alma) key_candidates=(/etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux*) ;;
    centos) key_candidates=(/etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-*) ;;
    ol) key_candidates=(/etc/pki/rpm-gpg/RPM-GPG-KEY-oracle*) ;;
    *) return 0 ;;
  esac

  for key_file in "${key_candidates[@]}"; do
    [[ -f "$key_file" && ! -L "$key_file" ]] || continue
    owner_id=$(stat -c '%u' "$key_file" 2>/dev/null) || return 1
    mode_value=$(stat -c '%a' "$key_file" 2>/dev/null) || return 1
    [[ "$owner_id" == "0" && "$mode_value" =~ ^[0-7]{3,4}$ ]] || {
      printf '错误: 拒绝导入所有权或权限异常的系统 RPM 公钥: %s\n' "$key_file" >&2
      return 1
    }
    # 只信任操作系统已安装在 /etc/pki/rpm-gpg 下、root 管理且不可由组/其他用户写入的厂商公钥。
    (( (8#$mode_value & 0022) == 0 )) || {
      printf '错误: 拒绝导入可被非 root 修改的系统 RPM 公钥: %s\n' "$key_file" >&2
      return 1
    }
    rpm --import "$key_file" || {
      printf '错误: 导入系统 RPM 公钥失败: %s\n' "$key_file" >&2
      return 1
    }
    echo "已加载系统 RPM 签名公钥: ${key_file}"
    return 0
  done

  echo "警告: 未找到 ${os_distro} 的系统 RPM 签名公钥；ISO 包仍将执行 GPG 校验" >&2
  return 0
}

function install_os_iso_packages() {
  local -a packages=("$@") repo_args=()
  local -a iso_missing=()
  local iso_root="${os_iso_root:-}" package_name yum_repo_dir iso_package_names repo_id
  (( ${#packages[@]} > 0 )) || return 0
  [[ -n "$iso_root" ]] || return 3
  [[ -d "$iso_root" ]] || {
    echo "错误: --os-iso-root 目录不存在: ${iso_root}" >&2
    return 1
  }
  iso_root=$(readlink -f -- "$iso_root") || return 1
  case "$os_distro_family" in
    rhel)
      if [[ -f "${iso_root}/BaseOS/repodata/repomd.xml" ]]; then
        repo_args+=(--repofrompath "mongodb-os-baseos,file://${iso_root}/BaseOS")
      fi
      if [[ -f "${iso_root}/AppStream/repodata/repomd.xml" ]]; then
        repo_args+=(--repofrompath "mongodb-os-appstream,file://${iso_root}/AppStream")
      fi
      if [[ -f "${iso_root}/repodata/repomd.xml" ]]; then
        repo_args+=(--repofrompath "mongodb-os-root,file://${iso_root}")
      fi
      (( ${#repo_args[@]} > 0 )) || {
        echo "错误: 指定目录不是有效的 RHEL ${os_version} ISO 根目录: ${iso_root}" >&2
        return 1
      }
      import_system_rpm_signing_key || return 1
      echo "使用已挂载 OS ISO 安装依赖: ${iso_root}"
      # 逐包安装：ISO 中不存在的包不会阻止其他基础依赖安装，缺失项随后由
      # mongdb-offline-rpm.tar.gz 补充。
      if command -v dnf >/dev/null 2>&1; then
        for package_name in "${packages[@]}"; do
          if ! dnf -q --disablerepo='*' "${repo_args[@]}" repoquery --available \
            --qf '%{name}' "$package_name" 2>/dev/null | grep -Fxq "$package_name"; then
            iso_missing+=("$package_name")
            continue
          fi
          dnf --disablerepo='*' "${repo_args[@]}" install -y -q "$package_name" || {
            printf '错误: 从 OS ISO 安装已存在的软件包失败（保留 GPG 校验）: %s\n' "$package_name" >&2
            return 1
          }
        done
      elif command -v yum >/dev/null 2>&1; then
        # CentOS/RHEL 7 没有 dnf。使用临时、只读 ISO 仓库配置，并从 RPM
        # 元数据生成一次包名索引，避免把已安装但 ISO 仍提供的包误判为缺失。
        yum_repo_dir=$(mktemp -d /tmp/mongo-os-iso-repo.XXXXXX) || return 1
        MONGO_INSTALL_TMPDIRS+=("$yum_repo_dir")
        iso_package_names="${yum_repo_dir}/package-names"
        find "$iso_root" -type f -name '*.rpm' -print0 \
          | xargs -0 -r rpm -qp --qf '%{NAME}\n' 2>/dev/null \
          | sort -u > "$iso_package_names" || return 1
        [[ -s "$iso_package_names" ]] || {
          echo "错误: OS ISO 中没有可读取的 RPM 软件包: ${iso_root}" >&2
          return 1
        }
        if [[ -f "${iso_root}/repodata/repomd.xml" ]]; then
          cat > "${yum_repo_dir}/mongodb-os-root.repo" <<EOF
[mongodb-os-root]
name=MongoDB installer OS ISO
baseurl=file://${iso_root}
enabled=1
gpgcheck=1
EOF
        else
          for repo_id in BaseOS AppStream; do
            [[ -f "${iso_root}/${repo_id}/repodata/repomd.xml" ]] || continue
            cat > "${yum_repo_dir}/mongodb-os-${repo_id}.repo" <<EOF
[mongodb-os-${repo_id}]
name=MongoDB installer OS ISO ${repo_id}
baseurl=file://${iso_root}/${repo_id}
enabled=1
gpgcheck=1
EOF
          done
        fi
        for package_name in "${packages[@]}"; do
          if ! grep -Fxq "$package_name" "$iso_package_names"; then
            iso_missing+=("$package_name")
            continue
          fi
          yum --disablerepo='*' --setopt="reposdir=${yum_repo_dir}" \
            --enablerepo='mongodb-os-*' install -y -q "$package_name" || {
            printf '错误: 从 OS ISO 安装已存在的软件包失败（保留 GPG 校验）: %s\n' "$package_name" >&2
            return 1
          }
        done
      else
        return 3
      fi
      if (( ${#iso_missing[@]} > 0 )); then
        printf 'OS ISO 未提供，转由离线补充包处理: %s\n' "${iso_missing[*]}"
        return 3
      fi
      ;;
    *)
      echo "警告: 当前仅自动支持从 RHEL 系列 ISO 安装依赖，其他系统请使用 OS 离线补充包"
      return 3
      ;;
  esac
}

function pkg_install() {
  log_print "安装依赖包"
  local -a required_commands=(tar awk grep sed find sort sha256sum ss ip ps)
  local -a optional_commands=(numactl netstat sar lsof logrotate)
  local -a required_packages=() optional_packages=()
  local command_name install_status=0 warning_status=0 repositories_available=1

  if (( HAS_SYSTEMD )); then
    required_commands+=(systemctl hostnamectl)
  fi
  if (( mongo_numa_nodes > 1 )); then
    required_commands+=(numactl)
  fi
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    required_commands+=(ssh scp)
    [[ -n "$remote_root_pass" ]] && required_commands+=(sshpass)
    [[ "$mongo_auth_enabled" == "Y" || "$mongo_tls_enabled" == "Y" ]] && required_commands+=(openssl)
  fi

  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 && continue
    case "$os_distro_family:$command_name" in
      rhel:ss|rhel:ip) required_packages+=(iproute) ;;
      rhel:ps) required_packages+=(procps-ng) ;;
      rhel:sort|rhel:sha256sum) required_packages+=(coreutils) ;;
      rhel:ssh|rhel:scp) required_packages+=(openssh-clients) ;;
      rhel:sshpass) required_packages+=(sshpass) ;;
      rhel:openssl) required_packages+=(openssl) ;;
      rhel:numactl) required_packages+=(numactl) ;;
      rhel:hostnamectl|rhel:systemctl) required_packages+=(systemd) ;;
      debian:ss|debian:ip) required_packages+=(iproute2) ;;
      debian:ps) required_packages+=(procps) ;;
      debian:ssh|debian:scp) required_packages+=(openssh-client) ;;
      debian:sshpass) required_packages+=(sshpass) ;;
      debian:openssl) required_packages+=(openssl) ;;
      *) required_packages+=("$command_name") ;;
    esac
  done
  for command_name in "${optional_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 && continue
    case "$os_distro_family:$command_name" in
      rhel:numactl) optional_packages+=(numactl) ;;
      rhel:netstat) optional_packages+=(net-tools) ;;
      rhel:sar) optional_packages+=(sysstat) ;;
      rhel:lsof) optional_packages+=(lsof) ;;
      rhel:logrotate) optional_packages+=(logrotate) ;;
      debian:netstat) optional_packages+=(net-tools) ;;
      debian:sar) optional_packages+=(sysstat) ;;
      *) optional_packages+=("$command_name") ;;
    esac
  done

  # 离线优先：OS ISO 提供基础包，安装器旁的 OS 离线包补充 ISO 中缺失的包。
  local -a requested_packages=() missing_after_offline=()
  local iso_status=0 bundle_status=0 optional_missing_count=0
  if (( ${#required_packages[@]} > 0 || ${#optional_packages[@]} > 0 )); then
    mapfile -t requested_packages < <(printf '%s\n' "${required_packages[@]}" "${optional_packages[@]}" | sed '/^$/d' | sort -u)
    install_os_iso_packages "${requested_packages[@]}" || iso_status=$?
    if (( iso_status != 0 && iso_status != 3 )); then
      return "$iso_status"
    fi
    install_os_offline_bundle || bundle_status=$?
    if (( bundle_status != 0 && bundle_status != 3 )); then
      return "$bundle_status"
    fi
    for command_name in "${required_commands[@]}"; do
      command -v "$command_name" >/dev/null 2>&1 || missing_after_offline+=("$command_name")
    done
    if (( ${#missing_after_offline[@]} == 0 )); then
      required_packages=()
    fi
    for command_name in "${optional_commands[@]}"; do
      command -v "$command_name" >/dev/null 2>&1 || ((optional_missing_count++))
    done
    if (( optional_missing_count == 0 )); then
      optional_packages=()
    fi
  fi

  # 已具备必需命令时，不因未配置软件仓库而让离线安装失败。
  # 可选工具只在仓库可用时尝试安装，失败降级为警告。
  case "$os_distro_family" in
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        dnf -q repolist 2>/dev/null | awk 'NR>1{found=1} END{exit !found}' || repositories_available=0
        if (( ${#required_packages[@]} > 0 )); then
          (( repositories_available == 1 )) || {
            printf '错误: 缺少必需命令且没有可用 DNF 仓库: %s\n' "${required_commands[*]}" >&2
            return 1
          }
          dnf install -y -q "${required_packages[@]}" || install_status=$?
        fi
        if (( repositories_available == 1 && ${#optional_packages[@]} > 0 )); then
          dnf install -y -q "${optional_packages[@]}" || warning_status=3
        fi
      elif command -v yum >/dev/null 2>&1; then
        if (( ${#required_packages[@]} > 0 )); then
          yum install -y -q "${required_packages[@]}" || install_status=$?
        fi
        if (( ${#optional_packages[@]} > 0 )); then
          yum install -y -q "${optional_packages[@]}" || warning_status=3
        fi
      elif (( ${#required_packages[@]} > 0 )); then
        echo "错误: 缺少必需命令且未找到 dnf/yum" >&2
        return 1
      fi
      ;;
    debian)
      if (( ${#required_packages[@]} > 0 || ${#optional_packages[@]} > 0 )); then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || install_status=$?
        if (( install_status == 0 && ${#required_packages[@]} > 0 )); then
          apt-get install -y -qq "${required_packages[@]}" || install_status=$?
        fi
        if (( install_status == 0 && ${#optional_packages[@]} > 0 )); then
          apt-get install -y -qq "${optional_packages[@]}" || warning_status=3
        fi
      fi
      ;;
    suse)
      (( ${#required_packages[@]} == 0 )) || zypper --non-interactive install "${required_packages[@]}" || install_status=$?
      (( ${#optional_packages[@]} == 0 )) || zypper --non-interactive install "${optional_packages[@]}" || warning_status=3
      ;;
    arch)
      (( ${#required_packages[@]} == 0 )) || pacman -Sy --noconfirm --needed "${required_packages[@]}" || install_status=$?
      (( ${#optional_packages[@]} == 0 )) || pacman -Sy --noconfirm --needed "${optional_packages[@]}" || warning_status=3
      ;;
    *)
      (( ${#required_packages[@]} == 0 )) || {
        printf '错误: 未知包管理器且缺少必需命令: %s\n' "${required_commands[*]}" >&2
        return 1
      }
      warning_status=3
      ;;
  esac

  (( install_status == 0 )) || return "$install_status"
  local -a still_missing=()
  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || still_missing+=("$command_name")
  done
  (( ${#still_missing[@]} == 0 )) || {
    printf '错误: 安装后仍缺少必需命令: %s\n' "${still_missing[*]}" >&2
    return 1
  }
  if (( repositories_available == 0 && ${#optional_packages[@]} > 0 )); then
    printf '警告: 未配置软件仓库，跳过可选工具: %s\n' "${optional_packages[*]}"
    warning_status=3
  fi
  return "$warning_status"
}
#==============================================================#
#                   创建用户与目录                             #
#==============================================================#
function create_users_groups() {
  log_print "创建 MongoDB 系统用户及同名主组"
  if ! getent group "${mongo_owner}" >/dev/null 2>&1; then
    if getent group 60300 >/dev/null 2>&1; then
      log_print "GID 60300 已占用，为 ${mongo_owner} 自动分配系统 GID"
      groupadd -r "${mongo_owner}" || return 1
    else
      groupadd -g 60300 "${mongo_owner}" || return 1
    fi
  fi
  if ! id "${mongo_owner}" &>/dev/null; then
    if getent passwd 60300 >/dev/null 2>&1; then
      log_print "UID 60300 已占用，为 ${mongo_owner} 自动分配系统 UID"
      useradd -r -g "${mongo_owner}" -s "${NOLOGIN_PATH}" -M "${mongo_owner}" || return 1
    else
      useradd -u 60300 -g "${mongo_owner}" -s "${NOLOGIN_PATH}" -M "${mongo_owner}" || return 1
    fi
  else
    usermod -g "${mongo_owner}" -s "${NOLOGIN_PATH}" "${mongo_owner}" 2>/dev/null || return 1
  fi
  passwd -l "${mongo_owner}" &>/dev/null || return 1
}

function runtime_user_can_traverse() {
  local path="$1"
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$mongo_owner" -- test -x "$path" >/dev/null 2>&1
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/sh "$mongo_owner" -c 'test -x "$1"' sh "$path" >/dev/null 2>&1
  else
    echo "错误: 无法验证 ${mongo_owner} 的目录穿越权限（缺少 runuser/su）" >&2
    return 1
  fi
}

function validate_runtime_parent_access() {
  local target current
  local -A checked_paths=()

  for target in "$@"; do
    current=$(dirname -- "$(readlink -m -- "$target")") || return 1
    while [[ "$current" != "/" ]]; do
      if [[ -z "${checked_paths[$current]+x}" ]]; then
        checked_paths[$current]=1
        if ! runtime_user_can_traverse "$current"; then
          printf '错误: MongoDB 运行用户 %s 无法穿越父目录 %s；安装器不会添加 ACL 或修改非托管父目录，请使用属主/属组和 mode 授予穿越权限\n' \
            "$mongo_owner" "$current" >&2
          return 1
        fi
      fi
      current=$(dirname -- "$current")
    done
  done
}

function create_dir() {
  log_print "创建 MongoDB 目录结构"
  validate_safe_install_dir "$env_base_dir" || {
    printf '错误: 拒绝在高风险目录创建 MongoDB 结构: %s\n' "$env_base_dir" >&2
    return 1
  }

  # 只设置安装器明确管理的目录本身，绝不递归修改用户指定根目录中的未知文件。
  install -d -o "$mongo_owner" -g "$mongo_owner" -m 0750 "$env_base_dir" || return 1
  install -d -o "$mongo_owner" -g "$mongo_owner" -m 0755 "$env_app_dir" || return 1
  install -d -o "$mongo_owner" -g "$mongo_owner" -m 0750 \
    "$data_dir" "${data_dir}/db" "${data_dir}/configdb" \
    "$log_dir" "$backup_dir" "$pid_dir" || return 1
  # 所有 MongoDB 管理目录的属主、属组都与 --owner 指定用户保持一致。
  install -d -o "$mongo_owner" -g "$mongo_owner" -m 0750 "$scripts_dir" || return 1
  validate_runtime_parent_access \
    "$env_base_dir" "$env_app_dir" "$data_dir" "${data_dir}/db" \
    "$log_dir" "$backup_dir" "$pid_dir" "$scripts_dir" || return 1
}
#==============================================================#
#                   OS 优化函数                                #
#==============================================================#
function conf_hostname() {
  local local_ip new_hostname
  local_ip=$(get_local_ip)
  new_hostname=$(build_install_hostname "$hostname" "$mongo_install_mode" "$local_ip") || return 1
  log_print "设置主机名: ${new_hostname}"
  if command -v hostnamectl &>/dev/null; then
    hostnamectl set-hostname "$new_hostname" || return 1
  else
    hostname "$new_hostname" || return 1
    echo "$new_hostname" > /etc/hostname || return 1
  fi
  if ! grep -Fqw -- "$new_hostname" /etc/hosts 2>/dev/null; then
    local_ip="${local_ip:-127.0.0.1}"
    echo "${local_ip}  ${new_hostname}" >> /etc/hosts || return 1
  fi
}

function conf_firewall() {
  log_print "关闭防火墙"
  local changed=0 service_name

  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'; then
    ufw --force disable >/dev/null || return 1
    changed=1
    echo "ufw 已关闭"
  fi

  if (( HAS_SYSTEMD )); then
    for service_name in firewalld iptables ip6tables nftables ufw; do
      if systemctl cat "${service_name}.service" &>/dev/null; then
        systemctl disable --now "${service_name}.service" >/dev/null 2>&1 || return 1
        changed=1
      fi
      # 即使软件包当前未安装，也阻止相应服务被后续依赖自动拉起。
      systemctl mask "${service_name}.service" >/dev/null 2>&1 || return 1
      changed=1
      echo "${service_name} 已停止、禁用并永久屏蔽"
    done
  elif command -v service &>/dev/null; then
    for service_name in firewalld iptables ip6tables nftables ufw; do
      if [[ -x "/etc/init.d/${service_name}" ]]; then
        service "$service_name" stop >/dev/null 2>&1 || return 1
        if command -v chkconfig &>/dev/null; then
          chkconfig "$service_name" off >/dev/null 2>&1 || return 1
        else
          echo "错误: 缺少 chkconfig，无法保证 ${service_name} 重启后保持关闭" >&2
          return 1
        fi
        changed=1
        echo "${service_name} 已停止并永久禁用"
      fi
    done
  fi

  (( changed == 1 )) || echo "未检测到活跃的 firewalld、ufw、iptables 或 nftables 服务"
  (( ${#firewall_sources[@]} == 0 )) || echo "提示: 防火墙已关闭，--allow-source 参数不会生效"
}

function conf_selinux() {
  log_print "关闭 SELinux"
  local state="未安装" persistent_configured=0 kernel_disabled=0
  command -v getenforce &>/dev/null && state=$(getenforce 2>/dev/null || echo "未知")

  if [[ "$state" == "Enforcing" ]]; then
    setenforce 0 || return 1
    state="Permissive"
  fi

  if [[ -f /etc/selinux/config ]]; then
    if grep -Eq '^[[:space:]]*SELINUX=' /etc/selinux/config; then
      sed -ri 's/^[[:space:]]*SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || return 1
    else
      printf '\nSELINUX=disabled\n' >> /etc/selinux/config || return 1
    fi
    persistent_configured=1
  fi

  # RHEL 9+ 需要通过内核参数完全关闭 SELinux；旧版本同时保留 config 设置。
  if [[ "$state" != "未安装" || -f /etc/selinux/config ]]; then
    if [[ -r /proc/cmdline ]] && grep -Eq '(^|[[:space:]])selinux=0([[:space:]]|$)' /proc/cmdline; then
      kernel_disabled=1
    elif command -v grubby &>/dev/null; then
      grubby --update-kernel ALL --args selinux=0 >/dev/null || return 1
      kernel_disabled=1
    elif [[ "$os_distro_family" == "rhel" ]]; then
      echo "错误: RHEL/Rocky 完全关闭 SELinux 需要 grubby 写入 selinux=0 内核参数" >&2
      return 1
    fi
  fi

  if [[ "$state" == "未安装" || "$state" == "Disabled" ]]; then
    echo "SELinux 当前未启用"
  elif (( persistent_configured == 1 || kernel_disabled == 1 )); then
    echo "SELinux 当前已切换为 Permissive，重启后将完全关闭"
  else
    echo "错误: 无法配置 SELinux 重启后保持关闭" >&2
    return 1
  fi
}

function resolve_storage_probe_path() {
  local target="${1:-$data_dir}"
  while [[ ! -e "$target" && "$target" != "/" ]]; do
    target=$(dirname "$target")
  done
  [[ -e "$target" ]] || target=/
  readlink -f -- "$target"
}

function resolve_data_block_device() {
  local probe_path source
  probe_path=$(resolve_storage_probe_path "$data_dir") || return 1
  if command -v findmnt >/dev/null 2>&1; then
    source=$(findmnt -n -o SOURCE -T "$probe_path" 2>/dev/null | head -n1)
  else
    source=$(df -P "$probe_path" 2>/dev/null | awk 'NR==2{print $1}')
  fi
  [[ "$source" == /dev/* ]] || return 3
  source=$(readlink -f -- "$source") || return 1
  [[ -b "$source" ]] || return 3
  printf '%s' "$source"
}

function configure_mongodb_readahead() {
  local data_device blockdev_bin current_ra service_status=0
  data_device=$(resolve_data_block_device) || return $?
  blockdev_bin=$(command -v blockdev 2>/dev/null) || {
    echo "警告: 缺少 blockdev，无法配置数据设备 readahead" >&2
    return 3
  }
  [[ "$data_device" =~ ^/dev/[A-Za-z0-9._/+:-]+$ ]] || {
    echo "错误: 数据块设备路径格式不安全: ${data_device}" >&2
    return 1
  }
  current_ra=$($blockdev_bin --getra "$data_device" 2>/dev/null || echo unknown)
  $blockdev_bin --setra "$mongo_readahead_sectors" "$data_device" || {
    echo "警告: 无法设置 ${data_device} readahead" >&2
    return 3
  }
  mongo_data_device="$data_device"
  printf 'readahead: device=%s, %s -> %s sectors\n' \
    "$data_device" "$current_ra" "$mongo_readahead_sectors"

  if (( HAS_SYSTEMD )); then
    cat > /etc/systemd/system/mongodb-readahead.service <<RADEOF || return 1
[Unit]
Description=Configure MongoDB data device readahead
DefaultDependencies=no
After=local-fs.target tuned.service
Before=mongod.service

[Service]
Type=oneshot
ExecStart=${blockdev_bin} --setra ${mongo_readahead_sectors} ${data_device}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RADEOF
    systemctl daemon-reload >/dev/null || return 1
    systemctl enable --now mongodb-readahead.service >/dev/null 2>&1 || service_status=3
  else
    service_status=3
  fi
  return "$service_status"
}

function conf_sysctl() {
  log_print "优化内核参数"
  (( mongo_resource_profile_ready == 1 )) || calculate_resource_profile || return 1

  local sysctl_file=/etc/sysctl.d/99-mongodb.conf
  local current_file_max current_map_count current_pid_max current_threads_max
  local file_max_conf="" map_count_conf="" pid_max_conf="" threads_max_conf=""
  local cgroup_swappiness_conf="" readahead_status=0 target_process_space

  current_file_max=$(< /proc/sys/fs/file-max 2>/dev/null) || current_file_max=0
  current_map_count=$(< /proc/sys/vm/max_map_count 2>/dev/null) || current_map_count=0
  current_pid_max=$(< /proc/sys/kernel/pid_max 2>/dev/null) || current_pid_max=0
  current_threads_max=$(< /proc/sys/kernel/threads-max 2>/dev/null) || current_threads_max=0
  [[ "$current_file_max" =~ ^[0-9]+$ ]] || current_file_max=0
  [[ "$current_map_count" =~ ^[0-9]+$ ]] || current_map_count=0
  [[ "$current_pid_max" =~ ^[0-9]+$ ]] || current_pid_max=0
  [[ "$current_threads_max" =~ ^[0-9]+$ ]] || current_threads_max=0

  (( current_file_max < mongo_file_max_target )) \
    && file_max_conf="fs.file-max = ${mongo_file_max_target}"
  (( current_map_count < 262144 )) && map_count_conf="vm.max_map_count = 262144"
  target_process_space=$((mongo_nproc_limit * 2))
  (( current_pid_max < target_process_space )) \
    && pid_max_conf="kernel.pid_max = ${target_process_space}"
  (( current_threads_max < target_process_space )) \
    && threads_max_conf="kernel.threads-max = ${target_process_space}"
  [[ -e /proc/sys/vm/force_cgroup_v2_swappiness ]] \
    && cgroup_swappiness_conf="vm.force_cgroup_v2_swappiness = 1"

  cat > "$sysctl_file" <<SYSEOF || return 1
# MongoBegin - MongoDB 系统内核参数优化
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 参照: https://www.mongodb.com/docs/manual/administration/production-notes/

#---------- 内存管理 ----------
# MongoDB 官方: 保留紧急 swap 能力，但尽量避免正常换页
vm.swappiness = 1
${cgroup_swappiness_conf}
# NUMA: 禁用 zone_reclaim (MongoDB 官方推荐)
vm.zone_reclaim_mode = 0
${map_count_conf}

#---------- 网络参数 ----------
# 只提高不足的监听队列；不覆盖 OS 自适应 TCP 缓冲和 TIME_WAIT 策略
net.core.somaxconn = ${mongo_somaxconn_target}
net.ipv4.tcp_keepalive_time = 120

#---------- 连接数、线程与文件系统 ----------
${file_max_conf}
${pid_max_conf}
${threads_max_conf}
# MongoEnd
SYSEOF

  # 删除条件项产生的空行，且只加载本安装器自己的配置，避免被无关的
  # 第三方 sysctl 文件错误阻断。
  sed -i '/^[[:space:]]*$/N;/^\n$/d' "$sysctl_file" || return 1
  if ! sysctl -p "$sysctl_file" >/dev/null 2>&1; then
    echo "错误: 加载 MongoDB 内核参数失败: ${sysctl_file}" >&2
    return 1
  fi
  configure_mongodb_readahead || readahead_status=$?
  return "$readahead_status"
}

function conf_limits() {
  log_print "配置资源限制"
  (( mongo_resource_profile_ready == 1 )) || calculate_resource_profile || return 1
  local limits_target="/etc/security/limits.conf"
  local redirect_mode="append"
  if [[ -d /etc/security/limits.d ]]; then
    limits_target="/etc/security/limits.d/99-mongodb.conf"
    redirect_mode="replace"
  else
    bak_file "$limits_target" || return 1
  fi

  # 优先使用独立的 limits.d 文件，避免重复修改系统主配置。
  if [[ "$redirect_mode" == "replace" ]]; then
    cat > "$limits_target" <<LIMEOF || return 1
# MongoBegin - MongoDB 资源限制
# 参照: https://www.mongodb.com/docs/manual/reference/ulimit/
${mongo_owner}  soft  nofile  ${mongo_nofile_limit}
${mongo_owner}  hard  nofile  ${mongo_nofile_limit}
${mongo_owner}  soft  nproc   ${mongo_nproc_limit}
${mongo_owner}  hard  nproc   ${mongo_nproc_limit}
${mongo_owner}  soft  fsize   unlimited
${mongo_owner}  hard  fsize   unlimited
${mongo_owner}  soft  cpu     unlimited
${mongo_owner}  hard  cpu     unlimited
${mongo_owner}  soft  as      unlimited
${mongo_owner}  hard  as      unlimited
${mongo_owner}  soft  core    unlimited
${mongo_owner}  hard  core    unlimited
${mongo_owner}  soft  memlock unlimited
${mongo_owner}  hard  memlock unlimited
# MongoEnd
LIMEOF
  else
    cat >> "$limits_target" <<LIMEOF || return 1
# MongoBegin - MongoDB 资源限制
# 参照: https://www.mongodb.com/docs/manual/reference/ulimit/
${mongo_owner}  soft  nofile  ${mongo_nofile_limit}
${mongo_owner}  hard  nofile  ${mongo_nofile_limit}
${mongo_owner}  soft  nproc   ${mongo_nproc_limit}
${mongo_owner}  hard  nproc   ${mongo_nproc_limit}
${mongo_owner}  soft  fsize   unlimited
${mongo_owner}  hard  fsize   unlimited
${mongo_owner}  soft  cpu     unlimited
${mongo_owner}  hard  cpu     unlimited
${mongo_owner}  soft  as      unlimited
${mongo_owner}  hard  as      unlimited
${mongo_owner}  soft  core    unlimited
${mongo_owner}  hard  core    unlimited
${mongo_owner}  soft  memlock unlimited
${mongo_owner}  hard  memlock unlimited
# MongoEnd
LIMEOF
  fi
}

function conf_thp() {
  log_print "配置 Transparent Huge Pages (THP)"
  # MongoDB 8.0+: 使用 TCMalloc，官方建议 **启用** THP
  # MongoDB 7.0 及更早: 官方建议 **禁用** THP

  local thp_mode thp_status=0
  thp_mode=$(mongo_thp_mode "$mongo_major_ver")
  if [[ "$thp_mode" == "skip" ]]; then
    echo "警告: MongoDB 版本未知，保持当前 THP 设置不变；可通过 --mongo-version 指定版本"
    return 3
  fi

  if [[ "$thp_mode" == "enable" ]]; then
    echo "MongoDB ${mongo_major_ver}.${mongo_minor_ver}: 启用 THP (TCMalloc 优化)"
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
      if ! { echo always > /sys/kernel/mm/transparent_hugepage/enabled; } 2>/dev/null; then
        echo "警告: 无法立即启用 THP"
        thp_status=3
      fi
    fi
    if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
      if ! { echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag; } 2>/dev/null; then
        echo "警告: 无法立即设置 THP defrag 模式"
        thp_status=3
      fi
    fi

    if (( HAS_SYSTEMD )); then
      systemctl disable --now disable-thp.service >/dev/null 2>&1 || true
      rm -f -- /etc/systemd/system/disable-thp.service
      cat > /etc/systemd/system/mongodb-thp.service <<'THPEOF' || return 1
[Unit]
Description=Enable Transparent Huge Pages for MongoDB 8.0+ (TCMalloc)
DefaultDependencies=no
After=sysinit.target local-fs.target tuned.service
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'set -e; [[ ! -f /sys/kernel/mm/transparent_hugepage/enabled ]] || echo always > /sys/kernel/mm/transparent_hugepage/enabled; [[ ! -f /sys/kernel/mm/transparent_hugepage/defrag ]] || echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
THPEOF
      systemctl daemon-reload >/dev/null || return 1
      systemctl enable --now mongodb-thp.service >/dev/null 2>&1 || {
        echo "错误: mongodb-thp.service 启用失败" >&2
        return 1
      }
    else
      echo "警告: 未检测到 systemd，THP 已在当前运行期设置，但重启后不会自动恢复"
      thp_status=3
    fi
  else
    echo "MongoDB ${mongo_major_ver}.${mongo_minor_ver}: 禁用 THP (官方推荐)"
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
      if ! { echo never > /sys/kernel/mm/transparent_hugepage/enabled; } 2>/dev/null; then
        echo "警告: 无法立即禁用 THP"
        thp_status=3
      fi
    fi
    if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
      if ! { echo never > /sys/kernel/mm/transparent_hugepage/defrag; } 2>/dev/null; then
        echo "警告: 无法立即禁用 THP defrag"
        thp_status=3
      fi
    fi

    if (( HAS_SYSTEMD )); then
      systemctl disable --now mongodb-thp.service >/dev/null 2>&1 || true
      rm -f -- /etc/systemd/system/mongodb-thp.service
      cat > /etc/systemd/system/disable-thp.service <<'THPEOF' || return 1
[Unit]
Description=Disable Transparent Huge Pages for MongoDB (pre-8.0)
DefaultDependencies=no
After=sysinit.target local-fs.target tuned.service
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'set -e; [[ ! -f /sys/kernel/mm/transparent_hugepage/enabled ]] || echo never > /sys/kernel/mm/transparent_hugepage/enabled; [[ ! -f /sys/kernel/mm/transparent_hugepage/defrag ]] || echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
THPEOF
      systemctl daemon-reload >/dev/null || return 1
      systemctl enable --now disable-thp.service >/dev/null 2>&1 || {
        echo "错误: disable-thp.service 启用失败" >&2
        return 1
      }
    else
      echo "警告: 未检测到 systemd，THP 已在当前运行期设置，但重启后不会自动恢复"
      thp_status=3
    fi
  fi
  return "$thp_status"
}

function optimize_mounts() {
  log_print "优化磁盘挂载选项"
  local probe_path data_mount fs_type mount_options data_device block_name
  local scheduler_file scheduler rotational
  probe_path=$(resolve_storage_probe_path "$data_dir") || return 1
  if command -v findmnt >/dev/null 2>&1; then
    data_mount=$(findmnt -n -o TARGET -T "$probe_path" 2>/dev/null | head -n1)
    fs_type=$(findmnt -n -o FSTYPE -T "$probe_path" 2>/dev/null | head -n1)
    mount_options=$(findmnt -n -o OPTIONS -T "$probe_path" 2>/dev/null | head -n1)
  else
    data_mount=$(df -P "$probe_path" 2>/dev/null | awk 'NR==2{print $6}')
    fs_type=$(df -PT "$probe_path" 2>/dev/null | awk 'NR==2{print $2}')
    mount_options=""
  fi
  [[ -n "$data_mount" ]] || {
    echo "警告: 无法确定数据目录所在挂载点: ${data_dir}" >&2
    return 3
  }

  # MongoDB 官方: 强烈推荐 XFS 文件系统
  if [[ "$fs_type" == "xfs" ]]; then
    echo "数据挂载点 ${data_mount} 使用 XFS 文件系统 (推荐)"
  elif [[ "$fs_type" == "ext4" ]]; then
    echo "数据挂载点 ${data_mount} 使用 EXT4 文件系统"
    echo "建议: MongoDB 官方强烈推荐使用 XFS 以获得更好性能"
  else
    echo "数据挂载点 ${data_mount} 文件系统: ${fs_type:-unknown}"
    echo "建议: MongoDB 官方推荐使用 XFS 文件系统"
  fi

  if [[ ",${mount_options}," == *",noatime,"* ]]; then
    echo "数据挂载点已启用 noatime"
  else
    echo "建议: 为数据挂载点 ${data_mount} 配置 noatime；安装器不会自动重挂载正在使用的文件系统"
  fi

  data_device=$(resolve_data_block_device 2>/dev/null || true)
  if [[ -n "$data_device" ]]; then
    block_name=$(lsblk -ndo KNAME "$data_device" 2>/dev/null | head -n1)
    scheduler_file="/sys/block/${block_name}/queue/scheduler"
    if [[ -n "$block_name" && -r "$scheduler_file" ]]; then
      scheduler=$(<"$scheduler_file")
      rotational=$(lsblk -ndo ROTA "$data_device" 2>/dev/null | head -n1)
      echo "I/O 调度器: device=${data_device}, scheduler=${scheduler}, rotational=${rotational:-unknown}"
      if [[ "$rotational" == "0" && "$scheduler" != *"[none]"* ]]; then
        echo "建议: SSD/NVMe/虚拟块设备优先使用 none 调度器；需结合云厂商和存储基准测试后修改"
      fi
    fi
  fi
}

function conf_ntp() {
  log_print "配置时间同步"
  local ntp_ok=0
  if command -v chronyc &>/dev/null; then
    if (( HAS_SYSTEMD )); then
      systemctl enable --now chronyd >/dev/null 2>&1 && ntp_ok=1
    elif chronyc tracking >/dev/null 2>&1; then
      ntp_ok=1
    fi
    (( ntp_ok == 1 )) && echo "时间同步: chronyd 已启用"
  elif command -v ntpd &>/dev/null || command -v ntpdate &>/dev/null; then
    if (( HAS_SYSTEMD )); then
      systemctl enable --now ntpd >/dev/null 2>&1 && ntp_ok=1
      (( ntp_ok == 0 )) && systemctl enable --now ntp >/dev/null 2>&1 && ntp_ok=1
    elif pgrep -x ntpd >/dev/null 2>&1; then
      ntp_ok=1
    fi
    (( ntp_ok == 1 )) && echo "时间同步: ntpd 已启用"
  elif command -v timedatectl &>/dev/null; then
    timedatectl set-ntp true >/dev/null 2>&1 && ntp_ok=1
    (( ntp_ok == 1 )) && echo "时间同步: systemd-timesyncd 已启用"
  fi
  if (( ntp_ok == 0 )); then
    echo "警告: 无法确认时间同步服务已启用，请手动检查"
    echo "MongoDB 副本集要求各节点时钟保持同步"
    return 3
  fi
}
#==============================================================#
#                   安装 MongoDB                               #
#==============================================================#
function install_mongodb() {
  log_print "安装 MongoDB"

  local mongo_tarball="${selected_mongo_tarball:-}"
  if [[ -z "$mongo_tarball" || ! -f "$mongo_tarball" ]]; then
    mongo_tarball=$(select_mongo_tarball) || {
    color_printf red "错误: 未找到 MongoDB 安装包" "请将安装包放在: ${software_dir}"
    return 1
    }
    selected_mongo_tarball="$mongo_tarball"
  fi

  echo "使用安装包: $(basename "$mongo_tarball")"

  local mongo_tmpdir
  mongo_tmpdir=$(mktemp -d /tmp/mongo_install.XXXXXX) || return 1
  MONGO_INSTALL_TMPDIRS+=("$mongo_tmpdir")
  if ! tar xzf "$mongo_tarball" -C "$mongo_tmpdir"; then
    rm -rf "$mongo_tmpdir"
    color_printf red "错误: MongoDB 安装包解压失败"
    return 1
  fi

  local mongo_src_dir
  mongo_src_dir=$(ls -1d "${mongo_tmpdir}"/mongodb-* 2>/dev/null | head -n1)
  if [[ -z "$mongo_src_dir" || ! -d "$mongo_src_dir" ]]; then
    rm -rf "$mongo_tmpdir"
    color_printf red "错误: 未找到 MongoDB 解压目录"
    return 1
  fi

  # 获取版本号
  local mongo_version
  mongo_version=$(basename "$mongo_src_dir" | grep -oP '\d+\.\d+\.\d+')
  if [[ -n "$mongo_version" ]]; then
    mongo_major_ver=$(echo "$mongo_version" | cut -d. -f1)
    mongo_minor_ver=$(echo "$mongo_version" | cut -d. -f2)
    mongo_patch_ver=$(echo "$mongo_version" | cut -d. -f3)
  fi
  echo "MongoDB 版本: ${mongo_version:-unknown} (major=${mongo_major_ver}, minor=${mongo_minor_ver})"

  if [[ -d "${env_app_dir}" ]]; then
    if [[ -n "$(find "${env_app_dir}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      local previous_app_dir="${env_app_dir}.backup.$(date +%Y%m%d%H%M%S)"
      mv "${env_app_dir}" "$previous_app_dir" || return 1
      chown -R "${mongo_owner}:${mongo_owner}" "$previous_app_dir" || return 1
      echo "原安装目录已保留为: ${previous_app_dir}"
    else
      rmdir "${env_app_dir}" || return 1
    fi
  fi
  if ! cp -a "$mongo_src_dir" "${env_app_dir}"; then
    rm -rf -- "$mongo_tmpdir"
    echo "错误: 复制 MongoDB 程序文件失败" >&2
    return 1
  fi
  rm -rf "$mongo_tmpdir"

  # 安装 mongosh (如果有单独的安装包)
  local mongosh_tarball
  mongosh_tarball=$(ls -1 "${software_dir}"/mongosh-*.tgz "${software_dir}"/mongosh-*.tar.gz 2>/dev/null | head -n1)
  if [[ -n "$mongosh_tarball" ]]; then
    echo "安装 mongosh: $(basename "$mongosh_tarball")"
    local mongosh_tmpdir
    mongosh_tmpdir=$(mktemp -d /tmp/mongosh_install.XXXXXX) || return 1
    MONGO_INSTALL_TMPDIRS+=("$mongosh_tmpdir")
    if ! tar xzf "$mongosh_tarball" -C "$mongosh_tmpdir" 2>/dev/null; then
      rm -rf -- "$mongosh_tmpdir"
      echo "错误: mongosh 安装包解压失败" >&2
      return 1
    fi
    local mongosh_src_dir
    mongosh_src_dir=$(ls -1d "${mongosh_tmpdir}"/mongosh-* 2>/dev/null | head -n1)
    if [[ -z "$mongosh_src_dir" || ! -x "${mongosh_src_dir}/bin/mongosh" ]]; then
      rm -rf -- "$mongosh_tmpdir"
      echo "错误: mongosh 安装包中未找到可执行文件" >&2
      return 1
    fi
    cp -f "${mongosh_src_dir}/bin/mongosh" "${env_app_dir}/bin/" || return 1
    echo "mongosh 安装完成"
    rm -rf "$mongosh_tmpdir"
  fi

  # 安装 MongoDB Database Tools (如果有)
  local tools_tarball
  tools_tarball=$(ls -1 "${software_dir}"/mongodb-database-tools-*.tgz "${software_dir}"/mongodb-database-tools-*.tar.gz 2>/dev/null | head -n1)
  if [[ -n "$tools_tarball" ]]; then
    echo "安装 Database Tools: $(basename "$tools_tarball")"
    local tools_tmpdir
    tools_tmpdir=$(mktemp -d /tmp/mongotools_install.XXXXXX) || return 1
    MONGO_INSTALL_TMPDIRS+=("$tools_tmpdir")
    if ! tar xzf "$tools_tarball" -C "$tools_tmpdir" 2>/dev/null; then
      rm -rf -- "$tools_tmpdir"
      echo "错误: Database Tools 安装包解压失败" >&2
      return 1
    fi
    local tools_src_dir
    tools_src_dir=$(ls -1d "${tools_tmpdir}"/mongodb-database-tools-* 2>/dev/null | head -n1)
    if [[ -z "$tools_src_dir" || ! -x "${tools_src_dir}/bin/mongodump" ]]; then
      rm -rf -- "$tools_tmpdir"
      echo "错误: Database Tools 安装包中未找到 mongodump" >&2
      return 1
    fi
    cp -f "${tools_src_dir}"/bin/* "${env_app_dir}/bin/" 2>/dev/null || return 1
    echo "Database Tools 安装完成"
    rm -rf "$tools_tmpdir"
  fi

  # 验证安装结果
  if [[ ! -x "${env_app_dir}/bin/mongod" ]]; then
    color_printf red "错误: mongod 不存在" "安装目录: ${env_app_dir}/bin/"
    return 1
  fi

  create_mongo_symlinks || return 1
  # 二进制由 root 管理，mongod 用户只需要读取和执行权限。
  chown -R "${mongo_owner}:${mongo_owner}" "${env_app_dir}" || return 1
  # 安装脚本 umask=027，且 cp -a 会保留压缩包目录权限；显式开放目录
  # 遍历和二进制执行权限，避免 systemd User=mongod 以 203/EXEC 失败。
  chmod 0755 "${env_app_dir}" "${env_app_dir}/bin" || return 1
  find "${env_app_dir}/bin" -maxdepth 1 -type f -exec chmod 0755 {} + || return 1
  echo "MongoDB 安装完成: ${env_app_dir}"
}
#==============================================================#
#               计算 WiredTiger 缓存大小                       #
#==============================================================#
function calc_wt_cache() {
  local mem_kb=${os_memory_total}
  local mem_mb=$((mem_kb / 1024))
  local cache_mb=$(((mem_mb - 1024) / 2))

  # 与 WiredTiger 默认规则一致：(RAM - 1GB) 的 50%，且至少 256MB。
  (( cache_mb < 256 )) && cache_mb=256
  # MongoDB 配置项允许的上限为 10000GB；不把超大内存机器写成无效值。
  (( cache_mb > 10240000 )) && cache_mb=10240000
  wt_cache_size_mb=$cache_mb
  mongo_memory_reserve_mb=$((mem_mb - cache_mb))
  wt_cache_size_gb=$(awk -v mb="$cache_mb" 'BEGIN { printf "%.2f", mb / 1024 }') || return 1

  printf '内存画像: 有效内存=%dMB, WiredTiger=%dMB (%sGB), OS/文件缓存/连接预留=%dMB\n' \
    "$mem_mb" "$wt_cache_size_mb" "$wt_cache_size_gb" "$mongo_memory_reserve_mb"
}
#==============================================================#
#             生成 MongoDB 配置文件                             #
#==============================================================#
function conf_mongodb() {
  log_print "生成 MongoDB 配置文件"

  # 从已安装目录重新检测版本号
  if [[ -x "${env_app_dir}/bin/mongod" ]]; then
    local _ver_line
    _ver_line=$("${env_app_dir}/bin/mongod" --version 2>/dev/null | head -1)
    local _ver_str
    _ver_str=$(echo "$_ver_line" | grep -oP '\d+\.\d+\.\d+')
    if [[ -n "$_ver_str" ]]; then
      mongo_major_ver=$(echo "$_ver_str" | cut -d. -f1)
      mongo_minor_ver=$(echo "$_ver_str" | cut -d. -f2)
      mongo_patch_ver=$(echo "$_ver_str" | cut -d. -f3)
      echo "检测到 MongoDB 版本: ${_ver_str} (major=${mongo_major_ver}, minor=${mongo_minor_ver})"
    fi
  fi

  calc_wt_cache || return 1

  local local_ip
  local_ip=$(get_local_ip)
  local_ip="${local_ip:-127.0.0.1}"

  # WiredTiger 默认 oplog 规则：使用数据卷可用空间的 5%，最小约 990MB、
  # 最大 50GB。只在副本集模式计算，避免单机配置产生无意义参数。
  if [[ "$mongo_install_mode" == "replicaset" ]] && (( oplog_size_mb == 0 )); then
    local disk_available_mb
    disk_available_mb=$(df -Pm "${data_dir}" 2>/dev/null | awk 'NR==2{print $4}')
    disk_available_mb=${disk_available_mb:-51200}
    oplog_size_mb=$((disk_available_mb * 5 / 100))
    (( oplog_size_mb < 990 )) && oplog_size_mb=990
    (( oplog_size_mb > 51200 )) && oplog_size_mb=51200
    printf 'Oplog 自动配置: 可用空间=%dMB, oplog=%dMB\n' "$disk_available_mb" "$oplog_size_mb"
  fi

  # ============ 版本感知: storage.journal 配置 ============
  # MongoDB 6.1+ 移除了 storage.journal.enabled (journal 始终开启)
  # MongoDB 4.x/5.x/6.0 仍使用该选项
  local journal_conf=""
  if mongo_supports_journal_option "$mongo_major_ver" "$mongo_minor_ver"; then
    journal_conf="  journal:
    enabled: true"
  fi

  # ============ 副本集配置段 ============
  local repl_conf=""
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    # enableMajorityReadConcern: MongoDB 5.0+ 始终为 true 且不可配置
    if mongo_supports_config_option replication.enableMajorityReadConcern \
      "$mongo_major_ver" "$mongo_minor_ver" "$mongo_patch_ver"; then
      repl_conf="replication:
  replSetName: \"${repl_set_name}\"
  oplogSizeMB: ${oplog_size_mb}
  enableMajorityReadConcern: true"
    else
      repl_conf="replication:
  replSetName: \"${repl_set_name}\"
  oplogSizeMB: ${oplog_size_mb}"
    fi
  fi

  # ============ 认证配置段 ============
  local security_conf="security:
  authorization: \"disabled\""
  if [[ "$mongo_auth_enabled" == "Y" ]]; then
    if [[ "$mongo_install_mode" == "replicaset" ]]; then
      if [[ "$mongo_cluster_auth_mode" == "x509" ]]; then
        security_conf="security:
  authorization: \"enabled\"
  clusterAuthMode: x509"
      else
        security_conf="security:
  authorization: \"enabled\"
  keyFile: \"${mongo_keyfile}\""
      fi
    else
      security_conf="security:
  authorization: \"enabled\""
    fi
  fi

  local tls_conf=""
  if [[ "$mongo_tls_enabled" == "Y" ]]; then
    tls_conf="  tls:
    mode: requireTLS
    certificateKeyFile: \"${mongo_tls_cert_path}\"
    CAFile: \"${mongo_tls_ca_path}\"
    allowConnectionsWithoutCertificates: true"
    if [[ "$mongo_cluster_auth_mode" == "x509" ]]; then
      tls_conf="${tls_conf}
    clusterFile: \"${mongo_tls_cert_path}\""
    fi
  fi

  # ============ WiredTiger 配置 ============
  local wt_conf="  wiredTiger:
    engineConfig:
      cacheSizeGB: ${wt_cache_size_gb}
      journalCompressor: snappy
      directoryForIndexes: true
    collectionConfig:
      blockCompressor: snappy
    indexConfig:
      prefixCompression: true"

  # ============ 版本感知: setParameter ============
  local set_param="setParameter:
  enableLocalhostAuthBypass: true"

  # ============ 生成配置文件 ============
  {
    cat <<CONFEOF
# MongoDB 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 版本: ${mongo_major_ver}.${mongo_minor_ver}.${mongo_patch_ver}
# 模式: ${mongo_install_mode}

systemLog:
  destination: file
  path: "${log_dir}/mongod.log"
  logAppend: true
  logRotate: reopen
  verbosity: 0

storage:
  dbPath: "${data_dir}/db"
  directoryPerDB: true
${journal_conf}
${wt_conf}

processManagement:
  fork: false
  pidFilePath: "${pid_dir}/mongod.pid"
  timeZoneInfo: /usr/share/zoneinfo

net:
  port: ${mongo_port}
  bindIp: "${mongo_bind_ip}"
  maxIncomingConnections: ${max_connections}
  ipv6: false
${tls_conf}

${security_conf}

${repl_conf}

${set_param}
CONFEOF
  } > "${env_base_dir}/mongod.conf" || return 1

  # 清理配置文件中的空行 (空 journal_conf/repl_conf 段可能导致多余空行)
  sed -i '/^$/N;/^\n$/d' "${env_base_dir}/mongod.conf" || return 1

  chown "${mongo_owner}:${mongo_owner}" "${env_base_dir}/mongod.conf" || return 1
  chmod 640 "${env_base_dir}/mongod.conf" || return 1

  echo "MongoDB 配置文件已生成: ${env_base_dir}/mongod.conf"
}
#==============================================================#
#             生成 keyFile (副本集认证)                         #
#==============================================================#
function generate_keyfile() {
  log_print "生成副本集 keyFile"

  if [[ "$mongo_install_mode" != "replicaset" || "$mongo_auth_enabled" != "Y" || "$mongo_cluster_auth_mode" != "keyFile" ]]; then
    echo "未启用 keyFile 成员认证，跳过 keyFile 生成"
    return 0
  fi

  if [[ -f "$mongo_keyfile" ]]; then
    chown "${mongo_owner}:${mongo_owner}" "$mongo_keyfile" || return 1
    chmod 400 "$mongo_keyfile" || return 1
    echo "keyFile 已存在: ${mongo_keyfile}"
    return 0
  fi

  openssl rand -base64 756 > "$mongo_keyfile" || return 1
  chown "${mongo_owner}:${mongo_owner}" "$mongo_keyfile" || return 1
  chmod 400 "$mongo_keyfile" || return 1
  echo "keyFile 已生成: ${mongo_keyfile}"
}
#==============================================================#
#             创建 systemd 服务                                #
#==============================================================#
function create_systemd_service() {
  log_print "创建 systemd 服务文件"
  (( mongo_resource_profile_ready == 1 )) || calculate_resource_profile || return 1

  if (( HAS_SYSTEMD == 0 )); then
    echo "未检测到 systemd，跳过服务创建"
    return 0
  fi

  local systemd_ver
  systemd_ver=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')
  systemd_ver=${systemd_ver:-0}

  local security_opts="PrivateTmp=yes
ProtectSystem=full"
  if (( systemd_ver >= 231 )); then
    security_opts="${security_opts}
ReadWritePaths=${env_base_dir} ${data_dir}"
  fi

  # NUMA 优化: 使用 numactl --interleave=all 启动 (官方推荐)
  local exec_prefix="" numactl_path=""
  numactl_path=$(command -v numactl 2>/dev/null || true)
  if [[ "$numactl_path" == /* ]]; then
    # CentOS 7 的 systemd 会拒绝非绝对路径的 ExecStart 第一个可执行文件。
    exec_prefix="${numactl_path} --interleave=all "
  fi

  cat > /etc/systemd/system/mongod.service <<SVCEOF || return 1
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.com/manual
After=network-online.target mongodb-readahead.service mongodb-thp.service disable-thp.service
Wants=network-online.target

[Service]
Type=simple
User=${mongo_owner}
Group=${mongo_owner}
UMask=0027
ExecStart=${exec_prefix}${env_app_dir}/bin/mongod --config ${env_base_dir}/mongod.conf
ExecStop=/bin/kill -s SIGTERM \$MAINPID
ExecReload=/bin/kill -s SIGHUP \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=300

# 资源限制
LimitNOFILE=${mongo_nofile_limit}
LimitNPROC=${mongo_nproc_limit}
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitCORE=infinity
LimitMEMLOCK=infinity

# 安全加固
${security_opts}

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload >/dev/null || {
    echo "错误: systemd daemon-reload 失败" >&2
    return 1
  }
  systemctl enable mongod.service >/dev/null || {
    echo "错误: 无法启用 mongod.service" >&2
    return 1
  }

  echo "systemd 服务已创建并启用"
}
#==============================================================#
#             创建受保护的本地认证材料                         #
#==============================================================#
function escape_yaml_double_quoted() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

function escape_js_single_quoted() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\'/\\\'}
  printf '%s' "$value"
}

function create_auth_material() {
  log_print "创建本地认证配置"
  if [[ "$mongo_auth_enabled" != "Y" ]]; then
    rm -f -- "$mongo_tools_config" "$mongo_auth_js" || return 1
    echo "认证未启用，不生成凭据文件"
    return 0
  fi

  get_mongo_shell >/dev/null || {
    echo "错误: 启用认证时必须安装 mongosh 或 legacy mongo shell" >&2
    return 1
  }

  local yaml_password js_user js_password
  yaml_password=$(escape_yaml_double_quoted "$mongo_admin_pass")
  js_user=$(escape_js_single_quoted "$mongo_admin_user")
  js_password=$(escape_js_single_quoted "$mongo_admin_pass")

  cat > "$mongo_tools_config" <<TOOLSEOF || return 1
password: "${yaml_password}"
TOOLSEOF

  cat > "$mongo_auth_js" <<AUTHEOF || return 1
const __mongoInstallerAdminDb = db.getSiblingDB('admin');
if (!__mongoInstallerAdminDb.auth('${js_user}', '${js_password}')) {
  throw new Error('MongoDB authentication failed');
}
db = __mongoInstallerAdminDb;
AUTHEOF

  chown "${mongo_owner}:${mongo_owner}" "$mongo_tools_config" "$mongo_auth_js" || return 1
  chmod 0640 "$mongo_tools_config" "$mongo_auth_js" || return 1
  echo "认证材料已写入受限文件（${mongo_owner}:${mongo_owner}, 0640）"
}
#==============================================================#
#             创建备份脚本                                     #
#==============================================================#
function create_backup_script() {
  log_print "创建备份脚本"

  local backup_status=0 mongodump_bin="${env_app_dir}/bin/mongodump" mongodump_help=""
  if [[ ! -x "$mongodump_bin" ]]; then
    echo "警告: 未安装 mongodump，将创建脚本但不会启用自动数据库备份"
    backup_status=3
  elif [[ "$mongo_auth_enabled" == "Y" ]]; then
    mongodump_help=$("$mongodump_bin" --help 2>&1) || {
      echo "错误: 无法检查 mongodump 功能: ${mongodump_bin}" >&2
      return 1
    }
    if [[ "$mongodump_help" != *"--config"* ]]; then
      echo "错误: 当前 mongodump 不支持 --config，无法安全读取认证凭据；请升级 Database Tools" >&2
      return 1
    fi
  fi

  cat > "${scripts_dir}/mongo_backup.sh" <<'BAKEOF' || return 1
#!/bin/bash
#==============================================================#
# MongoDB 备份脚本
# 支持 mongodump 逻辑备份
#==============================================================#
set -o pipefail
umask 077

MONGO_APP_DIR="MONGO_APP_DIR_PLACEHOLDER"
MONGO_BASE_DIR="MONGO_BASE_DIR_PLACEHOLDER"
MONGO_DATA_DIR="MONGO_DATA_DIR_PLACEHOLDER"
BACKUP_DIR="MONGO_BACKUP_DIR_PLACEHOLDER"
LOG_FILE="MONGO_LOG_DIR_PLACEHOLDER/mongo_backup.log"
RETENTION_DAYS=MONGO_RETENTION_PLACEHOLDER
LOCAL_IP="MONGO_LOCAL_IP_PLACEHOLDER"
MONGO_PORT="MONGO_PORT_PLACEHOLDER"
INSTALL_MODE="MONGO_INSTALL_MODE_PLACEHOLDER"
AUTH_ENABLED="MONGO_AUTH_ENABLED_PLACEHOLDER"
TLS_ENABLED="MONGO_TLS_ENABLED_PLACEHOLDER"
TLS_CA_FILE="MONGO_TLS_CA_FILE_PLACEHOLDER"
ADMIN_USER="MONGO_ADMIN_USER_PLACEHOLDER"
TOOLS_CONFIG="MONGO_TOOLS_CONFIG_PLACEHOLDER"
exit_code=0

# cron/su 可能继承 root 私有目录作为当前工作目录；先切换到 mongod 可遍历目录。
cd "$MONGO_BASE_DIR" || exit 1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

backup_date=$(date +%Y%m%d_%H%M%S)
backup_path="${BACKUP_DIR}/${backup_date}"
if ! mkdir -p "$backup_path"; then
  log "错误: 无法创建备份目录 $backup_path"
  exit 1
fi

log "开始 MongoDB 备份... (模式: ${INSTALL_MODE})"

# 备份 mongod.conf
if [[ -f "${MONGO_BASE_DIR}/mongod.conf" ]]; then
  if cp -f "${MONGO_BASE_DIR}/mongod.conf" "${backup_path}/"; then
    log "配置文件备份完成"
  else
    log "警告: 配置文件备份失败"
    exit_code=1
  fi
fi

# mongodump 逻辑备份
MONGODUMP="${MONGO_APP_DIR}/bin/mongodump"
if [[ -x "$MONGODUMP" ]]; then
  dump_args=(--host "${LOCAL_IP}" --port "${MONGO_PORT}" --out "${backup_path}/dump" --gzip)
  if [[ "$INSTALL_MODE" == "replicaset" ]]; then
    dump_args+=(--oplog)
  fi
  if [[ "$AUTH_ENABLED" == "Y" ]]; then
    dump_args+=(--config "$TOOLS_CONFIG" --username "$ADMIN_USER" --authenticationDatabase admin)
  fi
  if [[ "$TLS_ENABLED" == "Y" ]]; then
    dump_args+=(--ssl --sslCAFile "$TLS_CA_FILE")
  fi
  if "$MONGODUMP" "${dump_args[@]}" 2>>"$LOG_FILE"; then
    log "mongodump 备份完成"
  else
    log "警告: mongodump 执行失败"
    exit_code=1
  fi
else
  log "警告: mongodump 不存在，跳过数据库备份"
  exit_code=1
fi

# 压缩备份
cd "$BACKUP_DIR" && tar czf "${backup_date}.tar.gz" "${backup_date}" && rm -rf "${backup_date}"
if [[ $? -ne 0 ]]; then
  log "错误: 备份压缩失败"
  exit_code=1
else
  log "备份压缩完成: ${BACKUP_DIR}/${backup_date}.tar.gz"
fi

# 清理过期备份
expired_count=$(find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +${RETENTION_DAYS} 2>/dev/null | wc -l)
if ! find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null; then
  log "警告: 部分过期备份清理失败"
  exit_code=1
fi
remaining_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
log "清理 ${RETENTION_DAYS} 天前备份 ${expired_count} 个, 剩余备份数: ${remaining_count}"
log "备份流程结束"
exit $exit_code
BAKEOF

  sed -i \
    -e "s|MONGO_APP_DIR_PLACEHOLDER|${env_app_dir}|g" \
    -e "s|MONGO_BASE_DIR_PLACEHOLDER|${env_base_dir}|g" \
    -e "s|MONGO_DATA_DIR_PLACEHOLDER|${data_dir}|g" \
    -e "s|MONGO_BACKUP_DIR_PLACEHOLDER|${backup_dir}|g" \
    -e "s|MONGO_LOG_DIR_PLACEHOLDER|${log_dir}|g" \
    -e "s|MONGO_RETENTION_PLACEHOLDER|${backup_retention_days}|g" \
    -e "s|MONGO_LOCAL_IP_PLACEHOLDER|127.0.0.1|g" \
    -e "s|MONGO_PORT_PLACEHOLDER|${mongo_port}|g" \
    -e "s|MONGO_INSTALL_MODE_PLACEHOLDER|${mongo_install_mode}|g" \
    -e "s|MONGO_AUTH_ENABLED_PLACEHOLDER|${mongo_auth_enabled}|g" \
    -e "s|MONGO_TLS_ENABLED_PLACEHOLDER|${mongo_tls_enabled}|g" \
    -e "s|MONGO_TLS_CA_FILE_PLACEHOLDER|${mongo_tls_ca_path}|g" \
    -e "s|MONGO_ADMIN_USER_PLACEHOLDER|${mongo_admin_user}|g" \
    -e "s|MONGO_TOOLS_CONFIG_PLACEHOLDER|${mongo_tools_config}|g" \
    "${scripts_dir}/mongo_backup.sh" || return 1

  chmod 750 "${scripts_dir}/mongo_backup.sh" || return 1
  chown "${mongo_owner}:${mongo_owner}" "${scripts_dir}/mongo_backup.sh" || return 1
  return "$backup_status"
}
#==============================================================#
#             创建监控脚本                                     #
#==============================================================#
function create_monitor_script() {
  log_print "创建监控脚本"

  cat > "${scripts_dir}/mongo_monitor.sh" <<'MONEOF' || return 1
#!/bin/bash
#==============================================================#
# MongoDB 健康检查与监控脚本
#==============================================================#
set -o pipefail
umask 077

MONGO_APP_DIR="MONGO_APP_DIR_PLACEHOLDER"
MONGO_BASE_DIR="MONGO_BASE_DIR_PLACEHOLDER"
MONGO_PORT="MONGO_PORT_PLACEHOLDER"
LOG_FILE="MONGO_LOG_DIR_PLACEHOLDER/mongo_monitor.log"
LOCAL_IP="MONGO_LOCAL_IP_PLACEHOLDER"
INSTALL_MODE="MONGO_INSTALL_MODE_PLACEHOLDER"
AUTH_ENABLED="MONGO_AUTH_ENABLED_PLACEHOLDER"
AUTH_JS="MONGO_AUTH_JS_PLACEHOLDER"
TLS_ENABLED="MONGO_TLS_ENABLED_PLACEHOLDER"
TLS_CA_FILE="MONGO_TLS_CA_FILE_PLACEHOLDER"
monitor_exit_code=0

# mongosh 基于 Node.js，启动时需要可访问的当前工作目录。
cd "$MONGO_BASE_DIR" || exit 1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 1. 进程检查 (PID 文件优先，回退到端口检测)
mongod_pid=""
if [[ -f "MONGO_PID_DIR_PLACEHOLDER/mongod.pid" ]]; then
  mongod_pid=$(cat "MONGO_PID_DIR_PLACEHOLDER/mongod.pid" 2>/dev/null)
  if [[ -n "$mongod_pid" ]] && ! kill -0 "$mongod_pid" 2>/dev/null; then
    mongod_pid=""
  fi
fi
if [[ -z "$mongod_pid" ]]; then
  mongod_pid=$(pgrep -f "mongod.*--config" 2>/dev/null | head -1)
fi
if [[ -z "$mongod_pid" ]]; then
  log "CRITICAL: mongod 进程不存在"
  exit 1
fi
log "INFO: mongod PID=${mongod_pid}"

# 2. 端口检查
socket_list=$(ss -tln 2>/dev/null)
if [[ "$socket_list" != *":${MONGO_PORT} "* ]]; then
  log "CRITICAL: MongoDB 端口 ${MONGO_PORT} 未监听"
  exit 1
fi

# 3. 连通性检查 (尝试 ping)
SHELL_CMD=""
if [[ -x "${MONGO_APP_DIR}/bin/mongosh" ]]; then
  SHELL_CMD="${MONGO_APP_DIR}/bin/mongosh"
elif [[ -x "${MONGO_APP_DIR}/bin/mongo" ]]; then
  SHELL_CMD="${MONGO_APP_DIR}/bin/mongo"
fi

if [[ -n "$SHELL_CMD" ]]; then
  run_shell_eval() {
    local expression="$1"
    local -a shell_args=(--host "${LOCAL_IP}" --port "${MONGO_PORT}" --quiet)
    if [[ "$AUTH_ENABLED" == "Y" ]]; then
      expression="load('${AUTH_JS}'); ${expression}"
    fi
    if [[ "$TLS_ENABLED" == "Y" ]]; then
      shell_args+=(--tls --tlsCAFile "$TLS_CA_FILE")
    fi
    "$SHELL_CMD" "${shell_args[@]}" --eval "$expression"
  }

  ping_result=$(run_shell_eval "var r=db.adminCommand('ping'); print('MONGO_MONITOR_PING=' + r.ok)" 2>/dev/null)
  if [[ "$ping_result" == *"MONGO_MONITOR_PING=1"* ]]; then
    log "INFO: MongoDB ping 成功"
  else
    log "CRITICAL: MongoDB ping 或认证失败"
    monitor_exit_code=1
  fi

  # 4. 副本集状态检查
  if [[ "$INSTALL_MODE" == "replicaset" ]]; then
    rs_status=$(run_shell_eval "
      var s = rs.status();
      var primary = 0, secondary = 0, down = 0;
      s.members.forEach(function(m) {
        if (m.stateStr === 'PRIMARY') primary++;
        else if (m.stateStr === 'SECONDARY') secondary++;
        else down++;
      });
      print('primary=' + primary + ',secondary=' + secondary + ',down=' + down);
    " 2>/dev/null)
    if [[ "$rs_status" == *"primary=1"* ]]; then
      log "INFO: 副本集状态: ${rs_status}"
    else
      log "CRITICAL: 副本集无可用 PRIMARY: ${rs_status:-无法读取状态}"
      monitor_exit_code=1
    fi
  fi

  # 5. 连接数检查
  conn_info=$(run_shell_eval "
    var s = db.serverStatus();
    print('current=' + s.connections.current + ',available=' + s.connections.available);
  " 2>/dev/null)
  if [[ "$conn_info" == *"current="* ]]; then
    log "INFO: 连接数: ${conn_info}"
  else
    log "WARNING: 无法读取连接数"
    monitor_exit_code=1
  fi
else
  log "CRITICAL: 未找到 mongosh 或 legacy mongo shell，无法执行数据库健康检查"
  monitor_exit_code=1
fi

# 6. JVM/进程内存使用
if [[ -n "$mongod_pid" ]]; then
  local_rss=$(awk '/VmRSS/{print $2}' /proc/${mongod_pid}/status 2>/dev/null)
  local_rss_mb=$((${local_rss:-0} / 1024))
  log "INFO: mongod RSS=${local_rss_mb}MB"
fi

# 7. 磁盘使用
data_usage=$(du -sh "MONGO_DATA_DIR_PLACEHOLDER" 2>/dev/null | awk '{print $1}')
log "INFO: 数据目录磁盘使用: ${data_usage}"

data_disk_pct=$(df "MONGO_DATA_DIR_PLACEHOLDER" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
if [[ -n "$data_disk_pct" ]] && (( data_disk_pct > 85 )); then
  log "WARNING: 数据分区磁盘使用率 ${data_disk_pct}% 超过 85% 阈值"
fi

log "STATUS: mode=${INSTALL_MODE}, pid=${mongod_pid}, port=${MONGO_PORT}, rss=${local_rss_mb}MB, disk=${data_usage}"
exit "$monitor_exit_code"
MONEOF

  sed -i \
    -e "s|MONGO_APP_DIR_PLACEHOLDER|${env_app_dir}|g" \
    -e "s|MONGO_BASE_DIR_PLACEHOLDER|${env_base_dir}|g" \
    -e "s|MONGO_PORT_PLACEHOLDER|${mongo_port}|g" \
    -e "s|MONGO_LOG_DIR_PLACEHOLDER|${log_dir}|g" \
    -e "s|MONGO_LOCAL_IP_PLACEHOLDER|127.0.0.1|g" \
    -e "s|MONGO_DATA_DIR_PLACEHOLDER|${data_dir}|g" \
    -e "s|MONGO_INSTALL_MODE_PLACEHOLDER|${mongo_install_mode}|g" \
    -e "s|MONGO_PID_DIR_PLACEHOLDER|${pid_dir}|g" \
    -e "s|MONGO_AUTH_ENABLED_PLACEHOLDER|${mongo_auth_enabled}|g" \
    -e "s|MONGO_AUTH_JS_PLACEHOLDER|${mongo_auth_js}|g" \
    -e "s|MONGO_TLS_ENABLED_PLACEHOLDER|${mongo_tls_enabled}|g" \
    -e "s|MONGO_TLS_CA_FILE_PLACEHOLDER|${mongo_tls_ca_path}|g" \
    "${scripts_dir}/mongo_monitor.sh" || return 1

  chmod 750 "${scripts_dir}/mongo_monitor.sh" || return 1
  chown "${mongo_owner}:${mongo_owner}" "${scripts_dir}/mongo_monitor.sh" || return 1
}
#==============================================================#
#             配置 crontab                                     #
#==============================================================#
function conf_crontab() {
  log_print "配置定时任务"

  local cron_file="/etc/cron.d/mongodb-shell-install"
  {
    cat <<CRONEOF
# MongoDBShellInstall 管理的定时任务
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=${env_base_dir}
CRONEOF
    if [[ -x "${env_app_dir}/bin/mongodump" ]]; then
      printf '# 每天凌晨 2 点备份\n'
      printf '0 2 * * * %s "%s/mongo_backup.sh" >> "%s/mongo_backup_cron.log" 2>&1\n' "$mongo_owner" "$scripts_dir" "$log_dir"
    else
      printf '# 未安装 mongodump，未启用自动数据库备份\n'
    fi
    printf '# 每 5 分钟健康检查\n'
    printf '*/5 * * * * %s "%s/mongo_monitor.sh" >> "%s/mongo_monitor_cron.log" 2>&1\n' "$mongo_owner" "$scripts_dir" "$log_dir"
  } > "$cron_file" || return 1
  chown root:root "$cron_file" || return 1
  chmod 0644 "$cron_file" || return 1

  # 启用并重载 cron；失败必须阻止安装继续，避免产生“已生效”的假象。
  local cron_started=0
  if (( HAS_SYSTEMD )); then
    systemctl enable --now crond.service >/dev/null 2>&1 && cron_started=1
    if (( cron_started == 0 )); then
      systemctl enable --now cron.service >/dev/null 2>&1 && cron_started=1
    fi
  else
    if command -v service &>/dev/null; then
      service crond restart >/dev/null 2>&1 && cron_started=1
      if (( cron_started == 0 )); then
        service cron restart >/dev/null 2>&1 && cron_started=1
      fi
    elif pgrep -x crond >/dev/null 2>&1 || pgrep -x cron >/dev/null 2>&1; then
      cron_started=1
    fi
  fi
  (( cron_started == 1 )) || {
    echo "错误: cron/crond 服务无法启动，定时任务未生效" >&2
    return 1
  }
  echo "定时任务已配置"
}
#==============================================================#
#             配置日志轮转                                     #
#==============================================================#
function conf_logrotate() {
  log_print "配置日志轮转"

  cat > /etc/logrotate.d/mongodb <<LREOF || return 1
${log_dir}/mongod.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y%m%d
    su ${mongo_owner} ${mongo_owner}
}
LREOF
  if command -v logrotate &>/dev/null; then
    logrotate --debug /etc/logrotate.d/mongodb >/dev/null 2>&1 || {
      echo "错误: logrotate 配置校验失败" >&2
      return 1
    }
  else
    echo "警告: 未找到 logrotate，配置文件已生成但不会自动轮转"
    return 3
  fi
  echo "日志轮转已配置"
}
#==============================================================#
#             启动 MongoDB                                     #
#==============================================================#
function start_mongodb() {
  log_print "启动 MongoDB"

  if (( HAS_SYSTEMD )); then
    # restart 同时覆盖首次安装和同大版本补丁升级，确保运行中的进程确实
    # 切换到刚安装的二进制，而不是仅替换磁盘文件后保留旧进程。
    systemctl restart mongod.service || {
      systemctl status mongod.service --no-pager -l 2>&1 | tail -10
      return 1
    }
    local retries=0
    while (( retries < 60 )); do
      if systemctl is-active mongod.service &>/dev/null && port_is_listening "$mongo_port"; then
        echo "MongoDB 启动成功，端口 ${mongo_port} 已监听"
        return 0
      fi
      systemctl is-failed mongod.service &>/dev/null && break
      sleep 2
      ((retries++))
    done
    color_printf red "MongoDB 启动失败或端口等待超时"
    systemctl status mongod.service --no-pager -l 2>&1 | tail -10
    return 1
  else
    # 非 systemd 环境: fork 模式启动
    local _numactl=""
    if command -v numactl &>/dev/null; then
      _numactl="numactl --interleave=all"
    fi
    su -s /bin/bash "${mongo_owner}" -c "${_numactl} ${env_app_dir}/bin/mongod --config ${env_base_dir}/mongod.conf --fork"
    sleep 3
    # 使用 PID 文件或端口检测
    if [[ -f "${pid_dir}/mongod.pid" ]]; then
      local _pid
      _pid=$(cat "${pid_dir}/mongod.pid" 2>/dev/null)
      if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null; then
        echo "MongoDB 启动成功 (PID: ${_pid})"
        return 0
      fi
    fi
    # 回退: 检测端口
    if port_is_listening "$mongo_port"; then
      echo "MongoDB 启动成功 (端口 ${mongo_port} 已监听)"
    else
      color_printf red "MongoDB 启动失败"
      if [[ -f "${log_dir}/mongod.log" ]]; then
        echo "最近日志:"
        tail -5 "${log_dir}/mongod.log" | sed 's/^/  /'
      fi
      return 1
    fi
  fi
}
#==============================================================#
#             远程部署函数                                     #
#==============================================================#
function ensure_ssh_control_dir() {
  if [[ -n "$mongo_ssh_control_dir" && -d "$mongo_ssh_control_dir" && ! -L "$mongo_ssh_control_dir" ]]; then
    return 0
  fi
  mongo_ssh_control_dir=$(mktemp -d /tmp/mongo-ssh-control.XXXXXX) || return 1
  chmod 0700 "$mongo_ssh_control_dir" || return 1
  MONGO_INSTALL_TMPDIRS+=("$mongo_ssh_control_dir")
}

function remote_exec() {
  local host="$1"; shift
  ensure_ssh_control_dir || return 1
  local -a ssh_args=(
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=${ssh_known_hosts_file}"
    -o ConnectTimeout=10
    -o ControlMaster=auto
    -o ControlPersist=60
    -o "ControlPath=${mongo_ssh_control_dir}/%C"
    -p "$serverport"
  )
  if [[ -n "$ssh_identity_file" ]]; then
    ssh_args+=(-o IdentitiesOnly=yes -i "$ssh_identity_file")
  fi
  if [[ -n "$remote_root_pass" ]]; then
    SSHPASS="$remote_root_pass" sshpass -e ssh "${ssh_args[@]}" "root@${host}" "$@"
  else
    ssh_args+=(-o BatchMode=yes)
    ssh "${ssh_args[@]}" "root@${host}" "$@"
  fi
}

function remote_copy() {
  local src="$1" host="$2" dest="$3"
  ensure_ssh_control_dir || return 1
  local -a scp_args=(
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=${ssh_known_hosts_file}"
    -o ConnectTimeout=10
    -o ControlMaster=auto
    -o ControlPersist=60
    -o "ControlPath=${mongo_ssh_control_dir}/%C"
    -P "$serverport"
  )
  if [[ -n "$ssh_identity_file" ]]; then
    scp_args+=(-o IdentitiesOnly=yes -i "$ssh_identity_file")
  fi
  if [[ -n "$remote_root_pass" ]]; then
    SSHPASS="$remote_root_pass" sshpass -e scp "${scp_args[@]}" "$src" "root@${host}:${dest}"
  else
    scp_args+=(-o BatchMode=yes)
    scp "${scp_args[@]}" "$src" "root@${host}:${dest}"
  fi
}

function check_ssh_connectivity() {
  local host="$1"
  if ! remote_exec "$host" "echo OK" &>/dev/null; then
    color_printf red "SSH 连接失败: ${host}"
    return 1
  fi
  return 0
}

function resolve_cluster_endpoint_ip() {
  local endpoint="$1" resolved
  if check_ip "$endpoint"; then
    printf '%s' "$endpoint"
    return 0
  fi
  resolved=$(getent ahostsv4 "$endpoint" 2>/dev/null | awk '{print $1}' | sort -u | head -1)
  check_ip "$resolved" || return 1
  printf '%s' "$resolved"
}

function update_local_cluster_hosts() {
  local begin='# MongoDBShellInstall cluster hosts begin'
  local end='# MongoDBShellInstall cluster hosts end'
  local index backup_path
  if ! grep -Fqx "$begin" /etc/hosts 2>/dev/null; then
    backup_path="/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    cp -p /etc/hosts "$backup_path" || return 1
  fi
  sed -i "/^${begin}$/,/^${end}$/d" /etc/hosts || return 1
  printf '%s\n' "$begin" >> /etc/hosts || return 1
  for ((index=0; index<${#hosts_array[@]}; index++)); do
    printf '%s  %s\n' "${cluster_endpoint_ips_array[$index]}" "${hosts_array[$index]}" >> /etc/hosts || return 1
  done
  printf '%s\n' "$end" >> /etc/hosts || return 1
}

function build_remote_cluster_hosts_command() {
  local begin='# MongoDBShellInstall cluster hosts begin'
  local end='# MongoDBShellInstall cluster hosts end'
  local command index
  command="set -e; if ! grep -Fqx '${begin}' /etc/hosts 2>/dev/null; then cp -p /etc/hosts /etc/hosts.bak.\$(date +%Y%m%d%H%M%S); fi; sed -i '/^${begin}$/,/^${end}$/d' /etc/hosts; printf '%s\\n' '${begin}' >> /etc/hosts;"
  for ((index=0; index<${#hosts_array[@]}; index++)); do
    command+=" printf '%s  %s\\n' '${cluster_endpoint_ips_array[$index]}' '${hosts_array[$index]}' >> /etc/hosts;"
  done
  command+=" printf '%s\\n' '${end}' >> /etc/hosts"
  printf '%s' "$command"
}

function configure_cluster_host_mappings() {
  local index endpoint endpoint_ip local_ip remote_command
  local_ip=$(get_local_ip)
  cluster_endpoint_ips_array=()
  for endpoint in "${remote_ips_array[@]}"; do
    endpoint_ip=$(resolve_cluster_endpoint_ip "$endpoint") || {
      echo "错误: 无法将 SSH 端点解析为 IPv4: ${endpoint}" >&2
      return 1
    }
    cluster_endpoint_ips_array+=("$endpoint_ip")
  done
  update_local_cluster_hosts || return 1
  remote_command=$(build_remote_cluster_hosts_command) || return 1
  for ((index=0; index<${#remote_ips_array[@]}; index++)); do
    endpoint=${remote_ips_array[$index]}
    if is_local_host "$endpoint" "$local_ip"; then
      continue
    fi
    check_ssh_connectivity "$endpoint" || return 1
    remote_exec "$endpoint" "$remote_command" || {
      echo "错误: 无法在 SSH 端点 ${endpoint} 写入副本集主机映射" >&2
      return 1
    }
  done
  echo "已在 ${#hosts_array[@]} 个节点配置副本集主机名与 SSH 端点映射"
}

function check_cluster_connectivity() {
  log_print "检查集群节点连通性"
  local local_ip host endpoint index
  local_ip=$(get_local_ip)
  local fail=0

  configure_cluster_host_mappings || return 1
  for ((index=0; index<${#hosts_array[@]}; index++)); do
    host=${hosts_array[$index]}
    endpoint=${remote_ips_array[$index]}
    if ! getent ahostsv4 "$host" &>/dev/null; then
      echo "  ${host} ... DNS 解析失败"
      ((fail++))
      continue
    fi
    if is_local_host "$endpoint" "$local_ip"; then
      echo "  ${host} (${endpoint}, 本机) ... OK"
      continue
    fi
    if check_ssh_connectivity "$endpoint"; then
      local member check_command=""
      for member in "${hosts_array[@]}"; do
        check_command+="getent ahostsv4 '${member}' >/dev/null || exit 21; "
      done
      if remote_exec "$endpoint" "$check_command" &>/dev/null; then
        echo "  ${host} (${endpoint}) ... SSH 与成员 DNS 解析均正常"
      else
        echo "  ${host} (${endpoint}) ... 远程节点无法解析全部副本集主机名"
        ((fail++))
      fi
    else
      ((fail++))
    fi
  done

  if (( fail > 0 )); then
    color_printf red "有 ${fail} 个节点连通性检查失败"
    return 1
  fi
}

function calculate_app_fingerprint() {
  local app_dir="${1:-$env_app_dir}"
  [[ -d "$app_dir/bin" ]] || return 1
  (
    cd "$app_dir" || exit 1
    while IFS= read -r relative_path; do
      sha256sum "$relative_path" || exit 1
    done < <(find bin -maxdepth 1 -type f -printf '%p\n' | LC_ALL=C sort)
  ) | sha256sum | awk '{print $1}'
}

function deploy_remote_node() {
  local member_host="$1"
  local requested_endpoint="$2"
  local app_pkg="$3"
  local local_app_fingerprint="$4"
  local expected_version="$5"
  local -a deployment_endpoints=("$requested_endpoint")
  if [[ "$mongo_install_mode" == "single" ]]; then return 0; fi
  if [[ ${#deployment_endpoints[@]} -eq 0 ]]; then return 0; fi

  local local_ip
  local_ip=$(get_local_ip)
  local script_path="${software_dir}/${script_name}"

  local remote_count=0 remote_state

  for host in "${deployment_endpoints[@]}"; do
    if is_local_host "$host" "$local_ip"; then
      log_print "跳过本机: ${host}"
      continue
    fi

    ((remote_count++))
    log_print ">>> 部署远程节点: ${member_host} (${host})"

    # 1. 测试连通性
    if ! check_ssh_connectivity "$host"; then
      echo "错误: [${host}] SSH 连接失败" >&2
      return 1
    fi

    local remote_ip
    remote_ip=$(remote_exec "$host" "ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \\([0-9.]*\\).*/\\1/p' | head -1" 2>/dev/null)
    check_ip "$remote_ip" || {
      echo "错误: [${host}] 无法检测远程节点内网 IPv4 地址" >&2
      return 1
    }

    # 2. 分发脚本，远程执行 OS 优化
    log_print "  [${host}] OS 优化..."
    local remote_workdir="/tmp/mongodb-shell-install"
    remote_exec "$host" "install -d -o root -g root -m 0700 '${remote_workdir}'" || return 1
    if ! remote_copy "$script_path" "$host" "${remote_workdir}/${script_name}"; then
      echo "错误: [${host}] 脚本分发失败" >&2
      return 1
    fi
    local remote_node_bind_ip="${mongo_bind_ip}"
    if [[ ",${mongo_bind_ip}," != *",0.0.0.0,"* ]]; then
      remote_node_bind_ip="127.0.0.1,${remote_ip}"
    fi
    local remote_os_command="cd '${remote_workdir}' && bash '${script_name}' -m replicaset -n '${hostname}' --os-only -d '${env_base_dir}' --data-dir '${data_dir}' --backup-dir '${backup_dir}' -ou '${mongo_owner}' -p '${mongo_port}' --bind-ip '${remote_node_bind_ip}' --mongo-version '${mongo_major_ver}.${mongo_minor_ver}.${mongo_patch_ver}' --max-connections '${max_connections}'"
    local remote_os_output
    if ! remote_os_output=$(remote_exec "$host" "$remote_os_command" 2>&1); then
      printf '%s\n' "$remote_os_output" | sed "s/^/  [${host}] /"
      echo "错误: [${host}] OS 配置失败" >&2
      return 1
    fi
    printf '%s\n' "$remote_os_output" | sed "s/^/  [${host}] /"

    # 3. 创建用户和目录
    log_print "  [${host}] 创建用户与目录..."
    if ! remote_exec "$host" "
      set -e
      _nologin='/sbin/nologin'
      if [[ ! -f \"\$_nologin\" ]]; then _nologin='/usr/sbin/nologin'; fi
      if [[ ! -f \"\$_nologin\" ]]; then _nologin='/bin/false'; fi
      if ! getent group '${mongo_owner}' >/dev/null 2>&1; then
        if getent group 60300 >/dev/null 2>&1; then groupadd -r '${mongo_owner}'; else groupadd -g 60300 '${mongo_owner}'; fi
      fi
      if ! id '${mongo_owner}' &>/dev/null; then
        if getent passwd 60300 >/dev/null 2>&1; then useradd -r -g '${mongo_owner}' -s \"\$_nologin\" -M '${mongo_owner}'; else useradd -u 60300 -g '${mongo_owner}' -s \"\$_nologin\" -M '${mongo_owner}'; fi
      else
        usermod -g '${mongo_owner}' -s \"\$_nologin\" '${mongo_owner}'
      fi
      passwd -l '${mongo_owner}' &>/dev/null
      install -d -o '${mongo_owner}' -g '${mongo_owner}' -m 0750 '${env_base_dir}' '${scripts_dir}'
      install -d -o '${mongo_owner}' -g '${mongo_owner}' -m 0755 '${env_app_dir}'
      install -d -o '${mongo_owner}' -g '${mongo_owner}' -m 0750 '${data_dir}' '${data_dir}/db' '${data_dir}/configdb' '${log_dir}' '${backup_dir}' '${pid_dir}'
    "; then
      echo "错误: [${host}] 用户/目录创建失败" >&2
      return 1
    fi

    # 4. 版本和应用指纹都一致时跳过重复传输；仅版本相同但文件不同仍更新。
    remote_state=$(remote_exec "$host" "
      if [[ -x '${env_app_dir}/bin/mongod' ]]; then
        _version=\$('${env_app_dir}/bin/mongod' --version 2>/dev/null | sed -n 's/^db version v\\([0-9.]*\\).*/\\1/p' | head -1)
        _fingerprint=\$(
          (
            cd '${env_app_dir}' || exit 1
            while IFS= read -r _path; do sha256sum \"\$_path\" || exit 1; done < <(find bin -maxdepth 1 -type f -printf '%p\\n' | LC_ALL=C sort)
          ) | sha256sum | awk '{print \$1}'
        )
        printf '%s|%s' \"\$_version\" \"\$_fingerprint\"
      fi
    " 2>/dev/null || true)
    if [[ "$remote_state" == "${expected_version}|${local_app_fingerprint}" ]]; then
      echo "  [${host}] MongoDB ${expected_version} 应用指纹一致，跳过二进制传输与解压"
    else
      log_print "  [${host}] 分发 MongoDB..."
      if ! remote_copy "$app_pkg" "$host" "${remote_workdir}/mongo-app-installed.tar.gz"; then
        echo "错误: [${host}] MongoDB 包分发失败" >&2
        return 1
      fi
      if ! remote_exec "$host" "
        set -e
        if [[ -n \"\$(find '${env_app_dir}' -mindepth 1 -print -quit 2>/dev/null)\" ]]; then
          _previous_app_dir='${env_app_dir}.backup.'\$(date +%Y%m%d%H%M%S)
          mv '${env_app_dir}' \"\$_previous_app_dir\"
          chown -R '${mongo_owner}:${mongo_owner}' \"\$_previous_app_dir\"
        else
          rmdir '${env_app_dir}'
        fi
        tar xzf '${remote_workdir}/mongo-app-installed.tar.gz' -C '${env_base_dir}'
        rm -f '${remote_workdir}/mongo-app-installed.tar.gz'
        for cmd in mongod mongos mongosh mongo mongodump mongorestore mongoexport mongoimport mongostat mongotop; do
          if [[ -x '${env_app_dir}/bin/'\$cmd ]]; then ln -sf '${env_app_dir}/bin/'\$cmd /usr/local/bin/\$cmd; fi
        done
        chown -R '${mongo_owner}:${mongo_owner}' '${env_app_dir}'
        chmod 0755 '${env_app_dir}' '${env_app_dir}/bin'
        find '${env_app_dir}/bin' -maxdepth 1 -type f -exec chmod 0755 {} +
      "; then
        echo "错误: [${host}] MongoDB 解压失败" >&2
        return 1
      fi
    fi

    # 5. 分发配置文件和 keyFile
    log_print "  [${host}] 分发配置..."
    local node_conf
    node_conf=$(mktemp /tmp/mongod-node.XXXXXX.conf) || return 1
    MONGO_INSTALL_TMPFILES+=("$node_conf")
    sed "s|^  bindIp:.*|  bindIp: \"${remote_node_bind_ip}\"|" "${env_base_dir}/mongod.conf" > "$node_conf" || return 1
    remote_copy "$node_conf" "$host" "${env_base_dir}/mongod.conf" || return 1
    rm -f "$node_conf"
    if [[ "$mongo_auth_enabled" == "Y" && "$mongo_cluster_auth_mode" == "keyFile" && -f "${mongo_keyfile}" ]]; then
      remote_copy "${mongo_keyfile}" "$host" "${mongo_keyfile}" || return 1
      remote_exec "$host" "chown '${mongo_owner}:${mongo_owner}' '${mongo_keyfile}' && chmod 400 '${mongo_keyfile}'" || return 1
    fi
    if [[ "$mongo_tls_enabled" == "Y" ]]; then
      local remote_tls_source
      remote_tls_source=$(tls_cert_source_for_host "$member_host") || return 1
      remote_exec "$host" "install -d -o '${mongo_owner}' -g '${mongo_owner}' -m 0750 '${mongo_tls_dir}'" || return 1
      remote_copy "$mongo_tls_ca_path" "$host" "$mongo_tls_ca_path" || return 1
      remote_copy "$remote_tls_source" "$host" "$mongo_tls_cert_path" || return 1
      remote_exec "$host" "chown '${mongo_owner}:${mongo_owner}' '${mongo_tls_ca_path}' && chmod 640 '${mongo_tls_ca_path}'; chown '${mongo_owner}:${mongo_owner}' '${mongo_tls_cert_path}' && chmod 600 '${mongo_tls_cert_path}'" || return 1
    fi
    remote_exec "$host" "chown '${mongo_owner}:${mongo_owner}' '${env_base_dir}/mongod.conf' && chmod 640 '${env_base_dir}/mongod.conf'" || return 1

    # 6. 创建 systemd 服务
    log_print "  [${host}] 创建并启动服务..."
    local _exec_prefix=""
    local _numactl_path
    _numactl_path=$(remote_exec "$host" "command -v numactl 2>/dev/null || true" 2>/dev/null)
    if [[ "$_numactl_path" =~ ^/[A-Za-z0-9_./+-]+$ ]]; then
      _exec_prefix="${_numactl_path} --interleave=all "
    fi

    if ! remote_exec "$host" "
      set -e
      cat > /etc/systemd/system/mongod.service <<'RSVCEOF'
[Unit]
Description=MongoDB Database Server
After=network-online.target mongodb-readahead.service mongodb-thp.service disable-thp.service
Wants=network-online.target

[Service]
Type=simple
User=${mongo_owner}
Group=${mongo_owner}
UMask=0027
ExecStart=${_exec_prefix}${env_app_dir}/bin/mongod --config ${env_base_dir}/mongod.conf
ExecStop=/bin/kill -s SIGTERM \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStopSec=300
LimitNOFILE=${mongo_nofile_limit}
LimitNPROC=${mongo_nproc_limit}
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitCORE=infinity
LimitMEMLOCK=infinity
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=${env_base_dir} ${data_dir}

[Install]
WantedBy=multi-user.target
RSVCEOF
      systemctl daemon-reload
      systemctl enable mongod.service
      systemctl restart mongod.service
      sleep 5
      if systemctl is-active mongod.service &>/dev/null; then
        echo 'MONGO_START_OK'
      else
        echo 'MONGO_START_FAIL'
        systemctl status mongod.service --no-pager -l 2>&1 | tail -5
        exit 1
      fi
    "; then
      echo "错误: [${host}] 创建或启动 systemd 服务失败" >&2
      return 1
    fi
    local _start_result
    _start_result=$(remote_exec "$host" "systemctl is-active mongod.service 2>/dev/null" 2>/dev/null)
    if [[ "$_start_result" == *"active"* ]]; then
      echo "  [${host}] MongoDB 启动成功"
    else
      echo "  [${host}] MongoDB 启动失败"
      return 1
    fi
  done

  echo "所有远程节点部署完成 (${remote_count} 个)"
}

function deploy_remote_nodes() {
  [[ "$mongo_install_mode" == "replicaset" ]] || return 0
  local local_ip host endpoint log_file pid index batch_count=0 failure=0 remote_count=0
  local app_pkg local_app_fingerprint expected_version
  local -a remote_hosts=() remote_endpoints=()
  local -a batch_pids=() batch_logs=() batch_hosts=() batch_endpoints=()
  local_ip=$(get_local_ip)

  for ((index=0; index<${#hosts_array[@]}; index++)); do
    host=${hosts_array[$index]}
    endpoint=${remote_ips_array[$index]}
    if is_local_host "$endpoint" "$local_ip"; then
      log_print "跳过本机: ${host} (${endpoint})"
      continue
    fi
    remote_hosts+=("$host")
    remote_endpoints+=("$endpoint")
  done

  remote_count=${#remote_hosts[@]}
  (( remote_count > 0 )) || {
    echo "没有需要部署的远程节点"
    return 0
  }

  # 所有并行任务复用同一份只读压缩包，避免按节点重复打包。
  app_pkg=$(mktemp /tmp/mongo-app-installed.XXXXXX.tar.gz) || return 1
  MONGO_INSTALL_TMPFILES+=("$app_pkg")
  log_print "打包 MongoDB 安装目录（供 ${remote_count} 个远程节点复用）..."
  tar czf "$app_pkg" -C "$(dirname "${env_app_dir}")" "$(basename "${env_app_dir}")" || return 1
  local_app_fingerprint=$(calculate_app_fingerprint "$env_app_dir") || return 1
  expected_version="${mongo_major_ver}.${mongo_minor_ver}.${mongo_patch_ver}"

  for ((index=0; index<${#remote_hosts[@]}; index++)); do
    host=${remote_hosts[$index]}
    endpoint=${remote_endpoints[$index]}
    log_file=$(mktemp /tmp/mongo-remote-deploy.XXXXXX.log) || return 1
    MONGO_INSTALL_TMPFILES+=("$log_file")
    (deploy_remote_node "$host" "$endpoint" "$app_pkg" "$local_app_fingerprint" "$expected_version") >"$log_file" 2>&1 &
    batch_pids+=("$!")
    MONGO_REMOTE_DEPLOY_PIDS+=("$!")
    batch_logs+=("$log_file")
    batch_hosts+=("$host")
    batch_endpoints+=("$endpoint")
    ((batch_count++))

    if (( batch_count >= mongo_remote_parallelism )); then
      for ((index=0; index<batch_count; index++)); do
        pid=${batch_pids[$index]}
        wait "$pid" || failure=1
        printf '%s\n' "--- ${batch_hosts[$index]} (${batch_endpoints[$index]}) ---"
        cat "${batch_logs[$index]}"
      done
      batch_pids=(); batch_logs=(); batch_hosts=(); batch_endpoints=(); batch_count=0
    fi
  done

  for ((index=0; index<batch_count; index++)); do
    pid=${batch_pids[$index]}
    wait "$pid" || failure=1
    printf '%s\n' "--- ${batch_hosts[$index]} (${batch_endpoints[$index]}) ---"
    cat "${batch_logs[$index]}"
  done
  (( failure == 0 )) || {
    echo "错误: 至少一个远程节点部署失败" >&2
    return 1
  }
  rm -f "$app_pkg"
  echo "远程节点并行部署完成 (${remote_count} 个，并发上限 ${mongo_remote_parallelism})"
}
#==============================================================#
#             副本集初始化                                     #
#==============================================================#
function init_replicaset() {
  log_print "初始化副本集"

  if [[ "$mongo_install_mode" != "replicaset" ]]; then
    echo "非副本集模式，跳过"
    return 0
  fi

  local local_ip="127.0.0.1"

  # 确定 mongo shell 命令
  local SHELL_CMD=""
  if [[ -x "${env_app_dir}/bin/mongosh" ]]; then
    SHELL_CMD="${env_app_dir}/bin/mongosh"
  elif [[ -x "${env_app_dir}/bin/mongo" ]]; then
    SHELL_CMD="${env_app_dir}/bin/mongo"
  else
    color_printf red "错误: 未找到 mongosh 或 mongo shell"
    return 1
  fi

  # 构建副本集成员列表
  local members=""
  local idx=0
  for host in "${hosts_array[@]}"; do
    if (( idx > 0 )); then
      members="${members},"
    fi
    members="${members}{_id:${idx},host:\"${host}:${mongo_port}\"}"
    ((idx++))
  done

  # 如果是单机副本集 (hosts_array 为空或只有本机)
  if [[ ${#hosts_array[@]} -eq 0 ]]; then
    members="{_id:0,host:\"${local_ip}:${mongo_port}\"}"
  fi

  echo "副本集成员: ${members}"

  # 等待本机 MongoDB 就绪。重复安装必须优先尝试认证，因为 ping 命令本身
  # 即使在 authorization=enabled 时也可能允许未认证执行，不能用它判断 localhost exception。
  local retries=0 use_auth=N
  local -a shell_connection_args=(--host "$local_ip" --port "$mongo_port" --quiet)
  if [[ "$mongo_tls_enabled" == "Y" ]]; then
    shell_connection_args+=(--tls --tlsCAFile "$mongo_tls_ca_path")
  fi
  while (( retries < 20 )); do
    if [[ "$mongo_auth_enabled" == "Y" ]] && run_mongo_eval "db.adminCommand({connectionStatus:1})" Y &>/dev/null; then
      use_auth=Y
      break
    fi
    if "$SHELL_CMD" "${shell_connection_args[@]}" --eval "db.adminCommand({connectionStatus:1})" &>/dev/null; then
      break
    fi
    sleep 2
    ((retries++))
  done

  if (( retries >= 20 )); then
    color_printf red "错误: 本机 MongoDB 未就绪，无法初始化副本集"
    return 1
  fi

  # 初始化副本集
  local rs_init_result
  rs_init_result=$(run_mongo_eval "
    var config = {
      _id: '${repl_set_name}',
      members: [${members}]
    };
    var result = rs.initiate(config);
    printjson(result);
    if (result && result.ok === 1) print('MONGO_INSTALL_RS_INIT_OK');
  " "$use_auth" 2>&1)

  echo "$rs_init_result"

  if [[ "$rs_init_result" == *"MONGO_INSTALL_RS_INIT_OK"* ]]; then
    echo "副本集 ${repl_set_name} 初始化成功"
  elif echo "$rs_init_result" | grep -q "already initialized"; then
    echo "副本集 ${repl_set_name} 已初始化"
  else
    echo "错误: 副本集初始化返回异常" >&2
    return 1
  fi

  # 等待选主完成
  echo "等待副本集选主..."
  retries=0
  while (( retries < 30 )); do
    local rs_status
    rs_status=$(run_mongo_eval "
      var s = rs.status();
      var hasPrimary = false;
      s.members.forEach(function(m) { if (m.stateStr === 'PRIMARY') hasPrimary = true; });
      print(hasPrimary ? 'HAS_PRIMARY' : 'NO_PRIMARY');
    " "$use_auth" 2>/dev/null)
    if [[ "$rs_status" == *"HAS_PRIMARY"* ]]; then
      echo "副本集选主完成"
      break
    fi
    sleep 2
    ((retries++))
  done

  if (( retries >= 30 )); then
    echo "错误: 副本集选主超时，请检查成员 DNS、网络和 mongod 日志" >&2
    return 1
  fi

}
#==============================================================#
#             管理员初始化与认证执行                           #
#==============================================================#
function get_mongo_shell() {
  if [[ -x "${env_app_dir}/bin/mongosh" ]]; then
    printf '%s' "${env_app_dir}/bin/mongosh"
  elif [[ -x "${env_app_dir}/bin/mongo" ]]; then
    printf '%s' "${env_app_dir}/bin/mongo"
  else
    return 1
  fi
}

function run_mongo_eval() {
  local expression="$1" use_auth="${2:-Y}" shell_cmd
  local -a shell_connection_args=(--host 127.0.0.1 --port "$mongo_port" --quiet)
  shell_cmd=$(get_mongo_shell) || {
    echo "错误: 未找到 mongosh 或 mongo shell" >&2
    return 1
  }
  if [[ "$use_auth" == "Y" && "$mongo_auth_enabled" == "Y" ]]; then
    expression="load('${mongo_auth_js}'); ${expression}"
  fi
  if [[ "$mongo_tls_enabled" == "Y" ]]; then
    shell_connection_args+=(--tls --tlsCAFile "$mongo_tls_ca_path")
  fi
  "$shell_cmd" "${shell_connection_args[@]}" --eval "$expression"
}

function create_admin_user() {
  log_print "创建 MongoDB 管理员"
  [[ "$mongo_auth_enabled" == "Y" ]] || {
    echo "认证未启用，跳过管理员创建"
    return 0
  }

  local shell_cmd js_file js_user js_password result status
  shell_cmd=$(get_mongo_shell) || {
    echo "错误: 启用认证时必须安装 mongosh 或 mongo shell" >&2
    return 1
  }
  js_file=$(mktemp /tmp/mongo_create_admin.XXXXXX.js) || return 1
  MONGO_INSTALL_TMPFILES+=("$js_file")
  chmod 0600 "$js_file" || return 1
  js_user=$(escape_js_single_quoted "$mongo_admin_user")
  js_password=$(escape_js_single_quoted "$mongo_admin_pass")

  cat > "$js_file" <<ADMINEOF || return 1
db = db.getSiblingDB('admin');
try {
  db.createUser({
    user: '${js_user}',
    pwd: '${js_password}',
    roles: [{role: 'root', db: 'admin'}],
    mechanisms: ['${mongo_auth_mechanism}']
  });
  print('MONGO_INSTALL_ADMIN_CREATED');
} catch (e) {
  if (e.codeName === 'DuplicateKey' || e.code === 51003) {
    print('MONGO_INSTALL_ADMIN_EXISTS');
  } else {
    print('MONGO_INSTALL_ADMIN_ERROR:' + e.message);
    quit(12);
  }
}
ADMINEOF

  local -a shell_connection_args=(--host 127.0.0.1 --port "$mongo_port" --quiet)
  if [[ "$mongo_tls_enabled" == "Y" ]]; then
    shell_connection_args+=(--tls --tlsCAFile "$mongo_tls_ca_path")
  fi
  result=$("$shell_cmd" "${shell_connection_args[@]}" --file "$js_file" 2>&1)
  status=$?
  rm -f "$js_file"
  if (( status == 0 )) && [[ "$result" == *"MONGO_INSTALL_ADMIN_CREATED"* || "$result" == *"MONGO_INSTALL_ADMIN_EXISTS"* ]]; then
    echo "$result"
    return 0
  fi

  # 重复安装时 localhost exception 已关闭；验证传入的现有凭据即可。
  if run_mongo_eval "print('MONGO_INSTALL_ADMIN_AUTH_OK')" Y 2>/dev/null | grep -q 'MONGO_INSTALL_ADMIN_AUTH_OK'; then
    echo "管理员已存在，提供的凭据验证成功"
    return 0
  fi
  echo "$result" >&2
  echo "错误: 无法创建管理员，且提供的凭据无法认证" >&2
  (( status == 0 )) && status=1
  return "$status"
}

function verify_installation() {
  log_print "验证 MongoDB 安装"
  local result expected_version="${mongo_major_ver}.${mongo_minor_ver}.${mongo_patch_ver}"
  result=$(run_mongo_eval "var r=db.adminCommand('ping'); print('MONGO_INSTALL_PING=' + r.ok); print('MONGO_INSTALL_VERSION=' + db.version());" "$mongo_auth_enabled" 2>&1) || {
    echo "$result" >&2
    return 1
  }
  [[ "$result" == *"MONGO_INSTALL_PING=1"* ]] || {
    echo "错误: MongoDB ping 验证未返回 ok=1" >&2
    return 1
  }
  [[ "$result" == *"MONGO_INSTALL_VERSION=${expected_version}"* ]] || {
    printf '错误: 运行中 MongoDB 版本不是期望版本 %s:\n%s\n' "$expected_version" "$result" >&2
    return 1
  }
  echo "MongoDB 服务、版本 (${expected_version}) 与认证验证成功"
}
#==============================================================#
#             集群验证                                         #
#==============================================================#
function verify_cluster() {
  log_print "验证副本集状态"
  local expected_members="" host attempt=0 result status=1
  for host in "${hosts_array[@]}"; do
    [[ -z "$expected_members" ]] || expected_members+=","
    expected_members+="'${host}:${mongo_port}'"
  done
  [[ -n "$expected_members" ]] || expected_members="'127.0.0.1:${mongo_port}'"

  # 初次全量同步所需时间与数据量、磁盘性能有关。等待所有节点进入健康的
  # PRIMARY/SECONDARY 状态，而不是只要 rs.status() 能打印就判定成功。
  while (( attempt < 60 )); do
    result=$(run_mongo_eval "
      var expectedSet = '${repl_set_name}';
      var expected = [${expected_members}].sort();
      var s = rs.status();
      var actual = s.members.map(function(m) { return m.name; }).sort();
      var primaryCount = s.members.filter(function(m) { return m.stateStr === 'PRIMARY'; }).length;
      var secondaryCount = s.members.filter(function(m) { return m.stateStr === 'SECONDARY'; }).length;
      var allHealthy = s.members.every(function(m) { return m.health === 1; });
      var membersMatch = expected.length === actual.length && expected.every(function(v, i) { return v === actual[i]; });
      if (s.set === expectedSet && membersMatch && allHealthy && primaryCount === 1 && secondaryCount === expected.length - 1) {
        print('MONGO_INSTALL_CLUSTER_OK');
        print('副本集名称: ' + s.set);
        s.members.forEach(function(m) {
          print('  ' + m.name + ' => ' + m.stateStr + ' (health=' + m.health + ')');
        });
      } else {
        print('MONGO_INSTALL_CLUSTER_WAIT set=' + s.set +
          ' expectedMembers=' + expected.join(',') + ' actualMembers=' + actual.join(',') +
          ' primary=' + primaryCount + ' secondary=' + secondaryCount + ' allHealthy=' + allHealthy);
        quit(31);
      }
    " 2>&1)
    status=$?
    if (( status == 0 )) && [[ "$result" == *"MONGO_INSTALL_CLUSTER_OK"* ]]; then
      printf '%s\n' "$result" | grep -v 'MONGO_INSTALL_CLUSTER_OK'
      echo
      echo "副本集配置:"
      run_mongo_eval "
        var c = rs.conf();
        c.members.forEach(function(m) {
          print('  _id=' + m._id + ' host=' + m.host + ' priority=' + m.priority);
        });
      " 2>&1 || return 1
      return 0
    fi
    (( status == 0 )) && status=1
    ((attempt++))
    sleep 3
  done
  printf '错误: 副本集在 180 秒内未达到 1 PRIMARY + %d SECONDARY 且全部 health=1\n%s\n' \
    "$(( ${#hosts_array[@]} > 0 ? ${#hosts_array[@]} - 1 : 0 ))" "$result" >&2
  return "${status:-1}"
}

mongo_replica_seed_list() {
  local result="" host
  for host in "${hosts_array[@]}"; do
    [[ -z "$result" ]] || result+=","
    result+="${host}:${mongo_port}"
  done
  [[ -n "$result" ]] || result="127.0.0.1:${mongo_port}"
  printf '%s' "$result"
}
#==============================================================#
#             安装汇总                                         #
#==============================================================#
function print_summary() {
  local local_ip="127.0.0.1" server_ip effective_hostname application_endpoint
  server_ip=$(get_local_ip)
  effective_hostname=$(build_install_hostname "$hostname" "$mongo_install_mode" "$server_ip")
  application_endpoint="${server_ip}:${mongo_port}"
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    application_endpoint="$(mongo_replica_seed_list)/?replicaSet=${repl_set_name}"
  fi

  echo
  echo "============================================================"
  echo "            MongoDB 安装完成 - 信息汇总"
  echo "============================================================"
  echo "  安装模式        : ${mongo_install_mode}"
  echo "  当前主机名      : ${effective_hostname}"
  echo "  MongoDB 目录    : ${env_app_dir}"
  echo "  配置文件        : ${env_base_dir}/mongod.conf"
  echo "  数据目录        : ${data_dir}/db"
  echo "  日志目录        : ${log_dir}"
  echo "  备份目录        : ${backup_dir}"
  echo "  脚本目录        : ${scripts_dir}"
  echo "  端口            : ${mongo_port}"
  echo "  监听地址        : ${mongo_bind_ip}"

  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    echo "  副本集名称      : ${repl_set_name}"
    echo "  副本集成员      : ${hosts_array[*]}"
    echo "  SSH 端点        : ${remote_ips_array[*]}"
    echo "  Oplog 大小      : ${oplog_size_mb}MB"
    if [[ "$mongo_auth_enabled" == "Y" && "$mongo_cluster_auth_mode" == "keyFile" ]]; then
      echo "  节点内部认证    : keyFile"
      echo "  keyFile         : ${mongo_keyfile}"
    elif [[ "$mongo_auth_enabled" == "Y" ]]; then
      echo "  节点内部认证    : X.509"
      echo "  成员证书        : ${mongo_tls_cert_path}"
    else
      echo "  节点内部认证    : 未启用"
      echo "  keyFile         : 未生成（认证关闭）"
    fi
  fi

  echo "  运行用户/组     : ${mongo_owner}:${mongo_owner}"
  echo "  WiredTiger 缓存 : ${wt_cache_size_gb}GB"
  echo "  最大连接数      : ${max_connections}"
  echo "  文件句柄限制    : ${mongo_nofile_limit}"
  echo "  线程/进程限制   : ${mongo_nproc_limit}"
  echo "  NUMA 节点       : ${mongo_numa_nodes}"
  [[ -z "$mongo_data_device" ]] || echo "  数据块设备      : ${mongo_data_device}（readahead=${mongo_readahead_sectors} sectors）"
  if [[ "$mongo_tls_enabled" == "Y" ]]; then
    echo "  TLS             : 已启用（requireTLS）"
    echo "  TLS CA          : ${mongo_tls_ca_path}"
  else
    echo "  TLS             : 未启用"
  fi
  if [[ "$mongo_auth_enabled" == "Y" ]]; then
    echo "  认证            : 已启用"
    echo "  管理员用户      : ${mongo_admin_user}"
    echo "  管理员密码      : ${mongo_admin_pass}"
    echo "  认证方式        : ${mongo_auth_mechanism}（authSource=admin）"
    if [[ "$mongo_install_mode" == "replicaset" ]]; then
      echo "  应用连接        : mongodb://${mongo_admin_user}:<URL编码密码>@${application_endpoint}&authSource=admin&authMechanism=${mongo_auth_mechanism}$([[ "$mongo_tls_enabled" == "Y" ]] && printf '&tls=true')"
    else
      echo "  应用连接        : mongodb://${mongo_admin_user}:<URL编码密码>@${application_endpoint}/admin?authSource=admin&authMechanism=${mongo_auth_mechanism}$([[ "$mongo_tls_enabled" == "Y" ]] && printf '&tls=true')"
    fi
    echo "  凭据提示        : 明文只显示在本次终端摘要，不写入安装详细日志"
  else
    echo "  认证            : 未启用"
    echo "  认证方式        : 无"
    if [[ "$mongo_install_mode" == "replicaset" ]]; then
      echo "  应用连接        : mongodb://${application_endpoint}$([[ "$mongo_tls_enabled" == "Y" ]] && printf '&tls=true')"
    else
      echo "  应用连接        : mongodb://${application_endpoint}$([[ "$mongo_tls_enabled" == "Y" ]] && printf '/?tls=true')"
    fi
  fi
  if [[ "$mongo_tls_enabled" == "Y" ]]; then
    echo "  客户端 TLS 参数 : --tls --tlsCAFile <客户端可读的 CA 文件>"
  fi
  echo "------------------------------------------------------------"
  if (( HAS_SYSTEMD )); then
    echo "  服务管理        : systemctl {start|stop|restart|status} mongod"
  else
    echo "  服务管理        : 非 systemd fork 模式，请使用 mongod PID 管理"
  fi
  echo "  备份脚本        : ${scripts_dir}/mongo_backup.sh"
  if [[ -x "${env_app_dir}/bin/mongodump" ]]; then
    echo "  自动备份        : 已启用（每天 02:00）"
  else
    echo "  自动备份        : 未启用（缺少 mongodump）"
  fi
  echo "  监控脚本        : ${scripts_dir}/mongo_monitor.sh"
  echo "  安装日志        : ${Mongoinstalllog}"
  echo "  本次安装耗时    : $(format_duration "$INSTALL_ELAPSED_SECONDS")（${INSTALL_ELAPSED_SECONDS} 秒）"
  echo "============================================================"

  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    local node_count=${#hosts_array[@]}
    local risks=()
    if (( node_count < 3 )); then
      risks+=("节点数不足 3 (当前: ${node_count})，无法容忍任何节点故障。建议至少 3 个节点")
    fi
    if (( node_count % 2 == 0 )); then
      risks+=("节点数为偶数 (${node_count})，选举在网络分区时可能无法达成多数。建议使用奇数个节点")
    fi
    if (( ${#risks[@]} > 0 )); then
      echo
      echo "  风险提示:"
      for ((i=0; i<${#risks[@]}; i++)); do
        echo "    $((i+1)). ${risks[$i]}"
      done
      echo
      echo "============================================================"
    fi
  fi

  echo
  echo "  常用命令:"
  if [[ -x "${env_app_dir}/bin/mongosh" ]]; then
    echo "    # 连接 MongoDB"
    if [[ "$mongo_auth_enabled" == "Y" ]]; then
      echo "    mongosh --host ${local_ip} --port ${mongo_port} --username ${mongo_admin_user} --authenticationDatabase admin --authenticationMechanism ${mongo_auth_mechanism} --password"
    else
      echo "    mongosh --host ${local_ip} --port ${mongo_port}"
    fi
  else
    echo "    # 连接 MongoDB"
    if [[ "$mongo_auth_enabled" == "Y" ]]; then
      echo "    mongo --host ${local_ip} --port ${mongo_port} --username ${mongo_admin_user} --authenticationDatabase admin --authenticationMechanism ${mongo_auth_mechanism} --password"
    else
      echo "    mongo --host ${local_ip} --port ${mongo_port}"
    fi
  fi
  echo "    # 查看数据库列表"
  echo "    show dbs"
  echo "    # 查看集合"
  echo "    show collections"
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    echo "    # 查看副本集状态"
    echo "    rs.status()"
  fi
  echo
}
#==============================================================#
#             前置检查                                         #
#==============================================================#
function check_prerequisites() {
  if [[ $EUID -ne 0 ]]; then
    color_printf red "错误: 此脚本必须以 root 用户运行"
    exit 1
  fi

  if [[ "$os_distro_family" == "unknown" ]]; then
    color_printf yellow "警告: 无法识别操作系统发行版 (${os_distro})，脚本已支持 RHEL/Debian/SUSE/Arch 系列"
  fi

  case "${os_distro}:${os_version}" in
    rhel:8|rhel:9|rocky:8|rocky:9)
      echo "平台级别: 认证矩阵 (${os_distro}-${os_version_id}/${os_arch})"
      ;;
    centos:7)
      color_printf yellow "平台级别: 遗留兼容 (CentOS 7 已 EOL，仅允许 MongoDB 6.0/7.0)"
      ;;
    *)
      color_printf yellow "平台级别: 未完成当前实机认证矩阵，按现有兼容逻辑尽力安装"
      ;;
  esac

  if (( os_memory_mb < 1024 )); then
    color_printf red "错误: 物理内存不足 1024MB (当前: ${os_memory_mb}MB)，MongoDB 至少需要 1GB 内存"
    exit 1
  fi

  echo "系统信息: OS=${os_distro}(${os_distro_family}), 版本=${os_version_id}, 架构=${os_arch}, 内存=${os_memory_mb}MB, CPU=${os_core}核, systemd=$(if (( HAS_SYSTEMD )); then echo '是'; else echo '否'; fi)"
}

function validate_and_finalize_parameters() {
  validate_port "$mongo_port" || {
    echo "错误: MongoDB 端口必须是 1-65535 的整数 (当前: ${mongo_port})" >&2
    return 1
  }
  validate_port "$serverport" || {
    echo "错误: SSH 端口必须是 1-65535 的整数 (当前: ${serverport})" >&2
    return 1
  }
  validate_positive_integer "$backup_retention_days" 1 36500 || {
    echo "错误: --backup-days 必须是 1-36500 的整数" >&2
    return 1
  }
  validate_positive_integer "$max_connections" 100 10000000 || {
    echo "错误: --max-connections 必须是 100-10000000 的整数" >&2
    return 1
  }
  validate_positive_integer "$mongo_remote_parallelism" 1 32 || {
    echo "错误: --remote-parallelism 必须是 1-32 的整数" >&2
    return 1
  }
  validate_positive_integer "$oplog_size_mb" 0 2147483647 || {
    echo "错误: --oplog-size 必须是 0-2147483647 的整数" >&2
    return 1
  }
  mongo_port=$((10#$mongo_port))
  serverport=$((10#$serverport))
  backup_retention_days=$((10#$backup_retention_days))
  max_connections=$((10#$max_connections))
  mongo_remote_parallelism=$((10#$mongo_remote_parallelism))
  oplog_size_mb=$((10#$oplog_size_mb))
  if (( oplog_size_mb > 0 && oplog_size_mb < 990 )); then
    echo "错误: --oplog-size 使用 0 自动计算，或指定至少 990MB" >&2
    return 1
  fi
  calculate_resource_profile || return 1
  validate_safe_install_dir "$env_base_dir" || {
    echo "错误: 安装目录必须是安全的绝对路径；拒绝 /、/etc、/var、/data 等系统或宽泛目录" >&2
    return 1
  }
  validate_safe_install_dir "$data_dir" || {
    echo "错误: --data-dir 必须是安全的绝对路径；拒绝系统根目录或宽泛挂载根目录" >&2
    return 1
  }
  validate_safe_install_dir "$backup_dir" || {
    echo "错误: --backup-dir 必须是安全的绝对路径；拒绝系统根目录或宽泛挂载根目录" >&2
    return 1
  }
  local managed_path
  for managed_path in "$env_app_dir" "$log_dir" "$scripts_dir" "$pid_dir" "$mongo_tls_dir"; do
    if paths_overlap "$data_dir" "$managed_path"; then
      echo "错误: 数据目录不能与安装器管理目录重叠: ${data_dir} <-> ${managed_path}" >&2
      return 1
    fi
    if paths_overlap "$backup_dir" "$managed_path"; then
      echo "错误: 备份目录不能与安装器管理目录重叠: ${backup_dir} <-> ${managed_path}" >&2
      return 1
    fi
  done
  if paths_overlap "$data_dir" "$backup_dir"; then
    echo "错误: 数据目录和备份目录不能相同或相互包含: ${data_dir} <-> ${backup_dir}" >&2
    return 1
  fi
  [[ "$mongo_owner" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
    echo "错误: MongoDB 运行用户名格式无效: ${mongo_owner}" >&2
    return 1
  }
  local effective_hostname
  effective_hostname=$(build_install_hostname "$hostname" "$mongo_install_mode" "$(get_local_ip)") || return 1
  validate_host "$effective_hostname" && ! check_ip "$effective_hostname" || {
    printf '错误: --hostname 基础名根据安装模式生成的最终主机名无效: %s（基础名: %s）\n' \
      "$effective_hostname" "$hostname" >&2
    return 1
  }
  [[ "$mongo_admin_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]] || {
    echo "错误: MongoDB 管理员用户名格式无效" >&2
    return 1
  }
  [[ "$repl_set_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || {
    echo "错误: 副本集名称格式无效" >&2
    return 1
  }

  local forbidden_users=(root bin daemon adm lp sync shutdown halt mail operator games ftp nobody systemd-network dbus polkitd sshd postfix chrony ntp)
  local forbidden
  for forbidden in "${forbidden_users[@]}"; do
    [[ "$mongo_owner" == "$forbidden" ]] && {
      echo "错误: 不允许使用系统用户 '${mongo_owner}' 作为 MongoDB 运行用户" >&2
      return 1
    }
  done

  if [[ -z "$mongo_bind_ip" ]]; then
    mongo_bind_ip="0.0.0.0"
  fi
  mongo_bind_ip="${mongo_bind_ip//[[:space:]]/}"
  validate_bind_ip_list "$mongo_bind_ip" || {
    echo "错误: --bind-ip 包含无效地址；支持 0.0.0.0，但不支持 :: 或 *" >&2
    return 1
  }

  case "${mongo_cluster_auth_mode,,}" in
    keyfile) mongo_cluster_auth_mode="keyFile" ;;
    x509|x.509) mongo_cluster_auth_mode="x509" ;;
    *)
      echo "错误: --cluster-auth-mode 仅支持 keyFile 或 x509" >&2
      return 1
      ;;
  esac
  if [[ "$mongo_cluster_auth_mode" == "x509" ]]; then
    [[ "$mongo_install_mode" == "replicaset" && "$mongo_auth_enabled" == "Y" && "$mongo_tls_enabled" == "Y" ]] || {
      echo "错误: X.509 成员认证必须同时使用 replicaset、--auth 和 --tls" >&2
      return 1
    }
  fi
  if [[ "$mongo_tls_enabled" != "Y" && ( -n "$mongo_tls_ca_file" || -n "$mongo_tls_cert_dir" || -n "$mongo_tls_cert_key_file" ) ]]; then
    echo "错误: 提供 TLS 文件时必须显式指定 --tls" >&2
    return 1
  fi

  local source
  for source in ${firewall_sources[@]+"${firewall_sources[@]}"}; do
    validate_firewall_source "$source" || {
      echo "错误: --allow-source 必须是 IPv4 或 IPv4 CIDR: ${source}" >&2
      return 1
    }
  done

  if [[ "$mongo_auth_enabled" != "Y" && ( -n "$mongo_admin_pass" || -n "$mongo_admin_pass_file" ) ]]; then
    echo "警告: 未启用 --auth，管理员密码参数将被忽略" >&2
  fi
  if [[ -n "$remote_root_pass_file" ]]; then
    read_secret_file "$remote_root_pass_file" remote_root_pass || return 1
  fi
  [[ -z "$ssh_identity_file" || ( -f "$ssh_identity_file" && ! -L "$ssh_identity_file" ) ]] || {
    echo "错误: SSH 私钥不存在或是符号链接: ${ssh_identity_file}" >&2
    return 1
  }
  if [[ -n "$os_iso_root" ]]; then
    [[ "$os_iso_root" == /* && "$os_iso_root" != *$'\n'* && "$os_iso_root" != *$'\r'* && -d "$os_iso_root" ]] || {
      echo "错误: --os-iso-root 必须是当前已挂载 ISO 的绝对目录: ${os_iso_root}" >&2
      return 1
    }
  fi
  if [[ -n "$os_packages_dir" ]]; then
    [[ "$os_packages_dir" == /* && "$os_packages_dir" != *$'\n'* && "$os_packages_dir" != *$'\r'* && -d "$os_packages_dir" ]] || {
      echo "错误: --os-packages-dir 必须是已解压离线依赖包的绝对目录: ${os_packages_dir}" >&2
      return 1
    }
  fi

  if [[ "$mongo_install_mode" == "replicaset" && "$only_conf_os" != "Y" ]]; then
    # 兼容旧用法：只提供 -ri 时仍可作为成员列表；MongoDB 5.0+ 的纯 IP
    # 成员会在版本预检阶段被明确拒绝。正常集群建议同时提供 -H 与 -ri。
    if (( ${#hosts_array[@]} == 0 && ${#remote_ips_array[@]} > 0 )); then
      hosts_array=("${remote_ips_array[@]}")
    fi
    (( ${#hosts_array[@]} > 0 )) || {
      echo "错误: replicaset 模式必须通过 --hosts 指定包含本机的 DNS 主机名" >&2
      return 1
    }
    if (( ${#remote_ips_array[@]} == 0 )); then
      remote_ips_array=("${hosts_array[@]}")
    fi
    (( ${#remote_ips_array[@]} == ${#hosts_array[@]} )) || {
      printf '错误: --hosts 与 --remote-ips 数量必须一致（当前 %d != %d）\n' \
        "${#hosts_array[@]}" "${#remote_ips_array[@]}" >&2
      return 1
    }
    local host endpoint local_ip local_found=0 remote_found=0 local_member="" expected_local_hostname
    local index
    local -A seen_hosts=() seen_endpoints=()
    local_ip=$(get_local_ip)
    for ((index=0; index<${#hosts_array[@]}; index++)); do
      host=${hosts_array[$index]}
      endpoint=${remote_ips_array[$index]}
      validate_host "$host" || {
        echo "错误: 无效的副本集主机: ${host}" >&2
        return 1
      }
      [[ -z "${seen_hosts[$host]+present}" ]] || {
        echo "错误: 副本集主机名不能重复: ${host}" >&2
        return 1
      }
      seen_hosts[$host]=1
      validate_host "$endpoint" || {
        echo "错误: 无效的 SSH 端点: ${endpoint}" >&2
        return 1
      }
      [[ -z "${seen_endpoints[$endpoint]+present}" ]] || {
        echo "错误: SSH 端点不能重复: ${endpoint}" >&2
        return 1
      }
      seen_endpoints[$endpoint]=1
      if is_local_host "$endpoint" "$local_ip"; then
        ((local_found++))
        local_member=$host
      else
        remote_found=1
      fi
    done
    (( local_found == 1 )) || {
      echo "错误: --remote-ips 必须且只能包含一个当前节点端点" >&2
      return 1
    }
    expected_local_hostname=$(build_install_hostname "$hostname" "$mongo_install_mode" "$local_ip") || return 1
    [[ "$local_member" == "$expected_local_hostname" ]] || {
      printf '错误: 本机副本集成员名必须与安装模式生成的主机名一致：期望 %s，实际 %s\n' \
        "$expected_local_hostname" "$local_member" >&2
      return 1
    }
    if (( remote_found == 1 )); then
      [[ -f "$ssh_known_hosts_file" ]] || {
        echo "错误: SSH known_hosts 文件不存在: ${ssh_known_hosts_file}" >&2
        echo "请先使用 ssh-keyscan/人工核验写入主机密钥，安装器不会跳过主机校验" >&2
        return 1
      }
    fi
  fi

  if [[ "$only_conf_os" != "Y" ]]; then
    ensure_admin_password || return 1
  fi
}

function calculate_total_steps() {
  local total
  if [[ "$only_conf_os" == "Y" ]]; then
    printf '9'
    return
  elif [[ "$mongo_install_mode" == "replicaset" ]]; then
    if [[ "$mongo_auth_enabled" == "Y" ]]; then total=29; else total=28; fi
  elif [[ "$mongo_auth_enabled" == "Y" ]]; then
    total=25
  else
    total=24
  fi
  [[ "$mongo_tls_enabled" == "Y" ]] && total=$((total + 2))
  printf '%d' "$total"
}
#==============================================================#
#             帮助信息                                         #
#==============================================================#
function show_help() {
  cat <<HELPEOF
用法: $script_name [选项]

MongoDB 一键安装脚本 (单机 + 副本集) v${MONGO_INSTALL_VERSION}

选项:
  -m,  --mode MODE         安装模式: single|replicaset (不指定则交互选择)
                           支持简写: si|rs
  -n,  --hostname NAME     主机名/前缀 (默认: mongodb；副本集追加本机 IP 后两段)
  -p,  --port PORT         MongoDB 端口 (默认: 27017)
  -d,  --dir DIR           安装根目录 (默认: /mongodb；--install-dir 共用 -d)
  -dd, --data-dir DIR      数据根目录 (默认: <安装根目录>/data，dbPath 为 DIR/db)
  -bd, --backup-dir DIR    备份归档目录 (默认: <安装根目录>/backup)
  -ou, --owner USER        运行用户及同名主组 (默认: mongod；60300 冲突时自动分配 UID/GID)
  -H,  --hosts HOSTS       副本集 DNS 主机名 (逗号分隔，按节点顺序)
  -ri, --remote-ips HOSTS  对应的 SSH 端点/IP (逗号分隔，数量与 --hosts 一致)
  -sk, --ssh-key FILE      远程 root SSH 私钥 (推荐)
  -rpf, --root-pass-file FILE 远程 root 密码文件 (权限建议 600)
  -rp, --root-pass PASS    兼容参数，不推荐：密码可能进入 shell 历史
  -ss, --ssh-port PORT     SSH 端口 (默认: 22)
  -kh, --known-hosts FILE  SSH known_hosts 文件 (默认: ~/.ssh/known_hosts)
  -rs, --repl-set NAME     副本集名称 (默认: rs0)
  -a,  --auth              启用 SCRAM-SHA-256 用户名/密码认证 (可选)
  -na, --no-auth           关闭认证 (默认)
  -au, --admin-user USER   管理员用户名 (默认: admin)
  -apf, --admin-pass-file FILE 管理员密码文件 (非交互安装推荐，权限建议 600)
  -ap, --admin-pass PASS   直接提供管理员密码；详细日志脱敏，但可能进入 shell 历史
  -t,  --tls               要求所有 MongoDB 网络连接使用 TLS
  -nt, --no-tls            关闭 TLS (默认)
  -tca, --tls-ca-file FILE CA 证书 PEM 文件
  -tck, --tls-cert-key-file FILE 单机证书+未加密私钥 PEM 文件 (权限 600)
  -tcd, --tls-cert-dir DIR 副本集证书目录，每个成员使用 <主机名>.pem
  -cam, --cluster-auth-mode MODE 副本集内部认证: keyFile|x509 (默认: keyFile)
  -bi, --bind-ip ADDRS     监听地址 (默认: 0.0.0.0)
  -as, --allow-source CIDRS 兼容参数；防火墙关闭时不生效
  -op, --oplog-size MB     Oplog 大小 (默认: 自动计算)
  -mc, --max-connections NUM 最大连接数 (默认: 65536)
  -j,  --remote-parallelism NUM 远程节点并行数 (默认: 4，范围: 1-32)
  -oo, --os-only           仅配置操作系统，不安装 MongoDB
  -dbg, --debug            开启调试模式
  -br, --backup-days DAYS  备份保留天数 (默认: 7)
  -mv, --mongo-version VER --os-only 时指定版本，以正确配置 THP
  -mp, --mongo-package FILE|VER 多个 Server 包时指定文件名或版本；只有一个时自动选择
  -oir, --os-iso-root DIR  已挂载的 OS ISO 根目录（优先安装 ISO 内依赖）
  -opd, --os-packages-dir DIR 已解压的 OS 离线依赖目录（高级覆盖）
  -np, --no-progress       禁用 ANSI 动画，输出逐行日志
  -y, --yes                非交互确认安装
  -h,  --help              显示帮助信息

示例:
  # 交互式选择模式安装
  $script_name

  # 单机模式（默认无认证，监听全部 IPv4 地址）
  $script_name -m single

  # 可选：启用认证并直接提供密码（会进入 shell 历史）
  $script_name -m single --auth --admin-user admin --admin-pass 'ChangeMe_123456'

  # 推荐：通过权限为 600 的文件提供密码
  $script_name -m single --auth --admin-pass-file /root/.mongodb-admin-password

  # 3 节点副本集（DNS 主机名 + SSH 密钥）
  $script_name -m rs --hosts db1.example.internal,db2.example.internal,db3.example.internal \
    --remote-ips 10.0.1.11,10.0.1.12,10.0.1.13 \
    --ssh-key /root/.ssh/id_ed25519 --auth --admin-pass-file /root/.mongodb-admin-password

  # TLS + X.509 节点内部认证（每个 PEM 同时包含证书和未加密私钥）
  $script_name -m rs --hosts db1.example.internal,db2.example.internal,db3.example.internal \
    --remote-ips 10.0.1.11,10.0.1.12,10.0.1.13 \
    --ssh-key /root/.ssh/id_ed25519 --auth --admin-pass-file /root/.mongodb-admin-password \
    --tls --tls-ca-file /root/pki/ca.pem --tls-cert-dir /root/pki/members \
    --cluster-auth-mode x509 --remote-parallelism 3

  # 自定义端口和目录
  $script_name -m single -p 27018 -d /data/mongodb

  # 安装、数据和备份分别放置（参数顺序不影响目录解析）
  $script_name -m single --data-dir /data/mongodb-data \
    --backup-dir /backup/mongodb -d /opt/mongodb-install

离线安装 (内网环境):
  将以下文件放在脚本同目录 (${software_dir}/):
  1. MongoDB 安装包:  mongodb-linux-x86_64-*.tgz
  2. mongosh (MongoDB 6.0+ 必需): mongosh-*.tgz
  3. Database Tools (自动备份需要): mongodb-database-tools-*.tgz
  4. ISO 缺失依赖补充包: mongdb-offline-rpm.tar.gz
     内部按 OS 主版本 + CPU 架构隔离，例如:
     mongdb-offline-rpm/rhel/9/x86_64/

认证平台矩阵 (x86_64):
  RHEL 8/9、Rocky Linux 8/9: MongoDB 6.0、7.0、8.0、8.3
  CentOS 7: MongoDB 6.0、7.0（遗留兼容；8.x 会在安装前拒绝）
HELPEOF
}
#==============================================================#
#             主函数                                           #
#==============================================================#
function main() {
  # 解析命令行参数
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--mode)
        checkpara_NULL "$1" "$2"
        mongo_install_mode="$2"
        shift 2
        ;;
      -n|--hostname)
        checkpara_NULL "$1" "$2"
        hostname="$2"
        shift 2
        ;;
      -p|--port)
        checkpara_NULL "$1" "$2"
        mongo_port="$2"
        shift 2
        ;;
      -d|--dir|--install-dir)
        checkpara_NULL "$1" "$2"
        env_base_dir="$2"
        env_app_dir=${env_base_dir}/app
        data_dir=${env_base_dir}/data
        log_dir=${env_base_dir}/logs
        backup_dir=${env_base_dir}/backup
        scripts_dir=${env_base_dir}/scripts
        pid_dir=${env_base_dir}/run
        mongo_keyfile="${env_base_dir}/keyfile"
        mongo_tools_config="${env_base_dir}/mongodb-tools.yml"
        mongo_auth_js="${env_base_dir}/mongosh-auth.js"
        mongo_tls_dir="${env_base_dir}/tls"
        mongo_tls_ca_path="${mongo_tls_dir}/ca.pem"
        mongo_tls_cert_path="${mongo_tls_dir}/member.pem"
        shift 2
        ;;
      -dd|--data-dir)
        checkpara_NULL "$1" "$2"
        mongo_data_dir_override="$2"
        shift 2
        ;;
      -bd|--backup-dir)
        checkpara_NULL "$1" "$2"
        mongo_backup_dir_override="$2"
        shift 2
        ;;
      -ou|--owner)
        checkpara_NULL "$1" "$2"
        mongo_owner="$2"
        shift 2
        ;;
      -H|--hosts)
        checkpara_NULL "$1" "$2"
        local -a _parsed_hosts=()
        IFS=',' read -ra _parsed_hosts <<< "$2"
        hosts_array=()
        for host in "${_parsed_hosts[@]}"; do
          host="${host//[[:space:]]/}"
          if ! validate_host "$host"; then
            color_printf red "错误: 无效的主机名或 IP 地址: $host"
            exit 1
          fi
          hosts_array+=("$host")
        done
        shift 2
        ;;
      -ri|--remote-ips)
        checkpara_NULL "$1" "$2"
        local -a _parsed_endpoints=()
        IFS=',' read -ra _parsed_endpoints <<< "$2"
        remote_ips_array=()
        for host in "${_parsed_endpoints[@]}"; do
          host="${host//[[:space:]]/}"
          if ! validate_host "$host"; then
            color_printf red "错误: 无效的 SSH 端点主机名或 IP 地址: $host"
            exit 1
          fi
          remote_ips_array+=("$host")
        done
        shift 2
        ;;
      -rp|--root-pass)
        checkpara_NULL "$1" "$2"
        remote_root_pass="$2"
        printf '警告: --root-pass 会暴露在 shell 历史中，请改用 --root-pass-file 或 --ssh-key\n' >&2
        shift 2
        ;;
      -rpf|--root-pass-file)
        checkpara_NULL "$1" "$2"
        remote_root_pass_file="$2"
        shift 2
        ;;
      -sk|--ssh-key)
        checkpara_NULL "$1" "$2"
        ssh_identity_file="$2"
        shift 2
        ;;
      -kh|--known-hosts)
        checkpara_NULL "$1" "$2"
        ssh_known_hosts_file="$2"
        shift 2
        ;;
      -ss|--ssh-port)
        checkpara_NULL "$1" "$2"
        serverport="$2"
        shift 2
        ;;
      -rs|--repl-set)
        checkpara_NULL "$1" "$2"
        repl_set_name="$2"
        shift 2
        ;;
      -a|--auth)
        mongo_auth_enabled=Y
        shift
        ;;
      -na|--no-auth)
        mongo_auth_enabled=N
        shift
        ;;
      -au|--admin-user)
        checkpara_NULL "$1" "$2"
        mongo_admin_user="$2"
        shift 2
        ;;
      -ap|--admin-pass)
        checkpara_NULL "$1" "$2"
        mongo_admin_pass="$2"
        printf '警告: --admin-pass 会暴露在 shell 历史中，请改用 --admin-pass-file\n' >&2
        shift 2
        ;;
      -apf|--admin-pass-file)
        checkpara_NULL "$1" "$2"
        mongo_admin_pass_file="$2"
        shift 2
        ;;
      -t|--tls)
        mongo_tls_enabled=Y
        shift
        ;;
      -nt|--no-tls)
        mongo_tls_enabled=N
        shift
        ;;
      -tca|--tls-ca-file)
        checkpara_NULL "$1" "$2"
        mongo_tls_ca_file="$2"
        shift 2
        ;;
      -tck|--tls-cert-key-file)
        checkpara_NULL "$1" "$2"
        mongo_tls_cert_key_file="$2"
        shift 2
        ;;
      -tcd|--tls-cert-dir)
        checkpara_NULL "$1" "$2"
        mongo_tls_cert_dir="$2"
        shift 2
        ;;
      -cam|--cluster-auth-mode)
        checkpara_NULL "$1" "$2"
        mongo_cluster_auth_mode="$2"
        shift 2
        ;;
      -bi|--bind-ip)
        checkpara_NULL "$1" "$2"
        mongo_bind_ip="$2"
        shift 2
        ;;
      -as|--allow-source)
        checkpara_NULL "$1" "$2"
        local _source
        local -a _sources=()
        IFS=',' read -ra _sources <<< "$2"
        for _source in "${_sources[@]}"; do
          _source="${_source//[[:space:]]/}"
          firewall_sources+=("$_source")
        done
        shift 2
        ;;
      -op|--oplog-size)
        checkpara_NULL "$1" "$2"
        oplog_size_mb="$2"
        shift 2
        ;;
      -mc|--max-connections)
        checkpara_NULL "$1" "$2"
        max_connections="$2"
        shift 2
        ;;
      -j|--remote-parallelism)
        checkpara_NULL "$1" "$2"
        mongo_remote_parallelism="$2"
        shift 2
        ;;
      -oo|--os-only)
        only_conf_os=Y
        shift
        ;;
      -dbg|--debug)
        debug_flag=Y
        shift
        ;;
      -br|--backup-days)
        checkpara_NULL "$1" "$2"
        backup_retention_days="$2"
        shift 2
        ;;
      -mv|--mongo-version)
        checkpara_NULL "$1" "$2"
        if [[ "$2" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
          mongo_major_ver="${BASH_REMATCH[1]}"
          mongo_minor_ver="${BASH_REMATCH[2]}"
          mongo_patch_ver="${BASH_REMATCH[4]:-0}"
        else
          color_printf red "错误: --mongo-version 格式必须为 MAJOR.MINOR[.PATCH]"
          exit 1
        fi
        shift 2
        ;;
      -mp|--mongo-package)
        checkpara_NULL "$1" "$2"
        mongo_package_choice="$2"
        shift 2
        ;;
      -oir|--os-iso-root)
        checkpara_NULL "$1" "$2"
        os_iso_root="$2"
        shift 2
        ;;
      -opd|--os-packages-dir)
        checkpara_NULL "$1" "$2"
        os_packages_dir="$2"
        shift 2
        ;;
      -np|--no-progress)
        MONGO_PROGRESS_MODE=plain
        shift
        ;;
      -y|--yes)
        assume_yes=Y
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        color_printf red "错误: 未知参数: $1" "使用 -h 查看帮助"
        exit 1
        ;;
    esac
  done

  # ---- 开始安装 ----
  finalize_directory_layout || {
    echo "错误: 无法规范化安装、数据或备份目录" >&2
    return 1
  }
  [[ -t 1 && "${TERM:-dumb}" != "dumb" ]] && clear
  logo_print
  echo
  check_prerequisites

  # --os-only 模式
  if [[ "$only_conf_os" == "Y" ]]; then
    case "${mongo_install_mode:-single}" in
      single|si) mongo_install_mode="single" ;;
      replicaset|rs) mongo_install_mode="replicaset" ;;
      *) echo "错误: 无效的安装模式: ${mongo_install_mode}" >&2; return 1 ;;
    esac
    validate_and_finalize_parameters || return $?
    begin_install_timer
    progress_init "$(calculate_total_steps)" "$Mongoinstalllog" || return $?
    progress_set_stage "系统配置"
    execute_and_log "检查主机名" conf_hostname || return $?
    execute_and_log "安装系统依赖" pkg_install || return $?
    execute_and_log "关闭防火墙" conf_firewall || return $?
    execute_and_log "关闭 SELinux" conf_selinux || return $?
    execute_and_log "配置内核参数" conf_sysctl || return $?
    execute_and_log "配置资源限制" conf_limits || return $?
    execute_and_log "配置 THP" conf_thp || return $?
    execute_and_log "检查磁盘挂载" optimize_mounts || return $?
    execute_and_log "配置时间同步" conf_ntp || return $?
    progress_close
    finish_install_timer
    echo "操作系统配置完成"
    echo "本次操作耗时：$(format_duration "$INSTALL_ELAPSED_SECONDS")（${INSTALL_ELAPSED_SECONDS} 秒）"
    echo "详细日志：${Mongoinstalllog}"
    return 0
  fi

  # 交互式选择模式
  if [[ -z "$mongo_install_mode" ]]; then
    echo
    echo "请选择安装模式:"
    echo
    echo "  [1] single       单机模式    适用于开发测试及中小型应用"
    echo "  [2] replicaset   副本集模式  多节点高可用"
    echo
    while true; do
      printf "请输入编号或模式名称 [1-2/si/rs]: "
      read -r _mode_input
      case "${_mode_input,,}" in
        1|single|si)      mongo_install_mode="single";     break ;;
        2|replicaset|rs)  mongo_install_mode="replicaset"; break ;;
        *)
          echo "  无效输入，请重新选择"
          ;;
      esac
    done
  else
    case "$mongo_install_mode" in
      single|si)      mongo_install_mode="single" ;;
      replicaset|rs)  mongo_install_mode="replicaset" ;;
      *)
        color_printf red "错误: 无效的安装模式: $mongo_install_mode" "支持: single|replicaset"
        exit 1
        ;;
    esac
  fi

  validate_and_finalize_parameters || return $?

  if [[ "$mongo_auth_enabled" != "Y" ]] && ! bind_is_loopback_only "$mongo_bind_ip"; then
    color_printf yellow "高风险警告: MongoDB 未启用认证且监听 ${mongo_bind_ip}，任何网络可达主机都可能读写数据"
  fi
  color_printf yellow "系统安全提示: 安装器将停止并禁用防火墙，同时关闭 SELinux"

  # 在动画接管终端前显示非阻断性拓扑提示。
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    local node_count=${#hosts_array[@]}
    (( node_count < 3 )) && color_printf yellow "警告: 副本集建议至少 3 个节点 (当前: ${node_count})"
    (( node_count % 2 == 0 )) && color_printf yellow "警告: 副本集建议使用奇数个节点 (当前: ${node_count})"
  fi

  # 确认安装意图
  local _mode_summary="${mongo_install_mode}"
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    _mode_summary="replicaset (${#hosts_array[@]} 节点, rs=${repl_set_name})"
  fi
  echo
  if [[ "$assume_yes" != "Y" ]]; then
    [[ -t 0 ]] || {
      echo "错误: 非交互安装必须显式指定 --yes" >&2
      return 1
    }
    color_printf purple "即将以 [${_mode_summary}] 模式安装 MongoDB，是否继续？(Y/N) "
  fi

  begin_install_timer
  progress_init "$(calculate_total_steps)" "$Mongoinstalllog" || return $?

  progress_set_stage "安装预检"
  execute_and_log "检测 MongoDB 版本" detect_mongo_version || return $?
  execute_and_log "检查离线安装包" check_packages || return $?
  execute_and_log "验证 OS/CPU/二进制兼容性" validate_mongo_platform_compatibility || return $?

  progress_set_stage "系统配置"
  execute_and_log "检查主机名" conf_hostname || return $?
  execute_and_log "安装系统依赖" pkg_install || return $?
  if [[ "$mongo_tls_enabled" == "Y" ]]; then
    execute_and_log "验证 TLS/X.509 证书" validate_tls_material || return $?
  fi
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    progress_set_stage "集群预检"
    execute_and_log "检查 SSH 与成员 DNS" check_cluster_connectivity || return $?
    progress_set_stage "系统配置"
  fi
  execute_and_log "关闭防火墙" conf_firewall || return $?
  execute_and_log "关闭 SELinux" conf_selinux || return $?
  execute_and_log "配置内核参数" conf_sysctl || return $?
  execute_and_log "配置资源限制" conf_limits || return $?
  execute_and_log "配置 THP" conf_thp || return $?
  execute_and_log "检查磁盘挂载" optimize_mounts || return $?
  execute_and_log "配置时间同步" conf_ntp || return $?

  progress_set_stage "账号与目录"
  execute_and_log "创建系统用户" create_users_groups || return $?
  execute_and_log "创建安全目录结构" create_dir || return $?
  if [[ "$mongo_tls_enabled" == "Y" ]]; then
    execute_and_log "安装 TLS/X.509 证书" install_tls_material || return $?
  fi

  progress_set_stage "安装程序"
  execute_and_log "安装 MongoDB 二进制" install_mongodb || return $?

  progress_set_stage "MongoDB 配置"
  execute_and_log "生成 MongoDB 配置" conf_mongodb || return $?
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    execute_and_log "生成副本集 keyFile" generate_keyfile || return $?
  fi

  progress_set_stage "服务与运维"
  execute_and_log "创建 systemd 服务" create_systemd_service || return $?
  execute_and_log "创建受保护认证配置" create_auth_material || return $?
  execute_and_log "创建备份脚本" create_backup_script || return $?
  execute_and_log "创建监控脚本" create_monitor_script || return $?
  execute_and_log "配置日志轮转" conf_logrotate || return $?

  progress_set_stage "启动服务"
  execute_and_log "启动 MongoDB" start_mongodb || return $?

  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    progress_set_stage "远程节点部署"
    execute_and_log "分发并安装远程节点" deploy_remote_nodes || return $?
    progress_set_stage "副本集初始化"
    execute_and_log "初始化副本集" init_replicaset || return $?
  fi

  if [[ "$mongo_auth_enabled" == "Y" ]]; then
    progress_set_stage "访问控制"
    execute_and_log "创建并验证管理员" create_admin_user || return $?
  fi

  progress_set_stage "安装验证"
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    execute_and_log "验证副本集状态" verify_cluster || return $?
  else
    execute_and_log "验证 MongoDB 服务" verify_installation || return $?
  fi

  progress_set_stage "定时任务"
  execute_and_log "配置非特权定时任务" conf_crontab || return $?

  progress_close
  finish_install_timer
  print_summary
  return 0
}
# ============================================================
# 入口
# ============================================================
if [[ "${MONGO_INSTALL_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
