# OpenGenie AI Stack v1.0.0

本版以 PR #8 作為 OpenGenie AI Stack 的第一個正式版本基準，聚焦多 GPU 硬體判斷、跨平台 Lemonade 部署規則，以及部署失敗後的復原與清除指引。

## What's Changed

- NVIDIA hardware advisor 改為加總所有 GPU 的 VRAM。
- NVIDIA 與 ARM64 部署自動略過 AMD ROCm 專用的 Lemonade module。
- 更新 port conflict、錯誤復原與完整清除流程。
- [PR #8：更新 skills、多顯卡判斷](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/8)

**Full Changelog**: [PR #7...v1.0.0](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/ecec8a99a3fe879bdc84274f5fa2afda2967e187...v1.0.0)

## Release Details

### 多 GPU VRAM 判斷

NVIDIA advisor 原本以 `nvidia-smi ... | head -n 1` 只讀取第一張 GPU 的 VRAM。多 GPU 主機因此會低估可用顯示記憶體，並可能選到過度保守的 tuning profile；在啟用 `pipefail` 時，`head` 提前關閉 pipe 也可能讓上游 `nvidia-smi` 產生 SIGPIPE。

本版改用 `awk` 讀完所有輸出並加總每張 GPU 的 `memory.total`，同時解決容量低估與 pipe 提前中止問題。此變更只影響 NVIDIA advisor；單 GPU 主機結果不變。

### Lemonade 平台限制

Lemonade module 是 AMD ROCm 環境專用元件。NVIDIA 與 ARM64 的 `master-deploy.sh` 現在會辨識 `06-ai-core-lemonade` 並直接略過，避免在不支援的平台嘗試安裝或要求無用的 `LEMONADE_API_KEY`。

### 部署與復原文件

- deployment state machine 補充 Lemonade 的平台規則。
- error recovery guide 加入 port conflict 判斷，要求先辨識現有服務並由操作者決定保留、停用或更換 port。
- full purge procedure 精簡重複步驟，補齊 Lemonade Snap package 與 stack virtual environment 清理。

## 驗證重點

- 多 GPU NVIDIA 主機應確認 advisor 顯示的 VRAM 為所有 GPU 容量總和。
- NVIDIA／ARM64 執行完整部署時，log 應顯示略過 Lemonade，且流程繼續執行。
- AMD 部署仍應保留 Lemonade module，不受 skip rule 影響。

## 已知限制

- VRAM 總和適合目前的整機 tuning profile，但不代表單一模型一定能跨 GPU 無限制使用全部記憶體；實際能力仍取決於推論框架的 multi-GPU 支援。
