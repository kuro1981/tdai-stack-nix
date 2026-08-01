# metadata-instances.json を BWS 由来の秘密から生成するヘルパー。
#
# このファイルは Gateway の Bearer token を含むため、git に置けない
# （上流も .gitignore で除外し「禁止提交」と明記している）。
#
# 原則（docs/adr/0006-config-governance.md）に従い「保存しない」を採る:
#   - 起動直前に tmpfs 上へ生成する
#   - コンテナには :ro でマウントする
#   - 生成先は /dev/shm 配下。再起動で消え、ディスクにもバックアップにも残らない
#
# 秘密は TDAI_GATEWAY_API_KEY（BWS 登録済み）から取る。
{ lib, writeShellApplication, jq, coreutils }:

writeShellApplication {
  name = "tdai-write-instances";

  runtimeInputs = [ jq coreutils ];

  text = ''
    : "''${TDAI_GATEWAY_API_KEY:?TDAI_GATEWAY_API_KEY が未設定です（BWS から供給されるはず）}"

    INSTANCE_ID="''${TDAI_INSTANCE_ID:-default}"
    INSTANCE_NAME="''${TDAI_INSTANCE_NAME:-local}"
    GATEWAY_ENDPOINT="''${TDAI_GATEWAY_ENDPOINT:-http://127.0.0.1:8420}"

    # tmpfs 上に置く。ディスクへ落とさないための選択。
    OUT_DIR="''${TDAI_RUNTIME_DIR:-/dev/shm/tdai}"
    OUT="$OUT_DIR/metadata-instances.json"

    mkdir -p "$OUT_DIR"
    chmod 700 "$OUT_DIR"

    # jq に --arg で渡す。シェル展開で秘密がプロセス引数へ出るのを避けるため
    # 環境変数経由（--arg は argv に載るので env で受ける）。
    jq -n \
      --arg id   "$INSTANCE_ID" \
      --arg name "$INSTANCE_NAME" \
      --arg ep   "$GATEWAY_ENDPOINT" \
      --arg key  "$TDAI_GATEWAY_API_KEY" \
      '{instances: [{id: $id, name: $name, gateway_endpoint: $ep, api_key: $key}]}' \
      > "$OUT"

    chmod 600 "$OUT"
    echo "$OUT"
  '';

  meta = with lib; {
    description = "Generate metadata-instances.json on tmpfs from BWS-provided secrets";
    platforms = platforms.linux;
    mainProgram = "tdai-write-instances";
  };
}
