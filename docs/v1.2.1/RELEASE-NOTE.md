# OpenGenie AI Stack v1.2.1

本版是針對 NVIDIA 與 ARM64 Lemonade deployer 的小型修正版，讓 AMD GPU guard 與既定部署規格一致，避免非 AMD 環境錯誤進入 AMD 專用流程。

## What's Changed

- 修正 NVIDIA／ARM64 `detect_amd_gpu` guard block。
- 對齊兩種平台的函式結構、註解與 skip log。
- [PR #11：update detect_amd_gpu guard block](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/11)

**Full Changelog**: [v1.2.0...v1.2.1](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.2.0...v1.2.1)

## Release Details

### 問題

Lemonade 是 AMD GPU 專用元件，但 NVIDIA 與 ARM64 stack 仍保留 deployer 作為跨平台同步的一部分。guard block 的結構與 canonical spec 不一致時，可能在缺少 AMD 工具或沒有 AMD GPU 的環境產生錯誤判斷或不清楚的 log。

### 修正

- 更新 `detect_amd_gpu` 的 guard 結構，只在偵測條件可用時判斷 AMD GPU。
- 沒有 AMD GPU 時明確記錄 skip 原因並正常返回。
- NVIDIA 與 ARM64 版本採用一致的函式結構與訊息，降低後續同步時再次分歧的風險。

## 影響範圍

- 僅修改 NVIDIA 與 ARM64 的 `06-ai-core-lemonade/deploy.sh`。
- AMD compose stack 未修改。
- 沒有資料格式、environment variable 或 migration 變更。

## 驗證重點

- NVIDIA 與 ARM64 主機執行 Lemonade deployer 時應顯示 skip 訊息並以成功狀態返回。
- guard 不應要求系統安裝 AMD ROCm 工具。
