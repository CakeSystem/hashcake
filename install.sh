#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="HashCake"
RELEASE_REPO="${HASHCAKE_RELEASE_REPO:-CakeSystem/hashcake}"
RELEASE_TAG="${HASHCAKE_VERSION:-latest}"
RELEASE_BRANCH="${HASHCAKE_RELEASE_BRANCH:-main}"
RELEASE_PLATFORM="${HASHCAKE_RELEASE_PLATFORM:-linux-amd64}"
SERVICE_NAME="${HASHCAKE_SERVICE:-hashcake}"
SERVICE_USER="${HASHCAKE_USER:-hashcake}"
SERVICE_GROUP="${HASHCAKE_GROUP:-${SERVICE_USER}}"
INSTALL_DIR="${HASHCAKE_HOME:-/opt/hashcake}"
CONFIG_FILE="${HASHCAKE_CONFIG:-${INSTALL_DIR}/hashcake.yaml}"
STATE_DIR="${HASHCAKE_STATE_DIR:-${INSTALL_DIR}/state}"
LOG_DIR="${HASHCAKE_LOG_DIR:-${INSTALL_DIR}/logs}"
BACKUP_DIR="${HASHCAKE_BACKUP_DIR:-${INSTALL_DIR}/backup}"
BIN_PATH="${INSTALL_DIR}/hashcake"
INSTALLER_STATE_DIR="${HASHCAKE_INSTALLER_STATE_DIR:-${INSTALL_DIR}/.installer}"
INSTALL_ENV="${INSTALLER_STATE_DIR}/install.env"
LEGACY_INSTALL_ENV="${STATE_DIR}/install.env"
ADMIN_BIND="${HASHCAKE_ADMIN_BIND:-}"
URL_PREFIX="${HASHCAKE_URL_PREFIX:-}"
HTTPS_ACTIVE="${HASHCAKE_HTTPS_ACTIVE:-}"

UPDATE_MANIFEST_URL="${HASHCAKE_UPDATE_MANIFEST_URL:-}"
RUST_LOG_VALUE="${RUST_LOG:-hashcake=info}"
BUILD_FEATURES="${HASHCAKE_FEATURES:-admin-spa}"
START_AFTER_INSTALL="${HASHCAKE_START_AFTER_INSTALL:-1}"
WEB_PORT_MIN="${HASHCAKE_WEB_PORT_MIN:-10000}"
WEB_PORT_MAX="${HASHCAKE_WEB_PORT_MAX:-60000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

red=$'\033[31m'
green=$'\033[32m'
yellow=$'\033[33m'
blue=$'\033[34m'
reset=$'\033[0m'

log() { printf '%s\n' "${blue}==>${reset} $*"; }
ok() { printf '%s\n' "${green}完成:${reset} $*"; }
warn() { printf '%s\n' "${yellow}注意:${reset} $*"; }
die() { printf '%s\n' "${red}错误:${reset} $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" = "0" ] || die "请使用 root 运行：sudo bash $0"
}

reject_space_path() {
  case "${INSTALL_DIR}${CONFIG_FILE}${STATE_DIR}${LOG_DIR}${BACKUP_DIR}${INSTALLER_STATE_DIR}" in
    *[[:space:]]*) die "安装路径不能包含空格：${INSTALL_DIR}" ;;
  esac
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

require_hardened_systemd() {
  local version
  version="$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
  case "${version}" in
    ''|*[!0-9]*) die "无法识别 systemd 版本，不能确认 ProtectProc 安全能力" ;;
  esac
  [ "${version}" -ge 247 ] || die "systemd ${version} 过旧；HashCake 安全服务要求 systemd >= 247"
}

ensure_service_user() {
  need_root
  if ! getent group "${SERVICE_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${SERVICE_GROUP}"
  fi
  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd --system --gid "${SERVICE_GROUP}" --home-dir "${INSTALL_DIR}" --shell /usr/sbin/nologin "${SERVICE_USER}"
  fi
}

run_as_service_user() {
  if [ "$(id -u)" = "$(id -u "${SERVICE_USER}")" ]; then
    "$@"
    return
  fi
  command -v runuser >/dev/null 2>&1 || die "缺少 runuser，无法以 ${SERVICE_USER} 身份安全写入运行状态"
  runuser -u "${SERVICE_USER}" -- "$@"
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

random_segment() {
  local prefix="$1"
  local body
  if command -v openssl >/dev/null 2>&1; then
    body="$(openssl rand -hex 4)"
  else
    body="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  printf '%s-%s' "${prefix}" "${body}"
}

normalize_url_prefix() {
  local raw="$1"
  raw="${raw#/}"
  raw="${raw%/}"
  [ -n "${raw}" ] || die "安全访问路径不能为空"
  case "${raw}" in
    *[!a-z0-9-]*|*/*|*.*|*_*) die "安全访问路径只能包含小写字母、数字和连字符：${raw}" ;;
    -*|*-) die "安全访问路径不能以连字符开头或结尾：${raw}" ;;
  esac
  [ "${#raw}" -ge 2 ] && [ "${#raw}" -le 32 ] || die "安全访问路径长度必须是 2-32 位：${raw}"
  case "${raw}" in
    api|assets|admin|static|openapi.json|favicon.svg|index.html) die "安全访问路径不能使用保留名称：${raw}" ;;
  esac
  printf '%s' "${raw}"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
  elif command_exists lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  elif command_exists netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" && return 0
  fi
  return 1
}

random_port() {
  local min="${WEB_PORT_MIN}" max="${WEB_PORT_MAX}" span port i rand
  [ "${min}" -ge 1 ] && [ "${max}" -le 65535 ] && [ "${min}" -le "${max}" ] || die "端口范围无效：${min}-${max}"
  span=$((max - min + 1))
  for i in $(seq 1 200); do
    if command_exists od; then
      rand="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    else
      rand="${RANDOM}${RANDOM}"
    fi
    port=$((min + rand % span))
    if ! port_in_use "${port}"; then
      printf '%s' "${port}"
      return 0
    fi
  done
  die "无法在 ${min}-${max} 范围内找到空闲端口"
}

validate_port_value() {
  local port="$1"
  case "${port}" in
    ''|*[!0-9]*) die "端口必须是数字：${port}" ;;
  esac
  [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ] || die "端口必须在 1-65535 范围内：${port}"
}

validate_admin_bind_for_install() {
  local port
  port="$(bind_port "${ADMIN_BIND}")"
  validate_port_value "${port}"
  if port_in_use "${port}"; then
    die "Web 后台端口 ${port} 已被占用，请更换端口后再安装"
  fi
}

bind_port() {
  local bind="$1"
  printf '%s' "${bind##*:}"
}

host_from_bind() {
  local bind="$1"
  printf '%s' "${bind%:*}"
}

ensure_installer_state_dir() {
  need_root
  if [ -e "${INSTALLER_STATE_DIR}" ] || [ -L "${INSTALLER_STATE_DIR}" ]; then
    [ ! -L "${INSTALLER_STATE_DIR}" ] || die "安装元数据目录不能是符号链接：${INSTALLER_STATE_DIR}"
    [ -d "${INSTALLER_STATE_DIR}" ] || die "安装元数据路径不是目录：${INSTALLER_STATE_DIR}"
    [ "$(stat -c '%u' -- "${INSTALLER_STATE_DIR}")" = "0" ] \
      || die "安装元数据目录必须属于 root：${INSTALLER_STATE_DIR}"
  else
    install -d -m 0700 -o root -g root "${INSTALLER_STATE_DIR}"
  fi
  chmod 700 "${INSTALLER_STATE_DIR}"
  chown root:root "${INSTALLER_STATE_DIR}"
}

validate_root_metadata_file() {
  local path="$1" mode
  [ ! -L "${path}" ] || die "安装元数据文件不能是符号链接：${path}"
  [ -f "${path}" ] || die "安装元数据不是普通文件：${path}"
  [ "$(stat -c '%u' -- "${path}")" = "0" ] || die "安装元数据必须属于 root：${path}"
  mode="$(stat -c '%a' -- "${path}")"
  [ "${mode}" = "600" ] || die "安装元数据权限必须是 600，当前为 ${mode}：${path}"
}

decode_install_env_value() {
  local value="$1"
  case "${value}" in
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
    *\'*|*\"*) die "安装元数据包含不允许的引号" ;;
  esac
  case "${value}" in
    *$'\r'*|*$'\n'*) die "安装元数据包含换行符" ;;
  esac
  printf '%s' "${value}"
}

validate_saved_admin_bind() {
  local value="$1" port
  [ -n "${value}" ] || return 0
  case "${value}" in
    *[!A-Za-z0-9.:[\]_-]*) die "安装元数据中的管理后台监听地址不安全：${value}" ;;
  esac
  port="$(bind_port "${value}")"
  validate_port_value "${port}"
  [ -n "$(host_from_bind "${value}")" ] || die "安装元数据中的管理后台监听主机为空"
}

validate_saved_https() {
  local value="$1"
  [ -z "${value}" ] && return 0
  case "${value}" in
    true|false|1|0|yes|no|on|off) ;;
    *) die "安装元数据中的 HTTPS 状态无效：${value}" ;;
  esac
}

parse_install_env() {
  local path="$1" line key value
  SAVED_ADMIN_BIND=""
  SAVED_URL_PREFIX=""
  SAVED_HTTPS_ACTIVE=""
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) die "安装元数据包含无效行：${path}" ;;
    esac
    key="${line%%=*}"
    value="$(decode_install_env_value "${line#*=}")"
    case "${key}" in
      SAVED_ADMIN_BIND) SAVED_ADMIN_BIND="${value}" ;;
      SAVED_URL_PREFIX) SAVED_URL_PREFIX="${value}" ;;
      SAVED_HTTPS_ACTIVE) SAVED_HTTPS_ACTIVE="${value}" ;;
      *) die "安装元数据包含未知字段 ${key}：${path}" ;;
    esac
  done < "${path}"
  validate_saved_admin_bind "${SAVED_ADMIN_BIND}"
  [ -z "${SAVED_URL_PREFIX}" ] || SAVED_URL_PREFIX="$(normalize_url_prefix "${SAVED_URL_PREFIX}")"
  validate_saved_https "${SAVED_HTTPS_ACTIVE}"
}

load_existing_web_settings() {
  local exec_line="" security_values=()
  if [ -e "${SERVICE_FILE}" ] || [ -L "${SERVICE_FILE}" ]; then
    [ ! -L "${SERVICE_FILE}" ] || die "systemd 服务文件不能是符号链接：${SERVICE_FILE}"
    [ -f "${SERVICE_FILE}" ] || die "systemd 服务路径不是普通文件：${SERVICE_FILE}"
    [ "$(stat -c '%u' -- "${SERVICE_FILE}")" = "0" ] || die "systemd 服务文件必须属于 root：${SERVICE_FILE}"
    if [ $((8#$(stat -c '%a' -- "${SERVICE_FILE}") & 8#022)) -ne 0 ]; then
      die "systemd 服务文件不能被 group/other 写入：${SERVICE_FILE}"
    fi
    exec_line="$(sed -n 's/^ExecStart=//p' "${SERVICE_FILE}" | tail -n 1)"
    SAVED_ADMIN_BIND="$(printf '%s\n' "${exec_line}" | sed -n 's/.*--admin-bind \([^ ]*\).*/\1/p')"
    validate_saved_admin_bind "${SAVED_ADMIN_BIND}"
  fi

  if [ -s "${STATE_DIR}/admin.json" ] && command_exists python3; then
    mapfile -t security_values < <(python3 - "${STATE_DIR}/admin.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
if os.path.islink(path) or not os.path.isfile(path):
    raise SystemExit(0)
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    raise SystemExit(0)
security = data.get("security")
if not isinstance(security, dict):
    raise SystemExit(0)
prefix = security.get("url_prefix")
https_active = security.get("https_active")
print(prefix if isinstance(prefix, str) else "")
print("true" if https_active is True else "false" if https_active is False else "")
PY
)
    [ -z "${security_values[0]:-}" ] || SAVED_URL_PREFIX="$(normalize_url_prefix "${security_values[0]}")"
    SAVED_HTTPS_ACTIVE="${security_values[1]:-}"
    validate_saved_https "${SAVED_HTTPS_ACTIVE}"
  fi

  if [ -e "${LEGACY_INSTALL_ENV}" ] || [ -L "${LEGACY_INSTALL_ENV}" ]; then
    warn "检测到旧版 ${LEGACY_INSTALL_ENV}；该文件由服务账户控制，出于安全原因不会执行或信任，更新后将迁移到 root 专属目录"
  fi
}

load_install_env() {
  SAVED_ADMIN_BIND=""
  SAVED_URL_PREFIX=""
  SAVED_HTTPS_ACTIVE=""
  if [ -e "${INSTALL_ENV}" ] || [ -L "${INSTALL_ENV}" ]; then
    validate_root_metadata_file "${INSTALL_ENV}"
    parse_install_env "${INSTALL_ENV}"
  else
    load_existing_web_settings
  fi
  ADMIN_BIND="${HASHCAKE_ADMIN_BIND:-${ADMIN_BIND:-${SAVED_ADMIN_BIND:-}}}"
  URL_PREFIX="${HASHCAKE_URL_PREFIX:-${URL_PREFIX:-${SAVED_URL_PREFIX:-}}}"
  HTTPS_ACTIVE="${HASHCAKE_HTTPS_ACTIVE:-${HTTPS_ACTIVE:-${SAVED_HTTPS_ACTIVE:-}}}"
}

save_install_env() {
  local tmp
  ensure_installer_state_dir
  validate_saved_admin_bind "${ADMIN_BIND}"
  URL_PREFIX="$(normalize_url_prefix "${URL_PREFIX}")"
  validate_saved_https "${HTTPS_ACTIVE}"
  if [ -e "${INSTALL_ENV}" ] || [ -L "${INSTALL_ENV}" ]; then
    validate_root_metadata_file "${INSTALL_ENV}"
  fi
  umask 077
  tmp="$(mktemp "${INSTALLER_STATE_DIR}/install.env.tmp.XXXXXX")"
  printf 'SAVED_ADMIN_BIND=%s\nSAVED_URL_PREFIX=%s\nSAVED_HTTPS_ACTIVE=%s\n' \
    "${ADMIN_BIND}" "${URL_PREFIX}" "${HTTPS_ACTIVE}" > "${tmp}"
  chmod 600 "${tmp}"
  chown root:root "${tmp}"
  mv -fT "${tmp}" "${INSTALL_ENV}"
  rm -f -- "${LEGACY_INSTALL_ENV}"
}

configure_web_defaults_for_install() {
  if [ -z "${ADMIN_BIND}" ]; then
    ADMIN_BIND="0.0.0.0:$(random_port)"
  fi
  if [ -z "${URL_PREFIX}" ]; then
    URL_PREFIX="$(random_segment hc)"
  else
    URL_PREFIX="$(normalize_url_prefix "${URL_PREFIX}")"
  fi
  if [ -z "${HTTPS_ACTIVE}" ]; then
    HTTPS_ACTIVE="true"
  fi
}

configure_web_defaults_for_update() {
  load_install_env
  [ -n "${ADMIN_BIND}" ] || ADMIN_BIND="0.0.0.0:$(random_port)"
  [ -n "${URL_PREFIX}" ] || URL_PREFIX="$(random_segment hc)"
  URL_PREFIX="$(normalize_url_prefix "${URL_PREFIX}")"
  [ -n "${HTTPS_ACTIVE}" ] || HTTPS_ACTIVE="true"
}

persist_admin_security() {
  command_exists python3 || die "缺少 python3，无法安全写入 ${STATE_DIR}/admin.json"
  local admin_json="${STATE_DIR}/admin.json"
  run_as_service_user python3 - "${admin_json}" "${URL_PREFIX}" "${HTTPS_ACTIVE}" <<'PY'
import json
import os
import stat
import sys
import tempfile

path, prefix, https_active = sys.argv[1:4]
data = {}
try:
    current = os.lstat(path)
except FileNotFoundError:
    current = None
if current is not None and (stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode)):
    raise SystemExit(f"unsafe admin state path: {path}")
if current is not None and current.st_size > 0:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
if not isinstance(data, dict):
    data = {}
security = data.get("security")
if not isinstance(security, dict):
    security = {}
security["version"] = int(security.get("version", 2) or 2)
security["url_prefix"] = prefix
security["https_enabled"] = False
security["https_active"] = https_active.lower() in ("1", "true", "yes", "on")
security.setdefault("offline_alerts_enabled", True)
security.setdefault("ip_blacklist", [])
security.setdefault("wallet_blacklist", [])
data["security"] = security
directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".admin.json.", dir=directory)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

is_installed() {
  [ -x "${BIN_PATH}" ] || [ -f "${SERVICE_FILE}" ] || [ -f "${INSTALL_ENV}" ] || [ -f "${LEGACY_INSTALL_ENV}" ]
}

running_processes() {
  pgrep -af "${BIN_PATH}|(^|/)hashcake( |$)" 2>/dev/null || true
}

check_no_running_conflict() {
  if has_systemd && systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    die "检测到 ${SERVICE_NAME}.service 正在运行；首次安装前请先停止，已安装请使用 update"
  fi
  local running
  running="$(running_processes | grep -v "pgrep -af" || true)"
  [ -z "${running}" ] || die "检测到正在运行的 HashCake 进程，首次安装已停止：
${running}"
}

systemd_unit_exists() {
  local unit="$1"
  systemctl list-unit-files "${unit}" --no-legend 2>/dev/null \
    | awk -v expected="${unit}" '$1 == expected { found = 1 } END { exit found ? 0 : 1 }'
}

firewall_unit_list() {
  printf '%s\n' \
    ufw.service \
    firewalld.service \
    nftables.service \
    iptables.service \
    ip6tables.service \
    netfilter-persistent.service \
    ferm.service \
    shorewall.service \
    shorewall6.service
}

FIREWALL_SNAPSHOT_DIR=""
FIREWALL_ROLLBACK_ARMED=0

capture_firewall_state() {
  local unit enabled active
  [ -z "${FIREWALL_SNAPSHOT_DIR}" ] || die "防火墙事务已经启动"
  FIREWALL_SNAPSHOT_DIR="$(mktemp -d /run/hashcake-firewall.XXXXXX)"
  chmod 700 "${FIREWALL_SNAPSHOT_DIR}"
  : > "${FIREWALL_SNAPSHOT_DIR}/units.tsv"
  chmod 600 "${FIREWALL_SNAPSHOT_DIR}/units.tsv"

  if command_exists ufw && ufw status 2>/dev/null | grep -Eiq '^Status:[[:space:]]*active'; then
    : > "${FIREWALL_SNAPSHOT_DIR}/ufw-active"
  fi

  while IFS= read -r unit; do
    systemd_unit_exists "${unit}" || continue
    enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
    active="$(systemctl is-active "${unit}" 2>/dev/null || true)"
    printf '%s\t%s\t%s\n' "${unit}" "${enabled:-unknown}" "${active:-unknown}" \
      >> "${FIREWALL_SNAPSHOT_DIR}/units.tsv"
  done < <(firewall_unit_list)
}

restore_firewall_unit_enablement() {
  local unit="$1" enabled="$2"
  case "${enabled}" in
    enabled|linked|alias) systemctl enable "${unit}" >/dev/null 2>&1 || return 1 ;;
    enabled-runtime|linked-runtime) systemctl enable --runtime "${unit}" >/dev/null 2>&1 || return 1 ;;
    disabled) systemctl disable "${unit}" >/dev/null 2>&1 || return 1 ;;
    masked) systemctl mask "${unit}" >/dev/null 2>&1 || return 1 ;;
    masked-runtime) systemctl mask --runtime "${unit}" >/dev/null 2>&1 || return 1 ;;
    static|indirect|generated|transient|not-found|unknown|'') ;;
    *) warn "无法精确恢复 ${unit} 的启用状态 ${enabled}，将只恢复运行状态" ;;
  esac
}

restore_firewall_state() {
  local unit enabled active failed=0
  [ -n "${FIREWALL_SNAPSHOT_DIR}" ] || return 0
  warn "HashCake 未成功启动，正在恢复安装前的防火墙状态"

  if command_exists ufw; then
    if [ -f "${FIREWALL_SNAPSHOT_DIR}/ufw-active" ]; then
      ufw --force enable >/dev/null 2>&1 || failed=1
    else
      ufw --force disable >/dev/null 2>&1 || failed=1
    fi
  fi

  while IFS=$'\t' read -r unit enabled active; do
    [ -n "${unit}" ] || continue
    restore_firewall_unit_enablement "${unit}" "${enabled}" || failed=1
    case "${active}" in
      active|activating|reloading) systemctl start "${unit}" >/dev/null 2>&1 || failed=1 ;;
      inactive|failed|deactivating) systemctl stop "${unit}" >/dev/null 2>&1 || failed=1 ;;
    esac
  done < "${FIREWALL_SNAPSHOT_DIR}/units.tsv"

  if [ "${failed}" = "0" ]; then
    ok "已恢复安装前的防火墙状态"
  else
    warn "防火墙自动恢复不完整，请立即检查 ufw/firewalld/nftables 状态"
  fi
}

cleanup_firewall_snapshot() {
  if [ -n "${FIREWALL_SNAPSHOT_DIR}" ]; then
    rm -rf -- "${FIREWALL_SNAPSHOT_DIR}"
    FIREWALL_SNAPSHOT_DIR=""
  fi
}

firewall_exit_guard() {
  local status="$1"
  trap - EXIT
  if [ "${FIREWALL_ROLLBACK_ARMED}" = "1" ]; then
    restore_firewall_state || true
  fi
  cleanup_firewall_snapshot
  exit "${status}"
}

arm_firewall_rollback() {
  capture_firewall_state
  FIREWALL_ROLLBACK_ARMED=1
  trap 'firewall_exit_guard "$?"' EXIT
}

commit_firewall_change() {
  FIREWALL_ROLLBACK_ARMED=0
  trap - EXIT
  cleanup_firewall_snapshot
}

disable_firewall_unit() {
  local unit="$1"
  systemd_unit_exists "${unit}" || return 1
  systemctl disable --now "${unit}" >/dev/null 2>&1 \
    || die "无法关闭并禁用 ${unit}；为避免后续代理端口被拦截，安装已停止"
  if systemctl is-active --quiet "${unit}"; then
    die "${unit} 关闭后仍处于 active 状态；为避免后续代理端口被拦截，安装已停止"
  fi
  if systemctl is-enabled --quiet "${unit}"; then
    die "${unit} 关闭后仍处于 enabled 状态；为避免重启后防火墙恢复，安装已停止"
  fi
  ok "已关闭并禁用 ${unit}"
}

nft_input_filter_is_open() {
  command_exists nft || return 0
  command_exists python3 || die "缺少 python3，无法确认 nftables INPUT 是否已完全放行"
  local nft_json="${FIREWALL_SNAPSHOT_DIR}/nft-after.json"
  nft -j list ruleset > "${nft_json}" 2>/dev/null \
    || die "无法读取 nftables 规则，不能确认整机防火墙已关闭"
  python3 - "${nft_json}" <<'PY'
import collections
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    objects = json.load(fh).get("nftables", [])

chains = {}
rules = collections.defaultdict(list)
for item in objects:
    chain = item.get("chain")
    if isinstance(chain, dict):
        key = (chain.get("family"), chain.get("table"), chain.get("name"))
        chains[key] = chain
    rule = item.get("rule")
    if isinstance(rule, dict):
        key = (rule.get("family"), rule.get("table"), rule.get("chain"))
        rules[key].append(rule.get("expr") or [])

def chain_blocks(key, visiting):
    if key in visiting:
        return False
    visiting = visiting | {key}
    for expr in rules.get(key, []):
        for statement in expr:
            if not isinstance(statement, dict):
                continue
            if "drop" in statement or "reject" in statement:
                return True
            xt = statement.get("xt")
            if isinstance(xt, dict) and str(xt.get("name", "")).upper() in {"DROP", "REJECT"}:
                return True
            target = None
            jump = statement.get("jump")
            goto = statement.get("goto")
            if isinstance(jump, dict):
                target = jump.get("target")
            elif isinstance(goto, dict):
                target = goto.get("target")
            if isinstance(target, str):
                child = (key[0], key[1], target)
                if child in chains and chain_blocks(child, visiting):
                    return True
    return False

for key, chain in chains.items():
    if chain.get("hook") != "input" or chain.get("type") != "filter":
        continue
    if chain.get("policy", "accept") != "accept" or chain_blocks(key, set()):
        raise SystemExit(1)
PY
}

iptables_input_filter_is_open() {
  local saver="$1"
  command_exists "${saver}" || return 0
  command_exists python3 || die "缺少 python3，无法确认 ${saver} INPUT 是否已完全放行"
  local rules_file="${FIREWALL_SNAPSHOT_DIR}/${saver}.after"
  "${saver}" > "${rules_file}" 2>/dev/null \
    || die "无法读取 ${saver} 规则，不能确认整机防火墙已关闭"
  python3 - "${rules_file}" <<'PY'
import shlex
import sys

policies = {}
jumps = {}
in_filter = False
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.strip()
        if line.startswith("*"):
            in_filter = line == "*filter"
            continue
        if not in_filter or not line or line == "COMMIT":
            continue
        if line.startswith(":"):
            parts = line[1:].split()
            if len(parts) >= 2:
                policies[parts[0]] = parts[1]
            continue
        try:
            parts = shlex.split(line)
        except ValueError:
            raise SystemExit(2)
        if len(parts) < 2 or parts[0] != "-A":
            continue
        chain = parts[1]
        target = None
        for flag in ("-j", "--jump", "-g", "--goto"):
            if flag in parts:
                index = parts.index(flag)
                if index + 1 < len(parts):
                    target = parts[index + 1]
                    break
        if target:
            jumps.setdefault(chain, []).append(target)

def blocks(chain, visiting):
    if chain in visiting:
        return False
    visiting = visiting | {chain}
    for target in jumps.get(chain, []):
        upper = target.upper()
        if upper in {"DROP", "REJECT"}:
            return True
        if target in policies and blocks(target, visiting):
            return True
    return False

if policies.get("INPUT", "ACCEPT") != "ACCEPT" or blocks("INPUT", set()):
    raise SystemExit(1)
PY
}

verify_firewall_disabled() {
  local unit
  if command_exists ufw && ufw status 2>/dev/null | grep -Eiq '^Status:[[:space:]]*active'; then
    die "ufw 关闭后仍显示 active；不能保证后续代理端口自动开放"
  fi
  while IFS= read -r unit; do
    systemd_unit_exists "${unit}" || continue
    systemctl is-active --quiet "${unit}" \
      && die "${unit} 关闭后仍处于 active 状态；不能保证后续代理端口自动开放"
    systemctl is-enabled --quiet "${unit}" \
      && die "${unit} 关闭后仍处于 enabled 状态；重启后可能重新拦截代理端口"
  done < <(firewall_unit_list)
  nft_input_filter_is_open \
    || die "仍检测到 nftables INPUT 的 drop/reject 规则；安装器不会谎报整机防火墙已关闭"
  iptables_input_filter_is_open iptables-save \
    || die "仍检测到 iptables INPUT 的 drop/reject 规则；安装器不会谎报整机防火墙已关闭"
  iptables_input_filter_is_open ip6tables-save \
    || die "仍检测到 ip6tables INPUT 的 drop/reject 规则；安装器不会谎报整机防火墙已关闭"
}

disable_firewall_now() {
  need_root
  has_systemd || die "当前系统没有可用 systemd，无法确认整机防火墙已关闭"

  local detected=0
  if command_exists ufw; then
    detected=1
    ufw --force disable >/dev/null 2>&1 \
      || die "无法关闭 ufw；为避免后续代理端口被拦截，安装已停止"
    if ufw status 2>/dev/null | grep -Eiq '^Status:[[:space:]]*active'; then
      die "ufw 关闭后仍显示 active；为避免后续代理端口被拦截，安装已停止"
    fi
    if systemd_unit_exists ufw.service; then
      disable_firewall_unit ufw.service
    else
      ok "已关闭 ufw"
    fi
  fi

  local unit
  while IFS= read -r unit; do
    [ "${unit}" = "ufw.service" ] && continue
    if systemd_unit_exists "${unit}"; then
      detected=1
      disable_firewall_unit "${unit}"
    fi
  done < <(firewall_unit_list)

  if [ "${detected}" = "0" ]; then
    ok "未检测到常见主机防火墙服务，将继续核验 INPUT 是否完全放行"
  fi
  verify_firewall_disabled
  warn "整机防火墙已按 HashCake 运行要求关闭；云厂商安全组和上游网络 ACL 不受安装器控制。"
}

disable_firewall() {
  arm_firewall_rollback
  disable_firewall_now
  commit_firewall_change
}

public_ip() {
  local ip=""
  if command_exists curl; then
    ip="$(curl -fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "${ip}" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${ip:-服务器IP}"
}

admin_url() {
  local scheme="http" host port
  case "${HTTPS_ACTIVE}" in true|1|yes|on) scheme="https" ;; esac
  host="$(host_from_bind "${ADMIN_BIND}")"
  port="$(bind_port "${ADMIN_BIND}")"
  case "${host}" in 0.0.0.0|::|\[::\]|"") host="$(public_ip)" ;; esac
  printf '%s://%s:%s/%s/' "${scheme}" "${host}" "${port}" "${URL_PREFIX}"
}

extract_bootstrap_token() {
  local file="${LOG_DIR}/hashcake.err.log"
  [ -f "${file}" ] || return 1
  awk '/HashCake admin API bootstrap token/{getline; gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); if ($0 != "") print $0}' "${file}" | tail -n 1
}

github_api_get() {
  local url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "${url}"
  elif [ -n "${GH_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" "${url}"
  else
    curl -fsSL "${url}"
  fi
}

download_repo_file() {
  local path="$1"
  local dst="$2"
  local url="https://api.github.com/repos/${RELEASE_REPO}/contents/${path}?ref=${RELEASE_BRANCH}"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fL -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.raw" "${url}" -o "${dst}"
  elif [ -n "${GH_TOKEN:-}" ]; then
    curl -fL -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github.raw" "${url}" -o "${dst}"
  else
    curl -fL -H "Accept: application/vnd.github.raw" "${url}" -o "${dst}"
  fi
}

asset_name_for_version() {
  local prefix="$1"
  if [ "${RELEASE_TAG}" != "latest" ]; then
    printf '%s-%s-%s' "${prefix}" "${RELEASE_TAG#v}" "${RELEASE_PLATFORM}"
    return
  fi
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法查询 latest Release"
  local name
  name="$(github_api_get "https://api.github.com/repos/${RELEASE_REPO}/contents/${RELEASE_PLATFORM}?ref=${RELEASE_BRANCH}" \
    | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -E "^${prefix}-[0-9][0-9A-Za-z._-]*-${RELEASE_PLATFORM}$" \
    | sort -V \
    | tail -n 1)"
  [ -n "${name}" ] || die "无法在 ${RELEASE_REPO}/${RELEASE_PLATFORM} 找到 ${prefix} 的发布文件；可改用 HASHCAKE_DOWNLOAD_URL"
  printf '%s' "${name}"
}

ensure_dirs() {
  need_root
  reject_space_path
  ensure_service_user
  [ ! -L "${INSTALL_DIR}" ] || die "安装目录不能是符号链接：${INSTALL_DIR}"
  [ ! -L "${STATE_DIR}" ] || die "状态目录不能是符号链接：${STATE_DIR}"
  [ ! -L "${LOG_DIR}" ] || die "日志目录不能是符号链接：${LOG_DIR}"
  [ ! -L "${BACKUP_DIR}" ] || die "备份目录不能是符号链接：${BACKUP_DIR}"
  mkdir -p "${INSTALL_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
  chmod 755 "${INSTALL_DIR}"
  chmod 700 "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
  chown root:root "${INSTALL_DIR}" "${BACKUP_DIR}"
  chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${STATE_DIR}" "${LOG_DIR}"
  ensure_installer_state_dir
}

validate_root_controlled_parent() {
  local path="$1" label="$2" parent mode
  parent="$(dirname -- "${path}")"
  [ ! -L "${parent}" ] || die "${label}所在目录不能是符号链接：${parent}"
  [ -d "${parent}" ] || die "${label}所在目录不存在：${parent}"
  [ "$(stat -c '%u' -- "${parent}")" = "0" ] || die "${label}所在目录必须属于 root：${parent}"
  mode="$(stat -c '%a' -- "${parent}")"
  if [ $((8#${mode} & 8#022)) -ne 0 ]; then
    die "${label}所在目录不能被 group/other 写入：${parent}"
  fi
}

ensure_metrics_token() {
  local token_file="${STATE_DIR}/metrics-token"
  command_exists python3 || die "缺少 python3，无法安全创建 ${token_file}"
  run_as_service_user python3 - "${token_file}" <<'PY'
import os
import secrets
import stat
import sys
import tempfile

path = sys.argv[1]
try:
    current = os.lstat(path)
except FileNotFoundError:
    current = None
if current is not None:
    if stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode):
        raise SystemExit(f"unsafe metrics token path: {path}")
    if current.st_size > 0:
        os.chmod(path, 0o600)
        raise SystemExit(0)

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".metrics-token.", dir=directory)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as fh:
        fh.write(secrets.token_hex(32))
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

write_default_config() {
  cat > "${CONFIG_FILE}" <<'YAML'
bind: "0.0.0.0"
max_debt_seconds: 600
reload_interval_secs: 2
legacy_plaintext_ingress: true

tunnel:
  ingress:
    listen: "127.0.0.1:18443"

ports: []
YAML
}

install_config() {
  validate_root_controlled_parent "${CONFIG_FILE}" "配置文件"
  [ ! -L "${CONFIG_FILE}" ] || die "配置文件不能是符号链接：${CONFIG_FILE}"
  if [ -e "${CONFIG_FILE}" ] && [ ! -f "${CONFIG_FILE}" ]; then
    die "配置文件路径不是普通文件：${CONFIG_FILE}"
  fi
  if [ -f "${CONFIG_FILE}" ]; then
    chmod 600 "${CONFIG_FILE}"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_FILE}"
    ok "保留已有配置 ${CONFIG_FILE}"
    return
  fi

  if [ -f "${SOURCE_ROOT}/hashcake.yaml" ]; then
    install -m 0600 "${SOURCE_ROOT}/hashcake.yaml" "${CONFIG_FILE}"
    ok "已复制配置到 ${CONFIG_FILE}"
  else
    write_default_config
    chmod 600 "${CONFIG_FILE}"
    warn "未找到项目内 hashcake.yaml，已生成空 ports 配置；上线前请编辑 ${CONFIG_FILE}"
  fi
  chmod 600 "${CONFIG_FILE}"
  chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_FILE}"
}

build_spa_if_needed() {
  case ",${BUILD_FEATURES}," in
    *,admin-spa,*)
      [ -d "${SOURCE_ROOT}/hashcake/web" ] || die "缺少 hashcake/web，无法构建 admin-spa"
      command -v pnpm >/dev/null 2>&1 || die "缺少 pnpm，无法构建 Web 管理后台"
      log "构建 Web 管理后台"
      if [ -f "${SOURCE_ROOT}/hashcake/web/pnpm-lock.yaml" ]; then
        pnpm --dir "${SOURCE_ROOT}/hashcake/web" install --frozen-lockfile
      else
        pnpm --dir "${SOURCE_ROOT}/hashcake/web" install
      fi
      pnpm --dir "${SOURCE_ROOT}/hashcake/web" build
      ;;
  esac
}

build_hashcake() {
  [ -f "${SOURCE_ROOT}/Cargo.toml" ] || die "当前脚本不在源码仓库内；请设置 HASHCAKE_BIN_SOURCE 或 HASHCAKE_DOWNLOAD_URL"
  command -v cargo >/dev/null 2>&1 || die "缺少 cargo，无法从源码构建"
  build_spa_if_needed
  log "构建 hashcake release 二进制"
  if [ -n "${BUILD_FEATURES}" ]; then
    cargo build --release -p hashcake --bin hashcake --features "${BUILD_FEATURES}"
  else
    cargo build --release -p hashcake --bin hashcake
  fi
}

download_hashcake() {
  local dst="$1"
  local url="${HASHCAKE_DOWNLOAD_URL:-}"
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载 HASHCAKE_DOWNLOAD_URL"
  if [ -z "${url}" ]; then
    case "$(uname -s):$(uname -m)" in
      Linux:x86_64|Linux:amd64) ;;
      *) return 1 ;;
    esac
    local asset
    asset="$(asset_name_for_version hashcake)"
    log "下载 hashcake 二进制：github.com/${RELEASE_REPO}/${RELEASE_PLATFORM}/${asset}"
    download_repo_file "${RELEASE_PLATFORM}/${asset}" "${dst}.download" \
      || die "下载 HashCake 发布文件失败"
  else
    log "下载 hashcake 二进制：${url}"
    curl -fL "${url}" -o "${dst}.download" \
      || die "下载 HASHCAKE_DOWNLOAD_URL 失败"
  fi
  install -m 0755 "${dst}.download" "${dst}" \
    || die "无法准备 HashCake 候选二进制"
  rm -f "${dst}.download"
  return 0
}

install_binary() {
  local src="${HASHCAKE_BIN_SOURCE:-}" candidate source_label
  validate_root_controlled_parent "${BIN_PATH}" "HashCake 二进制"
  [ ! -L "${BIN_PATH}" ] || die "HashCake 二进制不能是符号链接：${BIN_PATH}"
  if [ -e "${BIN_PATH}" ] && [ ! -f "${BIN_PATH}" ]; then
    die "HashCake 二进制路径不是普通文件：${BIN_PATH}"
  fi
  candidate="$(mktemp "${INSTALL_DIR}/.hashcake.candidate.XXXXXX")"
  rm -f -- "${candidate}"
  if [ -n "${src}" ]; then
    [ -x "${src}" ] || die "HASHCAKE_BIN_SOURCE 不存在或不可执行：${src}"
    [ ! -L "${src}" ] || die "HASHCAKE_BIN_SOURCE 不能是符号链接：${src}"
    install -m 0755 "${src}" "${candidate}"
    source_label="指定二进制"
  elif download_hashcake "${candidate}"; then
    source_label="下载的二进制"
  else
    build_hashcake
    install -m 0755 "${SOURCE_ROOT}/target/release/hashcake" "${candidate}"
    source_label="源码构建二进制"
  fi

  chown root:root "${candidate}"
  if command_exists timeout; then
    run_as_service_user timeout 15 "${candidate}" --version >/dev/null 2>&1 \
      || { rm -f -- "${candidate}"; die "HashCake 候选二进制无法正常执行，防火墙尚未修改"; }
  else
    run_as_service_user "${candidate}" --version >/dev/null 2>&1 \
      || { rm -f -- "${candidate}"; die "HashCake 候选二进制无法正常执行，防火墙尚未修改"; }
  fi
  mv -fT "${candidate}" "${BIN_PATH}"
  chmod 755 "${BIN_PATH}"
  chown root:root "${BIN_PATH}"
  ok "已原子安装${source_label} ${BIN_PATH}"
}

write_service() {
  need_root
  has_systemd || die "当前系统没有可用 systemd，暂不写入服务"
  require_hardened_systemd
  [ -n "${ADMIN_BIND}" ] || die "管理后台监听地址为空"
  URL_PREFIX="$(normalize_url_prefix "${URL_PREFIX}")"
  persist_admin_security
  save_install_env
  chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_FILE}"
  validate_root_controlled_parent "${SERVICE_FILE}" "systemd 服务文件"
  [ ! -L "${SERVICE_FILE}" ] || die "systemd 服务文件不能是符号链接：${SERVICE_FILE}"
  if [ -e "${SERVICE_FILE}" ] && [ ! -f "${SERVICE_FILE}" ]; then
    die "systemd 服务路径不是普通文件：${SERVICE_FILE}"
  fi

  local admin_args=""
  if [ "${ADMIN_BIND}" != "off" ] && [ -n "${ADMIN_BIND}" ]; then
    admin_args=" --admin-bind ${ADMIN_BIND} --admin-token-store ${STATE_DIR}/admin.json --admin-audit-db ${STATE_DIR}/admin-audit.sqlite --metrics-token-file ${STATE_DIR}/metrics-token"
  fi
  local update_args=""
  [ -n "${UPDATE_MANIFEST_URL}" ] && update_args=" --update-manifest-url ${UPDATE_MANIFEST_URL}"

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=HashCake Stratum Proxy
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
Environment=RUST_LOG=${RUST_LOG_VALUE}
ExecStart=${BIN_PATH} --config ${CONFIG_FILE} --no-tui --token-store ${STATE_DIR}/tokens.json --log-dir ${LOG_DIR} --log-file-prefix hashcake-debug.log${admin_args}${update_args}
Restart=always
RestartSec=2
TimeoutStopSec=10
LimitNOFILE=1048576
LimitCORE=0
MemorySwapMax=0
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadOnlyPaths=${BIN_PATH}
ReadWritePaths=${CONFIG_FILE} ${STATE_DIR} ${LOG_DIR}
StandardOutput=append:${LOG_DIR}/hashcake.service.log
StandardError=append:${LOG_DIR}/hashcake.err.log

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if command_exists systemd-analyze; then
    systemd-analyze verify "${SERVICE_FILE}" >/dev/null \
      || die "systemd 服务校验失败，防火墙尚未修改"
  fi
  ok "已写入 systemd 服务 ${SERVICE_FILE}"
}

print_install_result() {
  local token=""
  token="$(extract_bootstrap_token || true)"
  cat <<EOF

========== HashCake 安装结果 ==========
当前版本: $([ -x "${BIN_PATH}" ] && "${BIN_PATH}" --version 2>/dev/null || printf '未知')
后台访问地址: $(admin_url)
安装目录: ${INSTALL_DIR}
配置文件: ${CONFIG_FILE}
状态目录: ${STATE_DIR}
日志目录: ${LOG_DIR}
EOF
  if [ -n "${token}" ]; then
    cat <<EOF
首次 Web访问令牌: ${token}
有效期: 10 分钟
EOF
  else
    cat <<EOF
首次 Web访问令牌: 暂未从日志提取到
查看位置: ${LOG_DIR}/hashcake.err.log
有效期: 服务首次启动后 10 分钟
EOF
  fi
  cat <<EOF
安全访问路径: /${URL_PREFIX}/
HTTPS: ${HTTPS_ACTIVE}
提示: 整机防火墙已关闭并禁用；云厂商安全组仍需允许 HashCake 实际使用的端口。
EOF
  case "${HTTPS_ACTIVE}" in
    true|1|yes|on) warn "当前使用自签 HTTPS 证书，浏览器首次访问提示不受信任是预期行为" ;;
  esac
}

install_service() {
  need_root
  reject_space_path
  has_systemd || die "当前系统没有可用 systemd，无法安全安装 HashCake 服务"
  require_hardened_systemd
  is_installed && die "检测到已安装 HashCake，请使用 update 更新程序"
  check_no_running_conflict
  ensure_dirs
  configure_web_defaults_for_install
  validate_admin_bind_for_install
  ensure_metrics_token
  install_config
  install_binary
  write_service
  systemctl enable "${SERVICE_NAME}.service"
  arm_firewall_rollback
  disable_firewall_now
  if [ "${START_AFTER_INSTALL}" = "1" ]; then
    restart_service
  else
    ok "已安装，未自动启动"
  fi
  commit_firewall_change
  print_install_result
}

update_service() {
  need_root
  reject_space_path
  has_systemd || die "当前系统没有可用 systemd，无法安全更新 HashCake 服务"
  require_hardened_systemd
  is_installed || die "未检测到已安装 HashCake，请先执行 install 首次安装"
  ensure_dirs
  configure_web_defaults_for_update
  ensure_metrics_token
  install_config
  install_binary
  write_service
  systemctl enable "${SERVICE_NAME}.service"
  arm_firewall_rollback
  disable_firewall_now
  if [ "${START_AFTER_INSTALL}" = "1" ]; then
    restart_service
  else
    ok "已更新，未自动启动"
  fi
  commit_firewall_change
  cat <<EOF

========== HashCake 更新结果 ==========
当前版本: $([ -x "${BIN_PATH}" ] && "${BIN_PATH}" --version 2>/dev/null || printf '未知')
后台访问地址: $(admin_url)
安全访问路径: /${URL_PREFIX}/
提示: 更新已保留 Web 端口、安全访问路径、账号、令牌、配置和状态目录，并重新确认整机防火墙已关闭。
EOF
}

start_service() {
  need_root
  has_systemd || die "当前系统没有可用 systemd"
  systemctl start "${SERVICE_NAME}.service"
  sleep 1
  status_service
}

stop_service() {
  need_root
  has_systemd || die "当前系统没有可用 systemd"
  systemctl stop "${SERVICE_NAME}.service" || true
  ok "已停止 ${SERVICE_NAME}"
}

restart_service() {
  need_root
  has_systemd || die "当前系统没有可用 systemd"
  local restarts_before restarts_after
  restarts_before="$(systemctl show "${SERVICE_NAME}.service" -p NRestarts --value 2>/dev/null || printf '0')"
  systemctl daemon-reload
  systemctl restart "${SERVICE_NAME}.service"
  sleep 2
  if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
    die "${SERVICE_NAME}.service 启动失败"
  fi
  restarts_after="$(systemctl show "${SERVICE_NAME}.service" -p NRestarts --value 2>/dev/null || printf '0')"
  case "${restarts_before}:${restarts_after}" in
    *[!0-9:]*|'':*) ;;
    *)
      if [ "${restarts_after}" -gt "${restarts_before}" ]; then
        systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
        die "${SERVICE_NAME}.service 启动后发生异常重启"
      fi
      ;;
  esac
  sleep 2
  if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
    die "${SERVICE_NAME}.service 未能稳定运行"
  fi
  status_service
}

enable_service() {
  need_root
  systemctl enable "${SERVICE_NAME}.service"
  ok "已设置开机启动"
}

disable_service() {
  need_root
  systemctl disable "${SERVICE_NAME}.service" || true
  ok "已关闭开机启动"
}

status_service() {
  if has_systemd; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  else
    pgrep -af "${BIN_PATH}" || true
  fi
  show_paths
}

log_files() {
  shopt -s nullglob
  local files=(
    "${LOG_DIR}/hashcake.service.log"
    "${LOG_DIR}/hashcake.err.log"
    "${LOG_DIR}"/hashcake-debug.log.*
  )
  shopt -u nullglob
  printf '%s\n' "${files[@]}"
}

show_logs() {
  local lines="${LINES:-120}"
  local files
  mapfile -t files < <(log_files)
  [ "${#files[@]}" -gt 0 ] || die "还没有日志文件：${LOG_DIR}"
  tail -n "${lines}" "${files[@]}"
}

follow_logs() {
  local files
  mapfile -t files < <(log_files)
  [ "${#files[@]}" -gt 0 ] || die "还没有日志文件：${LOG_DIR}"
  tail -F "${files[@]}"
}

clear_logs() {
  need_root
  mkdir -p "${LOG_DIR}"
  find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log*' -exec sh -c ': > "$1"' _ {} \;
  ok "已清空 ${LOG_DIR} 下的日志文件"
}

edit_config() {
  need_root
  install_config
  local editor="${EDITOR:-}"
  [ -n "${editor}" ] || editor="$(command -v nano || command -v vi || true)"
  [ -n "${editor}" ] || die "找不到编辑器，请设置 EDITOR"
  "${editor}" "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
  chown "${SERVICE_USER}:${SERVICE_GROUP}" "${CONFIG_FILE}"
}

show_paths() {
  load_install_env
  cat <<EOF

安装目录: ${INSTALL_DIR}
配置文件: ${CONFIG_FILE}
状态目录: ${STATE_DIR}
日志目录: ${LOG_DIR}
二进制:   ${BIN_PATH}
服务名:   ${SERVICE_NAME}
运行用户: ${SERVICE_USER}
管理后台: ${ADMIN_BIND:-未设置}
访问地址: $([ -n "${ADMIN_BIND:-}" ] && [ -n "${URL_PREFIX:-}" ] && admin_url || printf '未设置')
安全访问路径: $([ -n "${URL_PREFIX:-}" ] && printf '/%s/' "${URL_PREFIX}" || printf '未设置')
发布仓库: https://github.com/${RELEASE_REPO}
EOF
  if [ -s "${STATE_DIR}/metrics-token" ]; then
    printf 'Prometheus token 文件: %s\n' "${STATE_DIR}/metrics-token"
  fi
  if [ -f "${LOG_DIR}/hashcake.err.log" ] && grep -q 'bootstrap token' "${LOG_DIR}/hashcake.err.log"; then
    warn "首次 Web访问令牌在 ${LOG_DIR}/hashcake.err.log 中，只在首次启动后 10 分钟内有效"
  fi
}

change_web_settings() {
  need_root
  ensure_dirs
  configure_web_defaults_for_update
  local current_port new_port new_prefix new_https
  current_port="$(bind_port "${ADMIN_BIND}")"
  if [ -t 0 ]; then
    read -r -p "Web 端口 [${current_port}]: " new_port
    read -r -p "安全访问路径 [/${URL_PREFIX}/]: " new_prefix
    read -r -p "是否启用 HTTPS，自签证书，不申请证书 [${HTTPS_ACTIVE}]: " new_https
  else
    new_port="${HASHCAKE_WEB_PORT:-}"
    new_prefix="${HASHCAKE_URL_PREFIX:-}"
    new_https="${HASHCAKE_HTTPS_ACTIVE:-}"
  fi
  if [ -n "${new_port}" ]; then
    validate_port_value "${new_port}"
    if [ "${new_port}" != "${current_port}" ] && port_in_use "${new_port}"; then
      die "Web 后台端口 ${new_port} 已被占用，请换一个端口"
    fi
    ADMIN_BIND="$(host_from_bind "${ADMIN_BIND}"):${new_port}"
  fi
  [ -n "${new_prefix}" ] && URL_PREFIX="$(normalize_url_prefix "${new_prefix}")"
  [ -n "${new_https}" ] && HTTPS_ACTIVE="${new_https}"
  write_service
  restart_service
  show_paths
}

change_limit() {
  need_root
  log "设置 Linux 文件句柄上限"
  grep -q 'root soft nofile 1048576' /etc/security/limits.conf 2>/dev/null || echo 'root soft nofile 1048576' >> /etc/security/limits.conf
  grep -q 'root hard nofile 1048576' /etc/security/limits.conf 2>/dev/null || echo 'root hard nofile 1048576' >> /etc/security/limits.conf
  grep -q 'DefaultLimitNOFILE=1048576' /etc/systemd/system.conf 2>/dev/null || echo 'DefaultLimitNOFILE=1048576' >> /etc/systemd/system.conf
  systemctl daemon-reexec || true
  ok "已设置连接数上限，完整生效可能需要重启服务器"
}

token_list() {
  [ -x "${BIN_PATH}" ] || die "请先安装 hashcake 二进制"
  run_as_service_user "${BIN_PATH}" --config "${CONFIG_FILE}" token list --store "${STATE_DIR}/tokens.json"
}

token_revoke() {
  local site="${1:-}"
  if [ -z "${site}" ]; then
    if [ -t 0 ]; then
      read -r -p "请输入要撤销的 site_id: " site
    else
      die "site_id 不能为空；命令模式请写：$0 token-revoke <site_id>"
    fi
  fi
  [ -n "${site}" ] || die "site_id 不能为空"
  run_as_service_user "${BIN_PATH}" --config "${CONFIG_FILE}" token revoke "${site}" --store "${STATE_DIR}/tokens.json"
  ok "已撤销 ${site}"
}

token_issue() {
  [ -x "${BIN_PATH}" ] || die "请先安装 hashcake 二进制"
  local site="${TOKEN_SITE:-}"
  local backend="${TOKEN_BACKEND:-}"
  local ports_text="${TOKEN_PORTS:-}"
  local cover_text="${TOKEN_COVER_IPS:-}"
  local ttl="${TOKEN_TTL:-}"
  local miner_bind="${TOKEN_MINER_BIND:-0.0.0.0}"
  local single_cover="${TOKEN_SINGLE_COVER:-}"

  if [ -z "${site}" ] && [ -t 0 ]; then
    read -r -p "site_id，例如 site-shenzhen-01: " site
  fi
  [ -n "${site}" ] || die "site_id 不能为空；命令模式请设置 TOKEN_SITE"

  if [ -z "${backend}" ] && [ -t 0 ]; then
    read -r -p "Backend 地址，例如 your-hashcake.example:18446: " backend
  fi
  [ -n "${backend}" ] || die "Backend 地址不能为空；命令模式请设置 TOKEN_BACKEND"

  if [ -z "${ports_text}" ] && [ -t 0 ]; then
    read -r -p "开放给该 CakeBox 的端口，多个用逗号分隔，留空=配置内全部端口: " ports_text
  fi

  if [ -z "${cover_text}" ] && [ -t 0 ]; then
    read -r -p "cover IP，多个用逗号分隔；单 IP 部署只填一个: " cover_text
  fi
  [ -n "${cover_text}" ] || die "cover IP 不能为空；命令模式请设置 TOKEN_COVER_IPS"

  if [ -z "${ttl}" ] && [ -t 0 ]; then
    read -r -p "有效期秒数，留空=永久: " ttl
  fi
  if [ -z "${single_cover}" ] && [ "$(printf '%s' "${cover_text}" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')" = "1" ]; then
    single_cover="1"
  fi

  local args=(--config "${CONFIG_FILE}" token issue --site "${site}" --backend "${backend}" --store "${STATE_DIR}/tokens.json" --miner-bind "${miner_bind}")
  local item
  IFS=',' read -r -a port_items <<< "${ports_text}"
  for item in "${port_items[@]}"; do
    item="$(printf '%s' "${item}" | xargs)"
    [ -n "${item}" ] && args+=(--port "${item}")
  done
  IFS=',' read -r -a cover_items <<< "${cover_text}"
  for item in "${cover_items[@]}"; do
    item="$(printf '%s' "${item}" | xargs)"
    [ -n "${item}" ] && args+=(--cover-ip "${item}")
  done
  [ -n "${ttl}" ] && args+=(--ttl "${ttl}")
  [ "${single_cover}" = "1" ] && args+=(--single-cover)

  run_as_service_user "${BIN_PATH}" "${args[@]}"
}

uninstall() {
  need_root
  local confirm="${CONFIRM_UNINSTALL:-}"
  if [ "${confirm}" != "yes" ]; then
    if [ -t 0 ]; then
      read -r -p "确认卸载并删除 ${INSTALL_DIR}？输入 yes 继续: " confirm
    else
      die "非交互卸载需要设置 CONFIRM_UNINSTALL=yes"
    fi
  fi
  [ "${confirm}" = "yes" ] || die "已取消卸载"
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "${INSTALL_DIR}"
  ok "已卸载 ${APP_NAME}"
}

menu() {
  clear || true
  cat <<EOF
========== ${APP_NAME} 一键安装管理 ==========
安装目录: ${INSTALL_DIR}
服务名:   ${SERVICE_NAME}

1. 首次安装
2. 更新程序
3. 启动
4. 停止
5. 重启
6. 查看运行状态
7. 查看最近日志
8. 实时跟随日志
9. 清空日志
10. 设置开机启动
11. 关闭开机启动
12. 编辑配置
13. 查看路径和访问地址
14. 修改 Web 访问设置
15. 签发隧道加密令牌
16. 查看隧道加密令牌列表
17. 撤销隧道加密令牌
18. 关闭并禁用整机防火墙
19. 解除系统连接数限制
20. 卸载
0. 退出
EOF
  read -r -p "请选择 [0-20]: " choice
  case "${choice}" in
    1) install_service ;;
    2) update_service ;;
    3) start_service ;;
    4) stop_service ;;
    5) restart_service ;;
    6) status_service ;;
    7) show_logs ;;
    8) follow_logs ;;
    9) clear_logs ;;
    10) enable_service ;;
    11) disable_service ;;
    12) edit_config ;;
    13) show_paths ;;
    14) change_web_settings ;;
    15) token_issue ;;
    16) token_list ;;
    17) token_revoke ;;
    18) disable_firewall ;;
    19) change_limit ;;
    20) uninstall ;;
    0) exit 0 ;;
    *) die "无效选择" ;;
  esac
}

cmd="${1:-menu}"
case "${cmd}" in
  install) install_service ;;
  update) update_service ;;
  start) start_service ;;
  stop) stop_service ;;
  restart) restart_service ;;
  status) status_service ;;
  logs) show_logs ;;
  follow-logs) follow_logs ;;
  clear-logs) clear_logs ;;
  enable) enable_service ;;
  disable) disable_service ;;
  edit-config) edit_config ;;
  paths|show-url) show_paths ;;
  web-settings|configure-web) change_web_settings ;;
  disable-firewall) disable_firewall ;;
  limit) change_limit ;;
  token-issue|token-create) shift; token_issue "$@" ;;
  token-list) token_list ;;
  token-revoke) shift; token_revoke "$@" ;;
  write-service) ensure_dirs; configure_web_defaults_for_update; ensure_metrics_token; install_config; write_service ;;
  uninstall) uninstall ;;
  menu|"") menu ;;
  *) die "未知命令：${cmd}" ;;
esac
