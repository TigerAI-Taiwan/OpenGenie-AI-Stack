# OpenGenie AI Deployment: GPU & Hardware Robustness

A common failure point for Autonomous Agents is incorrectly identifying the hardware environment. The system might be a Virtual Machine with vGPU, a cloud instance with PCI passthrough, or a CPU-only edge device. 
You must robustly identify the correct `$STACK_DIR` before taking any deployment actions.

## 1. Multi-Layer Hardware Detection
Do not rely on a single command to detect the GPU. Use a fallback chain.

### Step A: Native Utilities (Fastest, if installed)
Run these first:
```bash
HAS_NVIDIA=0; HAS_AMD=0
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 && HAS_NVIDIA=1
command -v rocm-smi >/dev/null 2>&1 && rocm-smi >/dev/null 2>&1 && HAS_AMD=1
echo "HAS_NVIDIA=$HAS_NVIDIA HAS_AMD=$HAS_AMD"
```
Decision matrix:
- `HAS_NVIDIA=1` and `HAS_AMD=0` → `TIGER_PLATFORM=nvidia`.
- `HAS_NVIDIA=0` and `HAS_AMD=1` → `TIGER_PLATFORM=amd`.
- `HAS_NVIDIA=1` and `HAS_AMD=1` → **STOP. Do not auto-pick.** See §3 *Multiple GPUs of Mixed Brands* below: ask the user which platform to deploy and only proceed after they answer.
- Both `0` → Native utilities did not find a usable GPU; proceed to Step B.

### Step B: PCI Bus Probing (For Pristine Systems)
If Native Utilities fail (e.g., drivers are not installed yet), probe the PCI bus:
```bash
lspci_out=$(lspci | grep -iE 'vga|3d|2d')
echo "$lspci_out"
HAS_NVIDIA_PCI=0; HAS_AMD_PCI=0
echo "$lspci_out" | grep -iE 'nvidia|geforce|tesla|grid' >/dev/null && HAS_NVIDIA_PCI=1
echo "$lspci_out" | grep -iE 'amd|radeon|advanced micro devices' >/dev/null && HAS_AMD_PCI=1
echo "HAS_NVIDIA_PCI=$HAS_NVIDIA_PCI HAS_AMD_PCI=$HAS_AMD_PCI"
```
Decision matrix:
- Only NVIDIA detected → `TIGER_PLATFORM=nvidia`.
- Only AMD detected → `TIGER_PLATFORM=amd`.
- **Both detected** → **STOP. Do not auto-pick.** See §3 *Multiple GPUs of Mixed Brands* — ask the user.
- Neither detected (`VMware SVGA`, `Virtio`, or empty output) → proceed to CPU/ARM fallback.

### Step C: CPU / ARM Fallback (The Safety Net)
If no dedicated GPU is detected, or the environment is heavily virtualized without passthrough, fall back to the arm64 platform, whose images are CPU-capable.
Run architecture check:
```bash
uname -m
```
- If `aarch64` or `arm64` (like AWS Graviton, Mac M-Series): `TIGER_PLATFORM=arm64`
- If `x86_64` but NO GPU was found: `TIGER_PLATFORM=arm64` still works — its overlay pulls CPU-capable images and the GPU reservation is ignored when no device is present.

## 2. Exporting the Platform
There is one stack. The platform is not a directory — it is `TIGER_PLATFORM`,
which every script reads and none will guess.
**Never hardcode absolute paths like `/home/user/OpenGenie`**, as your Git clone location may change.

```bash
export TIGER_PLATFORM=nvidia   # or amd / arm64, from the detection above
cd deployments/compose-stack
```

`deployments/tiger-deploy.sh` performs the same detection and export itself,
so prefer it unless you have a reason to override the result.

## 3. Handling Edge Cases
- **Stuck GPU (PCIe reset bug):** If `nvidia-smi` hangs indefinitely, the GPU has crashed. Recovery: Reboot the machine immediately.
- **Multiple GPUs of Mixed Brands:** If a system has both AMD and NVIDIA GPUs detected in §1 Step A or Step B, the agent **MUST NOT auto-select** a stack. Stop and ask the user which stack to deploy. Print this exact message and wait for the user's reply:

  ---
  🎛️ **Mixed-vendor GPU configuration detected.**

  I detected both NVIDIA and AMD GPUs on this host. The OpenGenie stack uses **only one** GPU vendor per deployment — Docker can address either NVIDIA (via `nvidia-container-toolkit`) or AMD (via ROCm `/dev/kfd`+`/dev/dri`), not both inside the same compose project. Please choose:

  1. **`nvidia`** — `TIGER_PLATFORM=nvidia` (CUDA path). Choose this if your NVIDIA card is the primary accelerator (typical: discrete RTX/Tesla + an AMD iGPU on the CPU).
  2. **`amd`** — `TIGER_PLATFORM=amd` (ROCm path). Choose this if your AMD card is the primary accelerator (typical: discrete Radeon/Instinct + an NVIDIA iGPU on a workstation board).

  Reply with `nvidia` or `amd`.
  ---

  After the user answers, set `$STACK_DIR` to the chosen stack and write `gpu` in `.agent-state.json` accordingly (`NVIDIA` or `AMD`). Do NOT default to either vendor without an explicit user reply.
