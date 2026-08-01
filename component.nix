# TDAI スタックの 1 コンポーネントを、docker コンテナを起動するラッパーとして包む。
#
# なぜ dockerTools ではないのか:
#   上流が公開しているイメージをそのまま使うため、nix でイメージを作る必要がない。
#   nix が担うのは「どのイメージを、どう起動するか」の宣言であり、実行は docker に任せる。
#
# なぜタグではなく digest なのか:
#   タグ（1.0.0-beta.1）は上流が差し替えられる。digest なら内容が固定される。
#   宣言と実態を一致させるという原則（docs/adr/0006）に従う。
{ lib
, writeShellApplication
, docker
, jq
}:

{ name              # コンテナ名の suffix / パッケージ名
, repo              # Docker Hub のリポジトリ
, digest            # sha256:...
, version
, ports ? [ ]       # [{ host = "8420"; container = "8420"; }] host は 127.0.0.1 に固定
, volumes ? [ ]     # [{ name = "vol"; path = "/data"; }]
, envVars ? [ ]     # 起動時に環境から引き継ぐ変数名
, requiredEnv ? [ ] # 未設定なら起動を拒否する変数名
, networkAlias ? name
, extraDockerArgs ? [ ]
, description
}:

let
  container = "tdai-${name}";
  network = "tdai-memory-stack";
  image = "${repo}@${digest}";

  portArgs = lib.concatMapStringsSep " \\\n  " (p:
    ''-p "127.0.0.1:''${${p.hostVar}:-${p.host}}:${p.container}"''
  ) ports;

  volumeArgs = lib.concatMapStringsSep " \\\n  " (v:
    ''-v "''${${v.nameVar}:-${v.name}}:${v.path}"''
  ) volumes;

  envArgs = lib.concatMapStringsSep " \\\n  " (e:
    ''-e ${e}="''${${e}:-}"''
  ) envVars;

  requiredChecks = lib.concatMapStringsSep "\n" (e:
    '': "''${${e}:?${e} が未設定です}"''
  ) requiredEnv;
in
writeShellApplication {
  inherit name;

  runtimeInputs = [ docker jq ];

  text = ''
    # 必須環境変数の検査（秘密は BWS から供給される想定）
    ${requiredChecks}

    if ! docker network inspect ${network} >/dev/null 2>&1; then
      echo "[tdai] docker network を作成: ${network}"
      docker network create ${network} >/dev/null
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx "${container}"; then
      echo "[tdai] 既存コンテナを削除: ${container}"
      docker rm -f "${container}" >/dev/null
    fi

    echo "[tdai] ${name} を起動 (${version}, digest 固定)"
    docker run -d --name "${container}" \
      --network ${network} \
      --network-alias ${networkAlias} \
      --add-host=host.docker.internal:host-gateway \
      --restart unless-stopped \
      ${portArgs} \
      ${volumeArgs} \
      ${envArgs} \
      ${lib.concatStringsSep " \\\n  " extraDockerArgs} \
      "${image}" >/dev/null

    docker ps --filter "name=${container}" --format '  {{.Names}}  {{.Status}}  {{.Ports}}'
  '';

  meta = with lib; {
    inherit description;
    homepage = "https://github.com/TencentCloud/TencentDB-Agent-Memory";
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = name;
  };
}
