#!/usr/bin/env bash
set -euo pipefail
umask 022

archive_name="mongdb-offline-rpm.tar.gz"
output_file="${PWD}/${archive_name}"
declare -a requested_packages=()
declare -a default_packages=(
  bash coreutils findutils gawk grep sed tar gzip shadow-utils util-linux
  iproute procps-ng systemd openssh-clients openssl cronie logrotate
  numactl net-tools sysstat lsof libcurl xz-libs cyrus-sasl cyrus-sasl-plain
)

usage() {
  cat <<'EOF'
用法: build_offline_rpm_bundle.sh [选项] [额外软件包...]

在有仓库的目标同版本 RHEL 系列主机上下载 MongoDB 安装器所需的 RPM
及其依赖，生成 mongdb-offline-rpm.tar.gz。归档内部按 OS 主版本和
CPU 架构隔离，例如 mongdb-offline-rpm/rhel/9/x86_64/。

选项:
  -o, --output FILE   输出归档路径（默认: 当前目录/mongdb-offline-rpm.tar.gz）
  -p, --package NAME  额外下载一个软件包，可重复
  --only NAME         只下载指定软件包；首次使用时清空默认列表，可重复
  -h, --help          显示帮助

软件包版本不在脚本中固定，由构建机当前启用的软件仓库解析。
EOF
}

only_mode=0
while (( $# > 0 )); do
  case "$1" in
    -o|--output)
      (( $# >= 2 )) || { echo "错误: $1 缺少值" >&2; exit 2; }
      output_file="$2"
      shift 2
      ;;
    -p|--package)
      (( $# >= 2 )) || { echo "错误: $1 缺少值" >&2; exit 2; }
      requested_packages+=("$2")
      shift 2
      ;;
    --only)
      (( $# >= 2 )) || { echo "错误: $1 缺少值" >&2; exit 2; }
      if (( only_mode == 0 )); then
        default_packages=()
        only_mode=1
      fi
      requested_packages+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      requested_packages+=("$@")
      break
      ;;
    -*)
      echo "错误: 未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      requested_packages+=("$1")
      shift
      ;;
  esac
done

[[ -r /etc/os-release ]] || { echo "错误: 无法读取 /etc/os-release" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
os_id="${ID:-unknown}"
os_major="${VERSION_ID%%.*}"
arch=$(uname -m)

case "$os_id" in
  rhel|centos|rocky|alma|ol|anolis|openEuler|tencentos|alinux) ;;
  *)
    echo "错误: 该工具只生成 RHEL 系列 RPM 包，当前 OS=${os_id}" >&2
    exit 1
    ;;
esac
[[ "$os_major" =~ ^[0-9]+$ ]] || { echo "错误: 无法识别 OS 主版本: ${VERSION_ID:-unknown}" >&2; exit 1; }
[[ "$arch" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "错误: 无法识别 CPU 架构: ${arch}" >&2; exit 1; }
command -v dnf >/dev/null 2>&1 || { echo "错误: 未找到 dnf" >&2; exit 1; }
if ! dnf download --help >/dev/null 2>&1; then
  echo "错误: dnf download 不可用，请先安装 dnf-plugins-core" >&2
  exit 1
fi

declare -a packages=("${default_packages[@]}" "${requested_packages[@]}")
mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sed '/^$/d' | sort -u)
(( ${#packages[@]} > 0 )) || { echo "错误: 没有要下载的软件包" >&2; exit 1; }

output_parent=$(dirname "$output_file")
mkdir -p "$output_parent"
output_parent=$(cd "$output_parent" && pwd)
output_file="${output_parent}/$(basename "$output_file")"

work_dir=$(mktemp -d /tmp/mongdb-offline-rpm-build.XXXXXX)
cleanup() {
  case "$work_dir" in
    /tmp/mongdb-offline-rpm-build.*) rm -rf -- "$work_dir" ;;
  esac
}
trap cleanup EXIT

bundle_dir="${work_dir}/mongdb-offline-rpm/${os_id}/${os_major}/${arch}"
mkdir -p "$bundle_dir"

echo "构建平台: ${os_id}/${os_major}/${arch}"
echo "解析并下载 ${#packages[@]} 个软件包及其依赖..."
dnf download --resolve --alldeps --destdir "$bundle_dir" "${packages[@]}"

shopt -s nullglob
rpm_files=("${bundle_dir}"/*.rpm)
shopt -u nullglob
(( ${#rpm_files[@]} > 0 )) || { echo "错误: 仓库未下载到任何 RPM" >&2; exit 1; }

{
  printf 'format=1\n'
  printf 'os_id=%s\n' "$os_id"
  printf 'os_major=%s\n' "$os_major"
  printf 'arch=%s\n' "$arch"
  printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'package_count=%d\n' "${#rpm_files[@]}"
} > "${bundle_dir}/manifest.env"

(
  cd "$bundle_dir"
  sha256sum ./*.rpm | sed 's#  \./#  #' > SHA256SUMS
)

archive_tmp="${output_file}.part.$$"
tar -C "$work_dir" -czf "$archive_tmp" mongdb-offline-rpm
tar -tzf "$archive_tmp" >/dev/null
mv -f -- "$archive_tmp" "$output_file"

echo "完成: ${output_file}"
echo "内部目录: mongdb-offline-rpm/${os_id}/${os_major}/${arch}/"
echo "RPM 数量: ${#rpm_files[@]}"
