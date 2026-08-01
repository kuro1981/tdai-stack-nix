# tdai-stack-nix

[TencentDB Agent Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory) のスタックを nix で宣言的に扱うためのパッケージ群。

`llm-agents.nix` と同じく、**1 つの flake が複数のコンポーネントを個別パッケージとして公開**する。3 つをまとめて起動することも、必要なものだけ単独で起動することもできる。

---

## 公開パッケージ

| パッケージ | ポート | 役割 |
| --- | --- | --- |
| `tdai-memory-core` | 8420 | 記憶の読み書き / 認証 / skill・RAG データプレーン |
| `tdai-memory-hub` | 8125 / 8424 | Panel UI + Knowledge Service（**Wiki / CodeGraph**） |
| `tdai-memory-proxy` | 8096 | LLM 中継。memory / skill をリクエストに注入する |
| `tdai-write-instances` | — | `metadata-instances.json` を tmpfs 上に生成するヘルパー |

```bash
nix run github:kuro1981/tdai-stack-nix#core
nix run github:kuro1981/tdai-stack-nix#hub
nix run github:kuro1981/tdai-stack-nix#proxy
```

---

## 設計上の判断

### なぜイメージをタグではなく digest で固定するのか

`1.0.0-beta.1` のようなタグは上流が差し替えられる。digest なら内容が固定される。宣言と実態を一致させるための選択で、`images.json` が正となる。

### なぜ `dockerTools` でイメージを作らないのか

上流が公開しているイメージをそのまま使うため。**nix が担うのは「どのイメージを、どう起動するか」の宣言**であり、コンテナの実行は docker に任せる。

### なぜ proxy も同梱するのか

**パッケージとして持つことと、実際に起動することは別**だから。

proxy を Claude Code に使うと `ANTHROPIC_BASE_URL` を差し替えることになり、Claude Max のサブスクリプション認証ではなく `PROXY_UPSTREAM_*` の API キー課金になる。この判断はパッケージング時点で下す必要がなく、実行時に決めればよい。

なお proxy を**使わない**場合のみ `MEMORY_CORE_GATEWAY_API_KEY` を設定できる。上流に既知の非互換があり（`MemoryProxy/src/auth.ts` が `/v3/meta/auth/verify` に Bearer を付けない）、proxy 併用時は空にせざるを得ないためである。**proxy を捨てることで Core の認証を有効化できる。**

### 秘密を保存しない

`metadata-instances.json` は Gateway の Bearer token を含む。上流も `.gitignore` で除外し「禁止提交」と明記している。

`tdai-write-instances` は、これを **tmpfs（`/dev/shm/tdai`）上に権限 600 で生成**する。ディスクにもバックアップにもスナップショットにも残らない。秘密は BWS（`TDAI_GATEWAY_API_KEY`）から供給する。

---

## 必要な環境変数

秘密は BWS から供給する前提。ここに書かない。

### core

| 変数 | 必須 | 備考 |
| --- | --- | --- |
| `LLM_API_KEY` | ✅ | embed / summarize 用 |
| `LLM_BASE_URL` / `LLM_MODEL` / `LLM_PROTOCOL` | | |
| `GATEWAY_API_KEY` | | Bearer gate。**proxy を使わないなら設定すべき** |
| `MEMORY_CORE_PORT` / `MEMORY_CORE_VOLUME` | | 既定 8420 / `tdai-memory-core-data` |

### hub

| 変数 | 必須 | 備考 |
| --- | --- | --- |
| `TDAI_INSTANCES_FILE` | ✅ | `tdai-write-instances` の出力パス |
| `KNOWLEDGE_PUBLIC_BASE_URL` | ✅ | **`127.0.0.1` / `localhost` は不可**。`/v3` を含むこと |
| `LLM_API_KEY` / `LLM_BASE_URL` | ✅ | `LLM_MODE=custom` のため |
| `LLM_MODE` | | `custom` にすると Tencent Cloud のインスタンス購入が不要になる |
| `PANEL_PORT` / `KNOWLEDGE_PORT` / `PANEL_VOLUME` | | 既定 8125 / 8424 / `tdai-panel-data` |

### proxy

| 変数 | 必須 | 備考 |
| --- | --- | --- |
| `PROXY_CONFIG_FILE` | ✅ | proxy は上流 URL / key を環境変数ではなく YAML から読む |
| `PROXY_PORT` | | 既定 8096 |

---

## 既知の制約

- **`KNOWLEDGE_PUBLIC_BASE_URL` に `127.0.0.1` を使えない。** Agent と Gateway が KS の tools を呼ぶため、外部から到達できるアドレスが要る。したがって KS のポートは外部公開になる。認証の要否は要確認
- `metadata-instances.json` の `api_key` は Core の Bearer token と同じもの
- 上流は `1.0.0-beta.1` の段階。API もディレクトリ構成も変わりうる

---

## 更新

`.github/workflows/update.yml` が毎日 Docker Hub を確認し、新しい digest があれば PR を作成する。手動では以下。

```bash
./scripts/update.sh          # 最新 digest へ更新
./scripts/update.sh --check  # 差分の有無だけ確認（あれば exit 1）
```

---

## License

パッケージングのコードは MIT。上流イメージのライセンスは上流に従う。
