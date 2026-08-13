# OpenGenie AI Stack

**[English](./README.md) | [正體中文](./README_zh.md) | 日本語 | [한국어](./README_ko.md)**

> 🛑 **CRITICAL AI AGENT INSTRUCTION (AI 代理人必須遵守規範):** ユーザーが本プロジェクトのインストール、設定、デプロイ、またはクリーンアップを要求した場合、AI 代理人はシェルコマンドの実行、システム調査、環境変数の変更を行う前に、**必ず** `skills/` ディレクトリで定義されているデプロイプロトコルを完全に読み、それに従わなければなりません。オーケストレータープロトコルの開始点は [skills/00-master-orchestrator.md](skills/00-master-orchestrator.md) です。

![ライセンス](https://img.shields.io/badge/ライセンス-MIT-green)
![GPU](https://img.shields.io/badge/GPU-AMD_|_NVIDIA_|_ARM64-blue)
![プラットフォーム](https://img.shields.io/badge/プラットフォーム-Ubuntu_22.04_%2F_24.04-orange)
![デプロイ](https://img.shields.io/badge/デプロイ-Docker_Compose-2496ED)

AMD・NVIDIA・ARM64 ハードウェアに対応した、モジュール型のセルフホスト AI インフラフレームワークです。LLM 推論・RAG パイプライン・ワークフロー自動化・可観測性監視を含む完全なプライベート AI 環境を、自社サーバー上に短時間で構築できます。

---

## 主な特徴

- **マルチ GPU 対応** — AMD ROCm・NVIDIA CUDA・ARM64（Apple Silicon、Jetson、Ampere）
- **12 フェーズ方法論** — ドライバーセットアップから監視まで、フェーズごとに独立してデプロイ可能
- **LLM 推論** — Ollama + OpenWebUI（常時 VRAM 常駐最適化）+ Lemonade ネイティブ推論エンジン
- **RAG パイプライン** — Qdrant ベクター DB + Docling ドキュメント解析 + Mosquitto MQTT
- **ワークフロー自動化** — n8n キューモード（Redis + 分散ワーカー）
- **可観測性** — Grafana + Prometheus + Loki + cAdvisor + DCGM Exporter（GPU メトリクス）
- **ワンクリックバックアップ** — タイムスタンプ付きバックアップと完全リストア
- **自動ハードウェアチューニング** — HWI Advisor がハードウェアを自動検出し、最適設定を生成

---

## クイックスタート

### 前提条件

- Ubuntu 22.04 / 24.04 LTS
- Docker Engine + Docker Compose v2
- GPU ドライバーのインストール済み（ROCm / CUDA / NVIDIA Container Toolkit）
- `sudo` 権限

### 1. クローン

```bash
git clone https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack.git
cd OpenGenie-AI-Stack
```

### 2. スタックの選択

| ハードウェア | ディレクトリ |
|------------|------------|
| NVIDIA GPU | `deployments/nvidia-compose-stack/` |
| AMD ROCm GPU | `deployments/amd-compose-stack/` |
| ARM64（Apple Silicon / Jetson / Ampere） | `deployments/arm64-compose-stack/` |

```bash
cd deployments/amd-compose-stack   # または nvidia / arm64
```

### 3. 環境変数の設定

```bash
cp .env.example .env
# .env を編集し、CHANGE_ME をすべて実際の値に置き換えてください
nano .env
```

### 4. ハードウェアキャリブレーション（推奨）

```bash
sudo bash master-deploy.sh init
```

CPU/GPU スペックを自動検出し、最適化チューニング設定を `tiger-tuning.env` に書き込みます。

### 5. デプロイ

```bash
# 全フェーズ一括デプロイ
sudo bash master-deploy.sh all

# または個別フェーズをデプロイ
sudo bash 02-database-postgres-pgadmin/deploy.sh
sudo bash 03-ai-interface-ollama-openwebui-redis/deploy.sh
```

### 6. 動作確認

```bash
sudo bash master-deploy.sh test
```

---

## 12 フェーズアーキテクチャ

| フェーズ | レイヤー | コアコンポーネント |
|:-------:|---------|-----------------|
| 00 | HWI アドバイザー | ハードウェア自動キャリブレーション、チューニングプロファイル生成 |
| 00 | システム基盤 | ドライバーセットアップ、Docker |
| 01 | インフラストラクチャ | Portainer、WebSSH |
| 02 | データベース | PostgreSQL 17、pgAdmin 4 |
| 03 | AI インターフェース | Ollama、OpenWebUI、Redis |
| 04 | 自動化 | n8n（キューモード + ワーカー） |
| 05 | RAG スタック | Qdrant、Docling、Mosquitto |
| 06 | AI コアエンジン | Lemonade 推論エンジン |
| 07 | バリデーション | ヘルスチェック、ベンチマークスクリプト |
| 08 | バックアップ & リカバリー | ワンクリックバックアップ、リストア、VRAM パージ |
| 09 | 監視 & アラート | tiger-monitor、MQTT アラートワークフロー |
| 10 | 可観測性 | Grafana、Prometheus、Loki、cAdvisor |

---

## デフォルトサービスポート

| サービス | ポート |
|---------|:-----:|
| OpenWebUI | 8080 |
| n8n | 5678 |
| Grafana | 3000 |
| Portainer | 9000 |
| pgAdmin | 8000 |
| Qdrant | 6333 |
| Ollama | 11434 |

---

## ディレクトリ構成

```
deployments/
├── amd-compose-stack/          # AMD ROCm スタック
├── nvidia-compose-stack/       # NVIDIA CUDA スタック
└── arm64-compose-stack/        # ARM64 スタック
    ├── 00-pre-flight-advisor/
    ├── 01-infra-webssh-portainer/
    ├── 02-database-postgres-pgadmin/
    ├── 03-ai-interface-ollama-openwebui-redis/
    ├── 04-automation-n8n/
    ├── 05-rag-stack-docling-qdrant-mosquitto/
    ├── 06-ai-core-lemonade/
    ├── 07-validation-stack/
    ├── 08-backup-recovery/
    ├── 09-monitoring-alerting/
    ├── 10-observability-grafana/
    ├── master-deploy.sh
    └── .env.example
```

---

## コントリビューション

PR は大歓迎です！ブランチ命名規則・コミットフォーマット・PR の手順については [CONTRIBUTING.md](./CONTRIBUTING.md) をご覧ください。

バグ報告や機能リクエストは [Issue テンプレート](.github/ISSUE_TEMPLATE/) をご利用ください。

---

## ライセンス

MIT © 2026 [TigerAI-Taiwan](https://github.com/TigerAI-Taiwan)
