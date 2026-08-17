# Contributing to OpenGenie-AI-Stack

Thank you for your interest in contributing! Please follow the guidelines below.

---

## Getting Started

1. **Fork** this repository
2. **Clone** your fork locally
3. Create a new branch from `main`:
   ```bash
   git checkout -b feat/your-feature-name
   ```

---

## Branch Naming

| Type | Pattern | Example |
|------|---------|---------|
| Feature | `feat/<name>` | `feat/arm64-ollama` |
| Bug fix | `fix/<name>` | `fix/n8n-migration-race` |
| Hotfix | `hotfix/<name>` | `hotfix/lemonade-version` |
| Docs | `docs/<name>` | `docs/amd-setup` |

---

## Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short description>

[optional body]
```

**Types:** `feat`, `fix`, `chore`, `docs`, `refactor`, `test`

**Scopes:** `amd`, `nvidia`, `arm64`, `n8n`, `openwebui`, `lemonade`, `apisix`, `observability`

Examples:
```
feat(amd): add ROCm 6.2 support
fix(n8n): serialize worker deployment to avoid migration race
chore: remove obsolete config audit reports
```

---

## Submitting a Pull Request

1. Make sure your branch is up to date with `main`
2. Test your changes on the relevant stack (AMD / NVIDIA / ARM64)
3. Push your branch and open a PR against `main`
4. Fill in the PR template — include what changed and how to test it
5. A maintainer will review within a few business days

---

## Stack Testing

Before submitting, verify your changes on each platform you can reach. There
is one stack; the platform is selected by `TIGER_PLATFORM`:

```bash
TIGER_PLATFORM=amd    sudo -E bash deployments/compose-stack/master-deploy.sh all
TIGER_PLATFORM=nvidia sudo -E bash deployments/compose-stack/master-deploy.sh all
TIGER_PLATFORM=arm64  sudo -E bash deployments/compose-stack/master-deploy.sh all
```

If you cannot test on real hardware, at minimum confirm the compose files
still expand for all three platforms:

```bash
cd deployments/compose-stack/<module>
for p in amd nvidia arm64; do
  docker compose -f docker-compose.base.yaml \
    $([ -f docker-compose.$p.yaml ] && echo -f docker-compose.$p.yaml) \
    --env-file ../.env.$p.example config >/dev/null && echo "$p OK"
done
```

---

## Reporting Issues

Use the [issue templates](.github/ISSUE_TEMPLATE/) to report bugs or request features.
