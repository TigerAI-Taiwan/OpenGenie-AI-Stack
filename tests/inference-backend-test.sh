#!/bin/bash
# =====================================================================
# TigerAI Inference Backend Test Script
# Path: tests/inference-backend-test.sh
# Purpose: Exercise the INFERENCE_BACKEND logic with a stubbed docker, no daemon needed:
#            - lib/common.sh §8: validate / resolve / cutover
#            - 03-ai-core/pre-deploy.sh
#            - migrations/renumber-migrate.sh section 0 (step_backend)
#            - 07-validation-stack: CHECK_BACKEND (health check) and the benchmark dispatch
# Run it on Linux bash >= 4 (macOS bash 3.2 is not trustworthy), e.g.:
#   docker run --rm -v "$PWD":/w -w /w ubuntu:24.04 bash tests/inference-backend-test.sh
# The stack is copied into a temp directory first, so no real .env is read or written.
# =====================================================================

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRC_STACK="${REPO_DIR}/deployments/compose-stack"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STACK="${WORK}/stack"
STATE="${WORK}/state"
STUB="${WORK}/bin"
cp -a "$SRC_STACK" "$STACK"
# Never read a real host's settings.
find "$STACK" -name '.env' -delete
rm -f "$STACK/tiger-tuning.env"

PASS=0
FAILED=0
ok()   { PASS=$((PASS + 1)); echo -e "\033[0;32m  PASS\033[0m $1"; }
bad()  { FAILED=$((FAILED + 1)); echo -e "\033[0;31m  FAIL\033[0m $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; }
has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)" "$1"; fi; }
hasnt(){ if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected: $2)" "$1"; else ok "$3"; fi; }
rc_is(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (exit $1, want $2)"; fi; }
section() { echo; echo -e "\033[1;34m== $1\033[0m"; }

# --- Stubs --------------------------------------------------------------------
# State: $STATE/containers/<name> holds the compose project label; <name>.running holds true/false.
#        $STATE/volumes/<name> holds the mountpoint; $STATE/nodocker makes `docker info` fail.
#        Every docker call is appended to $STATE/calls.
mkdir -p "$STUB"
cat > "$STUB/docker" <<'EOF'
#!/bin/bash
S="${TEST_STATE:?}"
echo "docker $*" >> "$S/calls"
cmd="$1"; shift
case "$cmd" in
    info) [ -e "$S/nodocker" ] && exit 1; exit 0 ;;
    container|inspect)
        [ "$cmd" = container ] && shift   # drop "inspect"
        fmt=""
        if [ "${1:-}" = "-f" ]; then fmt="$2"; shift 2; fi
        name="$1"
        [ -f "$S/containers/$name" ] || exit 1
        case "$fmt" in
            *compose.project*) cat "$S/containers/$name" ;;
            *State.Running*)   cat "$S/containers/$name.running" 2>/dev/null || echo true ;;
            *Health*)          echo healthy ;;
            *Image*)           echo stub-image ;;
            "")                echo '[{}]' ;;
        esac
        exit 0 ;;
    ps)
        filter=""
        while [ $# -gt 0 ]; do
            case "$1" in --filter) filter="$2"; shift 2 ;; *) shift ;; esac
        done
        for f in "$S"/containers/*; do
            [ -f "$f" ] || continue
            case "$f" in *.running) continue ;; esac
            n="$(basename "$f")"
            case "$filter" in
                label=com.docker.compose.project=*) [ "$(cat "$f")" = "${filter#label=com.docker.compose.project=}" ] || continue ;;
                "") ;;
                *) continue ;;
            esac
            echo "$n"
        done
        exit 0 ;;
    stop) exit 0 ;;
    rm)   for a in "$@"; do case "$a" in -*) ;; *) rm -f "$S/containers/$a" "$S/containers/$a.running" ;; esac; done; exit 0 ;;
    restart) exit 0 ;;
    volume)
        sub="$1"; shift
        case "$sub" in
            ls) ls "$S/volumes" 2>/dev/null; exit 0 ;;
            inspect)
                [ "${1:-}" = "-f" ] && shift 2
                [ -f "$S/volumes/$1" ] || exit 1
                cat "$S/volumes/$1"; exit 0 ;;
        esac
        exit 0 ;;
    compose|run|network) exit 0 ;;
esac
exit 0
EOF
# Health check: every endpoint answers 200. Migration: empty root crontab.
printf '#!/bin/bash\necho 200\n' > "$STUB/curl"
# crontab: stateful, backed by $STATE/crontab (absent = "no crontab for root", exit 1). `crontab -` reads all
# of stdin into a temp file BEFORE replacing the state, because the caller's pipeline is still reading it.
cat > "$STUB/crontab" <<'EOF'
#!/bin/bash
S="${TEST_STATE:?}"
case "${1:-}" in
    -l) [ -f "$S/crontab" ] || { echo "no crontab for root" >&2; exit 1; }; cat "$S/crontab" ;;
    -)  t="$(mktemp)"; cat > "$t"; mv "$t" "$S/crontab" ;;
esac
EOF
# next_platform must not guess from the test machine's architecture.
printf '#!/bin/bash\necho x86_64\n' > "$STUB/uname"
chmod +x "$STUB"/*

reset_state() {
    rm -rf "$STATE"
    mkdir -p "$STATE/containers" "$STATE/volumes"
    : > "$STATE/calls"
    find "$STACK" -name '.env' -delete
}
# add_container <name> <compose project label>
add_container() { printf '%s' "$2" > "$STATE/containers/$1"; }
set_env() { printf 'INFERENCE_BACKEND=%s\n' "$1" > "$STACK/.env"; }
calls() { cat "$STATE/calls"; }

# lib <platform> <INFERENCE_BACKEND> <code...> -> sources lib/common.sh in a fresh bash
lib() {
    local plat="$1" be="$2"; shift 2
    env -u TIGER_INFERENCE_BACKEND PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM="$plat" \
        INFERENCE_BACKEND="$be" TIGER_MODULE_DIR="$STACK" \
        bash -c 'source "$1/lib/common.sh"; shift; eval "$*"' _ "$STACK" "$@" 2>&1
}

# --- 1. validate --------------------------------------------------------------
section "lib/common.sh: tiger_inference_backend_validate"
for p in amd nvidia arm64; do
    for v in "" ollama lemonade vllm bogus; do
        reset_state
        # Pass the value through a separate variable so an empty value is exercised as such.
        out="$(env PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM="$p" TIGER_MODULE_DIR="$STACK" \
            bash -c 'source "$1/lib/common.sh"; tiger_inference_backend_validate "$2" "$3"' _ "$STACK" "$v" "$p" 2>&1)"; rc=$?
        want=1
        { [ "$p" = amd ] && [ "$v" = lemonade ]; } && want=0
        { [ "$p" != amd ] && [ "$v" = ollama ]; } && want=0
        rc_is "$rc" "$want" "validate $p '$v' -> exit $want"
        case "$v" in
            "")       if [ "$p" = amd ]; then has "$out" "amd requires INFERENCE_BACKEND=lemonade" "  empty on amd names the required value"
                      else has "$out" "$p requires INFERENCE_BACKEND=ollama" "  empty on $p names the required value"; fi ;;
            vllm|bogus) has "$out" "is not recognised" "  '$v' is not recognised on $p" ;;
            ollama)   [ "$p" = amd ] && has "$out" "not supported on amd" "  ollama is not supported on amd" ;;
            lemonade) [ "$p" != amd ] && has "$out" "not supported on $p" "  lemonade is not supported on $p" ;;
        esac
        [ -z "$(calls)" ] && ok "  validate never calls docker" || bad "  validate called docker" "$(calls)"
    done
done
reset_state
out="$(lib amd "" 'tiger_inference_backend_validate lemonade solaris || echo "rc=$?"')"
has "$out" "unknown platform 'solaris'" "validate rejects an unknown platform"
has "$out" "rc=1" "  with exit 1"

# --- 2. resolve ---------------------------------------------------------------
section "lib/common.sh: tiger_inference_backend_resolve"
for p in amd nvidia arm64; do
    for v in "" ollama lemonade vllm bogus; do
        reset_state
        out="$(lib "$p" "$v" 'tiger_inference_backend_resolve; echo "BE=$TIGER_INFERENCE_BACKEND EXPLICIT=$TIGER_INFERENCE_BACKEND_EXPLICIT PRESENT=[$TIGER_INFERENCE_BACKENDS_PRESENT]"')"; rc=$?
        legal=""
        { [ "$p" = amd ] && [ "$v" = lemonade ]; } && legal=1
        { [ "$p" != amd ] && [ "$v" = ollama ]; } && legal=1
        if [ -n "$legal" ]; then
            rc_is "$rc" 0 "resolve $p '$v' succeeds"
            has "$out" "BE=$v EXPLICIT=1 PRESENT=[]" "  effective value $v, EXPLICIT=1"
        else
            rc_is "$rc" 1 "resolve $p '$v' stops"
            has "$out" "Fix INFERENCE_BACKEND in" "  points at the stack .env"
            [ -z "$(calls)" ] && ok "  stops before any docker call" || bad "  docker was called before the stop" "$(calls)"
        fi
    done
done

reset_state
out="$(env PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM=amd INFERENCE_BACKEND=lemonade TIGER_MODULE_DIR="$STACK" \
    TIGER_INFERENCE_BACKEND=ollama TIGER_INFERENCE_BACKEND_EXPLICIT=1 \
    bash -c 'source "$1/lib/common.sh"; tiger_inference_backend_resolve; echo "BE=$TIGER_INFERENCE_BACKEND"' _ "$STACK" 2>&1)"
has "$out" "BE=lemonade" "an inherited TIGER_INFERENCE_BACKEND is cleared on source"

reset_state
add_container ollama 03-ai-core-ollama
add_container lemonade-edu 03-ai-core-lemonade
out="$(lib nvidia ollama 'tiger_inference_backend_resolve; echo "PRESENT=[$TIGER_INFERENCE_BACKENDS_PRESENT]"')"
has "$out" "PRESENT=[ollama lemonade]" "resolve lists the backends that have a container"

reset_state
touch "$STATE/nodocker"
out="$(lib amd lemonade 'tiger_inference_backend_resolve; echo RESOLVED')"; rc=$?
rc_is "$rc" 1 "resolve with docker unreachable stops"
has "$out" "Cannot call docker" "  says docker cannot be called"
hasnt "$out" "RESOLVED" "  does not continue"

# --- 3. cutover ---------------------------------------------------------------
section "lib/common.sh: tiger_inference_backend_cutover"
cut='tiger_inference_backend_resolve; tiger_inference_backend_cutover; echo "CUTOVER-DONE PRESENT=[$TIGER_INFERENCE_BACKENDS_PRESENT]"'

reset_state
out="$(lib amd lemonade "$cut")"; rc=$?
rc_is "$rc" 0 "clean host: cutover succeeds"
hasnt "$(calls)" "docker stop" "  nothing stopped"
hasnt "$(calls)" "docker rm" "  nothing removed"

reset_state
for c in lemonade-edu lemonade-rag lemonade-embed; do add_container "$c" 03-ai-core-lemonade; done
out="$(lib amd lemonade "$cut")"; rc=$?
rc_is "$rc" 0 "own containers in the new project: cutover succeeds"
has "$out" "PRESENT=[lemonade]" "  lemonade stays present"
hasnt "$(calls)" "docker rm" "  nothing removed"

reset_state
add_container lemonade-edu 06-ai-core-lemonade
add_container ollama 03-ai-interface-ollama-openwebui-redis
out="$(lib amd lemonade "$cut")"; rc=$?
rc_is "$rc" 1 "own container in the pre-renumber project: stops"
has "$out" "Run migrations/renumber-migrate.sh first" "  says to run the migration script"
hasnt "$(calls)" "docker stop" "  nothing stopped (old ollama untouched too)"
hasnt "$(calls)" "docker rm" "  nothing removed"

reset_state
add_container lemonade-edu some-other-project
out="$(lib amd lemonade "$cut")"; rc=$?
rc_is "$rc" 1 "foreign container with an own name: stops"
has "$out" "Remove it yourself (docker rm -f lemonade-edu)" "  says to remove it by hand"
hasnt "$(calls)" "docker rm lemonade-edu" "  it is not removed"

reset_state
add_container ollama 03-ai-interface-ollama-openwebui-redis
mkdir -p "$WORK/models"
out="$(MODELS_DIR="$WORK/models" lib amd lemonade "$cut")"; rc=$?
rc_is "$rc" 0 "AMD with only the pre-renumber Ollama: cutover succeeds"
has "$(calls)" "docker stop -t 30 ollama" "  ollama stopped with -t 30"
has "$(calls)" "docker rm ollama" "  ollama removed"
has "$out" "REMOVED ollama" "  removal is logged"
# /var/lib/ollama is listed only when it exists; the summary line is always printed.
has "$out" "Removed: ollama. Models and caches are kept" "  says the models are kept"
has "$out" "PRESENT=[]" "  nothing of ollama is left present"

reset_state
add_container ollama someone-elses
out="$(lib amd lemonade "$cut")"; rc=$?
rc_is "$rc" 1 "AMD with a foreign ollama container: stops"
has "$out" "not created by this stack; left alone" "  foreign container left alone"
hasnt "$(calls)" "docker stop" "  nothing stopped"

reset_state
add_container ollama 03-ai-core-ollama
add_container lemonade-rag 03-ai-core-lemonade
printf '%s' "$WORK" > "$STATE/volumes/03-ai-core-lemonade_lemonade-rag-cache"
out="$(lib arm64 ollama "$cut")"; rc=$?
rc_is "$rc" 0 "arm64 with a stray stack Lemonade: cutover succeeds"
has "$(calls)" "docker rm lemonade-rag" "  lemonade-rag removed"
hasnt "$(calls)" "docker rm ollama" "  own ollama kept"
has "$out" "volume 03-ai-core-lemonade_lemonade-rag-cache" "  lemonade volume listed"
has "$out" "PRESENT=[ollama]" "  only ollama stays present"

reset_state
add_container ollama 03-ai-interface-ollama-openwebui-redis
out="$(lib amd ollama "$cut")"; rc=$?
rc_is "$rc" 1 "an invalid value never reaches cutover"
hasnt "$out" "CUTOVER-DONE" "  cutover did not run"
hasnt "$(calls)" "docker rm" "  nothing removed"

# --- 4. 03-ai-core/pre-deploy.sh ---------------------------------------------
section "03-ai-core/pre-deploy.sh"
for p in amd nvidia arm64; do
    reset_state
    out="$(env PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM="$p" bash "$STACK/03-ai-core/pre-deploy.sh" 2>&1)"; rc=$?
    rc_is "$rc" 1 "pre-deploy $p with no INFERENCE_BACKEND -> 1"
    want=ollama; [ "$p" = amd ] && want=lemonade
    has "$out" "[MISSING] 03-ai-core/INFERENCE_BACKEND" "  reports MISSING"
    has "$out" "requires INFERENCE_BACKEND=${want}" "  names ${want}"
    set_env "$want"
    out="$(env PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM="$p" bash "$STACK/03-ai-core/pre-deploy.sh" 2>&1)"; rc=$?
    rc_is "$rc" 0 "pre-deploy $p with INFERENCE_BACKEND=${want} -> 0"
    has "$out" "PRE-DEPLOY 03-ai-core: 0 missing" "  summary line"
    [ -z "$(calls)" ] && ok "  never calls docker" || bad "  called docker" "$(calls)"
done

# --- 5. renumber-migrate.sh section 0 ----------------------------------------
section "migrations/renumber-migrate.sh: step_backend"
mig() {
    env -u INFERENCE_BACKEND -u TIGER_PLATFORM PATH="$STUB:$PATH" TEST_STATE="$STATE" "$@" bash "$STACK/migrations/renumber-migrate.sh" 2>&1
}
sec0() { printf '%s\n' "$1" | sed -n '/^== 0\./,/^$/p'; }
for p in amd nvidia arm64; do
    for v in "" ollama lemonade vllm bogus; do
        reset_state
        [ -n "$v" ] && set_env "$v"
        out="$(mig TIGER_PLATFORM="$p")"; rc=$?
        s="$(sec0 "$out")"
        legal=""
        { [ "$p" = amd ] && [ "$v" = lemonade ]; } && legal=1
        { [ "$p" != amd ] && [ "$v" = ollama ]; } && legal=1
        if [ -n "$legal" ]; then
            has "$s" "OK        INFERENCE_BACKEND=${v} (${p}" "migrate $p '$v': OK"
        else
            has "$s" "CONFLICT" "migrate $p '$v': CONFLICT"
            hasnt "$s" "FAILED]" "  CONFLICT carries no ERR-trap noise"
            rc_is "$rc" 1 "  list mode exits 1"
            case "$v" in
                "") has "$s" "requires INFERENCE_BACKEND=" "  CONFLICT carries the validation text" ;;
                *)  has "$s" "INFERENCE_BACKEND" "  CONFLICT carries the validation text" ;;
            esac
        fi
        hasnt "$(calls)" "docker stop" "  list mode stops nothing"
        hasnt "$(calls)" "docker rm" "  list mode removes nothing"
    done
done

reset_state
set_env lemonade
add_container ollama 03-ai-interface-ollama-openwebui-redis
out="$(mig TIGER_PLATFORM=amd)"
s="$(sec0 "$out")"
has "$s" "old backend containers: ollama" "AMD with the old Ollama: named as old backend"
has "$s" "NOTE      AMD no longer runs Ollama" "  AMD NOTE printed"

# --apply as "root" (id stubbed): a CONFLICT in section 0 must stop it before section 1.
reset_state
set_env bogus
add_container ollama 03-ai-interface-ollama-openwebui-redis
out="$(env -u INFERENCE_BACKEND PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM=amd \
    bash -c 'id() { echo 0; }; export -f id; bash "$1" --apply' _ "$STACK/migrations/renumber-migrate.sh" 2>&1)"; rc=$?
rc_is "$rc" 1 "--apply with a CONFLICT in section 0 exits 1"
has "$out" "--apply did nothing" "  --apply does nothing"
hasnt "$(calls)" "docker compose" "  no compose down"

reset_state
set_env lemonade
out="$(mig)"; rc=$?
rc_is "$rc" 2 "no platform detectable: stops (exit 2)"
has "$out" "TIGER_PLATFORM={amd|nvidia|arm64}" "  asks for TIGER_PLATFORM"
hasnt "$(calls)" "docker stop" "  nothing stopped"

# --- 6. 07 health check ------------------------------------------------------
section "07-validation-stack: CHECK_BACKEND"
hc() {
    env -u INFERENCE_BACKEND PATH="$STUB:$PATH" TEST_STATE="$STATE" \
        bash "$STACK/07-validation-stack/resource/$1/check-health.sh" 2>&1
}
reset_state; set_env lemonade
out="$(hc amd)"
hasnt "$out" "Checking Ollama API" "amd + lemonade: Ollama API not probed"
has "$out" "Phase 5: Lemonade Core" "  Lemonade phase runs"
hasnt "$out" "INFERENCE_BACKEND=" "  no backend FAIL"
reset_state
out="$(hc amd)"
has "$out" "INFERENCE_BACKEND='' in .env is not set or not recognised" "amd + empty: backend FAIL"
hasnt "$out" "Phase 5: Lemonade Core" "  Lemonade phase skipped"
hasnt "$out" "Checking Ollama API" "  Ollama API not probed"
has "$out" "Checking OpenWebUI" "  OpenWebUI still checked"
for p in nvidia arm64; do
    reset_state; set_env ollama
    out="$(hc "$p")"
    has "$out" "Checking Ollama API" "$p + ollama: Ollama API probed"
    hasnt "$out" "INFERENCE_BACKEND=" "  no backend FAIL"
done
reset_state; set_env bogus
out="$(hc nvidia)"
has "$out" "INFERENCE_BACKEND='bogus' in .env is not set or not recognised" "nvidia + bogus: backend FAIL"
hasnt "$out" "Checking Ollama API" "  Ollama API not probed"

# --- 7. benchmark dispatch ---------------------------------------------------
section "07-validation-stack: benchmark-tps.sh dispatch"
BENCH="$STACK/07-validation-stack/resource/_shared/benchmark-tps.sh"
mkdir -p "$STACK/07-validation-stack/.venv/bin"
printf '#!/bin/bash\necho "BENCH-RAN $*"\n' > "$STACK/07-validation-stack/.venv/bin/python3"
chmod +x "$STACK/07-validation-stack/.venv/bin/python3"
bench() { env -u INFERENCE_BACKEND PATH="$STUB:$PATH" bash "$BENCH" "$@" 2>&1; }
reset_state
out="$(bench)"; rc=$?
rc_is "$rc" 1 "benchmark with no INFERENCE_BACKEND -> 1"
has "$out" "INFERENCE_BACKEND is not set in .env" "  says it is not set"
hasnt "$out" "BENCH-RAN" "  benchmark not run"
reset_state; set_env lemonade
out="$(bench)"; rc=$?
rc_is "$rc" 1 "benchmark with lemonade -> 1"
has "$out" "INFERENCE_BACKEND=lemonade has no benchmark" "  says lemonade has none"
reset_state; set_env bogus
out="$(bench)"; rc=$?
rc_is "$rc" 1 "benchmark with bogus -> 1"
has "$out" "INFERENCE_BACKEND='bogus' in .env is not recognised" "  says not recognised"
reset_state; set_env ollama
out="$(bench llama3)"; rc=$?
rc_is "$rc" 0 "benchmark with ollama -> runs"
has "$out" "BENCH-RAN benchmark_tps.py llama3" "  benchmark_tps.py called with the model"

# --- 8. 03-ai-core deploy.sh: SKIP and pull -> cutover -> up ----------------
section "03-ai-core/<backend>/deploy.sh"
printf '#!/bin/bash\nexec "$@"\n' > "$STUB/sudo"; chmod +x "$STUB/sudo"
dep() {
    local mod="$1" plat="$2"; shift 2
    env -u INFERENCE_BACKEND PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM="$plat" MODELS_DIR="$WORK/models" SUDO_USER="$(id -un)" \
        bash "$STACK/03-ai-core/$mod/deploy.sh" "$@" 2>&1
}
reset_state; set_env lemonade
out="$(dep ollama amd all)"; rc=$?
rc_is "$rc" 0 "ollama deploy on amd + lemonade: exit 0"
has "$out" "skipping 03-ai-core/ollama" "  SKIP printed"
hasnt "$(calls)" "docker compose" "  no compose call"
reset_state; set_env ollama
out="$(dep lemonade nvidia all)"; rc=$?
rc_is "$rc" 0 "lemonade deploy on nvidia + ollama: exit 0"
has "$out" "skipping 03-ai-core/lemonade" "  SKIP printed"
hasnt "$(calls)" "docker compose" "  no compose call"
reset_state
out="$(dep lemonade amd all)"; rc=$?
rc_is "$rc" 1 "lemonade deploy on amd with no INFERENCE_BACKEND: stops"
has "$out" "amd requires INFERENCE_BACKEND=lemonade" "  names the value to set"
reset_state
out="$(dep lemonade nvidia down)"; rc=$?
rc_is "$rc" 0 "lemonade down on nvidia with no INFERENCE_BACKEND: exit 0 (stop actions ignore the backend)"
reset_state; set_env lemonade
add_container ollama 03-ai-interface-ollama-openwebui-redis
out="$(dep lemonade amd all)"; rc=$?
rc_is "$rc" 0 "lemonade deploy on amd with the pre-renumber Ollama: succeeds"
order="$(grep -nE 'docker compose .* pull$|docker stop -t 30 ollama|docker compose .* up -d$' "$STATE/calls" | cut -d: -f1 | tr '\n' ' ')"
if [ "$(printf '%s' "$order" | wc -w)" -eq 3 ] && [ "$(printf '%s\n' $order | sort -n | tr '\n' ' ')" = "$order" ]; then
    ok "  order is pull -> stop ollama -> up -d"
else
    bad "  order is pull -> stop ollama -> up -d (lines: $order)" "$(calls)"
fi
reset_state; set_env ollama
out="$(dep ollama arm64 all)"; rc=$?
rc_is "$rc" 0 "ollama deploy on arm64 + ollama: succeeds"
has "$(calls)" "docker-compose.arm64.yaml" "  arm64 overlay layered"

# --- 9. 08 setup-cron.sh: the backend in the cron line ----------------------
section "08-backup-recovery: setup-cron.sh"
PURGE="$STACK/08-backup-recovery/resource/amd/vram-purge.sh"
MLOG="$STACK/08-backup-recovery/maintenance.log"
cron() { env PATH="$STUB:$PATH" TEST_STATE="$STATE" bash "$STACK/08-backup-recovery/resource/_shared/setup-cron.sh" "$@" 2>&1; }
ctab() { cat "$STATE/crontab" 2>/dev/null; }
reset_state
out="$(cron "$PURGE" lemonade)"; rc=$?
rc_is "$rc" 0 "fresh host (no crontab): installs"
has "$(ctab)" "0 5 * * * /bin/bash $PURGE lemonade >> $MLOG 2>&1" "  cron line carries the backend"
[ "$(ctab | grep -c vram-purge)" = 1 ] && ok "  exactly one purge line" || bad "  exactly one purge line" "$(ctab)"
reset_state
printf '%s\n' "@reboot /usr/bin/true unrelated-job" "0 5 * * * /bin/bash $PURGE >> $MLOG 2>&1" > "$STATE/crontab"
out="$(cron "$PURGE" lemonade)"; rc=$?
rc_is "$rc" 0 "old line without a backend: replaced"
has "$(ctab)" "$PURGE lemonade >>" "  new line present"
hasnt "$(ctab)" "$PURGE >>" "  old line gone"
has "$(ctab)" "unrelated-job" "  unrelated line kept"
out="$(cron "$PURGE" lemonade)"; rc=$?
rc_is "$rc" 0 "re-run: succeeds"
has "$out" "already exists, skipping" "  says it is already installed"
[ "$(ctab | grep -c vram-purge)" = 1 ] && ok "  still exactly one purge line" || bad "  still exactly one purge line" "$(ctab)"
out="$(cron "$PURGE" ollama)"; rc=$?
rc_is "$rc" 0 "backend switched: succeeds"
has "$(ctab)" "$PURGE ollama >>" "  new backend in the line"
hasnt "$(ctab)" "$PURGE lemonade" "  old backend line gone"
[ "$(ctab | grep -c vram-purge)" = 1 ] && ok "  exactly one purge line" || bad "  exactly one purge line" "$(ctab)"
for v in "" bogus; do
    before="$(ctab)"
    # shellcheck disable=SC2086  # unquoted on purpose: '' must pass no second argument at all
    out="$(cron "$PURGE" $v)"; rc=$?
    rc_is "$rc" 1 "backend '$v': rejected"
    has "$out" "invalid or missing" "  says invalid or missing"
    [ "$(ctab)" = "$before" ] && ok "  crontab unchanged" || bad "  crontab unchanged" "$(ctab)"
done

# --- 10. 09 tiger-monitor: unit and systemctl order ------------------------
section "09-monitoring-alerting: tiger-monitor install/start/uninstall"
# sudo stub: never touch /etc/systemd on the test machine. `tee <unit>` goes to $STATE/unit, `rm` of a unit is logged only.
cat > "$STUB/sudo" <<'EOF'
#!/bin/bash
S="${TEST_STATE:?}"
case "$*" in
    *"/etc/systemd/"*)
        echo "sudo $*" >> "$S/calls"
        [ "$1" = tee ] && cat > "$S/unit"
        exit 0 ;;
esac
exec "$@"
EOF
printf '#!/bin/bash\necho "systemctl $*" >> "${TEST_STATE:?}/calls"\n' > "$STUB/systemctl"
printf '#!/bin/bash\nexit 0\n' > "$STUB/mosquitto_pub"
chmod +x "$STUB"/*
mon() { local be="$1"; shift; env -u TIGER_MONITOR_BACKEND PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_MONITOR_BACKEND="$be" \
    bash "$STACK/09-monitoring-alerting/resource/amd/tiger-monitor.sh" "$@" 2>&1; }
reset_state
out="$(mon lemonade install)"; rc=$?
rc_is "$rc" 0 "install with TIGER_MONITOR_BACKEND=lemonade"
has "$(cat "$STATE/unit" 2>/dev/null)" "Environment=TIGER_MONITOR_BACKEND=lemonade" "  unit carries the backend"
order="$(grep -nE '^systemctl (daemon-reload|enable tiger-monitor.service|restart tiger-monitor.service)$' "$STATE/calls" | cut -d: -f2- | tr '\n' '|')"
[ "$order" = "systemctl daemon-reload|systemctl enable tiger-monitor.service|systemctl restart tiger-monitor.service|" ] \
    && ok "  systemctl order: daemon-reload -> enable -> restart" || bad "  systemctl order: daemon-reload -> enable -> restart" "$(calls)"
hasnt "$(calls)" "enable --now" "  no enable --now"
reset_state
out="$(mon "" start)"; rc=$?
rc_is "$rc" 1 "start with an empty TIGER_MONITOR_BACKEND: refused"
has "$out" "TIGER_MONITOR_BACKEND is empty" "  says the backend is empty"
hasnt "$out" "Starting unattended monitoring loop" "  the loop never starts"
reset_state
out="$(mon "" uninstall)"; rc=$?
rc_is "$rc" 0 "uninstall with an empty TIGER_MONITOR_BACKEND: still works"
has "$out" "Systemd service removed" "  removal completes"

# --- 11. 05 pre-deploy: SearXNG secret and sandbox keys --------------------
section "05-automation-n8n/pre-deploy.sh"
n8n_env() {
    # base: everything else real, so only the lines under test can be missing
    printf '%s\n' "N8N_ENCRYPTION_KEY=real-enc-key" "PG_PASS=real-pg-pass" "N8N_DIR=$WORK/n8n" "$@" > "$STACK/.env"
}
n8n_pre() { env -u COMPOSE_PROFILES PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM=amd bash "$STACK/05-automation-n8n/pre-deploy.sh" 2>&1; }
SB="SANDBOX_API_KEYS=k1 SANDBOX_REGISTRATION_TOKEN=k2 SANDBOX_RUNNER_API_KEY=k3"
for case_ in "unset|" "empty|SEARXNG_SECRET=" "CHANGE_ME|SEARXNG_SECRET=CHANGE_ME" "old placeholder|SEARXNG_SECRET=CHANGE_ME_searxng_secret"; do
    name="${case_%%|*}"; line="${case_#*|}"
    reset_state
    # shellcheck disable=SC2086  # one argument per key
    n8n_env $SB ${line:+"$line"}
    out="$(n8n_pre)"; rc=$?
    rc_is "$rc" 1 "SEARXNG_SECRET $name: missing"
    has "$out" "[MISSING] 05-automation-n8n/SEARXNG_SECRET" "  reported"
    has "$out" "PRE-DEPLOY 05-automation-n8n: 1 missing" "  only that one"
done
reset_state
# shellcheck disable=SC2086
n8n_env $SB "SEARXNG_SECRET=real-searxng"
out="$(n8n_pre)"; rc=$?
rc_is "$rc" 0 "real SEARXNG_SECRET and sandbox keys: nothing missing"
for sw in "unset|" "true|N8N_AI_ASSISTANT_ENABLED=true"; do
    name="${sw%%|*}"; line="${sw#*|}"
    reset_state
    n8n_env "SEARXNG_SECRET=real-searxng" ${line:+"$line"}
    out="$(n8n_pre)"; rc=$?
    rc_is "$rc" 1 "N8N_AI_ASSISTANT_ENABLED $name, no sandbox keys: missing"
    for k in SANDBOX_API_KEYS SANDBOX_REGISTRATION_TOKEN SANDBOX_RUNNER_API_KEY; do
        has "$out" "[MISSING] 05-automation-n8n/$k" "  $k checked"
    done
done
reset_state
n8n_env "SEARXNG_SECRET=real-searxng" "N8N_AI_ASSISTANT_ENABLED=false"
out="$(n8n_pre)"; rc=$?
rc_is "$rc" 0 "N8N_AI_ASSISTANT_ENABLED=false, no sandbox keys: nothing missing"
hasnt "$out" "SANDBOX_" "  sandbox keys not checked"

# --- 12. master-deploy.sh pre-deploy picks up 03-ai-core -------------------
section "master-deploy.sh pre-deploy"
printf '#!/bin/bash\nif [ "${1:-}" = -u ]; then echo 0; else exec /usr/bin/id "$@"; fi\n' > "$STUB/id"; chmod +x "$STUB/id"
reset_state
out="$(env PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM=amd BASE_DIR="$WORK/base" SUDO_USER="$(/usr/bin/id -un)" \
    bash "$STACK/master-deploy.sh" pre-deploy 2>&1)"; rc=$?
has "$out" "PRE-DEPLOY 03-ai-core:" "03-ai-core/pre-deploy.sh is run"
has "$out" "[MISSING] 03-ai-core/INFERENCE_BACKEND" "  its MISSING line is reported"
rc_is "$rc" 1 "  something missing -> exit 1"
rm -f "$STUB/id"

# --- 13. .env line forms: CRLF and quotes ----------------------------------
section ".env: INFERENCE_BACKEND with CRLF / quotes"
for form in 'INFERENCE_BACKEND=lemonade\r' 'INFERENCE_BACKEND="lemonade"' "INFERENCE_BACKEND='lemonade'"; do
    reset_state
    # shellcheck disable=SC2059  # the format is the line under test: \r must be interpreted
    printf "${form//%/%%}\n" > "$STACK/.env"
    out="$(env -u INFERENCE_BACKEND PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM=amd TIGER_MODULE_DIR="$STACK" \
        bash -c 'source "$1/lib/common.sh"; tiger_inference_backend_resolve; echo "BE=[$TIGER_INFERENCE_BACKEND]"' _ "$STACK" 2>&1)"; rc=$?
    rc_is "$rc" 0 "resolve with $(printf '%q' "$form")"
    has "$out" "BE=[lemonade]" "  effective value lemonade"
    out="$(env -u INFERENCE_BACKEND PATH="$STUB:$PATH" TEST_STATE="$STATE" TIGER_PLATFORM=amd bash "$STACK/03-ai-core/pre-deploy.sh" 2>&1)"; rc=$?
    rc_is "$rc" 0 "  03-ai-core/pre-deploy.sh passes"
done

echo
echo "Result: ${PASS} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
