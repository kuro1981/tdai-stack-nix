# Panel の Web UI（Vite + React）を別パッケージとしてビルドする。
#
# 【なぜ分けるか】
#   MemoryPanel は pnpm workspace で、サーバ（ルート）と UI（web/）が
#   それぞれ独立した package.json / package-lock.json を持つ。
#   buildNpmPackage は npmDeps を 1 つしか扱えないため、1 derivation に
#   まとめられない。
#
# 【なぜ必要か】
#   npm は .npmignore が無いと .gitignore を代用する。上流の .gitignore は
#   dist/ を除外するため、`web/dist`（UI のビルド成果物）がパッケージから
#   落ちる。ルートの dist と同じ事情だが、こちらは npmBuildScript が
#   走らせる `tsc` の対象外なので postBuild で退避する手が使えない。
#
#   結果、Panel は起動するが UI が無く GET / が 404 になり、ログに
#     serveStatic: root path './web/dist' is not found
#   が出る。
#
#   サーバ側は UI_DIST_DIR でパスを差し替えられる（panel-config.ts:51）ので、
#   ここでビルドした成果物を panel.nix のラッパーから指させる。
{ lib
, buildNpmPackage
, fetchFromGitHub
, nodejs
, upstreamRev
, upstreamHash
, npmDepsHash
, lockFile
}:

buildNpmPackage {
  pname = "tdai-panel-web";
  version = "0.1.0-${builtins.substring 0 7 upstreamRev}";

  src = fetchFromGitHub {
    owner = "TencentCloud";
    repo = "TencentDB-Agent-Memory";
    rev = upstreamRev;
    hash = upstreamHash;
  };

  sourceRoot = "source/MemoryPanel/web";

  inherit npmDepsHash nodejs;

  # 上流の web/package-lock.json は mirrors.tencent.com (364) と
  # registry.npmjs.org (111) が混在し、さらに react-onclickoutside の peer
  # 衝突で npm ci が再解決に入る。offline cache には無いため ENOTCACHED で
  # 落ちる。単一レジストリで生成し直したロックを持ち込む。
  #
  # 【graphology-types を直接依存に足している理由】
  #   npm ci を通すには --legacy-peer-deps が要るが、このフラグは peer
  #   dependency を install しない。すると graphology の peer である
  #   graphology-types が落ち、Graph 型がスタブになって tsc が TS2339 で
  #   失敗する（KnowledgeGraph.tsx の addNode / hasNode / addEdgeWithKey）。
  #
  #   フラグを外すと今度は npm ci が再解決に入って ENOTCACHED になる。
  #   両立させるため、peer を直接依存として明示する。バージョンは上流
  #   ロックと同じ 0.24.8 に固定してある。
  #
  #   ロック生成時もこの package.json 変更を入れること。入れないと
  #   npm ci が lock と package.json の不一致で失敗する。
  postPatch = ''
    cp ${lockFile} ./package-lock.json

    ${nodejs}/bin/node -e '
      const fs = require("fs");
      const p = JSON.parse(fs.readFileSync("package.json", "utf8"));
      p.devDependencies = p.devDependencies || {};
      p.devDependencies["graphology-types"] = "0.24.8";
      fs.writeFileSync("package.json", JSON.stringify(p, null, 2));
    '
  '';

  # ロック生成時と同じフラグを使うこと（揃えないと再解決が走る）。
  npmFlags = [ "--legacy-peer-deps" ];

  npmBuildScript = "build";

  # npm の install フックは package.json の名前で node_modules 配下へ置くが、
  # ここで欲しいのは静的ファイル一式だけ。dist をそのまま $out へ置く。
  installPhase = ''
    runHook preInstall

    if [ ! -e dist/index.html ]; then
      echo "ERROR: web/dist が生成されていません" >&2
      ls -A . >&2
      exit 1
    fi
    mkdir -p "$out"
    cp -r dist/. "$out/"

    runHook postInstall
  '';

  # 静的ファイルのみなので、実行可能ファイルの検査は不要。
  dontFixup = true;

  meta = with lib; {
    description = "TDAI Memory Panel — web UI (static assets)";
    homepage = "https://github.com/TencentCloud/TencentDB-Agent-Memory";
    license = licenses.asl20;
    platforms = platforms.all;
  };
}
