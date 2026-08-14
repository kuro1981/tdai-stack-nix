# tdai-stack-nix

[TencentDB Agent Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory) のコンポーネントを **上流ソースから** nix でビルドする。

`llm-agents.nix` と同じく、1 つの flake が複数パッケージを個別に公開する。

---

## パッケージ

| パッケージ | 実行ファイル | 役割 |
| --- | --- | --- |
| `tdai-knowledge` | `knowledge-server` / `knowledge-mcp` | Wiki / CodeGraph。MCP でも公開できる |
| `tdai-panel` | `tdai-panel` | Team / Agent / Task の管理コンソール |

`memory-core` は別リポジトリ [`memory-tencentdb-nix`](https://github.com/kuro1981/memory-tencentdb-nix) にある（npm 公開されているため方式が異なる）。

```bash
nix run github:kuro1981/tdai-stack-nix#knowledge
nix run github:kuro1981/tdai-stack-nix#knowledge-mcp
nix run github:kuro1981/tdai-stack-nix#panel
```

---

## なぜ Docker ではないのか

一度は公開イメージを digest 固定で包む方式で作ったが、**捨てた**。

Docker イメージを nix でラップしても、再現性の実体は Docker Hub 側にある。nix で管理する意味がない。

そしてソースからビルドしたことで、**上流の不具合が 4 つ見つかった**。イメージを使っていれば「動いているように見えるが中身は分からない」まま進んでいた。

---

## 上流の不具合と、その回避

### 1. `bin/*.mjs` の import 先が存在しない（Knowledge）

`import "../dist/server.js"` と書かれているが、`tsdown` の出力は `server.mjs`。`ERR_MODULE_NOT_FOUND` になる。

### 2. 拡張子を直しても起動しない（Knowledge）

`dist/server.mjs` は `import.meta.url` で「直接実行されたか」を判定している。`bin` から import されると起動処理に進まず、telemetry の初期化で止まる。

→ **`bin` は使わず `dist` を直接 `node` に渡すラッパーを自前で作る。**

### 3. Dockerfile が参照するファイルが存在しない（Knowledge）

`ENTRYPOINT` に `docker/entrypoint.sh` を指定しているが、そのディレクトリがリポジトリに無い（404）。**この経路は誰も通っていない**と見られる。

### 4. `dist` が install で除外される（Panel）

上流に `.npmignore` が無く `.gitignore` に `dist/` がある。npm は `.npmignore` が無い場合 `.gitignore` を代用するため、ビルド成果物が落ちる。npm の仕様どおりの挙動で、上流が npm 公開を想定していないために起きる。

→ **`postBuild` で退避し `postInstall` で戻す。**

---

## 上流のロックファイルが使えない

4 パッケージすべて、`locks/` に自前生成したロックを置き `postPatch` で持ち込んでいる。理由はそれぞれ違う。

| パッケージ | 上流のロック | 自前生成する理由 |
| --- | --- | --- |
| `MemoryKnowledge` | 無い | `buildNpmPackage` がロックを要求する |
| `MemoryCore` | 無い | 同上。peer 衝突があり `--legacy-peer-deps` が要る |
| `MemoryPanel` | ある | 229 エントリ全部が `mirrors.tencent.com`。GitHub Actions の runner から取れずタイムアウトする。さらに `package.json` に無い依存（drizzle 系）が残っており内容も古い |
| `MemoryPanel/web` | ある | `mirrors.tencent.com` と `registry.npmjs.org` が混在。peer 衝突で `npm ci` が再解決に入り `ENOTCACHED` になる |

生成はすべて `--registry=https://registry.npmjs.org` で行う（`scripts/update.sh` の `regenerate_one_lock`）。

---

## 設定

### knowledge-server

| 変数 | 備考 |
| --- | --- |
| `PORT` | 既定 8421 |
| `KNOWLEDGE_DATA_DIR` / `KNOWLEDGE_DB_PATH` | SQLite。外部 DB 不要 |
| `KNOWLEDGE_PUBLIC_BASE_URL` | **`127.0.0.1` / `localhost` 不可**。`/v3` を含むこと |
| `LLM_MODE` | `custom` にすると Tencent Cloud のインスタンス購入が不要 |
| `LLM_BASE_URL` / `LLM_API_KEY` / `LLM_MODEL` | `LLM_MODE=custom` 時に必須 |

### tdai-panel

| 変数 | 備考 |
| --- | --- |
| `PORT` | 既定 8125 |
| `TDAI_PANEL_WORKDIR` | **`config/metadata-instances.json` を置いたディレクトリ。** Panel は cwd 基準でこれを探し、環境変数での指定口が無いためラッパーで補っている。既定は `$PWD` |

`metadata-instances.json` は Gateway の Bearer token を含む。上流も `.gitignore` で除外し「禁止提交」としている。**git に置かず、実行時に tmpfs 等へ生成すること。**

---

## ⚠️ Knowledge Service には認証が無い

`MemoryKnowledge/src/middleware/` にあるのは `error-handler.ts` と `response-envelope.ts` だけで、`server.ts` もこの 2 つしか `app.use` していない。

無認証で以下が呼べる。

```
POST /v3/tools/call
    search / list_pages / read_page / get_graph / list_raw / read_raw
```

**`read_raw` と `get_graph` により、到達できる者は誰でもコードベースの中身と構造を読める。**

上流が `127.0.0.1` を禁じるのは「呼び出し元から到達できること」の意味であり、**インターネット公開ではない**。Docker ネットワーク内の名前や Tailnet に限定すること。`0.0.0.0` で公開してはならない。

---

## 更新

`.github/workflows/update.yml` が毎日、追跡ブランチ（既定 `feat/server_team`）の HEAD を確認して PR を作る。

```bash
./scripts/update.sh          # 最新 rev へ追随
./scripts/update.sh --check  # 差分の有無だけ（あれば exit 1）
./scripts/update.sh --rev <sha>
```

更新するものが 4 つあり、**順序に依存関係がある**。

1. `upstreamRev`
2. `upstreamHash`
3. `locks/*.json` × 4（再生成）
4. `npmDepsHash` × 4（3 から決まる。ダミーでビルドを失敗させ `got:` を拾う）

`tdai-panel-web` は `tdai-panel` より先に解決すること。panel のラッパーが panel-web の store path を埋め込むため。

---

## License

パッケージングのコードは MIT。上流のライセンスは上流に従う。
