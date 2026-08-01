#!/usr/bin/env bash
# 上流 TencentDB-Agent-Memory の追跡ブランチを確認し、必要なら追随する。
#
# bws-nix / memory-tencentdb-nix と同じ作法だが、更新すべきものが 4 つあり
# 順序に依存関係がある点が異なる。
#
#   1. upstreamRev      追跡ブランチの HEAD
#   2. upstreamHash     そのソースの NAR ハッシュ
#   3. locks/*.json     上流に package-lock.json が無いため自前生成したもの
#   4. npmDepsHash      3 から決まる
#
# 3 を再生成しないと 4 が古い依存のままになるため、必ずこの順で行う。
set -euo pipefail

readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'; readonly NC='\033[0m'

readonly UPSTREAM_REPO="TencentCloud/TencentDB-Agent-Memory"
readonly TRACK_BRANCH="${TDAI_TRACK_BRANCH:-feat/server_team}"
readonly DUMMY_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

ensure_in_repository_root() {
  [[ -f flake.nix && -f knowledge.nix ]] || {
    log_error "flake.nix / knowledge.nix が見つかりません。リポジトリ root で実行してください。"
    exit 1
  }
}

ensure_required_tools_installed() {
  for c in gh jq nix npm; do
    command -v "$c" >/dev/null 2>&1 || { log_error "$c が必要です"; exit 1; }
  done
}

get_current_rev() {
  sed -n 's/.*upstreamRev = "\([^"]*\)".*/\1/p' flake.nix | head -1
}

get_latest_rev() {
  gh api "repos/${UPSTREAM_REPO}/branches/${TRACK_BRANCH}" --jq '.commit.sha' 2>/dev/null || true
}

set_nix_string() {
  # $1=キー名 $2=新しい値
  sed -i "s|$1 = \"[^\"]*\";|$1 = \"$2\";|" flake.nix
}

fetch_source_hash() {
  local rev="$1" b32
  b32="$(nix-prefetch-url --unpack \
    "https://github.com/${UPSTREAM_REPO}/archive/${rev}.tar.gz" 2>/dev/null | tail -1)"
  [[ -n "$b32" ]] || { log_error "ソースハッシュを取得できませんでした"; exit 1; }
  nix hash to-sri --type sha256 "$b32"
}

regenerate_lock() {
  local rev="$1"
  log_info "MemoryKnowledge の package-lock.json を再生成..."
  local work; work="$(mktemp -d)"
  gh api "repos/${UPSTREAM_REPO}/contents/MemoryKnowledge/package.json?ref=${rev}" \
    --jq '.content' | base64 -d > "$work/package.json"
  ( cd "$work" && npm install --package-lock-only --ignore-scripts >/dev/null 2>&1 )
  [[ -f "$work/package-lock.json" ]] || { log_error "ロック生成に失敗しました"; rm -rf "$work"; exit 1; }
  cp "$work/package-lock.json" locks/knowledge-package-lock.json
  log_info "  $(jq '.packages|length' locks/knowledge-package-lock.json) パッケージ"
  rm -rf "$work"
}

# npmDepsHash は事前計算できない。ダミーでビルドを失敗させ got: を拾う。
resolve_npm_deps_hash() {
  log_info "npmDepsHash を解決（ここでビルドが 1 度失敗するのは想定どおり）..."
  set_nix_string "npmDepsHash" "$DUMMY_HASH"
  local out; out="$(nix build .#tdai-knowledge 2>&1 || true)"
  local h; h="$(echo "$out" | sed -n 's/.*got: *\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -1)"
  [[ -n "$h" ]] || { log_error "npmDepsHash を特定できませんでした:"; echo "$out" | tail -20; exit 1; }
  log_info "  npmDepsHash: $h"
  set_nix_string "npmDepsHash" "$h"
}

verify_build() {
  log_info "ビルド検証..."
  nix build .#tdai-knowledge >/dev/null
  [[ -x result/bin/knowledge-server ]] || { log_error "knowledge-server が生成されていません"; exit 1; }
  log_info "ビルド検証を通過しました。実行ファイル: $(ls result/bin | tr '\n' ' ')"
}

print_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo "  --rev REV   特定のリビジョンへ更新"
  echo "  --check     更新の有無のみ確認（あれば exit 1）"
  echo "  --help      このヘルプ"
}

main() {
  ensure_in_repository_root
  ensure_required_tools_installed

  local target_rev="" check_only="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rev)   target_rev="$2"; shift 2 ;;
      --check) check_only="true"; shift ;;
      --help)  print_usage; exit 0 ;;
      *) log_error "不明なオプション: $1"; print_usage; exit 1 ;;
    esac
  done

  local current latest
  current="$(get_current_rev)"
  latest="${target_rev:-$(get_latest_rev)}"
  [[ -n "$latest" ]] || { log_error "上流の rev を取得できませんでした"; exit 1; }

  log_info "追跡ブランチ: ${TRACK_BRANCH}"
  log_info "現在の rev  : ${current:0:12}"
  log_info "最新の rev  : ${latest:0:12}"

  if [[ "$current" == "$latest" ]]; then
    log_info "既に最新です。"
    exit 0
  fi

  if [[ "$check_only" == "true" ]]; then
    log_warn "更新があります: ${current:0:12} -> ${latest:0:12}"
    exit 1
  fi

  set_nix_string "upstreamRev" "$latest"
  log_info "ソースハッシュを取得..."
  set_nix_string "upstreamHash" "$(fetch_source_hash "$latest")"
  regenerate_lock "$latest"
  resolve_npm_deps_hash
  echo "$latest" > locks/UPSTREAM_REV
  nix flake update
  verify_build

  echo
  log_info "変更点:"
  git diff --stat flake.nix flake.lock locks/ 2>/dev/null || true
  log_info "${current:0:12} -> ${latest:0:12} へ更新しました。"
}

main "$@"
