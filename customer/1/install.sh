#!/usr/bin/env bash
set -Eeuo pipefail

EDITION_ID="1"
EDITION_PATH="customer/${EDITION_ID}"
RELEASE_REPO="${HASHCAKE_RELEASE_REPO:-CakeSystem/hashcake}"
RELEASE_BRANCH="${HASHCAKE_RELEASE_BRANCH:-main}"
RELEASE_PLATFORM="${HASHCAKE_RELEASE_PLATFORM:-linux-amd64}"
RELEASE_TAG="${HASHCAKE_VERSION:-latest}"

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
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

asset_name() {
  if [ "${RELEASE_TAG}" != "latest" ]; then
    printf 'hashcake-%s-%s' "${RELEASE_TAG#v}" "${RELEASE_PLATFORM}"
    return
  fi

  local api_url="https://api.github.com/repos/${RELEASE_REPO}/contents/${EDITION_PATH}/${RELEASE_PLATFORM}?ref=${RELEASE_BRANCH}"
  local name
  name="$(
    github_api_get "${api_url}" 2>/dev/null \
      | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | grep -E "^hashcake-[0-9][0-9A-Za-z._-]*-${RELEASE_PLATFORM}$" \
      | sort -V \
      | tail -n 1 \
      || true
  )"
  [ -n "${name}" ] || die "定制版 ${EDITION_ID} 尚未发布 Linux 二进制"
  printf '%s' "${name}"
}

command -v curl >/dev/null 2>&1 || die "缺少 curl"

asset="$(asset_name)"
export HASHCAKE_DOWNLOAD_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/${RELEASE_BRANCH}/${EDITION_PATH}/${RELEASE_PLATFORM}/${asset}"
export HASHCAKE_RELEASE_REPO="${RELEASE_REPO}"
export HASHCAKE_RELEASE_BRANCH="${RELEASE_BRANCH}"

if [ "$#" -eq 0 ]; then
  set -- install
fi

exec bash <(curl -fsSL "https://raw.githubusercontent.com/${RELEASE_REPO}/${RELEASE_BRANCH}/install.sh") "$@"
