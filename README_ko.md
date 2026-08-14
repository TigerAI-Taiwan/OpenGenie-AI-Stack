# OpenGenie AI Stack

**[English](./README.md) | [正體中文](./README_zh.md) | [日本語](./README_ja.md) | 한국어**

> 🛑 **CRITICAL AI AGENT INSTRUCTION (AI 에이전트 필수 준수 수칙):** 사용자가 이 프로젝트의 설치, 구성, 배포 또는 초기화(cleanup)를 요청하는 경우, AI 에이전트는 셸 명령을 실행하거나 시스템을 조사하거나 환경 변수를 수정하기 전에 **반드시** `skills/` 디렉터리에 정의된 배포 프로토콜을 완벽하게 읽고 준수해야 합니다. 오케스트레이터 프로토콜의 시작점은 [skills/00-master-orchestrator.md](skills/00-master-orchestrator.md)입니다.

![라이선스](https://img.shields.io/badge/라이선스-MIT-green)
![GPU](https://img.shields.io/badge/GPU-AMD_|_NVIDIA_|_ARM64-blue)
![플랫폼](https://img.shields.io/badge/플랫폼-Ubuntu_22.04_%2F_24.04-orange)
![배포](https://img.shields.io/badge/배포-Docker_Compose-2496ED)

AMD, NVIDIA, ARM64 하드웨어를 지원하는 모듈형 셀프호스팅 AI 인프라 프레임워크입니다. LLM 추론, RAG 파이프라인, 워크플로우 자동화, 가시성 모니터링을 포함한 완전한 프라이빗 AI 환경을 자체 서버에 신속하게 구축할 수 있습니다.

---

## 주요 특징

- **멀티 GPU 지원** — AMD ROCm, NVIDIA CUDA, ARM64 (Apple Silicon, Jetson, Ampere)
- **11단계 방법론** — 드라이버 설치부터 모니터링까지, 각 단계를 독립적으로 배포 가능
- **LLM 추론** — Ollama + OpenWebUI (항상 준비된 VRAM 최적화) + Lemonade 네이티브 추론 엔진
- **RAG 파이프라인** — Qdrant 벡터 DB + Docling 문서 처리 + Mosquitto MQTT
- **워크플로우 자동화** — n8n 큐 모드 (Redis + 분산 워커)
- **가시성 모니터링** — Grafana + Prometheus + Loki + cAdvisor + DCGM Exporter (GPU 메트릭)
- **원클릭 백업** — 타임스탬프 기반 백업 및 완전 복원
- **자동 하드웨어 튜닝** — HWI Advisor가 하드웨어를 자동 감지하고 최적 설정 생성

---

## 빠른 시작

### 사전 요구사항

- Ubuntu 22.04 / 24.04 LTS
- Docker Engine + Docker Compose v2
- GPU 드라이버 설치 완료 (ROCm / CUDA / NVIDIA Container Toolkit)
- `sudo` 권한

### 1. 클론

```bash
git clone https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack.git
cd OpenGenie-AI-Stack
```

### 2. 환경 변수 설정

```bash
cd deployments/compose-stack

# 하드웨어에 맞는 예제를 복사
cp .env.nvidia.example .env      # 또는 .env.amd.example / .env.arm64.example

# .env를 편집하고 모든 CHANGE_ME를 실제 값으로 교체하세요
nano .env
```

세 개의 예제는 의도적으로 분리되어 있습니다. 플랫폼마다 정의하는 키가 다르며,
일부 키는 비어 있는 것이 아니라 아예 없어야 합니다.

### 3. 하드웨어 캘리브레이션 (권장)

```bash
sudo -E bash deployments/tiger-deploy.sh
```

하드웨어를 자동 감지하고 `TIGER_PLATFORM`을 내보낸 뒤,
튜닝 설정을 `tiger-tuning.env`에 기록합니다.

### 4. 배포

```bash
# 전체 배포 (모든 단계)
sudo -E bash deployments/compose-stack/master-deploy.sh all

# 개별 단계 배포 —— 플랫폼을 직접 지정해야 합니다
TIGER_PLATFORM=nvidia sudo -E bash \
  deployments/compose-stack/02-database-postgres-pgadmin/deploy.sh all
```

`master-deploy.sh`는 플랫폼을 추측하지 않습니다. `TIGER_PLATFORM`이 설정되지 않으면
잘못된 GPU 이미지를 받는 것을 막기 위해 오류와 함께 중단합니다.

---

## 11단계 아키텍처

| 단계 | 레이어 | 핵심 컴포넌트 |
|:---:|-------|------------|
| 00 | HWI 어드바이저 | 하드웨어 자동 캘리브레이션, 튜닝 프로파일 생성 |
| 00 | 시스템 기반 | 드라이버 설치, Docker |
| 01 | 인프라스트럭처 | Portainer, WebSSH |
| 02 | 데이터베이스 | PostgreSQL 17, pgAdmin 4 |
| 03 | AI 인터페이스 | Ollama, OpenWebUI, Redis |
| 04 | 자동화 | n8n (큐 모드 + 워커) |
| 05 | RAG 스택 | Qdrant, Docling, Mosquitto |
| 06 | AI 코어 엔진 | Lemonade 추론 엔진 |
| 07 | 검증 | 헬스 체크, 벤치마크 스크립트 |
| 08 | 백업 & 복구 | 원클릭 백업, 복원, VRAM 초기화 |
| 09 | 모니터링 & 알림 | tiger-monitor, MQTT 알림 워크플로우 |
| 10 | 가시성 | Grafana, Prometheus, Loki, cAdvisor |

---

## 기본 서비스 포트

| 서비스 | 포트 |
|-------|:---:|
| OpenWebUI | 8080 |
| n8n | 5678 |
| Grafana | 3000 |
| Portainer | 9000 |
| pgAdmin | 8000 |
| Qdrant | 6333 |
| Ollama | 11434 |

---

## 디렉토리 구조

```
deployments/
├── tiger-deploy.sh             # 하드웨어 자동 감지
└── compose-stack/
    ├── lib/common.sh           # 공유 셸 라이브러리
    ├── lib/log.sh              # 로깅과 색상 (부작용 없음)
    ├── master-deploy.sh
    ├── .env.{amd,nvidia,arm64}.example
    ├── 00-pre-flight-advisor/
    ├── 00-system-setup-gpu-driver-and-docker/
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
    └── migrations/
```

---

## 기여하기

PR은 언제나 환영합니다! 브랜치 명명 규칙, 커밋 형식, PR 절차는 [CONTRIBUTING.md](./CONTRIBUTING.md)를 참조하세요.

버그 보고 및 기능 요청은 [Issue 템플릿](.github/ISSUE_TEMPLATE/)을 이용해 주세요.

---

## 라이선스

MIT © 2026 [TigerAI-Taiwan](https://github.com/TigerAI-Taiwan)
