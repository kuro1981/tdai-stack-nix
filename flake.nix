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
      upstreamRev = "b545fe9acf08b47b56d85872eb04b6aee24c85eb";
      upstreamHash = "sha256-uletu58mmKc8Ury79TnBOKrnfFCx1pTC+QTb9vQ9f18=";

      overlay = final: prev: {
        # ── Knowledge Service ────────────────────────────────────────────
        # Wiki / CodeGraph。SQLite だけで動き外部 DB は不要。
        # knowledge-server（HTTP）と knowledge-mcp（MCP）を公開する。
        # ── Memory Core (v2) ─────────────────────────────────────────────
        # metadata 層（user / team / agent / task / skill）を含む。
        # npm 公開版 1.x には metadata/ が無く Panel も Skill API も使えない。
        tdai-core = final.callPackage ./core.nix {
          inherit upstreamRev upstreamHash;
          npmDepsHash = "sha256-/Xo6Lc3d87vdDujiJQZxMKjzfqe/hT2p4A2bw7Xbi3I=";
          lockFile = ./locks/core-package-lock.json;
          nodejs = final.nodejs_22;
        };

        # ── Panel ────────────────────────────────────────────────────────
        # Team / Agent / Task と Knowledge 資産の管理コンソール。
        # Panel の UI。web/ は独立した package-lock.json を持つため
        # 別 derivation にする（panel-web.nix の冒頭を参照）。
        tdai-panel-web = final.callPackage ./panel-web.nix {
          inherit upstreamRev upstreamHash;
          npmDepsHash = "sha256-iUs7npKmJyxzWOhdV49kg0JPxHhV0SWbu28DBAoZgE0=";
          lockFile = ./locks/panel-web-package-lock.json;
        };

        tdai-panel = final.callPackage ./panel.nix {
          inherit upstreamRev upstreamHash;
          inherit (final) tdai-panel-web;
          npmDepsHash = "sha256-yYAnsOgE8rG+EUBA32EzCC+47rgUEFLUQYrx+S6Gj3Q=";
          lockFile = ./locks/panel-package-lock.json;
          nodejs = final.nodejs_22;
        };

        tdai-knowledge = final.callPackage ./knowledge.nix {
          inherit upstreamRev upstreamHash;
          # nix build が失敗したときに表示される値へ差し替える
          npmDepsHash = "sha256-hNCn81KI5RfykZUM2Z75j/dIgsIdQNy96ohMBY2wF04=";
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
