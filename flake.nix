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
      upstreamRev = "9059e52d11b7e66c2a3b5eb6161e4b4b8603c8c2";
      upstreamHash = "sha256-8VW67lzPDYrZ3YgWqFGZ4qyQA5t2PwytdalkfciBUu8=";

      overlay = final: prev: {
        # ── Knowledge Service ────────────────────────────────────────────
        # Wiki / CodeGraph。SQLite だけで動き外部 DB は不要。
        # knowledge-server（HTTP）と knowledge-mcp（MCP）を公開する。
        # ── Memory Core (v2) ─────────────────────────────────────────────
        # metadata 層（user / team / agent / task / skill）を含む。
        # npm 公開版 1.x には metadata/ が無く Panel も Skill API も使えない。
        tdai-core = final.callPackage ./core.nix {
          inherit upstreamRev upstreamHash;
          npmDepsHash = "sha256-9/b0XmaLcgfVcl7nL+UxDfGgb7pSljmvowVoGVMwPNY=";
          lockFile = ./locks/core-package-lock.json;
          nodejs = final.nodejs_22;
        };

        # ── Panel ────────────────────────────────────────────────────────
        # Team / Agent / Task と Knowledge 資産の管理コンソール。
        # Panel の UI。web/ は独立した package-lock.json を持つため
        # 別 derivation にする（panel-web.nix の冒頭を参照）。
        tdai-panel-web = final.callPackage ./panel-web.nix {
          inherit upstreamRev upstreamHash;
          npmDepsHash = "sha256-n+XtOzim5/cbWFMFk7siVFjST73QGJmXWBPsm1ALr/Q=";
          lockFile = ./locks/panel-web-package-lock.json;
        };

        tdai-panel = final.callPackage ./panel.nix {
          inherit upstreamRev upstreamHash;
          inherit (final) tdai-panel-web;
          npmDepsHash = "sha256-wZMZIxeXYHTu21WCj/8ZX7ACvp8O/SBhM22HDjf2Cjk=";
          lockFile = ./locks/panel-package-lock.json;
          nodejs = final.nodejs_22;
        };

        tdai-knowledge = final.callPackage ./knowledge.nix {
          inherit upstreamRev upstreamHash;
          # nix build が失敗したときに表示される値へ差し替える
          npmDepsHash = "sha256-PSsqQ/iIUe7eJDhHvF0tR1/w4GcIKuFJiq/A0qF1w5Y=";
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
