#!/usr/bin/env bash
# Docker Hub のイメージ digest を確認し、images.json を更新する。
#
# bws-nix / memory-tencentdb-nix と同じ作法。ただし対象がバイナリでも npm でも
# なく OCI イメージなので、Registry API から digest を引く。
#
# タグではなく digest を正とする理由は README.md を参照。
set -euo pipefail

readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'; readonly NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

ensure_in_repository_root() {
  [[ -f flake.nix && -f images.json ]] || {
    log_error "flake.nix / images.json が見つかりません。リポジトリ root で実行してください。"
    exit 1
  }
}

ensure_required_tools_installed() {
  for c in jq curl nix; do
    command -v "$c" >/dev/null 2>&1 || { log_error "$c が必要です"; exit 1; }
  done
}

# Docker Hub の匿名 pull トークンを取得する
registry_token() {
  local repo="$1"
  curl -sSf "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    | jq -r '.token'
}

# マルチアーキの index digest を取得する（arm64 / amd64 の両方を含む親 manifest）
fetch_digest() {
  local repo="$1" tag="$2" token
  token="$(registry_token "$repo")"
  curl -sSfI \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" \
    | grep -i '^docker-content-digest' | tr -d '\r' | awk '{print $2}'
}

verify_build() {
  log_info "ビルド検証..."
  nix build .#tdai-memory-core .#tdai-memory-hub .#tdai-memory-proxy --no-link >/dev/null
  log_info "ビルド検証を通過しました。"
}

print_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo "  --tag TAG   対象のタグ（既定: images.json の version）"
  echo "  --check     差分の有無のみ確認する（差分があれば exit 1）"
  echo "  --help      このヘルプ"
}

main() {
  ensure_in_repository_root
  ensure_required_tools_installed

  local target_tag="" check_only="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)   target_tag="$2"; shift 2 ;;
      --check) check_only="true"; shift ;;
      --help)  print_usage; exit 0 ;;
      *) log_error "不明なオプション: $1"; print_usage; exit 1 ;;
    esac
  done

  local tag
  tag="${target_tag:-$(jq -r '.version' images.json)}"
  log_info "対象タグ: ${tag}"

  local changed="false"
  local tmp; tmp="$(mktemp)"
  cp images.json "$tmp"

  for key in $(jq -r '.images | keys[]' images.json); do
    local repo current latest
    repo="$(jq -r --arg k "$key" '.images[$k].repo' images.json)"
    current="$(jq -r --arg k "$key" '.images[$k].digest' images.json)"
    latest="$(fetch_digest "$repo" "$tag")"

    if [[ -z "$latest" ]]; then
      log_error "digest を取得できませんでした: ${repo}:${tag}"
      exit 1
    fi

    if [[ "$current" == "$latest" ]]; then
      log_info "  ${key}: 変更なし"
    else
      log_warn "  ${key}: ${current:0:19}... -> ${latest:0:19}..."
      changed="true"
      jq --arg k "$key" --arg d "$latest" '.images[$k].digest = $d' "$tmp" > "$tmp.new"
      mv "$tmp.new" "$tmp"
    fi
  done

  if [[ "$changed" == "false" ]]; then
    rm -f "$tmp"
    log_info "すべて最新です。"
    exit 0
  fi

  if [[ "$check_only" == "true" ]]; then
    rm -f "$tmp"
    log_warn "更新があります。"
    exit 1
  fi

  jq --arg v "$tag" '.version = $v' "$tmp" > images.json
  rm -f "$tmp"
  verify_build

  echo
  log_info "変更点:"
  git diff --stat images.json 2>/dev/null || true
  log_info "images.json を更新しました。"
}

main "$@"
