# MemoryCore（v2）を上流ソースからビルドする。
#
# 記憶（L0〜L3）に加えて metadata 層（user / team / agent / task / skill）を
# 持つ。npm 公開版 @tencentdb-agent-memory/memory-tencentdb (1.x) には
# metadata/ が含まれず、Panel が必要とする /v3/meta/* API も無い。
# したがって Panel や Skill API を使うにはこちらが要る。
#
#   npm 版 : @tencentdb-agent-memory/memory-tencentdb     1.0.1
#   上流   : @tencentdb-agent-memory/memory-tencentdb-v2  2.0.0-beta.1
#
# 【データ形式】
#   v2.0.0+ はデータ形式 v3 を使う。v1.x（形式 v2）から上げる場合は
#   scripts/migrate-v2-to-v3/v2-to-v3-migrate.py を **新 Gateway 起動前に**
#   実行すること。vectors.db にテナント分離カラム（team_id / task_id /
#   user_id / agent_id / version）が追加され、L2/L3 ファイルが
#   profiles/ 配下の scoped path へ移る。
#
# 【ロックファイル】
#   上流に package-lock.json が無いため自前生成したものを持ち込む。
#   Knowledge と同じ事情。
{ lib
, buildNpmPackage
, fetchFromGitHub
, nodejs
, python3
, node-gyp
, makeWrapper
, upstreamRev
, upstreamHash
, npmDepsHash
, lockFile
}:

buildNpmPackage {
  pname = "tdai-core";
  version = "2.0.0-beta.1-${builtins.substring 0 7 upstreamRev}";

  src = fetchFromGitHub {
    owner = "TencentCloud";
    repo = "TencentDB-Agent-Memory";
    rev = upstreamRev;
    hash = upstreamHash;
  };

  sourceRoot = "source/MemoryCore";

  inherit npmDepsHash nodejs;

  nativeBuildInputs = [ python3 node-gyp makeWrapper ];

  # 上流の依存に peer dependency の競合がある（mongodb の peerOptional
  # gcp-metadata など）。npm ci が失敗するため legacy 解決を使う。
  # ロック生成時も同じフラグを使うこと（scripts/update.sh も合わせてある）。
  npmFlags = [ "--legacy-peer-deps" ];

  # 上流の build は build:plugin + build:scripts の連結で、後者が
  # scripts/seed-v2/tsconfig.json を参照する。しかしそのディレクトリは
  # リポジトリに存在せず TS5058 で失敗する（docker/entrypoint.sh が
  # 無いのと同じ、作業途中の状態）。
  #
  # Gateway の起動に必要なのは build:plugin（tsdown）だけなので、
  # 欠けている参照を除いた形に書き換える。
  postPatch = ''
    cp ${lockFile} ./package-lock.json

    # 存在しない tsconfig を参照するサブビルドを build から外す
    for t in seed-v2; do
      if [ ! -e "scripts/$t/tsconfig.json" ]; then
        echo "postPatch: scripts/$t が無いため build:$t を除外します"
        substituteInPlace package.json \
          --replace-quiet " && npm run build:$t" "" \
          --replace-quiet "npm run build:$t && " ""
      fi
    done
  '';

  npmBuildScript = "build";

  # Knowledge と同じく bin は使わず、ソースを直接 node に渡す。
  # 上流 README の Quick start も `node --import tsx src/gateway/server.ts` と
  # 書いており、これが想定された起動方法である。
  postInstall = ''
    mkdir -p "$out/bin"
    pkgDir="$out/lib/node_modules/@tencentdb-agent-memory/memory-tencentdb-v2"

    if [ ! -d "$pkgDir" ]; then
      echo "ERROR: 想定したパッケージディレクトリが見つかりません" >&2
      ls "$out/lib/node_modules" >&2
      exit 1
    fi

    makeWrapper ${nodejs}/bin/node "$out/bin/tdai-core-gateway" \
      --add-flags "--import tsx" \
      --add-flags "$pkgDir/src/gateway/server.ts"

    # 移行スクリプト（v2 -> v3）も同梱する。新 Gateway 起動前に要実行。
    if [ -e "$pkgDir/scripts/migrate-v2-to-v3/v2-to-v3-migrate.py" ]; then
      makeWrapper ${python3}/bin/python3 "$out/bin/tdai-core-migrate-v2-to-v3" \
        --add-flags "$pkgDir/scripts/migrate-v2-to-v3/v2-to-v3-migrate.py"
    fi
  '';

  meta = with lib; {
    description = "TDAI Memory Core v2 — memory (L0-L3) + metadata (user/team/agent/task/skill)";
    homepage = "https://github.com/TencentCloud/TencentDB-Agent-Memory";
    license = licenses.asl20;
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "tdai-core-gateway";
  };
}
