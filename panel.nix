# MemoryPanel（Team Memory Control）を上流ソースからビルドする。
#
# Team / Agent / Task と Knowledge 資産を管理する Web コンソール。
#
# Knowledge と違い、こちらは上流に package-lock.json があるためそのまま使える。
# ネイティブ依存も無く、依存は 5 個の軽量サーバ（Next.js ではない）。
#
# 【起動に必要なもの】
#   metadata-instances.json を config/ に置くこと。Memory インスタンスの
#   接続先（gateway_endpoint / api_key）を定義する。api_key は Core の
#   Bearer と同一。このファイルは秘密を含むため上流も .gitignore で除外し
#   「禁止提交」としている。実行時に用意する。
{ lib
, buildNpmPackage
, fetchFromGitHub
, nodejs
, makeWrapper
, tdai-panel-web
, upstreamRev
, upstreamHash
, npmDepsHash
}:

buildNpmPackage {
  pname = "tdai-panel";
  version = "0.1.0-${builtins.substring 0 7 upstreamRev}";

  src = fetchFromGitHub {
    owner = "TencentCloud";
    repo = "TencentDB-Agent-Memory";
    rev = upstreamRev;
    hash = upstreamHash;
  };

  sourceRoot = "source/MemoryPanel";

  inherit npmDepsHash nodejs;

  nativeBuildInputs = [ makeWrapper ];

  npmBuildScript = "build";

  # 上流には .npmignore が無く .gitignore に dist/ が入っている。npm は
  # .npmignore が無い場合 .gitignore を代用するため、npmInstallHook が
  # ビルド成果物である dist を除外してしまう（npm の仕様どおりの挙動で、
  # 上流がこのパッケージを npm 公開する想定を持たないために起きる）。
  #
  # ビルド直後の dist を退避し、install 後に戻す。
  postBuild = ''
    cp -r dist "$NIX_BUILD_TOP/panel-dist"
  '';

  # Knowledge と同様、bin 経由ではなくビルド成果物を直接 node に渡す。
  # package.json の scripts.start が `node dist/index.js` であり、これが
  # 上流の想定する起動方法である。
  postInstall = ''
    mkdir -p "$out/bin"
    pkgDir="$out/lib/node_modules/team-memory-control"

    # .gitignore により除外された dist を戻す（上記 postBuild の説明を参照）
    cp -r "$NIX_BUILD_TOP/panel-dist" "$pkgDir/dist"

    # Panel は起動時の作業ディレクトリ基準で config/metadata-instances.json を
    # 探す。環境変数での指定口は無い（dist を grep しても該当なし）。
    # そのため TDAI_PANEL_WORKDIR で作業ディレクトリを与えられるようにする。
    # 既定は $PWD なので、config/ を持つ場所から起動すればそのまま動く。
    #
    # UI（web/dist）も .gitignore により npm パッケージから落ちる。さらに
    # web/ は独立した package-lock.json を持つため buildNpmPackage の
    # npmDeps を分ける必要があり、別 derivation にしてある。
    # サーバは UI_DIST_DIR でパスを差し替えられる（panel-config.ts:51）ので
    # そこを指す。これが無いと GET / が 404 になり、ログに
    #   serveStatic: root path './web/dist' is not found
    # が出る。
    makeWrapper ${nodejs}/bin/node "$out/bin/tdai-panel" \
      --add-flags "$pkgDir/dist/index.js" \
      --set-default UI_DIST_DIR "${tdai-panel-web}" \
      --run 'cd "''${TDAI_PANEL_WORKDIR:-$PWD}"' 
  '';

  meta = with lib; {
    description = "TDAI Memory Panel — team / agent / task control console";
    homepage = "https://github.com/TencentCloud/TencentDB-Agent-Memory";
    license = licenses.asl20;
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "tdai-panel";
  };
}
