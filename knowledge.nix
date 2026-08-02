# MemoryKnowledge（Knowledge Service）を上流ソースからビルドする。
#
# Wiki / CodeGraph を提供する。SQLite（better-sqlite3）だけで動き、
# 外部 DB は不要。
#
# 【ロックファイルについて】
#   上流の MemoryKnowledge には package-lock.json が無い。buildNpmPackage は
#   ロックを要求するため、こちらで生成したものを postPatch で持ち込む。
#   locks/knowledge-package-lock.json が UPSTREAM_REV の package.json に
#   対応する。上流の依存が変わったら再生成が要る（scripts/update.sh が行う）。
#
# 【better-sqlite3】
#   ネイティブモジュール。node-gyp のビルドに python3 と C++ ツールチェインが
#   要る。nixpkgs の慣例どおり nativeBuildInputs で与える。
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
  pname = "tdai-knowledge";
  version = "0.1.0-${builtins.substring 0 7 upstreamRev}";

  src = fetchFromGitHub {
    owner = "TencentCloud";
    repo = "TencentDB-Agent-Memory";
    rev = upstreamRev;
    hash = upstreamHash;
  };

  sourceRoot = "source/MemoryKnowledge";

  inherit npmDepsHash nodejs;

  # 上流にロックが無いため持ち込む。
  # 【MCP クライアントが x-tdai-service-id を送らない】
  #   src/mcp/http-client.ts は Content-Type と Authorization しか付けない。
  #   一方 HTTP API 側は x-tdai-service-id を必須にしているため、上流の
  #   MCP サーバは上流の HTTP API に対して常に
  #     Error: x-tdai-service-id header is required
  #   を返す。この経路は誰も通していないと見られる。
  #
  #   ヘッダを注入する。値は KNOWLEDGE_SERVICE_ID で上書きでき、既定は
  #   "default"（KS / Core / Panel が使っている service id と揃えてある）。
  postPatch = ''
    cp ${lockFile} ./package-lock.json

    substituteInPlace src/mcp/http-client.ts \
      --replace-fail \
        'if (opts.token) headers["Authorization"] = `Bearer ''${opts.token}`;' \
        'if (opts.token) headers["Authorization"] = `Bearer ''${opts.token}`;
  headers["x-tdai-service-id"] = process.env.KNOWLEDGE_SERVICE_ID || "default";'
  '';

  nativeBuildInputs = [ python3 node-gyp makeWrapper ];

  # tsdown でビルドする（scripts.build）
  npmBuildScript = "build";

  # 上流の bin/*.mjs は使わない。2 つの問題があるため。
  #
  #   1. `import "../dist/server.js"` と書かれているが tsdown の出力は
  #      server.mjs である（拡張子が一致せず ERR_MODULE_NOT_FOUND）
  #   2. 拡張子を直しても起動しない。dist/server.mjs は import.meta.url を
  #      見て「直接実行されたか」を判定しており、bin から import された
  #      場合は起動処理へ進まない（telemetry の初期化で停止する）
  #
  # どちらも上流の bin が壊れていることによる。Docker イメージは
  # ENTRYPOINT に docker/entrypoint.sh を使う想定だが、そのファイル自体が
  # リポジトリに存在しない（404）ため、bin 経由は誰も通っていないと見られる。
  #
  # したがって dist を直接 node に渡すラッパーを自前で作る。
  postInstall = ''
    rm -f "$out/bin/knowledge-server" "$out/bin/knowledge-mcp"
    mkdir -p "$out/bin"

    pkgDir="$out/lib/node_modules/@tencentdb-agent-memory/knowledge-service"

    makeWrapper ${nodejs}/bin/node "$out/bin/knowledge-server" \
      --add-flags "$pkgDir/dist/server.mjs"

    if [ -e "$pkgDir/dist/mcp/server.mjs" ]; then
      makeWrapper ${nodejs}/bin/node "$out/bin/knowledge-mcp" \
        --add-flags "$pkgDir/dist/mcp/server.mjs"
    fi
  '';

  meta = with lib; {
    description = "TDAI Knowledge Service — wiki / code-graph, with an MCP entrypoint";
    homepage = "https://github.com/TencentCloud/TencentDB-Agent-Memory";
    license = licenses.asl20;
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "knowledge-server";
  };
}
