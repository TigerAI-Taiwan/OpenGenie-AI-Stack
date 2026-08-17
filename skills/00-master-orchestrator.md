# OpenGenie AI Deployment: Master Orchestrator

## 0. Bootstrap Rule — Read All Skills First (MANDATORY)

> 🛑 **STOP. Before doing ANYTHING — before reading `.agent-state.json`, before running ANY command, before responding to ANY wake-up phrase — you MUST read every file in the `skills/` directory in full.**

This is the first and only acceptable action on any new invocation. The required sequence:

```bash
ls skills/
```

Then read each file completely (no skimming, no partial reads):
- `skills/00-master-orchestrator.md` (this file)
- `skills/01-deployment-state-machine.md`
- `skills/02-error-recovery-guide.md`
- `skills/03-gpu-robustness.md`
- `skills/04-full-purge-procedure.md`
- …and any other `*.md` present in `skills/` that may have been added.

**Only after all skills are loaded into your context may you:**
1. Read `.agent-state.json`
2. Probe hardware
3. Execute any deployment step
4. Modify state

**Rationale:** Skipping skills causes the agent to ask redundant questions, miss the state-machine routing, or run commands out of order. The user has explicitly required this bootstrap — failure to follow it is a protocol violation.

---

## 1. System Overview
You are the **Master Orchestrator Agent** for the OpenGenie AI Stack deployment. Your goal is to achieve a 100% autonomous, production-grade installation on any Ubuntu server.
You will coordinate between multiple sub-skills (modules) to complete this task.

**CRITICAL DIRECTIVE:** You must NEVER execute installation commands blindly. You MUST act as a State Machine, read and write your state to disk, and route your actions through the designated sub-skills.

**ABSOLUTE PROHIBITION:** You must **NEVER modify any project file**. This includes any `.sh` script, `docker-compose.yaml`, `.env.example`, or documentation file. If a script behaves unexpectedly, run existing scripts directly or report to the user. Do not edit or rewrite project files to work around issues.

> **Exception:** Files under `skills/` are agent-protocol docs, not deployment artifacts. The user may explicitly instruct you to edit them (e.g. to add a new rule). Treat such edits as a separate, explicit authorization — never edit `skills/*.md` on your own initiative.

---

## 2. Global State Persistence (`.agent-state.json`)
Before probing hardware or running commands, check for the existence of your memory file: `.agent-state.json` (located in the project root directory).
This file persists your state across unexpected disconnects or forced reboots.

### 2.0 Locate the project root FIRST (mandatory)

Skills are invoked from different working directories — sometimes the project root, sometimes `deployments/<stack>/`, sometimes a sub-module. Never rely on relative paths like `./.agent-state.json` or `../../.agent-state.json` — they break the moment the agent's cwd shifts. Always resolve the project root once and reference everything through `$PROJECT_ROOT`:

```bash
# Walk up from the current directory until we find the project root,
# identified by the presence of the skills/ directory.
PROJECT_ROOT="$(pwd)"
while [ ! -d "$PROJECT_ROOT/skills" ] && [ "$PROJECT_ROOT" != "/" ]; do
  PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done
if [ ! -d "$PROJECT_ROOT/skills" ]; then
  echo "ERROR: cannot find project root (no skills/ directory in any parent)"
  exit 1
fi
export PROJECT_ROOT
echo "PROJECT_ROOT=$PROJECT_ROOT"
```

> 🧭 **Rule for every state read/write throughout these skills:** use `"$PROJECT_ROOT/.agent-state.json"`, never `./.agent-state.json` or `../../.agent-state.json`.

### 2.1 Reading state (with validation)

Never assume `.agent-state.json` is well-formed. Always validate before trusting it. The validator below requires `jq` (install with `sudo apt-get install -y jq` if missing — `jq` is a hard dependency for these skills).

```bash
STATE_FILE="$PROJECT_ROOT/.agent-state.json"
BAK_FILE="$PROJECT_ROOT/.agent-state.bak.json"

read_state() {
  # No file → caller is in PRISTINE state
  if [ ! -f "$STATE_FILE" ]; then
    echo "NO_STATE_FILE"
    return 0
  fi

  # Validate: must be parseable JSON AND have the three required string fields
  if ! jq -e 'type == "object" and (.state | type == "string") and (.gpu | type == "string") and (.stack | type == "string")' \
       "$STATE_FILE" >/dev/null 2>&1; then
    echo "⚠️ STATE CORRUPTED: $STATE_FILE failed schema validation" >&2

    # Auto-rollback to backup if backup is itself valid
    if [ -f "$BAK_FILE" ] && jq -e 'type == "object" and (.state | type == "string") and (.gpu | type == "string") and (.stack | type == "string")' \
         "$BAK_FILE" >/dev/null 2>&1; then
      echo "↩️ Restoring last good state from $BAK_FILE" >&2
      cp "$BAK_FILE" "$STATE_FILE"
    else
      # No usable backup — surface to user, do NOT auto-wipe
      echo "❌ No valid backup at $BAK_FILE — STOP. Show the file contents to the user and ask them to either:" >&2
      echo "   1. Manually fix $STATE_FILE (it must be valid JSON with string fields: state, gpu, stack), or" >&2
      echo "   2. Run the full purge procedure (see 04-full-purge-procedure.md) to start over." >&2
      cat "$STATE_FILE" >&2
      return 1
    fi
  fi

  jq -r '.state' "$STATE_FILE"
}
```

### 2.2 Writing state (atomic, with backup)

Every state transition MUST go through this pattern — never write `.agent-state.json` directly. Backup-then-atomic-rename guarantees that a crashed write leaves either the old state or the new state, never a half-written file.

```bash
# Usage: write_state '{"state": "INSTALLING_SYSTEM", "gpu": "NVIDIA", "platform": "nvidia"}'
write_state() {
  local new_json="$1"

  # Validate the new payload BEFORE touching disk
  if ! echo "$new_json" | jq -e 'type == "object" and (.state | type == "string") and (.gpu | type == "string") and (.stack | type == "string")' >/dev/null 2>&1; then
    echo "❌ write_state refused: payload failed schema validation: $new_json" >&2
    return 1
  fi

  # Backup the current state file (if it exists and is valid) before overwriting
  if [ -f "$STATE_FILE" ] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    cp "$STATE_FILE" "$BAK_FILE"
  fi

  # Atomic write: tmp + rename
  echo "$new_json" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}
```

- **If the file exists:** Call `read_state` (validates + auto-recovers from backup if corrupted). Understand exactly where you left off.
- **If the file does not exist:** You are in `STATE 0 (Pristine)`. Create it via `write_state` so the validation path runs and `.agent-state.bak.json` is seeded correctly:
  ```bash
  write_state '{"state": "PRISTINE", "gpu": "UNKNOWN", "stack": "UNKNOWN"}'
  ```

---

## 3. Strict Execution Loop (One Decision Per Invocation)

When invoked, you MUST strictly follow this deterministic pattern. **Never execute multiple state steps at once.**

```
READ .agent-state.json → DECIDE one action → EXECUTE → UPDATE state atomically → STOP
```

### Step 1: Read State (Single Source of Truth)
```bash
# read_state validates the file and auto-recovers from .agent-state.bak.json
# if corrupted. See §2.1 for the function definition.
CURRENT_STATE="$(read_state)"
echo "CURRENT_STATE=$CURRENT_STATE"
```
Never proceed without a valid state. If `$PROJECT_ROOT` is not yet set, run the locator block in §2.0 first; if the `read_state` / `write_state` functions are not yet defined in this shell, source the definitions from §2.1 and §2.2 first.

### Step 2: Decide & Execute ONE Step
Based on `state` and `gpu` in the JSON:

- **If `gpu: "UNKNOWN"`:**
  → Read and execute **`03-gpu-robustness.md`**.
  → Detect GPU type and set `$STACK_DIR`.
  → Update state:
  ```bash
  write_state '{"state": "HARDWARE_DETECTED", "gpu": "<DETECTED_GPU>", "stack": "<STACK_DIR>"}'
  ```
  → **STOP.**

- **If `gpu` is known and deployment is in progress:**
  → Read and execute **`01-deployment-state-machine.md`**.
  → Execute **only** the action for your current exact state.
  → Update state atomically as instructed.
  → **STOP.**

### Step 2.5: Mandatory Pre-flight Diagnostic Output & Zero-Excuse Communication Protocol
Whenever prompting the user for action (such as configuring `.env` in `STATE 0` or confirming reboot in `STATE 1`), the agent **MUST** include a Pre-flight Diagnostic Report in its response containing:
1. **Hardware & GPU Probe Results** (Platform, GPU vendor, driver status)
2. **Host Port Scan Table** (Status of 8080, 9000, 8000, 5432, 5678, 6333, 11434, 3000, 5001, 443)
3. **Registry / Image Fallback Status** (Confirmation of Docker Hub fallback for `OWUI_IMAGE` to prevent GHCR rate limiting)

> 🚨 **ABSOLUTE PROHIBITION ON EXCUSES & SILENT SKIPPING:**
> If background automated execution tools cannot run `sudo lsof` or `ss` directly (e.g. due to UI permission locks or non-interactive shell limits), the agent **MUST NOT** make excuses, silently skip informing the user, or assume port availability.
> Instead, the agent MUST:
> - Inspect non-intrusive sources (such as `/proc/net/tcp` and `/proc/net/tcp6`) to perform real-time port auditing.
> - Proactively print the exact `sudo lsof -i :8080 -i :9000 ...` command to the user, explaining why user execution is needed, and request the user to run it or verify.


---

## 4. User Wake-Up Word Reference

The deployment requires a manual reboot. After rebooting, the user must wake the agent by starting a **new conversation**.
The agent skills define the exact wake-up phrase to tell the user. For reference:

| After... | The user should say... |
|---|---|
| First reboot after `system` | `"resume deployment"` |
| Unexpected session drop | `"resume deployment"` |
| Deployment is running and user wants health check | `"check deployment health"` |
| User wants a full clean reinstall | `"full purge and reinstall"` |
| After purge + reboot (starting over from zero) | `"start fresh installation"` |

When you receive **"resume deployment"** or **"start fresh installation"** (or any other wake-up phrase in the table above), your first action is **always Section 0 — read every file in `skills/`**. Only after all skills are loaded do you proceed to `cat .agent-state.json` (or create it if it does not exist).

---

## 5. Running Commands — Terminal Access via Antigravity

> **You do NOT need to open a separate terminal app.**
> Antigravity (the AI coding assistant powering this deployment) has a **built-in terminal** you can use to run all installation commands directly.

### How to open the Antigravity terminal:

1. In the **Antigravity** chat panel, look for the **Terminal** tab or icon (usually in the bottom panel of the IDE / assistant window).
2. Click it to open an interactive shell session with full `sudo` support.
3. Run any command provided by the agent directly there — no need to copy-paste into a separate app.

### Why this matters:
- Commands that require `sudo` (like driver installation) need an **interactive terminal** to accept your password.
- Antigravity's built-in terminal provides this — the AI agent's "run command" tool cannot prompt for passwords.
- This is the **recommended way** to execute all Phase 0 and Phase 1 installation steps.

### Quick reference:
| Situation | Action |
|---|---|
| Need to run `sudo bash deploy.sh` | Open Antigravity terminal → paste command |
| Need to enter sudo password | Antigravity terminal handles it interactively |
| Want the agent to monitor output | Paste results back into the chat |

---

## 6. Sub-Skill Index

| File | Purpose |
|---|---|
| `01-deployment-state-machine.md` | Core deployment flow: system → reboot → init → app |
| `02-error-recovery-guide.md` | Self-healing strategies for APT, Docker, driver, and port errors |
| `03-gpu-robustness.md` | Multi-layer hardware detection for NVIDIA / AMD / CPU-only / ARM |
| `04-full-purge-procedure.md` | Complete stack + Docker wipe for clean reinstall cycles |
