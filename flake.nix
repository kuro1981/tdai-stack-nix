{
  description = "Nix packaging for the TencentDB Agent Memory stack (memory-core / memory-hub / memory-proxy)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      manifest = builtins.fromJSON (builtins.readFile ./images.json);
      inherit (manifest) version images;

      overlay = final: prev:
        let
          mk = final.callPackage ./component.nix { };
        in
        {
          # metadata-instances.json を tmpfs 上に生成するヘルパー。
          # このファイルは Gateway Bearer を含むため git に置けない（上流も禁止）。
          # 「保存しない」原則に従い、起動直前に /dev/shm へ書き、:ro でマウントする。
          tdai-write-instances = final.callPackage ./instances.nix { };

          # ── memory-core ────────────────────────────────────────────────
          # 記憶の読み書き / 認証 / skill・RAG データプレーン。
          # 実体は @tencentdb-agent-memory/memory-tencentdb と同系統の内核 gateway で、
          # Hermes プラグインが接続する先でもある。
          tdai-memory-core = mk {
            name = "tdai-memory-core";
            repo = images."memory-core".repo;
            digest = images."memory-core".digest;
            inherit version;
            networkAlias = "memory-core";
            description = "TDAI Memory Core — memory read/write, auth, skill/RAG data plane";
            ports = [{ hostVar = "MEMORY_CORE_PORT"; host = "8420"; container = "8420"; }];
            volumes = [{ nameVar = "MEMORY_CORE_VOLUME"; name = "tdai-memory-core-data"; path = "/data"; }];
            requiredEnv = [ "LLM_API_KEY" ];
            envVars = [ "GATEWAY_API_KEY" "LLM_BASE_URL" "LLM_API_KEY" "LLM_MODEL" "LLM_PROTOCOL" ];
          };

          # ── memory-hub ─────────────────────────────────────────────────
          # Panel UI (8125) と Knowledge Service (8424) を 1 コンテナに同梱した
          # 合併イメージ。KS が Wiki / CodeGraph を担う。
          #
          # 【必須 3 点】deploy/panel-knowledge-combined/README.md より
          #   1. metadata-instances.json のマウント（Memory インスタンスの定義）
          #   2. KNOWLEDGE_PUBLIC_BASE_URL —— 外部到達可能なアドレス。
          #      127.0.0.1 / localhost は不可。/v3 を含むこと
          #   3. LLM 接続先
          #
          # 【⚠ 認証が無い】
          #   KS には認証層が存在しない（middleware は error-handler と
          #   response-envelope のみ）。POST /v3/tools/call から read_raw /
          #   get_graph が無認証で呼べるため、到達できる者は取り込んだ
          #   コードベースの中身と構造をすべて読める。
          #
          #   「外部到達可能」はインターネット公開を意味しない。コンテナ /
          #   ホストの境界を越えられればよい。ポートは 127.0.0.1 に
          #   バインドしている。変更する場合は Tailnet / VPN / firewall で
          #   必ず到達範囲を絞ること。0.0.0.0 で公開してはならない。
          #
          # 【LLM_MODE】
          #   proxy  : Tencent Cloud の Memory Gateway の LLM 転送を使う（既定）
          #   custom : 自前のエンドポイントへ直結。クラウド購入が不要になる
          #   → 本パッケージは custom を前提とする。LLM_BASE_URL / LLM_API_KEY が必須。
          tdai-memory-hub = mk {
            name = "tdai-memory-hub";
            repo = images."memory-hub".repo;
            digest = images."memory-hub".digest;
            inherit version;
            networkAlias = "memory-hub";
            description = "TDAI Memory Hub — team panel (8125) + knowledge service / wiki / code-graph (8424)";
            ports = [
              { hostVar = "PANEL_PORT"; host = "8125"; container = "8125"; }
              { hostVar = "KNOWLEDGE_PORT"; host = "8424"; container = "8424"; }
            ];
            volumes = [{ nameVar = "PANEL_VOLUME"; name = "tdai-panel-data"; path = "/data/knowledge"; }];
            requiredEnv = [
              "TDAI_INSTANCES_FILE"        # metadata-instances.json の実パス
              "KNOWLEDGE_PUBLIC_BASE_URL"  # 外部到達可能なアドレス（/v3 必須）
              "LLM_API_KEY"                # LLM_MODE=custom のため必須
              "LLM_BASE_URL"
            ];
            envVars = [
              "PANEL_PORT" "KNOWLEDGE_PORT" "MEMORY_CORE_GATEWAY_API_KEY"
              "KNOWLEDGE_PUBLIC_BASE_URL"
              "LLM_MODE" "LLM_PROTOCOL" "LLM_MODEL" "LLM_BASE_URL" "LLM_API_KEY"
              "LLM_MAX_TOKENS" "LLM_TIMEOUT_MS"
            ];
            extraDockerArgs = [
              ''-v "$TDAI_INSTANCES_FILE:/app/panel/config/metadata-instances.json:ro"''
            ];
          };

          # ── memory-proxy ───────────────────────────────────────────────
          # LLM リクエストの中継。memory-core を呼んで skill / memory を注入する。
          #
          # 【注意】これを Claude Code に使うと ANTHROPIC_BASE_URL を差し替えることに
          # なり、Claude Max のサブスクリプション認証ではなく PROXY_UPSTREAM_* の
          # API キー課金になる。パッケージとして持つことと起動することは別なので、
          # 使うかは実行時に判断する。
          tdai-memory-proxy = mk {
            name = "tdai-memory-proxy";
            repo = images."memory-proxy".repo;
            digest = images."memory-proxy".digest;
            inherit version;
            networkAlias = "proxy";
            description = "TDAI Memory Proxy — LLM request proxy with memory/skill injection (Anthropic/OpenAI dual protocol)";
            ports = [{ hostVar = "PROXY_PORT"; host = "8096"; container = "8096"; }];
            requiredEnv = [ "PROXY_CONFIG_FILE" ];
            envVars = [ "MEMORY_CORE_GATEWAY_API_KEY" ];
            # proxy は上流 URL / key を環境変数ではなく YAML から読む
            extraDockerArgs = [ ''-v "$PROXY_CONFIG_FILE:/data/config.yaml:ro"'' ];
          };
        };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
      in
      {
        packages = {
          inherit (pkgs) tdai-memory-core tdai-memory-hub tdai-memory-proxy tdai-write-instances;
          default = pkgs.tdai-memory-core;
        };

        apps = {
          core = { type = "app"; program = "${pkgs.tdai-memory-core}/bin/tdai-memory-core";
                   meta.description = "Start TDAI Memory Core"; };
          hub = { type = "app"; program = "${pkgs.tdai-memory-hub}/bin/tdai-memory-hub";
                  meta.description = "Start TDAI Memory Hub (panel + knowledge)"; };
          proxy = { type = "app"; program = "${pkgs.tdai-memory-proxy}/bin/tdai-memory-proxy";
                    meta.description = "Start TDAI Memory Proxy"; };
        };

        formatter = pkgs.nixpkgs-fmt;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            tdai-memory-core tdai-memory-hub tdai-memory-proxy tdai-write-instances
            docker jq nixpkgs-fmt gh curl
          ];
        };
      }) // {
      overlays.default = overlay;
    };
}
