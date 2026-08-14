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
  [[ -f flake.nix && -f knowledge.nix && -f core.nix && -f panel-web.nix ]] || {
    log_error "flake.nix / *.nix が見つかりません。リポジトリ root で実行してください。"
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

# 上流にロックが無い / 使い物にならないものを自前生成する。
#
#   MemoryKnowledge    ロック自体が無い
#   MemoryCore         ロックが無い。peer 競合があり --legacy-peer-deps が要る
#   MemoryPanel        ロックはあるが 229 エントリ全部が mirrors.tencent.com。
#                      GitHub Actions の runner から取れずタイムアウトする
#   MemoryPanel/web    ロックはあるが mirrors.tencent.com と npmjs が混在し、
#                      peer 競合で npm ci が再解決に入って ENOTCACHED になる
#
# web だけ graphology-types を直接依存として足す。--legacy-peer-deps は peer を
# install しないため、これが無いと tsc が TS2339 で落ちる（panel-web.nix 参照）。
regenerate_one_lock() {
  local rev="$1" subdir="$2" out="$3" extra_flags="$4" inject_graphology="$5"
  log_info "${subdir} の package-lock.json を再生成..."
  local work; work="$(mktemp -d)"
  gh api "repos/${UPSTREAM_REPO}/contents/${subdir}/package.json?ref=${rev}" \
    --jq '.content' | base64 -d > "$work/package.json"

  if [[ "$inject_graphology" == "yes" ]]; then
    jq '.devDependencies["graphology-types"] = "0.24.8"' "$work/package.json" \
      > "$work/package.json.tmp" && mv "$work/package.json.tmp" "$work/package.json"
  fi

  # 2 回まわすこと。1 回目の npm は入れ子に置いたパッケージの dev / optional
  # フラグを落とすことがある。実例として MemoryKnowledge の
  #   node_modules/vitest/node_modules/@esbuild/aix-ppc64
  # が dev も optional も付かない「本番の必須依存」として書き出され、
  # buildNpmPackage の npm ci が EBADPLATFORM で落ちた
  #   （wanted {"os":"aix","cpu":"ppc64"} / current linux-x64）。
  # 同一版の tsx/node_modules/@esbuild/aix-ppc64 は正しく付いていたので、
  # 依存の中身ではなく npm のツリー構築側の取りこぼし。
  # 2 回目で npm がツリーを正規化し、重複placement が畳まれて解消する。
  local pass
  for pass in 1 2; do
    # shellcheck disable=SC2086
    ( cd "$work" && npm install --package-lock-only --ignore-scripts \
        --registry=https://registry.npmjs.org --no-audit --no-fund \
        $extra_flags >/dev/null 2>&1 )
    [[ -f "$work/package-lock.json" ]] || { log_error "${subdir} のロック生成に失敗しました（pass ${pass}）"; rm -rf "$work"; exit 1; }
  done

  # os / cpu 制約を持つのに dev / optional / devOptional のどれも付いていない
  # パッケージが残っていたら、上記の取りこぼしが再発している。
  # 黙って通すと nix build 側で EBADPLATFORM になるためここで落とす。
  local unflagged
  unflagged="$(jq -r '
    .packages | to_entries[]
    | select(.value.os or .value.cpu)
    | select((.value.dev|not) and (.value.optional|not) and (.value.devOptional|not))
    | .key' "$work/package-lock.json")"
  if [[ -n "$unflagged" ]]; then
    log_error "${subdir}: プラットフォーム制約付きなのに optional 扱いになっていないパッケージがあります:"
    echo "$unflagged"
    rm -rf "$work"
    exit 1
  fi

  cp "$work/package-lock.json" "$out"
  log_info "  $(jq '.packages|length' "$out") パッケージ -> ${out}"
  rm -rf "$work"
}

regenerate_lock() {
  local rev="$1"
  regenerate_one_lock "$rev" MemoryKnowledge  locks/knowledge-package-lock.json ""                    no
  regenerate_one_lock "$rev" MemoryCore       locks/core-package-lock.json      "--legacy-peer-deps"  no
  regenerate_one_lock "$rev" MemoryPanel      locks/panel-package-lock.json     ""                    no
  regenerate_one_lock "$rev" MemoryPanel/web  locks/panel-web-package-lock.json "--legacy-peer-deps"  yes
}

# npmDepsHash は事前計算できない。ダミーでビルドを失敗させ got: を拾う。
#
# flake.nix には npmDepsHash が 4 つある。以前は出現順（1 番目 / 2 番目…）で
# 差し替えていたが、パッケージが増えるたびに番号がずれて別のパッケージの
# ハッシュを壊す。属性名の直後に現れる npmDepsHash を書き換える方式にした。
set_npm_deps_hash() {
  local attr="$1" value="$2"
  awk -v a="$attr" -v v="$value" '
    $0 ~ ("^ *" a " = final.callPackage") { inblk = 1 }
    inblk && /npmDepsHash = "/ {
      sub(/npmDepsHash = "[^"]*";/, "npmDepsHash = \"" v "\";")
      inblk = 0
    }
    { print }
  ' flake.nix > flake.nix.tmp && mv flake.nix.tmp flake.nix
}

resolve_one_hash() {
  local attr="$1"
  log_info "npmDepsHash を解決: ${attr}（ここでビルドが 1 度失敗するのは想定どおり）..."
  set_npm_deps_hash "$attr" "$DUMMY_HASH"
  local out; out="$(nix build ".#${attr}" 2>&1 || true)"
  local h; h="$(echo "$out" | sed -n 's/.*got: *\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -1)"
  [[ -n "$h" ]] || { log_error "${attr} の npmDepsHash を特定できませんでした:"; echo "$out" | tail -20; exit 1; }
  log_info "  ${attr}: $h"
  set_npm_deps_hash "$attr" "$h"
}

resolve_npm_deps_hash() {
  # panel-web は panel より先に解決すること。panel のラッパーが
  # panel-web の store path を埋め込むため、後だと panel を建て直す羽目になる。
  resolve_one_hash tdai-core
  resolve_one_hash tdai-panel-web
  resolve_one_hash tdai-panel
  resolve_one_hash tdai-knowledge
}

verify_build() {
  log_info "ビルド検証..."
  nix build .#tdai-core .#tdai-knowledge .#tdai-panel .#tdai-panel-web --no-link >/dev/null
  local co; co="$(nix build .#tdai-core --no-link --print-out-paths)"
  local ks; ks="$(nix build .#tdai-knowledge --no-link --print-out-paths)"
  local pn; pn="$(nix build .#tdai-panel --no-link --print-out-paths)"
  local pw; pw="$(nix build .#tdai-panel-web --no-link --print-out-paths)"
  [[ -x "$co/bin/tdai-core-gateway" ]] || { log_error "tdai-core-gateway が生成されていません"; exit 1; }
  [[ -x "$ks/bin/knowledge-server" ]]  || { log_error "knowledge-server が生成されていません"; exit 1; }
  [[ -x "$pn/bin/tdai-panel" ]]        || { log_error "tdai-panel が生成されていません"; exit 1; }
  [[ -f "$pw/index.html" ]]            || { log_error "panel の UI が生成されていません"; exit 1; }

  # UI がラッパーに埋め込まれていること（これが抜けると GET / が 404 になる）
  grep -q "UI_DIST_DIR" "$pn/bin/tdai-panel" \
    || { log_error "tdai-panel に UI_DIST_DIR が埋め込まれていません"; exit 1; }
  log_info "ビルド検証を通過しました。"
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
