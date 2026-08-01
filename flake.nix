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
      upstreamRev = "f3df79326dfd763f45199c441e2129d780467949";
      upstreamHash = "sha256-8cXi3K4FJGCb12Er1iDMnwlYamyKPIHBtJtYtpz+zfQ=";

      overlay = final: prev: {
        # ── Knowledge Service ────────────────────────────────────────────
        # Wiki / CodeGraph。SQLite だけで動き外部 DB は不要。
        # knowledge-server（HTTP）と knowledge-mcp（MCP）を公開する。
        # ── Panel ────────────────────────────────────────────────────────
        # Team / Agent / Task と Knowledge 資産の管理コンソール。
        # 上流に package-lock.json があるためそのまま使える（Knowledge と違う点）。
        tdai-panel = final.callPackage ./panel.nix {
          inherit upstreamRev upstreamHash;
          npmDepsHash = "sha256-0xsK4XzIdFHSCiexmfJXIrZV/d3rHOIMyI39pMqQWGo=";
          nodejs = final.nodejs_22;
        };

        tdai-knowledge = final.callPackage ./knowledge.nix {
          inherit upstreamRev upstreamHash;
          # nix build が失敗したときに表示される値へ差し替える
          npmDepsHash = "sha256-KasBxq1d2o00mmdAjWhqpViLZmW5yUernpOI8mH2f3s=";
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
          inherit (pkgs) tdai-knowledge tdai-panel;
          default = pkgs.tdai-knowledge;
        };

        apps = {
          knowledge = {
            type = "app";
            program = "${pkgs.tdai-knowledge}/bin/knowledge-server";
            meta.description = "Start the TDAI Knowledge Service (wiki / code-graph)";
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
          packages = with pkgs; [ tdai-knowledge tdai-panel nodejs_22 jq nixpkgs-fmt gh curl ];
        };
      }) // {
      overlays.default = overlay;
    };
}
