#!/bin/bash
#==============================================================#
# 脚本名     :   MongoDBShellInstall
# 创建时间   :   2026-04-24 00:00:00
# 描述      :   MongoDB 一键安装脚本（单机/副本集 双模式）
# 路径      :   /soft/MongoDBShellInstall
# 版本      :   1.0.0
# 借鉴      :   KafkaShellInstall
# 兼容      :   RHEL/CentOS/Rocky/Alma 7-9, Debian 10-13, Ubuntu 18.04-24.04,
#               openSUSE/SLES 12-15, Arch Linux, Fedora, Amazon Linux 2/2023
#               (MongoDB 官方支持平台: RHEL 8/9, Debian 11/12, Ubuntu 22.04/24.04,
#                SLES 15, Amazon Linux 2023)
#==============================================================#
set -o pipefail

# 清理临时文件的 trap
MONGO_INSTALL_TMPFILES=()
_ACTIVE_SPINNER_PID=""
cleanup_on_exit() {
  if [[ -n "$_ACTIVE_SPINNER_PID" ]]; then
    kill "$_ACTIVE_SPINNER_PID" 2>/dev/null
    wait "$_ACTIVE_SPINNER_PID" 2>/dev/null
    _ACTIVE_SPINNER_PID=""
  fi
  for tmpf in "${MONGO_INSTALL_TMPFILES[@]}"; do
    [[ -f "$tmpf" ]] && rm -f "$tmpf"
  done
}
trap cleanup_on_exit EXIT INT TERM

make_tempfile() {
  local tmpf
  tmpf=$(mktemp /tmp/mongo_install.XXXXXX)
  MONGO_INSTALL_TMPFILES+=("$tmpf")
  echo "$tmpf"
}
#==============================================================#
#                         全局变量定义                         #
#==============================================================#
MONGO_INSTALL_VERSION="1.0.0"

software_dir=$(dirname "$(readlink -f "$0")")
script_name=$(basename "$0")
[[ $(find "$software_dir" -name "print_mongo_install_*.log" 2>/dev/null) ]] && rm -f "$software_dir"/print_mongo_install_*.log
current=$(date +%Y%m%d%H%M%S)
Mongoinstalllog="$software_dir/print_mongo_install_$current.log"

# 操作系统信息
os_distro="unknown"
os_distro_family="unknown"
if [[ -f /etc/os-release ]]; then
  os_distro=$(. /etc/os-release && echo "${ID:-unknown}")
  os_version=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
  os_version=${os_version:-0}
elif [[ -f /etc/redhat-release ]]; then
  os_distro="centos"
  os_version=$(sed -r 's/.* ([0-9]+)\..*/\1/' /etc/redhat-release 2>/dev/null || echo "unknown")
else
  os_version="0"
fi

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
os_memory_mb=$((${os_memory_total:-0} / 1024))
os_core=$(grep -c '^processor' /proc/cpuinfo)

# MongoDB 安装默认值
hostname=mongodb
mongo_owner=mongod
mongo_port=27017
debug_flag=N

# 目录结构
env_base_dir=/mongodb
env_app_dir=${env_base_dir}/app
data_dir=${env_base_dir}/data
log_dir=${env_base_dir}/logs
backup_dir=${env_base_dir}/backup
scripts_dir=${env_base_dir}/scripts
pid_dir=${env_base_dir}/run

# 安装模式: single / replicaset (空=交互选择)
declare -l mongo_install_mode=""
# 仅配置操作系统
declare -u only_conf_os=N
# 节点 IP 数组
declare -a hosts_array
# SSH 端口
export serverport=22
# 远程 root 密码
remote_root_pass=""

# 副本集名称
repl_set_name="rs0"

# MongoDB 版本号 (安装时检测填充)
mongo_major_ver=0
mongo_minor_ver=0
mongo_patch_ver=0

# WiredTiger 缓存大小 (自动计算，单位 GB)
wt_cache_size_gb=0

# 认证相关
mongo_auth_enabled=N
mongo_admin_user="admin"
mongo_admin_pass=""
# keyFile 路径 (副本集模式认证)
mongo_keyfile="${env_base_dir}/keyfile"

# 可配置运维参数
backup_retention_days=7
# oplog 大小 (MB, 0=自动)
oplog_size_mb=0
# 最大连接数
max_connections=65536
# journal: MongoDB 6.2+ 移除了 storage.journal.enabled 选项 (journal 始终开启)
# 此变量仅用于 MongoDB 4.x/5.x/6.0-6.1 的兼容
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

function is_local_host() {
  local target="$1"
  local local_ip="$2"
  [[ "$target" == "$local_ip" || "$target" == "127.0.0.1" || "$target" == "localhost" ]] && return 0
  local resolved
  resolved=$(getent hosts "$target" 2>/dev/null | awk '{print $1}')
  [[ -n "$resolved" && "$resolved" == "$local_ip" ]] && return 0
  [[ -n "$resolved" && "$resolved" == "127.0.0.1" ]] && return 0
  if ip -4 addr show 2>/dev/null | grep -qw "$target"; then
    return 0
  fi
  return 1
}

function create_mongo_symlinks() {
  local app_dir="${1:-$env_app_dir}"
  for cmd in mongod mongos mongosh mongo; do
    if [[ -f "${app_dir}/bin/${cmd}" ]]; then
      ln -sf "${app_dir}/bin/${cmd}" "/usr/local/bin/${cmd}"
    fi
  done
  # mongodump / mongorestore / mongostat / mongotop
  for tool in mongodump mongorestore mongoexport mongoimport mongostat mongotop; do
    if [[ -f "${app_dir}/bin/${tool}" ]]; then
      ln -sf "${app_dir}/bin/${tool}" "/usr/local/bin/${tool}"
    fi
  done
}
#==============================================================#
#                         颜色打印                             #
#==============================================================#
function color_printf() {
  declare -u con_flag
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
    printf "\n${color}%-20s %-30s %-50s\n${res}\n" "$2" "$3" "$4" >&2
    { printf "\n${color}%-20s %-30s %-50s\n${res}\n" "$2" "$3" "$4" >&3; } 2>/dev/null
    return 1
    ;;
  "green" | "light_blue")
    printf "${color}%-20s %-30s %-50s\n${res}" "$2" "$3" "$4"
    ;;
  "purple")
    printf "${color}%-s${res}" "$2" "$3"
    read -r con_flag
    if [[ -z $con_flag ]]; then con_flag=Y; fi
    if [[ $con_flag != "Y" ]]; then echo; exit 1; fi
    ;;
  *)
    printf "${color}%-20s %-30s %-50s\n${res}\n" "$2" "$3" "$4"
    ;;
  esac
}
#==============================================================#
#                  执行命令并输出日志文件                       #
#==============================================================#
function execute_and_log() {
  if [[ $# -lt 2 ]]; then
    echo "错误: execute_and_log 需要至少2个参数 (prompt, cmd)"
    return 1
  fi

  local prompt="$1"
  local cmd="$2"
  local log_file="${3:-$Mongoinstalllog}"
  local start_time end_time execution_time status

  if [[ -z "$log_file" ]]; then
    echo "错误: 日志文件路径不能为空"
    return 1
  fi

  echo -e "\e[1;34m${prompt}\e[0m\c"
  printf " "
  start_time=$(date +%s)

  {
    echo "=========================================="
    echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "任务: $prompt"
    echo "命令: $cmd"
    echo "------------------------------------------"
  } >>"$log_file"

  if [[ "$debug_flag" == "Y" ]]; then
    echo ""
    printf "\e[0;33m[DEBUG] 开始执行: %s\e[0m\n" "$cmd"
    echo "------------------------------------------"
    local _tmpout
    _tmpout=$(make_tempfile)
    exec 3>&1
    if [[ "$cmd" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      "$cmd" >"$_tmpout" 2>&1
    else
      eval "$cmd" >"$_tmpout" 2>&1
    fi
    status=$?
    exec 3>&-
    cat "$_tmpout"
    cat "$_tmpout" >>"$log_file"
    rm -f "$_tmpout"
    end_time=$(date +%s)
    execution_time=$((end_time - start_time))
    printf "\033[K\n"
  else
    (
      local spinner_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
      local spinner_index=0
      while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        printf "\033[K\e[1;34m${prompt}\e[0m %s 执行中... (%ds)\r" "${spinner_chars[$spinner_index]}" "$elapsed"
        ((spinner_index = (spinner_index + 1) % ${#spinner_chars[@]}))
        sleep 0.5
      done
    ) &
    _ACTIVE_SPINNER_PID=$!

    exec 3>&1
    if [[ "$cmd" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      "$cmd" >>"$log_file" 2>&1
    else
      eval "$cmd" >>"$log_file" 2>&1
    fi
    status=$?
    exec 3>&-

    kill "$_ACTIVE_SPINNER_PID" 2>/dev/null
    wait "$_ACTIVE_SPINNER_PID" 2>/dev/null
    _ACTIVE_SPINNER_PID=""
    end_time=$(date +%s)
    execution_time=$((end_time - start_time))
    printf "\033[K\n"
  fi

  {
    echo "执行结果: 退出码=$status, 耗时=${execution_time}秒"
    echo "=========================================="
    echo ""
  } >>"$log_file"

  if (( status == 0 )); then
    printf "\e[1;34m${prompt}\e[0m ✓ 已完成 (耗时: %s 秒)\n" "$execution_time"
  elif (( status == 3 )); then
    printf "\e[1;34m${prompt}\e[0m ⚠ 已完成 (耗时: %s 秒)\n" "$execution_time"
  else
    case "$cmd" in
      pkg_install|conf_firewall|conf_sysctl)
        printf "\e[1;34m${prompt}\e[0m ⚠ 已完成 (耗时: %s 秒)\n" "$execution_time"
        ;;
      *)
        printf "\e[1;34m${prompt}\e[0m ✗ 执行失败 (退出码: %d, 耗时: %s 秒)\n" "$status" "$execution_time"
        printf "请检查日志文件: %s\n" "$log_file"
        if [[ -f "$log_file" ]]; then
          echo "最近的日志内容:"
          tail -n 5 "$log_file" | sed 's/^/  /'
        fi
        return 1
        ;;
    esac
  fi
  return 0
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
  MongoDB One-Click Installer v1.0.0 (Standalone + ReplicaSet)
EOF
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
  local ip="$1"
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi
  local IFS='.'
  read -ra octets <<< "$ip"
  for o in "${octets[@]}"; do
    if (( o < 0 || o > 255 )); then return 1; fi
  done
  return 0
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
  # 查找 MongoDB 安装包 (排除 database-tools 和 mongosh)
  mongo_tarball=$(ls -1 "${software_dir}"/mongodb-linux-*.tgz 2>/dev/null | grep -v database-tools | grep -v mongosh | head -n1)
  if [[ -z "$mongo_tarball" ]]; then
    mongo_tarball=$(ls -1 "${software_dir}"/mongodb-linux-*.tar.gz 2>/dev/null | grep -v database-tools | grep -v mongosh | head -n1)
  fi
  if [[ -z "$mongo_tarball" ]]; then
    mongo_tarball=$(ls -1 "${software_dir}"/mongodb-*.tgz 2>/dev/null | grep -v database-tools | grep -v mongosh | head -n1)
  fi
  if [[ -z "$mongo_tarball" ]]; then
    mongo_tarball=$(ls -1 "${software_dir}"/mongodb-*.tar.gz 2>/dev/null | grep -v database-tools | grep -v mongosh | head -n1)
  fi
  if [[ -z "$mongo_tarball" ]]; then
    color_printf red "错误: 未找到 MongoDB 安装包" "请将 mongodb-linux-*.tgz 放在: ${software_dir}"
    return 1
  fi

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
}
#==============================================================#
#                   检查安装包                                 #
#==============================================================#
function check_packages() {
  log_print "检查安装包"

  local mongo_tarball
  mongo_tarball=$(ls -1 "${software_dir}"/mongodb-linux-*.tgz "${software_dir}"/mongodb-linux-*.tar.gz \
                       "${software_dir}"/mongodb-*.tgz "${software_dir}"/mongodb-*.tar.gz 2>/dev/null \
                  | grep -v database-tools | grep -v mongosh | head -n1)
  if [[ -z "$mongo_tarball" ]]; then
    color_printf red "错误: 未找到 MongoDB 安装包 (mongodb-linux-*.tgz / mongodb-*.tar.gz)" \
                     "请将安装包放在: ${software_dir}"
    return 1
  fi

  echo "MongoDB 安装包: $(basename "$mongo_tarball")"

  # 检查 mongosh 安装包 (可选, 支持多种包名格式)
  local mongosh_tarball
  mongosh_tarball=$(ls -1 "${software_dir}"/mongosh-*.tgz "${software_dir}"/mongosh-*.tar.gz 2>/dev/null | head -n1)
  if [[ -n "$mongosh_tarball" ]]; then
    echo "mongosh 安装包: $(basename "$mongosh_tarball")"
  else
    echo "提示: 未找到 mongosh 安装包 (MongoDB 6.0+ 不再自带 mongo shell)"
    echo "      推荐下载: https://www.mongodb.com/try/download/shell"
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
function pkg_install() {
  log_print "安装依赖包"
  local pkgs_common="numactl openssl curl net-tools"
  case "$os_distro_family" in
    rhel)
      if command -v dnf &>/dev/null; then
        dnf install -y -q ${pkgs_common} sysstat lsof cyrus-sasl cyrus-sasl-plain cyrus-sasl-gssapi 2>/dev/null
      elif command -v yum &>/dev/null; then
        yum install -y -q ${pkgs_common} sysstat lsof cyrus-sasl cyrus-sasl-plain cyrus-sasl-gssapi 2>/dev/null
      fi
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq 2>/dev/null
      apt-get install -y -qq ${pkgs_common} sysstat lsof libsasl2-2 snmp 2>/dev/null
      ;;
    suse)
      zypper --non-interactive install ${pkgs_common} sysstat lsof 2>/dev/null
      ;;
    arch)
      pacman -Sy --noconfirm --needed ${pkgs_common} sysstat lsof 2>/dev/null
      ;;
    *)
      echo "警告: 未知包管理器，跳过依赖安装"
      ;;
  esac
}
#==============================================================#
#                   创建用户与目录                             #
#==============================================================#
function create_users_groups() {
  log_print "创建 MongoDB 系统用户"
  if ! grep -q "^${mongo_owner}:" /etc/group 2>/dev/null; then
    groupadd -g 60300 "${mongo_owner}"
  fi
  if ! id "${mongo_owner}" &>/dev/null; then
    useradd -u 60300 -g "${mongo_owner}" -s "${NOLOGIN_PATH}" -M "${mongo_owner}"
  else
    usermod -s "${NOLOGIN_PATH}" "${mongo_owner}" 2>/dev/null
  fi
  passwd -l "${mongo_owner}" &>/dev/null
}

function create_dir() {
  log_print "创建 MongoDB 目录结构"
  local dirs=(
    "$env_base_dir" "$env_app_dir" "$data_dir"
    "${data_dir}/db" "${data_dir}/configdb"
    "$log_dir" "$backup_dir" "$scripts_dir" "$pid_dir"
  )
  for d in "${dirs[@]}"; do
    mkdir -p "$d"
  done
  chown -R "${mongo_owner}:${mongo_owner}" "$env_base_dir"
  chmod -R 750 "$env_base_dir"
}
#==============================================================#
#                   OS 优化函数                                #
#==============================================================#
function conf_hostname() {
  local new_hostname="$hostname"
  if [[ "$mongo_install_mode" != "single" ]]; then
    local _lip
    _lip=$(get_local_ip)
    if [[ -n "$_lip" ]]; then
      local ip_short
      ip_short=$(echo "$_lip" | awk -F. '{print $3$4}')
      new_hostname="${hostname}${ip_short}"
    fi
  fi
  log_print "设置主机名: ${new_hostname}"
  if command -v hostnamectl &>/dev/null; then
    hostnamectl set-hostname "$new_hostname"
  else
    hostname "$new_hostname"
    echo "$new_hostname" > /etc/hostname
  fi
  if ! grep -q "$new_hostname" /etc/hosts 2>/dev/null; then
    local bind_ip
    bind_ip=$(get_local_ip)
    bind_ip="${bind_ip:-127.0.0.1}"
    echo "${bind_ip}  ${new_hostname}" >> /etc/hosts
  fi
}

function conf_firewall() {
  log_print "配置防火墙"
  if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null 2>&1; then
    systemctl stop firewalld 2>/dev/null
    systemctl disable firewalld 2>/dev/null
  elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "active"; then
    ufw disable 2>/dev/null
  elif command -v iptables &>/dev/null; then
    if (( HAS_SYSTEMD )); then
      systemctl stop iptables 2>/dev/null
      systemctl disable iptables 2>/dev/null
    else
      service iptables stop 2>/dev/null
      chkconfig iptables off 2>/dev/null
    fi
  else
    echo "未检测到活跃的防火墙服务，跳过"
  fi
}

function conf_selinux() {
  log_print "关闭 SELinux"
  setenforce 0 2>/dev/null
  if [[ -f /etc/selinux/config ]]; then
    sed -i -e 's/SELINUX=enforcing/SELINUX=disabled/g' \
           -e 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
  fi
}

function conf_sysctl() {
  log_print "优化内核参数"
  bak_file /etc/sysctl.conf

  local mem_kb=${os_memory_total}
  local mem_mb=$((mem_kb / 1024))

  # vm.swappiness=1: MongoDB 官方建议最小化 swap 使用
  local swappiness=1
  # dirty_ratio: MongoDB 随机 I/O 为主，适当控制脏页
  local dirty_ratio=15
  local dirty_background_ratio=5
  # dirty_expire_centisecs: 30s (官方推荐范围)
  local dirty_expire=3000

  local somaxconn=65535
  # tcp_keepalive_time=120: MongoDB 官方推荐值
  local tcp_keepalive_time=120
  local tcp_keepalive_intvl=10
  local tcp_keepalive_probes=9

  local rmem_max=16777216
  local wmem_max=16777216

  # fs.file-max: 至少 64000 (MongoDB 启动检查)
  local file_max=2097152

  cat > /etc/sysctl.d/99-mongodb.conf <<SYSEOF
# MongoBegin - MongoDB 系统内核参数优化
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 参照: https://www.mongodb.com/docs/manual/administration/production-notes/

#---------- 内存管理 ----------
# MongoDB 官方: 尽量避免 swap
vm.swappiness = ${swappiness}
vm.dirty_ratio = ${dirty_ratio}
vm.dirty_background_ratio = ${dirty_background_ratio}
vm.dirty_expire_centisecs = ${dirty_expire}
# NUMA: 禁用 zone_reclaim (MongoDB 官方推荐)
vm.zone_reclaim_mode = 0
# vm.max_map_count: MongoDB WiredTiger 需要足够的 mmap 区域
vm.max_map_count = 262144

#---------- 网络参数 ----------
net.core.somaxconn = ${somaxconn}
# tcp_keepalive_time=120: MongoDB 官方推荐 (匹配云负载均衡超时)
net.ipv4.tcp_keepalive_time = ${tcp_keepalive_time}
net.ipv4.tcp_keepalive_intvl = ${tcp_keepalive_intvl}
net.ipv4.tcp_keepalive_probes = ${tcp_keepalive_probes}
net.ipv4.tcp_tw_reuse = 1
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 262144

#---------- 文件系统 ----------
fs.file-max = ${file_max}
# MongoEnd
SYSEOF

  sysctl --system >/dev/null 2>&1

  # readahead: MongoDB 官方推荐 8-32 (WiredTiger)
  # 仅在数据目录非根分区时设置
  local data_dev
  data_dev=$(df "${data_dir}" 2>/dev/null | awk 'NR==2{print $1}')
  if [[ -n "$data_dev" && "$data_dev" != "none" ]]; then
    local blk_dev
    blk_dev=$(basename "$data_dev" | sed 's/[0-9]*$//')
    if [[ -f "/sys/block/${blk_dev}/queue/read_ahead_kb" ]]; then
      # 设置 readahead 为 16KB (MongoDB 官方推荐范围 8-32)
      echo 16 > "/sys/block/${blk_dev}/queue/read_ahead_kb" 2>/dev/null
      echo "readahead 已设置为 16KB (${blk_dev})"
    fi
  fi
}

function conf_limits() {
  log_print "配置资源限制"
  bak_file /etc/security/limits.conf

  # MongoDB 官方: ulimit -n (nofile) 至少 64000，否则启动时发出警告
  # 推荐设置为足够大的值
  cat >> /etc/security/limits.conf <<LIMEOF
# MongoBegin - MongoDB 资源限制
# 参照: https://www.mongodb.com/docs/manual/reference/ulimit/
${mongo_owner}  soft  nofile  1048576
${mongo_owner}  hard  nofile  1048576
${mongo_owner}  soft  nproc   65536
${mongo_owner}  hard  nproc   65536
${mongo_owner}  soft  core    unlimited
${mongo_owner}  hard  core    unlimited
${mongo_owner}  soft  memlock unlimited
${mongo_owner}  hard  memlock unlimited
${mongo_owner}  soft  stack   65536
${mongo_owner}  hard  stack   65536
# MongoEnd
LIMEOF

  if [[ -d /etc/security/limits.d ]]; then
    cat > /etc/security/limits.d/99-mongodb.conf <<LIMDEOF
# MongoDB 资源限制 (官方推荐 nofile >= 64000)
${mongo_owner}  soft  nofile  1048576
${mongo_owner}  hard  nofile  1048576
${mongo_owner}  soft  nproc   65536
${mongo_owner}  hard  nproc   65536
${mongo_owner}  soft  core    unlimited
${mongo_owner}  hard  core    unlimited
${mongo_owner}  soft  memlock unlimited
${mongo_owner}  hard  memlock unlimited
${mongo_owner}  soft  stack   65536
${mongo_owner}  hard  stack   65536
LIMDEOF
  fi
}

function conf_thp() {
  log_print "配置 Transparent Huge Pages (THP)"
  # MongoDB 8.0+: 使用 TCMalloc，官方建议 **启用** THP
  # MongoDB 7.0 及更早: 官方建议 **禁用** THP

  if (( mongo_major_ver >= 8 )); then
    echo "MongoDB ${mongo_major_ver}.${mongo_minor_ver}: 启用 THP (TCMalloc 优化)"
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
      echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi
    if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
      echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
    fi

    if (( HAS_SYSTEMD )); then
      cat > /etc/systemd/system/mongodb-thp.service <<'THPEOF'
[Unit]
Description=Enable Transparent Huge Pages for MongoDB 8.0+ (TCMalloc)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo always > /sys/kernel/mm/transparent_hugepage/enabled && echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
THPEOF
      systemctl daemon-reload
      systemctl enable mongodb-thp.service 2>/dev/null
      systemctl start mongodb-thp.service 2>/dev/null
    fi
  else
    echo "MongoDB ${mongo_major_ver}.${mongo_minor_ver}: 禁用 THP (官方推荐)"
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
      echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi
    if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
      echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
    fi

    if (( HAS_SYSTEMD )); then
      cat > /etc/systemd/system/disable-thp.service <<'THPEOF'
[Unit]
Description=Disable Transparent Huge Pages for MongoDB (pre-8.0)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
THPEOF
      systemctl daemon-reload
      systemctl enable disable-thp.service 2>/dev/null
      systemctl start disable-thp.service 2>/dev/null
    else
      if [[ -f /etc/rc.local ]]; then
        if ! grep -q "transparent_hugepage" /etc/rc.local 2>/dev/null; then
          cat >> /etc/rc.local <<'RCEOF'
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
RCEOF
        fi
      fi
    fi
  fi
}

function optimize_mounts() {
  log_print "优化磁盘挂载选项"
  local data_mount
  data_mount=$(df "${data_dir}" 2>/dev/null | awk 'NR==2{print $6}')
  if [[ -z "$data_mount" || "$data_mount" == "/" ]]; then
    echo "数据目录挂载在根分区，跳过挂载优化"
    return 0
  fi

  # MongoDB 官方: 强烈推荐 XFS 文件系统
  local fs_type
  fs_type=$(df -T "${data_dir}" 2>/dev/null | awk 'NR==2{print $2}')
  if [[ "$fs_type" == "xfs" ]]; then
    echo "数据分区使用 XFS 文件系统 (推荐)"
  elif [[ "$fs_type" == "ext4" ]]; then
    echo "数据分区使用 EXT4 文件系统"
    echo "建议: MongoDB 官方强烈推荐使用 XFS 以获得更好性能"
  else
    echo "数据分区文件系统: ${fs_type:-unknown}"
    echo "建议: MongoDB 官方推荐使用 XFS 文件系统"
  fi

  if grep -q "$data_mount" /etc/fstab 2>/dev/null; then
    if ! grep "$data_mount" /etc/fstab | grep -q "noatime"; then
      echo "建议: 为数据分区 ${data_mount} 添加 noatime 挂载选项以提升性能"
    fi
  fi
}

function conf_ntp() {
  log_print "配置时间同步"
  if command -v chronyc &>/dev/null; then
    if (( HAS_SYSTEMD )); then
      systemctl enable chronyd 2>/dev/null
      systemctl start chronyd 2>/dev/null
    fi
    echo "时间同步: chronyd 已启用"
  elif command -v ntpd &>/dev/null || command -v ntpdate &>/dev/null; then
    if (( HAS_SYSTEMD )); then
      systemctl enable ntpd 2>/dev/null
      systemctl start ntpd 2>/dev/null
    fi
    echo "时间同步: ntpd 已启用"
  elif command -v timedatectl &>/dev/null; then
    timedatectl set-ntp true 2>/dev/null
    echo "时间同步: systemd-timesyncd 已启用"
  else
    echo "警告: 未找到时间同步服务，请手动配置"
    echo "MongoDB 副本集对时钟同步有严格要求"
  fi
}
#==============================================================#
#                   安装 MongoDB                               #
#==============================================================#
function install_mongodb() {
  log_print "安装 MongoDB"

  local mongo_tarball
  mongo_tarball=$(ls -1 "${software_dir}"/mongodb-linux-*.tgz "${software_dir}"/mongodb-linux-*.tar.gz \
                       "${software_dir}"/mongodb-*.tgz "${software_dir}"/mongodb-*.tar.gz 2>/dev/null \
                  | grep -v database-tools | grep -v mongosh | head -n1)
  if [[ -z "$mongo_tarball" ]]; then
    color_printf red "错误: 未找到 MongoDB 安装包" "请将安装包放在: ${software_dir}"
    return 1
  fi

  echo "使用安装包: $(basename "$mongo_tarball")"

  local mongo_tmpdir
  mongo_tmpdir=$(mktemp -d /tmp/mongo_install.XXXXXX)
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
    if [[ -d "${env_app_dir}/bin" ]]; then
      rm -rf "${env_app_dir}.old"
      mv "${env_app_dir}" "${env_app_dir}.old"
    else
      rm -rf "${env_app_dir}"
    fi
  fi
  cp -rf "$mongo_src_dir" "${env_app_dir}"
  rm -rf "$mongo_tmpdir"

  # 安装 mongosh (如果有单独的安装包)
  local mongosh_tarball
  mongosh_tarball=$(ls -1 "${software_dir}"/mongosh-*.tgz "${software_dir}"/mongosh-*.tar.gz 2>/dev/null | head -n1)
  if [[ -n "$mongosh_tarball" ]]; then
    echo "安装 mongosh: $(basename "$mongosh_tarball")"
    local mongosh_tmpdir
    mongosh_tmpdir=$(mktemp -d /tmp/mongosh_install.XXXXXX)
    if tar xzf "$mongosh_tarball" -C "$mongosh_tmpdir" 2>/dev/null; then
      local mongosh_src_dir
      mongosh_src_dir=$(ls -1d "${mongosh_tmpdir}"/mongosh-* 2>/dev/null | head -n1)
      if [[ -n "$mongosh_src_dir" && -f "${mongosh_src_dir}/bin/mongosh" ]]; then
        cp -f "${mongosh_src_dir}/bin/mongosh" "${env_app_dir}/bin/"
        echo "mongosh 安装完成"
      fi
    fi
    rm -rf "$mongosh_tmpdir"
  fi

  # 安装 MongoDB Database Tools (如果有)
  local tools_tarball
  tools_tarball=$(ls -1 "${software_dir}"/mongodb-database-tools-*.tgz "${software_dir}"/mongodb-database-tools-*.tar.gz 2>/dev/null | head -n1)
  if [[ -n "$tools_tarball" ]]; then
    echo "安装 Database Tools: $(basename "$tools_tarball")"
    local tools_tmpdir
    tools_tmpdir=$(mktemp -d /tmp/mongotools_install.XXXXXX)
    if tar xzf "$tools_tarball" -C "$tools_tmpdir" 2>/dev/null; then
      local tools_src_dir
      tools_src_dir=$(ls -1d "${tools_tmpdir}"/mongodb-database-tools-* 2>/dev/null | head -n1)
      if [[ -n "$tools_src_dir" && -d "${tools_src_dir}/bin" ]]; then
        cp -f "${tools_src_dir}"/bin/* "${env_app_dir}/bin/" 2>/dev/null
        echo "Database Tools 安装完成"
      fi
    fi
    rm -rf "$tools_tmpdir"
  fi

  # 验证安装结果
  if [[ ! -f "${env_app_dir}/bin/mongod" ]]; then
    color_printf red "错误: mongod 不存在" "安装目录: ${env_app_dir}/bin/"
    return 1
  fi

  create_mongo_symlinks
  chown -R "${mongo_owner}:${mongo_owner}" "${env_app_dir}"
  echo "MongoDB 安装完成: ${env_app_dir}"
}
#==============================================================#
#               计算 WiredTiger 缓存大小                       #
#==============================================================#
function calc_wt_cache() {
  local mem_kb=${os_memory_total}
  local mem_mb=$((mem_kb / 1024))
  local mem_gb=$((mem_mb / 1024))

  # MongoDB 官方推荐: WiredTiger cache = (RAM - 1GB) * 50% 或 256MB (取较大值)
  # 最小 256MB
  if (( mem_gb <= 2 )); then
    wt_cache_size_gb=0.25
  elif (( mem_gb <= 4 )); then
    wt_cache_size_gb=1
  elif (( mem_gb <= 8 )); then
    wt_cache_size_gb=2
  elif (( mem_gb <= 16 )); then
    wt_cache_size_gb=4
  elif (( mem_gb <= 32 )); then
    wt_cache_size_gb=8
  elif (( mem_gb <= 64 )); then
    wt_cache_size_gb=16
  else
    wt_cache_size_gb=24
  fi

  echo "WiredTiger 缓存: ${wt_cache_size_gb}GB (物理内存: ${mem_gb}GB)"
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

  calc_wt_cache

  local local_ip
  local_ip=$(get_local_ip)
  local_ip="${local_ip:-127.0.0.1}"

  # oplog 大小计算 (默认: 数据目录所在磁盘 5%, 或手动指定)
  if (( oplog_size_mb == 0 )); then
    local disk_mb
    disk_mb=$(df -BM "${data_dir}" 2>/dev/null | awk 'NR==2{gsub("M",""); print $2}')
    disk_mb=${disk_mb:-51200}
    oplog_size_mb=$((disk_mb * 5 / 100))
    (( oplog_size_mb < 990 )) && oplog_size_mb=990
    (( oplog_size_mb > 51200 )) && oplog_size_mb=51200
  fi

  # ============ 版本感知: storage.journal 配置 ============
  # MongoDB 6.2+ 移除了 storage.journal.enabled (journal 始终开启)
  # MongoDB 4.x/5.x/6.0-6.1 仍使用该选项
  local journal_conf=""
  if (( mongo_major_ver < 6 || (mongo_major_ver == 6 && mongo_minor_ver < 2) )); then
    journal_conf="  journal:
    enabled: true"
  fi

  # ============ 副本集配置段 ============
  local repl_conf=""
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    # enableMajorityReadConcern: MongoDB 5.0+ 始终为 true 且不可配置
    if (( mongo_major_ver < 5 )); then
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
      security_conf="security:
  authorization: \"enabled\"
  keyFile: \"${mongo_keyfile}\""
    else
      security_conf="security:
  authorization: \"enabled\""
    fi
  elif [[ "$mongo_install_mode" == "replicaset" ]]; then
    security_conf="security:
  keyFile: \"${mongo_keyfile}\""
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
  # MongoDB 8.0+: tcmallocReleaseRate 推荐调优
  local set_param="setParameter:
  enableLocalhostAuthBypass: true"
  if (( mongo_major_ver >= 8 )); then
    set_param="setParameter:
  enableLocalhostAuthBypass: true
  tcmallocReleaseRate: 5.0"
  fi

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
  bindIp: "0.0.0.0"
  maxIncomingConnections: ${max_connections}
  ipv6: false

${security_conf}

${repl_conf}

${set_param}
CONFEOF
  } > "${env_base_dir}/mongod.conf"

  # 清理配置文件中的空行 (空 journal_conf/repl_conf 段可能导致多余空行)
  sed -i '/^$/N;/^\n$/d' "${env_base_dir}/mongod.conf"

  chown "${mongo_owner}:${mongo_owner}" "${env_base_dir}/mongod.conf"
  chmod 640 "${env_base_dir}/mongod.conf"

  echo "MongoDB 配置文件已生成: ${env_base_dir}/mongod.conf"
}
#==============================================================#
#             生成 keyFile (副本集认证)                         #
#==============================================================#
function generate_keyfile() {
  log_print "生成副本集 keyFile"

  if [[ "$mongo_install_mode" != "replicaset" && "$mongo_auth_enabled" != "Y" ]]; then
    echo "非副本集模式且未启用认证，跳过 keyFile 生成"
    return 0
  fi

  if [[ -f "$mongo_keyfile" ]]; then
    echo "keyFile 已存在: ${mongo_keyfile}"
    return 0
  fi

  openssl rand -base64 756 > "$mongo_keyfile"
  chown "${mongo_owner}:${mongo_owner}" "$mongo_keyfile"
  chmod 400 "$mongo_keyfile"
  echo "keyFile 已生成: ${mongo_keyfile}"
}
#==============================================================#
#             创建 systemd 服务                                #
#==============================================================#
function create_systemd_service() {
  log_print "创建 systemd 服务文件"

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
ReadWritePaths=${env_base_dir}"
  fi

  # NUMA 优化: 使用 numactl --interleave=all 启动 (官方推荐)
  local exec_prefix=""
  if command -v numactl &>/dev/null; then
    exec_prefix="numactl --interleave=all "
  fi

  cat > /etc/systemd/system/mongod.service <<SVCEOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.com/manual
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${mongo_owner}
Group=${mongo_owner}
ExecStart=${exec_prefix}${env_app_dir}/bin/mongod --config ${env_base_dir}/mongod.conf
ExecStop=/bin/kill -s SIGTERM \$MAINPID
ExecReload=/bin/kill -s SIGHUP \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=300

# 资源限制
LimitNOFILE=1048576
LimitNPROC=65536
LimitCORE=infinity
LimitMEMLOCK=infinity

# OOM 保护
OOMScoreAdjust=-999

# 安全加固
${security_opts}

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable mongod.service

  echo "systemd 服务已创建并启用"
}
#==============================================================#
#             创建备份脚本                                     #
#==============================================================#
function create_backup_script() {
  log_print "创建备份脚本"

  local local_ip
  local_ip=$(get_local_ip)
  local_ip="${local_ip:-127.0.0.1}"

  cat > "${scripts_dir}/mongo_backup.sh" <<'BAKEOF'
#!/bin/bash
#==============================================================#
# MongoDB 备份脚本
# 支持 mongodump 逻辑备份
#==============================================================#

MONGO_APP_DIR="MONGO_APP_DIR_PLACEHOLDER"
MONGO_BASE_DIR="MONGO_BASE_DIR_PLACEHOLDER"
MONGO_DATA_DIR="MONGO_DATA_DIR_PLACEHOLDER"
BACKUP_DIR="MONGO_BACKUP_DIR_PLACEHOLDER"
LOG_FILE="MONGO_LOG_DIR_PLACEHOLDER/mongo_backup.log"
RETENTION_DAYS=MONGO_RETENTION_PLACEHOLDER
LOCAL_IP="MONGO_LOCAL_IP_PLACEHOLDER"
MONGO_PORT="MONGO_PORT_PLACEHOLDER"
INSTALL_MODE="MONGO_INSTALL_MODE_PLACEHOLDER"
exit_code=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

backup_date=$(date +%Y%m%d_%H%M%S)
backup_path="${BACKUP_DIR}/${backup_date}"
mkdir -p "$backup_path"
if [[ $? -ne 0 ]]; then
  log "错误: 无法创建备份目录 $backup_path"
  exit 1
fi

log "开始 MongoDB 备份... (模式: ${INSTALL_MODE})"

# 备份 mongod.conf
if [[ -f "${MONGO_BASE_DIR}/mongod.conf" ]]; then
  cp -f "${MONGO_BASE_DIR}/mongod.conf" "${backup_path}/"
  log "配置文件备份完成"
fi

# mongodump 逻辑备份
MONGODUMP="${MONGO_APP_DIR}/bin/mongodump"
if [[ -f "$MONGODUMP" ]]; then
  if "$MONGODUMP" --host "${LOCAL_IP}" --port "${MONGO_PORT}" \
     --out "${backup_path}/dump" --gzip 2>>"$LOG_FILE"; then
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
expired_count=$(find "$BACKUP_DIR" -name "*.tar.gz" -mtime +${RETENTION_DAYS} 2>/dev/null | wc -l)
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null
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
    -e "s|MONGO_LOCAL_IP_PLACEHOLDER|${local_ip}|g" \
    -e "s|MONGO_PORT_PLACEHOLDER|${mongo_port}|g" \
    -e "s|MONGO_INSTALL_MODE_PLACEHOLDER|${mongo_install_mode}|g" \
    "${scripts_dir}/mongo_backup.sh"

  chmod 750 "${scripts_dir}/mongo_backup.sh"
  chown "${mongo_owner}:${mongo_owner}" "${scripts_dir}/mongo_backup.sh"
}
#==============================================================#
#             创建监控脚本                                     #
#==============================================================#
function create_monitor_script() {
  log_print "创建监控脚本"

  cat > "${scripts_dir}/mongo_monitor.sh" <<'MONEOF'
#!/bin/bash
#==============================================================#
# MongoDB 健康检查与监控脚本
#==============================================================#

MONGO_APP_DIR="MONGO_APP_DIR_PLACEHOLDER"
MONGO_PORT="MONGO_PORT_PLACEHOLDER"
LOG_FILE="MONGO_LOG_DIR_PLACEHOLDER/mongo_monitor.log"
LOCAL_IP="MONGO_LOCAL_IP_PLACEHOLDER"
INSTALL_MODE="MONGO_INSTALL_MODE_PLACEHOLDER"

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
if ! ss -tlnp 2>/dev/null | grep -q ":${MONGO_PORT} "; then
  log "CRITICAL: MongoDB 端口 ${MONGO_PORT} 未监听"
  exit 1
fi

# 3. 连通性检查 (尝试 ping)
SHELL_CMD=""
if [[ -f "${MONGO_APP_DIR}/bin/mongosh" ]]; then
  SHELL_CMD="${MONGO_APP_DIR}/bin/mongosh"
elif [[ -f "${MONGO_APP_DIR}/bin/mongo" ]]; then
  SHELL_CMD="${MONGO_APP_DIR}/bin/mongo"
fi

if [[ -n "$SHELL_CMD" ]]; then
  ping_result=$("$SHELL_CMD" --host "${LOCAL_IP}" --port "${MONGO_PORT}" --quiet --eval "db.adminCommand('ping')" 2>/dev/null)
  if echo "$ping_result" | grep -q '"ok".*:.*1'; then
    log "INFO: MongoDB ping 成功"
  else
    log "WARNING: MongoDB ping 失败"
  fi

  # 4. 副本集状态检查
  if [[ "$INSTALL_MODE" == "replicaset" ]]; then
    rs_status=$("$SHELL_CMD" --host "${LOCAL_IP}" --port "${MONGO_PORT}" --quiet --eval "
      var s = rs.status();
      var primary = 0, secondary = 0, down = 0;
      s.members.forEach(function(m) {
        if (m.stateStr === 'PRIMARY') primary++;
        else if (m.stateStr === 'SECONDARY') secondary++;
        else down++;
      });
      print('primary=' + primary + ',secondary=' + secondary + ',down=' + down);
    " 2>/dev/null)
    log "INFO: 副本集状态: ${rs_status}"
  fi

  # 5. 连接数检查
  conn_info=$("$SHELL_CMD" --host "${LOCAL_IP}" --port "${MONGO_PORT}" --quiet --eval "
    var s = db.serverStatus();
    print('current=' + s.connections.current + ',available=' + s.connections.available);
  " 2>/dev/null)
  log "INFO: 连接数: ${conn_info}"
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
MONEOF

  local local_ip
  local_ip=$(get_local_ip)
  local_ip="${local_ip:-127.0.0.1}"

  sed -i \
    -e "s|MONGO_APP_DIR_PLACEHOLDER|${env_app_dir}|g" \
    -e "s|MONGO_PORT_PLACEHOLDER|${mongo_port}|g" \
    -e "s|MONGO_LOG_DIR_PLACEHOLDER|${log_dir}|g" \
    -e "s|MONGO_LOCAL_IP_PLACEHOLDER|${local_ip}|g" \
    -e "s|MONGO_DATA_DIR_PLACEHOLDER|${data_dir}|g" \
    -e "s|MONGO_INSTALL_MODE_PLACEHOLDER|${mongo_install_mode}|g" \
    -e "s|MONGO_PID_DIR_PLACEHOLDER|${pid_dir}|g" \
    "${scripts_dir}/mongo_monitor.sh"

  chmod 750 "${scripts_dir}/mongo_monitor.sh"
  chown "${mongo_owner}:${mongo_owner}" "${scripts_dir}/mongo_monitor.sh"
}
#==============================================================#
#             配置 crontab                                     #
#==============================================================#
function conf_crontab() {
  log_print "配置定时任务"

  local cron_file="/var/spool/cron/root"
  if [[ "$os_distro_family" == "debian" ]]; then
    cron_file="/var/spool/cron/crontabs/root"
  fi
  mkdir -p "$(dirname "$cron_file")"
  touch "$cron_file"

  local marker="# MongoBegin"
  if grep -q "$marker" "$cron_file" 2>/dev/null; then
    sed -i "/${marker}/,/# MongoEnd/d" "$cron_file"
  fi

  cat >> "$cron_file" <<CRONEOF
# MongoBegin - MongoDB 定时任务
# 每天凌晨 2 点备份
0 2 * * * ${scripts_dir}/mongo_backup.sh >> ${log_dir}/mongo_backup_cron.log 2>&1
# 每 5 分钟健康检查
*/5 * * * * ${scripts_dir}/mongo_monitor.sh >> ${log_dir}/mongo_monitor_cron.log 2>&1
# MongoEnd
CRONEOF

  # 重载 cron
  if command -v systemctl &>/dev/null; then
    systemctl restart crond 2>/dev/null || systemctl restart cron 2>/dev/null
  else
    service crond restart 2>/dev/null || service cron restart 2>/dev/null
  fi
  echo "定时任务已配置"
}
#==============================================================#
#             配置日志轮转                                     #
#==============================================================#
function conf_logrotate() {
  log_print "配置日志轮转"

  cat > /etc/logrotate.d/mongodb <<LREOF
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
  echo "日志轮转已配置"
}
#==============================================================#
#             启动 MongoDB                                     #
#==============================================================#
function start_mongodb() {
  log_print "启动 MongoDB"

  if (( HAS_SYSTEMD )); then
    systemctl start mongod.service
    sleep 3

    local retries=0
    while (( retries < 15 )); do
      if systemctl is-active mongod.service &>/dev/null; then
        break
      fi
      sleep 2
      ((retries++))
    done

    if systemctl is-active mongod.service &>/dev/null; then
      echo "MongoDB 启动成功"
      sleep 2
      if ss -tlnp 2>/dev/null | grep -q ":${mongo_port} "; then
        echo "端口 ${mongo_port} 已监听"
      else
        echo "警告: 端口 ${mongo_port} 暂未监听，MongoDB 可能仍在初始化"
      fi
    else
      color_printf red "MongoDB 启动失败"
      systemctl status mongod.service --no-pager -l 2>&1 | tail -10
      return 1
    fi
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
    if ss -tlnp 2>/dev/null | grep -q ":${mongo_port} "; then
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
function remote_exec() {
  local host="$1"; shift
  sshpass -p "$remote_root_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -p "$serverport" "root@${host}" "$@"
}

function remote_copy() {
  local src="$1" host="$2" dest="$3"
  sshpass -p "$remote_root_pass" scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -P "$serverport" "$src" "root@${host}:${dest}"
}

function check_ssh_connectivity() {
  local host="$1"
  if ! sshpass -p "$remote_root_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -p "$serverport" "root@${host}" "echo OK" &>/dev/null; then
    color_printf red "SSH 连接失败: ${host}"
    return 1
  fi
  return 0
}

function check_cluster_connectivity() {
  log_print "检查集群节点连通性"
  local local_ip
  local_ip=$(get_local_ip)
  local fail=0

  for host in "${hosts_array[@]}"; do
    if is_local_host "$host" "$local_ip"; then
      echo "  ${host} (本机) ... OK"
      continue
    fi
    if check_ssh_connectivity "$host"; then
      echo "  ${host} ... OK"
    else
      ((fail++))
    fi
  done

  if (( fail > 0 )); then
    color_printf red "有 ${fail} 个节点连通性检查失败"
    return 1
  fi
}

function deploy_remote_nodes() {
  if [[ "$mongo_install_mode" == "single" ]]; then return 0; fi
  if [[ ${#hosts_array[@]} -eq 0 ]]; then return 0; fi

  local local_ip
  local_ip=$(get_local_ip)
  local script_path="${software_dir}/${script_name}"

  local fail_count=0
  local remote_count=0
  local failed_hosts=()
  local failed_reasons=()

  # 打包已安装的 MongoDB 二进制
  local app_pkg="/tmp/mongo-app-installed.tar.gz"
  log_print "打包 MongoDB 安装目录..."
  tar czf "$app_pkg" -C "$(dirname "${env_app_dir}")" "$(basename "${env_app_dir}")"

  local node_idx=0
  for host in "${hosts_array[@]}"; do
    ((node_idx++))

    if is_local_host "$host" "$local_ip"; then
      log_print "跳过本机: ${host}"
      continue
    fi

    ((remote_count++))
    log_print ">>> 部署远程节点: ${host}"

    # 1. 测试连通性
    if ! check_ssh_connectivity "$host"; then
      ((fail_count++))
      failed_hosts+=("$host")
      failed_reasons+=("SSH 连接失败")
      continue
    fi

    # 2. 分发脚本，远程执行 OS 优化
    log_print "  [${host}] OS 优化..."
    remote_exec "$host" "mkdir -p ${software_dir}"
    if ! remote_copy "$script_path" "$host" "${software_dir}/"; then
      echo "错误: [${host}] 脚本分发失败" >&3
      ((fail_count++))
      failed_hosts+=("$host")
      failed_reasons+=("脚本分发失败")
      continue
    fi
    local remote_hn="${hostname}$(echo "$host" | awk -F. '{print $3$4}')"
    remote_exec "$host" "cd ${software_dir} && bash ${script_name} -m single --os-only -n ${remote_hn}" 2>&1 | \
      while IFS= read -r line; do echo "  [${host}] ${line}"; done

    # 3. 创建用户和目录
    log_print "  [${host}] 创建用户与目录..."
    if ! remote_exec "$host" "
      _nologin='/sbin/nologin'
      [[ ! -f \"\$_nologin\" ]] && _nologin='/usr/sbin/nologin'
      [[ ! -f \"\$_nologin\" ]] && _nologin='/bin/false'
      grep -q '^${mongo_owner}:' /etc/group 2>/dev/null || groupadd -g 60300 '${mongo_owner}'
      id '${mongo_owner}' &>/dev/null || useradd -u 60300 -g '${mongo_owner}' -s \"\$_nologin\" -M '${mongo_owner}'
      passwd -l '${mongo_owner}' &>/dev/null
      mkdir -p '${env_app_dir}' '${data_dir}/db' '${data_dir}/configdb' '${log_dir}' '${backup_dir}' '${scripts_dir}' '${pid_dir}'
      chown -R '${mongo_owner}:${mongo_owner}' '${env_base_dir}'
    "; then
      echo "错误: [${host}] 用户/目录创建失败" >&3
      ((fail_count++))
      failed_hosts+=("$host")
      failed_reasons+=("用户/目录创建失败")
      continue
    fi

    # 4. 分发 MongoDB 安装包
    log_print "  [${host}] 分发 MongoDB..."
    if ! remote_copy "$app_pkg" "$host" "/tmp/mongo-app-installed.tar.gz"; then
      ((fail_count++))
      failed_hosts+=("$host")
      failed_reasons+=("MongoDB 包分发失败")
      continue
    fi
    if ! remote_exec "$host" "
      tar xzf /tmp/mongo-app-installed.tar.gz -C '${env_base_dir}'
      rm -f /tmp/mongo-app-installed.tar.gz
      for cmd in mongod mongos mongosh mongo mongodump mongorestore mongoexport mongoimport mongostat mongotop; do
        [[ -f '${env_app_dir}/bin/'\$cmd ]] && ln -sf '${env_app_dir}/bin/'\$cmd /usr/local/bin/\$cmd
      done
      chown -R '${mongo_owner}:${mongo_owner}' '${env_app_dir}'
    "; then
      ((fail_count++))
      failed_hosts+=("$host")
      failed_reasons+=("MongoDB 解压失败")
      continue
    fi

    # 5. 分发配置文件和 keyFile
    log_print "  [${host}] 分发配置..."
    remote_copy "${env_base_dir}/mongod.conf" "$host" "${env_base_dir}/mongod.conf"
    if [[ -f "${mongo_keyfile}" ]]; then
      remote_copy "${mongo_keyfile}" "$host" "${mongo_keyfile}"
      remote_exec "$host" "chown '${mongo_owner}:${mongo_owner}' '${mongo_keyfile}' && chmod 400 '${mongo_keyfile}'"
    fi
    remote_exec "$host" "
      chown '${mongo_owner}:${mongo_owner}' '${env_base_dir}/mongod.conf'
      chmod 640 '${env_base_dir}/mongod.conf'
    "

    # 6. 禁用 THP
    remote_exec "$host" "
      echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
      echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
    "

    # 7. 创建 systemd 服务
    log_print "  [${host}] 创建并启动服务..."
    local _exec_prefix=""
    local _has_numactl
    _has_numactl=$(remote_exec "$host" "command -v numactl &>/dev/null && echo yes || echo no" 2>/dev/null)
    if [[ "$_has_numactl" == *"yes"* ]]; then
      _exec_prefix="numactl --interleave=all "
    fi

    remote_exec "$host" "
      cat > /etc/systemd/system/mongod.service <<'RSVCEOF'
[Unit]
Description=MongoDB Database Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${mongo_owner}
Group=${mongo_owner}
ExecStart=${_exec_prefix}${env_app_dir}/bin/mongod --config ${env_base_dir}/mongod.conf
ExecStop=/bin/kill -s SIGTERM \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStopSec=300
LimitNOFILE=1048576
LimitNPROC=65536
LimitCORE=infinity
LimitMEMLOCK=infinity
OOMScoreAdjust=-999
PrivateTmp=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
RSVCEOF
      systemctl daemon-reload
      systemctl enable mongod.service
      systemctl start mongod.service
      sleep 5
      if systemctl is-active mongod.service &>/dev/null; then
        echo 'MONGO_START_OK'
      else
        echo 'MONGO_START_FAIL'
        systemctl status mongod.service --no-pager -l 2>&1 | tail -5
      fi
    "
    local _start_result
    _start_result=$(remote_exec "$host" "systemctl is-active mongod.service 2>/dev/null" 2>/dev/null)
    if [[ "$_start_result" == *"active"* ]]; then
      echo "  [${host}] MongoDB 启动成功"
    else
      echo "  [${host}] MongoDB 启动失败"
      ((fail_count++))
      failed_hosts+=("$host")
      failed_reasons+=("MongoDB 启动失败")
    fi
  done

  # 清理临时文件
  rm -f "$app_pkg"

  if (( fail_count > 0 )); then
    echo
    color_printf yellow "远程部署失败节点: ${fail_count}/${remote_count}"
    for ((i=0; i<${#failed_hosts[@]}; i++)); do
      echo "  ${failed_hosts[$i]}: ${failed_reasons[$i]}"
    done
    return 1
  fi
  echo "所有远程节点部署完成 (${remote_count} 个)"
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

  local local_ip
  local_ip=$(get_local_ip)
  local_ip="${local_ip:-127.0.0.1}"

  # 确定 mongo shell 命令
  local SHELL_CMD=""
  if [[ -f "${env_app_dir}/bin/mongosh" ]]; then
    SHELL_CMD="${env_app_dir}/bin/mongosh"
  elif [[ -f "${env_app_dir}/bin/mongo" ]]; then
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

  # 等待本机 MongoDB 就绪
  local retries=0
  while (( retries < 20 )); do
    if "$SHELL_CMD" --host "$local_ip" --port "$mongo_port" --quiet --eval "db.adminCommand('ping')" &>/dev/null; then
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
  rs_init_result=$("$SHELL_CMD" --host "$local_ip" --port "$mongo_port" --quiet --eval "
    var config = {
      _id: '${repl_set_name}',
      members: [${members}]
    };
    var result = rs.initiate(config);
    printjson(result);
  " 2>&1)

  echo "$rs_init_result"

  if echo "$rs_init_result" | grep -q '"ok".*:.*1'; then
    echo "副本集 ${repl_set_name} 初始化成功"
  elif echo "$rs_init_result" | grep -q "already initialized"; then
    echo "副本集 ${repl_set_name} 已初始化"
  else
    color_printf yellow "副本集初始化返回异常，请手动检查"
  fi

  # 等待选主完成
  echo "等待副本集选主..."
  retries=0
  while (( retries < 30 )); do
    local rs_status
    rs_status=$("$SHELL_CMD" --host "$local_ip" --port "$mongo_port" --quiet --eval "
      var s = rs.status();
      var hasPrimary = false;
      s.members.forEach(function(m) { if (m.stateStr === 'PRIMARY') hasPrimary = true; });
      print(hasPrimary ? 'HAS_PRIMARY' : 'NO_PRIMARY');
    " 2>/dev/null)
    if [[ "$rs_status" == *"HAS_PRIMARY"* ]]; then
      echo "副本集选主完成"
      break
    fi
    sleep 2
    ((retries++))
  done

  if (( retries >= 30 )); then
    color_printf yellow "警告: 副本集选主超时，请手动检查 rs.status()"
  fi

  # 创建管理员用户 (如果启用认证)
  if [[ "$mongo_auth_enabled" == "Y" && -n "$mongo_admin_pass" ]]; then
    echo "创建管理员用户..."
    sleep 3
    "$SHELL_CMD" --host "$local_ip" --port "$mongo_port" --quiet --eval "
      db = db.getSiblingDB('admin');
      try {
        db.createUser({
          user: '${mongo_admin_user}',
          pwd: '${mongo_admin_pass}',
          roles: [{role:'root', db:'admin'}]
        });
        print('管理员用户创建成功');
      } catch(e) {
        if (e.codeName === 'DuplicateKey' || e.code === 51003) {
          print('管理员用户已存在');
        } else {
          print('创建用户失败: ' + e.message);
        }
      }
    " 2>&1
  fi
}
#==============================================================#
#             集群验证                                         #
#==============================================================#
function verify_cluster() {
  log_print "验证副本集状态"

  local local_ip
  local_ip=$(get_local_ip)
  local_ip="${local_ip:-127.0.0.1}"

  local SHELL_CMD=""
  if [[ -f "${env_app_dir}/bin/mongosh" ]]; then
    SHELL_CMD="${env_app_dir}/bin/mongosh"
  elif [[ -f "${env_app_dir}/bin/mongo" ]]; then
    SHELL_CMD="${env_app_dir}/bin/mongo"
  fi

  if [[ -z "$SHELL_CMD" ]]; then
    echo "警告: 未找到 mongo shell，跳过验证"
    return 0
  fi

  echo "副本集状态:"
  "$SHELL_CMD" --host "$local_ip" --port "$mongo_port" --quiet --eval "
    var s = rs.status();
    print('副本集名称: ' + s.set);
    s.members.forEach(function(m) {
      print('  ' + m.name + ' => ' + m.stateStr + ' (health=' + m.health + ')');
    });
  " 2>&1

  echo
  echo "副本集配置:"
  "$SHELL_CMD" --host "$local_ip" --port "$mongo_port" --quiet --eval "
    var c = rs.conf();
    c.members.forEach(function(m) {
      print('  _id=' + m._id + ' host=' + m.host + ' priority=' + m.priority);
    });
  " 2>&1
}
#==============================================================#
#             安装汇总                                         #
#==============================================================#
function print_summary() {
  local local_ip
  local_ip=$(get_local_ip)
  local_ip="${local_ip:-127.0.0.1}"

  echo
  echo "============================================================"
  echo "            MongoDB 安装完成 - 信息汇总"
  echo "============================================================"
  echo "  安装模式        : ${mongo_install_mode}"
  echo "  MongoDB 目录    : ${env_app_dir}"
  echo "  配置文件        : ${env_base_dir}/mongod.conf"
  echo "  数据目录        : ${data_dir}/db"
  echo "  日志目录        : ${log_dir}"
  echo "  备份目录        : ${backup_dir}"
  echo "  脚本目录        : ${scripts_dir}"
  echo "  端口            : ${mongo_port}"

  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    echo "  副本集名称      : ${repl_set_name}"
    echo "  副本集成员      : ${hosts_array[*]}"
    echo "  Oplog 大小      : ${oplog_size_mb}MB"
    echo "  keyFile         : ${mongo_keyfile}"
  fi

  echo "  运行用户        : ${mongo_owner}"
  echo "  WiredTiger 缓存 : ${wt_cache_size_gb}GB"
  echo "  最大连接数      : ${max_connections}"
  if [[ "$mongo_auth_enabled" == "Y" ]]; then
    echo "  认证            : 已启用"
    echo "  管理员用户      : ${mongo_admin_user}"
  else
    echo "  认证            : 未启用"
  fi
  echo "------------------------------------------------------------"
  echo "  服务管理        : systemctl {start|stop|restart|status} mongod"
  echo "  备份脚本        : ${scripts_dir}/mongo_backup.sh"
  echo "  监控脚本        : ${scripts_dir}/mongo_monitor.sh"
  echo "  安装日志        : ${Mongoinstalllog}"
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
  if [[ -f "${env_app_dir}/bin/mongosh" ]]; then
    echo "    # 连接 MongoDB"
    echo "    mongosh --host ${local_ip} --port ${mongo_port}"
  else
    echo "    # 连接 MongoDB"
    echo "    mongo --host ${local_ip} --port ${mongo_port}"
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

  if (( os_memory_mb < 1024 )); then
    color_printf red "错误: 物理内存不足 1024MB (当前: ${os_memory_mb}MB)，MongoDB 至少需要 1GB 内存"
    exit 1
  fi

  echo "系统信息: OS=${os_distro}(${os_distro_family}), 版本=${os_version}, 内存=${os_memory_mb}MB, CPU=${os_core}核, systemd=$(if (( HAS_SYSTEMD )); then echo '是'; else echo '否'; fi)"
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
  -n,  --hostname NAME     主机名 (单机直接使用；多节点作为前缀) (默认: mongodb)
  -p,  --port PORT         MongoDB 端口 (默认: 27017)
  -d,  --dir DIR           安装根目录 (默认: /mongodb)
  -ou, --owner USER        系统用户名 (默认: mongod)
  -ri, --remote-ips IPS    副本集节点 IP (逗号分隔，包含本机 IP)
  -rp, --root-pass PASS    远程节点 root 密码 (副本集模式必填)
  -ss, --ssh-port PORT     SSH 端口 (默认: 22)
  --repl-set NAME          副本集名称 (默认: rs0)
  --auth                   启用认证
  --admin-user USER        管理员用户名 (默认: admin)
  --admin-pass PASS        管理员密码 (启用认证时必填)
  --oplog-size MB          Oplog 大小 (默认: 自动计算)
  --max-connections NUM    最大连接数 (默认: 65536)
  --os-only                仅配置操作系统，不安装 MongoDB
  --debug                  开启调试模式
  --backup-days DAYS       备份保留天数 (默认: 7)
  -h,  --help              显示帮助信息

示例:
  # 交互式选择模式安装
  $script_name

  # 单机模式
  $script_name -m single

  # 3 节点副本集
  $script_name -m replicaset -ri 192.168.1.11,192.168.1.12,192.168.1.13 -rp 'RootPass123'

  # 副本集 + 启用认证
  $script_name -m rs -ri 192.168.1.11,192.168.1.12,192.168.1.13 -rp 'RootPass123' --auth --admin-pass 'MongoAdmin123'

  # 自定义端口和目录
  $script_name -m single -p 27018 -d /data/mongodb

离线安装 (内网环境):
  将以下文件放在脚本同目录 (${software_dir}/):
  1. MongoDB 安装包:  mongodb-linux-x86_64-*.tgz
  2. mongosh (可选):  mongosh-*.tgz
  3. Database Tools (可选): mongodb-database-tools-*.tgz
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
      -d|--dir)
        checkpara_NULL "$1" "$2"
        env_base_dir="$2"
        env_app_dir=${env_base_dir}/app
        data_dir=${env_base_dir}/data
        log_dir=${env_base_dir}/logs
        backup_dir=${env_base_dir}/backup
        scripts_dir=${env_base_dir}/scripts
        pid_dir=${env_base_dir}/run
        mongo_keyfile="${env_base_dir}/keyfile"
        shift 2
        ;;
      -ou|--owner)
        checkpara_NULL "$1" "$2"
        mongo_owner="$2"
        shift 2
        ;;
      -ri|--remote-ips)
        checkpara_NULL "$1" "$2"
        IFS=',' read -ra hosts_array <<< "$2"
        for ip in "${hosts_array[@]}"; do
          if ! check_ip "$ip"; then
            color_printf red "错误: 无效的 IP 地址: $ip"
            exit 1
          fi
        done
        shift 2
        ;;
      -rp|--root-pass)
        checkpara_NULL "$1" "$2"
        remote_root_pass="$2"
        shift 2
        ;;
      -ss|--ssh-port)
        checkpara_NULL "$1" "$2"
        serverport="$2"
        shift 2
        ;;
      --repl-set)
        checkpara_NULL "$1" "$2"
        repl_set_name="$2"
        shift 2
        ;;
      --auth)
        mongo_auth_enabled=Y
        shift
        ;;
      --admin-user)
        checkpara_NULL "$1" "$2"
        mongo_admin_user="$2"
        shift 2
        ;;
      --admin-pass)
        checkpara_NULL "$1" "$2"
        mongo_admin_pass="$2"
        shift 2
        ;;
      --oplog-size)
        checkpara_NULL "$1" "$2"
        oplog_size_mb="$2"
        shift 2
        ;;
      --max-connections)
        checkpara_NULL "$1" "$2"
        max_connections="$2"
        shift 2
        ;;
      --os-only)
        only_conf_os=Y
        shift
        ;;
      --debug)
        debug_flag=Y
        shift
        ;;
      --backup-days)
        checkpara_NULL "$1" "$2"
        backup_retention_days="$2"
        shift 2
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
  clear
  logo_print
  echo
  check_prerequisites

  # --os-only 模式
  if [[ "$only_conf_os" == "Y" ]]; then
    mongo_install_mode="${mongo_install_mode:-single}"
    log_print "第一阶段: 操作系统优化"
    execute_and_log "[0/8]  设置主机名"         conf_hostname
    execute_and_log "[1/8]  安装依赖包"         pkg_install
    execute_and_log "[2/8]  关闭防火墙"         conf_firewall
    execute_and_log "[3/8]  关闭 SELinux"       conf_selinux
    execute_and_log "[4/8]  优化内核参数"       conf_sysctl
    execute_and_log "[5/8]  配置资源限制"       conf_limits
    execute_and_log "[6/8]  配置 THP"           conf_thp
    execute_and_log "[7/8]  优化磁盘挂载"       optimize_mounts
    execute_and_log "[8/8]  配置时间同步"       conf_ntp
    log_print "操作系统优化完成 (仅 OS 模式)"
    exit 0
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

  # 副本集模式校验
  if [[ "$mongo_install_mode" == "replicaset" && ${#hosts_array[@]} -eq 0 ]]; then
    color_printf red "错误: replicaset 模式必须指定 -ri 参数（节点 IP，包含本机）"
    exit 1
  fi
  if [[ "$mongo_install_mode" == "replicaset" && -z "$remote_root_pass" ]]; then
    color_printf red "错误: replicaset 模式必须指定 -rp 参数（远程 root 密码）"
    exit 1
  fi

  # 认证校验
  if [[ "$mongo_auth_enabled" == "Y" && -z "$mongo_admin_pass" ]]; then
    color_printf red "错误: 启用认证时必须指定 --admin-pass 参数"
    exit 1
  fi

  # 端口范围校验
  if (( mongo_port < 1 || mongo_port > 65535 )); then
    color_printf red "错误: MongoDB 端口超出有效范围 1-65535 (当前: ${mongo_port})"
    exit 1
  fi

  # 目录路径校验
  if [[ "$env_base_dir" != /* ]]; then
    color_printf red "错误: 安装目录必须为绝对路径 (当前: ${env_base_dir})"
    exit 1
  fi

  # 用户名校验
  local forbidden_users=("root" "bin" "daemon" "adm" "lp" "sync" "shutdown" "halt" "mail" "operator" "games" "ftp" "nobody" "systemd-network" "dbus" "polkitd" "sshd" "postfix" "chrony" "ntp")
  for fu in "${forbidden_users[@]}"; do
    if [[ "$mongo_owner" == "$fu" ]]; then
      color_printf red "错误: 不允许使用系统用户 '${mongo_owner}' 作为 MongoDB 运行用户"
      exit 1
    fi
  done

  # 确认安装意图
  local _mode_summary="${mongo_install_mode}"
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    _mode_summary="replicaset (${#hosts_array[@]} 节点, rs=${repl_set_name})"
  fi
  echo
  color_printf purple "即将以 [${_mode_summary}] 模式安装 MongoDB，是否继续？(Y/N) "

  # 集群连通性检查
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    echo
    execute_and_log "[预检]  检查集群节点连通性" check_cluster_connectivity || { color_printf red "节点连通性检查失败"; exit 1; }
  fi

  # 版本检测
  log_print "版本检测与环境验证"
  execute_and_log "[1/2]  检测 MongoDB 版本"   detect_mongo_version || { color_printf red "检测版本失败"; exit 1; }
  execute_and_log "[2/2]  检查安装包"          check_packages       || { color_printf red "安装包检查失败"; exit 1; }

  # 副本集节点数量校验
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    local node_count=${#hosts_array[@]}
    if (( node_count < 3 )); then
      color_printf yellow "警告: 副本集建议至少 3 个节点 (当前: ${node_count})"
    fi
    if (( node_count % 2 == 0 )); then
      color_printf yellow "警告: 副本集建议使用奇数个节点 (当前: ${node_count})"
    fi
  fi

  log_print "第一阶段: 操作系统优化"
  execute_and_log "[0/8]  设置主机名"         conf_hostname
  execute_and_log "[1/8]  安装依赖包"         pkg_install
  execute_and_log "[2/8]  关闭防火墙"         conf_firewall
  execute_and_log "[3/8]  关闭 SELinux"       conf_selinux
  execute_and_log "[4/8]  优化内核参数"       conf_sysctl
  execute_and_log "[5/8]  配置资源限制"       conf_limits
  execute_and_log "[6/8]  配置 THP"           conf_thp
  execute_and_log "[7/8]  优化磁盘挂载"       optimize_mounts
  execute_and_log "[8/8]  配置时间同步"       conf_ntp

  log_print "第二阶段: 创建用户与目录"
  execute_and_log "[1/2]  创建系统用户"       create_users_groups || { color_printf red "创建用户失败"; exit 1; }
  execute_and_log "[2/2]  创建目录结构"       create_dir          || { color_printf red "创建目录失败"; exit 1; }

  log_print "第三阶段: 安装 MongoDB"
  execute_and_log "[1/1]  安装 MongoDB"       install_mongodb     || { color_printf red "安装 MongoDB 失败"; exit 1; }

  log_print "第四阶段: 配置 MongoDB"
  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    execute_and_log "[1/2]  生成 MongoDB 配置"  conf_mongodb       || { color_printf red "配置失败"; exit 1; }
    execute_and_log "[2/2]  生成副本集 keyFile"  generate_keyfile   || { color_printf red "keyFile 生成失败"; exit 1; }
  else
    execute_and_log "[1/1]  生成 MongoDB 配置"  conf_mongodb       || { color_printf red "配置失败"; exit 1; }
  fi

  log_print "第五阶段: 服务与运维"
  execute_and_log "[1/4]  创建 systemd 服务"  create_systemd_service || { color_printf red "创建服务失败"; exit 1; }
  execute_and_log "[2/4]  创建备份脚本"       create_backup_script
  execute_and_log "[3/4]  创建监控脚本"       create_monitor_script
  execute_and_log "[4/4]  配置定时任务"       conf_crontab
  execute_and_log "[附加]  配置日志轮转"      conf_logrotate

  log_print "第六阶段: 启动 MongoDB"
  execute_and_log "[1/1]  启动 MongoDB"       start_mongodb       || { color_printf red "启动失败"; exit 1; }

  if [[ "$mongo_install_mode" == "replicaset" ]]; then
    log_print "第七阶段: 远程节点部署"
    if execute_and_log "[1/1]  分发并安装远程节点"  deploy_remote_nodes; then
      log_print "第八阶段: 副本集初始化"
      execute_and_log "[1/2]  初始化副本集"         init_replicaset
      execute_and_log "[2/2]  验证副本集状态"       verify_cluster
    else
      color_printf yellow "远程节点部署失败，跳过副本集初始化"
    fi
  fi

  print_summary
}
# ============================================================
# 入口
# ============================================================
main "$@" 2>&1 | tee -a "$Mongoinstalllog"
