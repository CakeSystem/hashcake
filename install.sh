#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="HashCake"
RELEASE_REPO="${HASHCAKE_RELEASE_REPO:-CakeSystem/hashcake}"
RELEASE_TAG="${HASHCAKE_VERSION:-latest}"
RELEASE_BRANCH="${HASHCAKE_RELEASE_BRANCH:-main}"
RELEASE_PLATFORM="${HASHCAKE_RELEASE_PLATFORM:-linux-amd64}"
SERVICE_NAME="${HASHCAKE_SERVICE:-hashcake}"
INSTALL_DIR="${HASHCAKE_HOME:-/opt/hashcake}"
CONFIG_FILE="${HASHCAKE_CONFIG:-${INSTALL_DIR}/hashcake.yaml}"
STATE_DIR="${HASHCAKE_STATE_DIR:-${INSTALL_DIR}/state}"
LOG_DIR="${HASHCAKE_LOG_DIR:-${INSTALL_DIR}/logs}"
BACKUP_DIR="${HASHCAKE_BACKUP_DIR:-${INSTALL_DIR}/backup}"
BIN_PATH="${INSTALL_DIR}/hashcake"
ADMIN_BIND="${HASHCAKE_ADMIN_BIND:-0.0.0.0:8088}"
ADMIN_CERT_SAN="${HASHCAKE_ADMIN_CERT_SAN:-}"
UPDATE_MANIFEST_URL="${HASHCAKE_UPDATE_MANIFEST_URL:-}"
RUST_LOG_VALUE="${RUST_LOG:-hashcake=info}"
BUILD_FEATURES="${HASHCAKE_FEATURES:-admin-spa}"
START_AFTER_INSTALL="${HASHCAKE_START_AFTER_INSTALL:-1}"

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
  case "${INSTALL_DIR}${CONFIG_FILE}${STATE_DIR}${LOG_DIR}" in
    *[[:space:]]*) die "安装路径不能包含空格：${INSTALL_DIR}" ;;
  esac
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
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
  mkdir -p "${INSTALL_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
  chmod 700 "${INSTALL_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
}

ensure_metrics_token() {
  local token_file="${STATE_DIR}/metrics-token"
  if [ ! -s "${token_file}" ]; then
    random_secret > "${token_file}"
    chmod 600 "${token_file}"
  fi
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
  if [ -f "${CONFIG_FILE}" ]; then
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
    download_repo_file "${RELEASE_PLATFORM}/${asset}" "${BIN_PATH}.download"
  else
    log "下载 hashcake 二进制：${url}"
    curl -fL "${url}" -o "${BIN_PATH}.download"
  fi
  install -m 0755 "${BIN_PATH}.download" "${BIN_PATH}"
  rm -f "${BIN_PATH}.download"
  return 0
}

install_binary() {
  local src="${HASHCAKE_BIN_SOURCE:-}"
  if [ -n "${src}" ]; then
    [ -x "${src}" ] || die "HASHCAKE_BIN_SOURCE 不存在或不可执行：${src}"
    install -m 0755 "${src}" "${BIN_PATH}"
    ok "已安装二进制 ${BIN_PATH}"
    return
  fi

  if download_hashcake; then
    ok "已安装下载的二进制 ${BIN_PATH}"
    return
  fi

  build_hashcake
  install -m 0755 "${SOURCE_ROOT}/target/release/hashcake" "${BIN_PATH}"
  ok "已安装二进制 ${BIN_PATH}"
}

write_service() {
  need_root
  has_systemd || die "当前系统没有可用 systemd，暂不写入服务"

  local admin_args=""
  if [ "${ADMIN_BIND}" != "off" ] && [ -n "${ADMIN_BIND}" ]; then
    admin_args=" --admin-bind ${ADMIN_BIND} --admin-token-store ${STATE_DIR}/admin.json --admin-audit-db ${STATE_DIR}/admin-audit.sqlite --metrics-token-file ${STATE_DIR}/metrics-token"
  fi
  local san_args=""
  [ -n "${ADMIN_CERT_SAN}" ] && san_args=" --admin-cert-san ${ADMIN_CERT_SAN}"
  local update_args=""
  [ -n "${UPDATE_MANIFEST_URL}" ] && update_args=" --update-manifest-url ${UPDATE_MANIFEST_URL}"

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=HashCake Stratum Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
Environment=RUST_LOG=${RUST_LOG_VALUE}
ExecStart=${BIN_PATH} --config ${CONFIG_FILE} --no-tui --token-store ${STATE_DIR}/tokens.json --log-dir ${LOG_DIR} --log-file-prefix hashcake-debug.log${admin_args}${san_args}${update_args}
Restart=always
RestartSec=2
TimeoutStopSec=10
LimitNOFILE=1048576
StandardOutput=append:${LOG_DIR}/hashcake.service.log
StandardError=append:${LOG_DIR}/hashcake.err.log

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "已写入 systemd 服务 ${SERVICE_FILE}"
}

install_or_update() {
  need_root
  ensure_dirs
  ensure_metrics_token
  install_config
  install_binary
  write_service
  systemctl enable "${SERVICE_NAME}.service"
  if [ "${START_AFTER_INSTALL}" = "1" ]; then
    restart_service
  else
    ok "已安装，未自动启动"
  fi
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
  systemctl daemon-reload
  systemctl restart "${SERVICE_NAME}.service"
  sleep 2
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
}

show_paths() {
  cat <<EOF

安装目录: ${INSTALL_DIR}
配置文件: ${CONFIG_FILE}
状态目录: ${STATE_DIR}
日志目录: ${LOG_DIR}
二进制:   ${BIN_PATH}
服务名:   ${SERVICE_NAME}
管理后台: ${ADMIN_BIND}
发布仓库: https://github.com/${RELEASE_REPO}
EOF
  if [ -s "${STATE_DIR}/metrics-token" ]; then
    printf 'Prometheus token 文件: %s\n' "${STATE_DIR}/metrics-token"
  fi
  if [ -f "${LOG_DIR}/hashcake.err.log" ] && grep -q 'bootstrap token' "${LOG_DIR}/hashcake.err.log"; then
    warn "首次 Web 激活 token 在 ${LOG_DIR}/hashcake.err.log 中，只在首次启动后 10 分钟内有效"
  fi
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
  "${BIN_PATH}" --config "${CONFIG_FILE}" token list --store "${STATE_DIR}/tokens.json"
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
  "${BIN_PATH}" --config "${CONFIG_FILE}" token revoke "${site}" --store "${STATE_DIR}/tokens.json"
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

  "${BIN_PATH}" "${args[@]}"
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

1. 安装 / 更新
2. 启动
3. 停止
4. 重启
5. 查看运行状态
6. 查看最近日志
7. 实时跟随日志
8. 清空日志
9. 设置开机启动
10. 关闭开机启动
11. 编辑配置
12. 查看路径和访问地址
13. 签发 CakeBox 激活令牌
14. 查看 CakeBox 令牌列表
15. 撤销 CakeBox 令牌
16. 解除系统连接数限制
17. 卸载
0. 退出
EOF
  read -r -p "请选择 [0-17]: " choice
  case "${choice}" in
    1) install_or_update ;;
    2) start_service ;;
    3) stop_service ;;
    4) restart_service ;;
    5) status_service ;;
    6) show_logs ;;
    7) follow_logs ;;
    8) clear_logs ;;
    9) enable_service ;;
    10) disable_service ;;
    11) edit_config ;;
    12) show_paths ;;
    13) token_issue ;;
    14) token_list ;;
    15) token_revoke ;;
    16) change_limit ;;
    17) uninstall ;;
    0) exit 0 ;;
    *) die "无效选择" ;;
  esac
}

cmd="${1:-menu}"
case "${cmd}" in
  install|update) install_or_update ;;
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
  paths) show_paths ;;
  limit) change_limit ;;
  token-issue) shift; token_issue "$@" ;;
  token-list) token_list ;;
  token-revoke) shift; token_revoke "$@" ;;
  write-service) ensure_dirs; ensure_metrics_token; write_service ;;
  uninstall) uninstall ;;
  menu|"") menu ;;
  *) die "未知命令：${cmd}" ;;
esac
