# OpenGenie AI Stack v5.0.1

本版沒有任何 compose 變更（no compose change; aligns with Open-AI-Stack v5.0.1）。
版號與上游 Open-AI-Stack v5.0.1 對齊；上游這一版的 compose 改動全部落在 OpenGenie 沒有搬的部分，所以 OpenGenie 的部署內容與 v5.0.0 完全相同。

## What's Changed

- 沒有 compose 變更：部署腳本、compose 檔、`.env.<platform>.example` 都與 v5.0.0 相同。
- 版號對齊上游 Open-AI-Stack v5.0.1。

## 升級注意

從 v5.0.0 升級：不需要任何動作。
從 v5.0.0 以前的版本升級：照 [v5.0.0 Release Note](../v5.0.0/RELEASE-NOTE.md) 的「升級注意」做即可，本版沒有額外步驟。

## Release Details

上游 v5.0.1 的 compose 改動都在下列範圍，OpenGenie 都沒有對應的模組：

- vLLM 推論後端與其模型管理（OpenGenie 只保留 `ollama` 與 `lemonade`，見 v5.0.0）。
- 上游專屬模組與其 `.env` 設定、image 版本。

`01`、`02`、`03-ai-core/{ollama,lemonade}`、`04`–`10`、`lib/`、`migrations/`、`master-deploy.sh` 都沒有變更。
