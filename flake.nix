{
  description = "Nix packaging for TencentDB Agent Memory components, built from source";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # 上流のリビジョン。locks/ のロックファイルはこの rev の package.json に
      # 対応する。両方を同時に更新すること（scripts/update.sh が行う）。
      upstreamRev = "bd88cc83870bf9e7dbd2ec36aa13608d2295c7f4";
      upstreamHash = "sha256-3nB53QlfVM0WRUk6G/RsvmxxRE0PJMK1QnF7tA8Ic70=";

      overlay = final: prev: {
        # ── Knowledge Service ────────────────────────────────────────────
        # Wiki / CodeGraph。SQLite だけで動き外部 DB は不要。
        # knowledge-server（HTTP）と knowledge-mcp（MCP）を公開する。
        # ── Memory Core (v2) ─────────────────────────────────────────────
        # metadata 層（user / team / agent / task / skill）を含む。
        # npm 公開版 1.x には metadata/ が無く Panel も Skill API も使えない。
        tdai-core = final.callPackage ./core.nix {
          inherit upstreamRev upstreamHash;
          npmDepsHash = "sha256-I9qN7vWUH4fdzU8dqS7D7duIVbTtPCmwRTSiRjgJCE4=";
          lockFile = ./locks/core-package-lock.json;
          nodejs = final.nodejs_22;
        };

        # ── Panel ────────────────────────────────────────────────────────
        # Team / Agent / Task と Knowledge 資産の管理コンソール。
        # Panel の UI。web/ は独立した package-lock.json を持つため
        # 別 derivation にする（panel-web.nix の冒頭を参照）。
        tdai-panel-web = final.callPackage ./panel-web.nix {
          inherit upstreamRev upstreamHash;
          npmDepsHash = "sha256-imjpnk67CFqDrdUB2teW4Sqjk9aDeSBQ7faEpO6GNm0=";
          lockFile = ./locks/panel-web-package-lock.json;
        };

        tdai-panel = final.callPackage ./panel.nix {
          inherit upstreamRev upstreamHash;
          inherit (final) tdai-panel-web;
          npmDepsHash = "sha256-L6px5DJ1ROEEefmLjBBkj6Hf2+DzRyREOc8GprshXmc=";
          lockFile = ./locks/panel-package-lock.json;
          nodejs = final.nodejs_22;
        };

        tdai-knowledge = final.callPackage ./knowledge.nix {
          inherit upstreamRev upstreamHash;
          # nix build が失敗したときに表示される値へ差し替える
          npmDepsHash = "sha256-IqvrmBE/MrKQUpJ7e4yn6MM6zOwKKA6BBGcIW9fGjCI=";
          lockFile = ./locks/knowledge-package-lock.json;
          nodejs = final.nodejs_22;
        };
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
      in
      {
        packages = {
          inherit (pkgs) tdai-core tdai-knowledge tdai-panel tdai-panel-web;
          default = pkgs.tdai-knowledge;
        };

        apps = {
          knowledge = {
            type = "app";
            program = "${pkgs.tdai-knowledge}/bin/knowledge-server";
            meta.description = "Start the TDAI Knowledge Service (wiki / code-graph)";
          };
          core = {
            type = "app";
            program = "${pkgs.tdai-core}/bin/tdai-core-gateway";
            meta.description = "Start the TDAI Memory Core v2 gateway";
          };
          panel = {
            type = "app";
            program = "${pkgs.tdai-panel}/bin/tdai-panel";
            meta.description = "Start the TDAI Memory Panel";
          };
          knowledge-mcp = {
            type = "app";
            program = "${pkgs.tdai-knowledge}/bin/knowledge-mcp";
            meta.description = "Start the TDAI Knowledge MCP server";
          };
        };

        formatter = pkgs.nixpkgs-fmt;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ tdai-core tdai-knowledge tdai-panel nodejs_22 jq nixpkgs-fmt gh curl ];
        };
      }) // {
      overlays.default = overlay;
    };
}
