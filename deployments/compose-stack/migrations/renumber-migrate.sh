#!/usr/bin/env bash
# =====================================================================
# TigerAI — one-shot migration for the compose module renumbering (03→04, 04→05, 05→06, 06→03, redis to 02, Ollama / Lemonade to 03-ai-core)
# Path: deployments/compose-stack/migrations/renumber-migrate.sh
# =====================================================================
#
# Why this exists: the compose project name is the module directory name, so after the rename
#   - the old project's containers are still there and `up` in the new directory collides on container_name → down them by the old project name first
#   - named volumes get a new prefix → openwebui_data, the n8n sandbox-api-data and the three Lemonade caches are copied to the new names
#   - git only moves tracked files → module-level .env files stay in the old directories; the RAG cron hard-codes the old absolute path
#
# When to run: after git pull, after INFERENCE_BACKEND is set in .env, before deploying 03-ai-core (OpenWebUI, n8n, RAG and the old inference backend stop).
#
# Usage:
#   sudo bash ./renumber-migrate.sh            # list only, changes nothing
#   sudo bash ./renumber-migrate.sh --apply    # act; with any CONFLICT nothing at all is done
#   Re-runnable: finished items show GONE / DONE. Old volumes and old directories are never deleted; only the delete commands are printed.
#
# States: DOWN/COPY/MOVE/CRON pending / DOWNED/COPIED/MOVED/FIXED done / GONE/DONE/SKIP/OK nothing to do / LATER left to step 3 of the upgrade notes / CONFLICT needs a human
# Exit code: 0 = nothing pending (or apply finished); 1 = something pending (list mode) or a CONFLICT; 2 = cannot run or failed.
# Upgrade notes: docs/v5.0.0/RELEASE-NOTE.md, section 「升級注意」.
# =====================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
NOTES="docs/v5.0.0/RELEASE-NOTE.md (升級注意)"

APPLY=0
case "${1:-}" in
    "") ;;
    --apply) APPLY=1 ;;
    *) sed -n '/^# Usage:/,/^#   Re-runnable/p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac

fail() { echo "ERROR $*" >&2; exit 2; }
row()  { printf '  %-9s %s\n' "$1" "$2"; }

docker info >/dev/null 2>&1 || fail "Cannot call docker (not installed or no permission; use sudo)"
[ "$APPLY" -eq 0 ] || [ "$(id -u)" -eq 0 ] || fail "--apply needs root (crontab, docker volumes)"

# old directory|new directory (project name = directory name; 03-ai-core/<backend> pins its name with `name:` in the compose file)
MOVES=(
    "03-ai-interface-ollama-openwebui-redis|04-ai-interface-openwebui"
    "04-automation-n8n|05-automation-n8n"
    "05-rag-stack-docling-qdrant-mosquitto|06-rag-stack-docling-qdrant-mosquitto"
    "06-ai-core-lemonade|03-ai-core/lemonade"
)
# old project|new project|volume key; the n8n sandbox volume only exists with --profile sandbox, SKIP when absent.
VOLUMES=(
    "03-ai-interface-ollama-openwebui-redis|04-ai-interface-openwebui|openwebui_data"
    "04-automation-n8n|05-automation-n8n|sandbox-api-data"
    "06-ai-core-lemonade|03-ai-core-lemonade|lemonade-edu-cache"
    "06-ai-core-lemonade|03-ai-core-lemonade|lemonade-rag-cache"
    "06-ai-core-lemonade|03-ai-core-lemonade|lemonade-embed-cache"
)
# The inner dockerd's image cache: cp -a drops overlayfs trusted.* xattrs, so a copy would be broken layers; let it rebuild in the new volume.
NOCOPY_VOL="04-automation-n8n_sandbox-runner-1-docker"
# The old 03's OLLAMA_* lines are read only by Ollama: after the .env moves to 04 they move on to 03-ai-core/ollama.
OWUI_ENV="04-ai-interface-openwebui/.env"
OLLAMA_ENV="03-ai-core/ollama/.env"
OLLAMA_RE='^[[:space:]]*(export[[:space:]]+)?OLLAMA_[A-Za-z0-9_]*='
OLD_RAG="05-rag-stack-docling-qdrant-mosquitto"
NEW_RAG="06-rag-stack-docling-qdrant-mosquitto"
# Set on the new volume: tells "copied by this script" apart from "an empty volume created by deploying the new module first".
MARK="tigerai.renumber.from"
# Written into the new volume before copying, removed only after the check: only its presence means "the last copy did not finish".
# File counts cannot tell, they change as soon as a service uses the volume.
COPYING=".tigerai-renumber-copying"

pending=0 conflict=0
NEED_PLATFORM=0
DONE_VOLS=()
HELPER_IMG=""
COPY_STATE=""

vol_exists() { docker volume inspect "$1" >/dev/null 2>&1; }

# Image for copying: postgres is always running (02 is not renamed) so it is on this host already; nothing is pulled.
helper_image() {
    [ -n "$HELPER_IMG" ] && return 0
    local c
    for c in postgres redis; do
        HELPER_IMG="$(docker container inspect -f '{{.Image}}' "$c" 2>/dev/null)" && [ -n "$HELPER_IMG" ] && return 0
    done
    HELPER_IMG=""
    fail "No postgres / redis container to borrow an image from for copying volumes - deploy 02-database first"
}

count_files() {
    docker run --rm --network none --entrypoint sh -v "$1":/d:ro "$HELPER_IMG" \
        -c "find /d -path /d/$COPYING -prune -o -print | wc -l" | tr -d ' '
}

# Trust only "copying" / "done" printed by the container: treating a docker failure (125 etc.) as "no marker" would mark an unfinished copy as done.
copying_state() {
    local out
    out="$(docker run --rm --network none --entrypoint sh -v "$1":/d:ro "$HELPER_IMG" \
        -c "if [ -e /d/$COPYING ]; then echo copying; else echo done; fi")"
    case "$out" in
        copying|done) COPY_STATE="$out" ;;
        *) fail "Cannot read the copying marker of $1 (docker run failed); not treating it as done. Fix it and re-run this script" ;;
    esac
}

# --- 0. INFERENCE_BACKEND (validated before section 1 stops anything) ---------
# Every deploy refuses an empty or wrong value; checking first means nothing is stopped on a host that cannot redeploy.
step_backend() {
    local old="" plat raw reason
    [ -n "$(docker ps -a -q --filter label=com.docker.compose.project=06-ai-core-lemonade)" ] && old="lemonade"
    if [ "$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' ollama 2>/dev/null)" = "03-ai-interface-ollama-openwebui-redis" ]; then
        old="${old:+$old }ollama"
    fi
    echo "== 0. INFERENCE_BACKEND"
    plat="$(next_platform)"
    [ -n "$plat" ] || fail "Cannot tell the platform; re-run with TIGER_PLATFORM={amd|nvidia|arm64}"
    # Same load order (tiger-tuning.env < stack .env) and validation as deploy.
    # shellcheck disable=SC2016  # $1 is expanded by the inner bash
    raw="$(TIGER_PLATFORM="$plat" TIGER_MODULE_DIR="$STACK_DIR" bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1 && printf %s "${INFERENCE_BACKEND:-}"' _ "$STACK_DIR")" \
        || fail "Cannot read $STACK_DIR/.env (source lib/common.sh failed)"
    # lib/common.sh installs an ERR trap; drop it so a failed validate prints only its own reason.
    # shellcheck disable=SC2016  # $1..$3 are expanded by the inner bash
    reason="$(TIGER_PLATFORM="$plat" TIGER_MODULE_DIR="$STACK_DIR" bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1 && trap - ERR && tiger_inference_backend_validate "$2" "$3"' _ "$STACK_DIR" "$raw" "$plat" 2>&1)" || {
        conflict=$((conflict + 1))
        row CONFLICT "${reason:-INFERENCE_BACKEND=${raw} failed validation}. Fix $STACK_DIR/.env and re-run"
        return 0
    }
    row OK "INFERENCE_BACKEND=${raw} (${plat}; old backend containers: ${old:-none}, stopped in section 1)"
    case "$plat $old" in
        amd*ollama*) row NOTE "AMD no longer runs Ollama: section 1 removes the container; models stay in /var/lib/ollama, OpenWebUI must be switched to Lemonade (step 4 of $NOTES)" ;;
    esac
}

# --- 1. Old compose projects --------------------------------------------------
step_projects() {
    local m old n
    echo "== 1. Old compose projects (down, volumes kept)"
    for m in "${MOVES[@]}"; do
        old="${m%%|*}"
        n="$(docker ps -a -q --filter "label=com.docker.compose.project=$old" | wc -l | tr -d ' ')"
        if [ "$n" -eq 0 ]; then
            row GONE "$old"
        elif [ "$1" = plan ]; then
            pending=$((pending + 1))
            row DOWN "$old (${n} containers)"
        else
            # No compose file: start from / so compose does not find another file up the tree; COMPOSE_* must not leak in either.
            ( cd / && env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME docker compose -p "$old" down ) >/dev/null \
                || fail "docker compose -p $old down failed; fix it and re-run this script"
            row DOWNED "$old"
        fi
    done
}

# --- 2. Named volumes ---------------------------------------------------------
copy_volume() {
    local oldv="$1" newv="$2" np="$3" key="$4" c1 c2
    [ -z "$(docker ps -q --filter "volume=$oldv")" ] || fail "$oldv is still used by a running container - finish the down in section 1 first"
    helper_image
    docker volume create --label "com.docker.compose.project=$np" --label "com.docker.compose.volume=$key" \
        --label "$MARK=$oldv" "$newv" >/dev/null || fail "Creating $newv failed"
    docker run --rm --network none --entrypoint sh -v "$oldv":/from:ro -v "$newv":/to "$HELPER_IMG" \
        -c "touch /to/$COPYING && cp -a /from/. /to/" \
        || { docker volume rm "$newv" >/dev/null 2>&1; fail "Copying $oldv → $newv failed (the incomplete $newv was removed)"; }
    c1="$(count_files "$oldv")"; c2="$(count_files "$newv")"
    if [ -z "$c1" ] || [ "$c1" != "$c2" ]; then
        docker volume rm "$newv" >/dev/null 2>&1
        fail "File counts differ ($oldv=$c1, $newv=$c2; $newv was removed)"
    fi
    docker run --rm --network none --entrypoint sh -v "$newv":/d "$HELPER_IMG" -c "rm -f /d/$COPYING" \
        || fail "Removing the copying marker of $newv failed (the data is fully copied; fix it and re-run this script)"
    row COPIED "$oldv → $newv (${c1} files; old volume kept)"
}

step_volumes() {
    local v op np key oldv newv from
    echo "== 2. Named volumes (copied to the new project name, old ones kept)"
    if vol_exists "$NOCOPY_VOL"; then
        row SKIP "$NOCOPY_VOL (the sandbox runner's image cache, not moved: cp -a drops overlayfs xattrs; the new volume pulls the image again on start)"
    fi
    for v in "${VOLUMES[@]}"; do
        op="${v%%|*}"; np="${v#*|}"; np="${np%%|*}"; key="${v##*|}"
        oldv="${op}_${key}" newv="${np}_${key}"
        if ! vol_exists "$oldv"; then
            row SKIP "$oldv (does not exist)"
            continue
        fi
        if vol_exists "$newv"; then
            from="$(docker volume inspect -f "{{index .Labels \"$MARK\"}}" "$newv" 2>/dev/null)"
            if [ "$from" != "$oldv" ]; then
                conflict=$((conflict + 1))
                row CONFLICT "$newv exists but was not copied by this script (was the new module deployed first?). Once sure it holds nothing to keep: down that module, docker volume rm $newv, re-run this script"
                continue
            fi
            helper_image
            copying_state "$newv"
            if [ "$COPY_STATE" = "done" ]; then
                row DONE "$oldv → $newv (copy finished)"
                DONE_VOLS+=("$oldv")
                continue
            fi
            # Once a container has mounted it, it may hold new data: never delete it automatically.
            if [ -n "$(docker ps -a -q --filter "volume=$newv")" ]; then
                conflict=$((conflict + 1))
                row CONFLICT "The last copy to $newv did not finish, but a container already mounts it - not deleted automatically. Once sure it holds nothing to keep: down that module, docker volume rm $newv, re-run this script"
                continue
            fi
            if [ "$1" = plan ]; then
                pending=$((pending + 1))
                row COPY "$oldv → $newv (the last copy did not finish; $newv will be deleted and copied again)"
                continue
            fi
            docker volume rm "$newv" >/dev/null || fail "Removing the incomplete $newv failed"
        elif [ "$1" = plan ]; then
            # Check and cache in plan: apply's section 1 downs the old 03's redis, so finding no image only in section 2 would stop half-way.
            helper_image
            pending=$((pending + 1))
            row COPY "$oldv → $newv"
            continue
        fi
        copy_volume "$oldv" "$newv" "$np" "$key"
        DONE_VOLS+=("$oldv")
    done
}

# --- 3. Module-level .env (gitignored, git pull does not move it) -------------
without_moved_ollama() {
    local ol="$STACK_DIR/$OLLAMA_ENV"
    if [ -f "$ol" ]; then grep -vxFf <(grep -E "$OLLAMA_RE" "$ol" || true) "$1" || true; else cat "$1"; fi
}

step_env() {
    local m old new src dst
    echo "== 3. Module-level .env"
    for m in "${MOVES[@]}"; do
        old="${m%%|*}"; new="${m#*|}"
        src="$STACK_DIR/$old/.env"; dst="$STACK_DIR/$new/.env"
        [ -f "$src" ] || continue
        if [ -f "$dst" ]; then
            # Lines 3b already moved to 03-ai-core/ollama/.env (verbatim) do not count; OLLAMA_* only in the old file do, or they would be dropped as "old, can be deleted".
            if cmp -s <(without_moved_ollama "$src") <(without_moved_ollama "$dst"); then
                row DONE "$old/.env (same as $new/.env, the old one can be deleted)"
            else
                conflict=$((conflict + 1))
                row CONFLICT "$old/.env and $new/.env both exist and differ - merge by hand into $new/.env (OLLAMA_* into $OLLAMA_ENV), delete the old one, re-run"
            fi
            continue
        fi
        if [ "$1" = plan ]; then
            pending=$((pending + 1))
            row MOVE "$old/.env → $new/.env"
        else
            mv "$src" "$dst" || fail "Moving $src failed"
            row MOVED "$old/.env → $new/.env"
        fi
        # redis moved to 02: a REDIS_IMAGE in the old 03's module .env no longer applies to the redis container.
        if [ "$old" = "03-ai-interface-ollama-openwebui-redis" ] && grep -qE '^[[:space:]]*REDIS_IMAGE=' "${dst}" "${src}" 2>/dev/null; then
            echo "            ⚠️ This .env has REDIS_IMAGE: redis moved to 02-database; to keep it in effect move it to the stack .env or 02-database-postgres-pgadmin/.env"
        fi
    done
}

# --- 3b. OLLAMA_* from 04 to 03-ai-core/ollama --------------------------------
# Look at "the file that will become 04's .env": in plan the old 03's .env may not have moved yet. Also handles one that already moved.
step_ollama_env() {
    local f src="$STACK_DIR/03-ai-interface-ollama-openwebui-redis/.env" owui="$STACK_DIR/$OWUI_ENV" dst="$STACK_DIR/$OLLAMA_ENV"
    local line key cur add=() tmp
    echo "== 3b. OLLAMA_* → $OLLAMA_ENV"
    f="$owui"; [ "$1" = plan ] && [ -f "$src" ] && [ ! -f "$owui" ] && f="$src"
    if [ ! -f "$f" ] || ! grep -qE "$OLLAMA_RE" "$f"; then
        row GONE "$OWUI_ENV has no OLLAMA_*"
        return 0
    fi
    # Same variable with different values on both sides: do not guess.
    while IFS= read -r line; do
        key="${line%%=*}"; key="${key##* }"; key="${key#"${key%%[![:space:]]*}"}"
        cur="$( [ -f "$dst" ] && grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$dst" || true)"
        if [ -z "$cur" ]; then
            add+=("$line")
        elif ! printf '%s\n' "$cur" | grep -qxF -- "$line"; then
            conflict=$((conflict + 1))
            row CONFLICT "$key differs between $OWUI_ENV and $OLLAMA_ENV - merge it into $OLLAMA_ENV by hand, delete it from $OWUI_ENV, re-run"
            return 0
        fi
    done < <(grep -E "$OLLAMA_RE" "$f")
    if [ "$1" = plan ]; then
        pending=$((pending + 1))
        row MOVE "$(grep -cE "$OLLAMA_RE" "$f") OLLAMA_* lines → $OLLAMA_ENV (${#add[@]} of them new)"
        return 0
    fi
    if [ "${#add[@]}" -gt 0 ]; then
        printf '%s\n' "${add[@]}" >> "$dst" || fail "Writing $dst failed"
    fi
    # cat > the original file: keeps the .env's mode and owner.
    tmp="$(mktemp)" || fail "mktemp failed"
    { grep -vE "$OLLAMA_RE" "$owui" || true; } > "$tmp" && cat "$tmp" > "$owui" || { rm -f "$tmp"; fail "Rewriting $owui failed (OLLAMA_* is already in $dst; fix it and re-run this script)"; }
    rm -f "$tmp"
    row MOVED "OLLAMA_* → $OLLAMA_ENV (${#add[@]} lines added; comments above them stay in $OWUI_ENV)"
}

# --- 4. RAG cron (the crontab hard-codes the old absolute path) ---------------
next_platform() {
    local arch; arch=$(uname -m)
    if [ -n "${TIGER_PLATFORM:-}" ]; then echo "$TIGER_PLATFORM"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then echo arm64
    elif command -v nvidia-smi >/dev/null 2>&1; then echo nvidia
    elif command -v rocm-smi >/dev/null 2>&1 || command -v amd-smi >/dev/null 2>&1 || [ -e /dev/kfd ]; then echo amd
    fi
}

# setup-cron.sh's one @reboot entry, counted at the new module path.
new_cron_count() {
    crontab -l 2>/dev/null | grep -F "/$NEW_RAG/" | grep -c 'monitor_device\.py'
}

# State is judged only by "what it looks like now": old path present → remove, new path missing → install; a re-run after a failure always completes it.
step_host() {
    local n m plat venv="$STACK_DIR/$NEW_RAG/.venv/bin/python3"
    echo "== 4. RAG cron"
    [ "$(id -u)" -eq 0 ] || echo "            ⚠️ Not root: the crontab below is yours, not root's; run with sudo"

    n="$(crontab -l 2>/dev/null | grep -cF "/$OLD_RAG/")"
    if [ "${n:-0}" -eq 0 ]; then
        row GONE "crontab has no entry with the old path"
    elif [ "$1" = plan ]; then
        pending=$((pending + 1))
        row CRON "remove ${n} @reboot entries with the old path"
    else
        # grep -v returns 1 when nothing else is left; that is not a failure.
        { crontab -l 2>/dev/null | grep -vF "/$OLD_RAG/" || true; } | crontab - || fail "Rewriting the crontab failed"
        row FIXED "removed ${n} @reboot entries with the old path"
    fi

    m="$(new_cron_count)"
    if [ "${m:-0}" -ge 1 ]; then
        row DONE "crontab already has the @reboot entry of $NEW_RAG"
    elif [ ! -x "$venv" ] && { [ "$1" = apply ] || [ "$NEED_PLATFORM" -eq 0 ]; }; then
        # Without .venv it cannot be installed; 06's deploy.sh all creates .venv, then master-deploy.sh all installs the cron.
        row LATER "$NEW_RAG has no .venv yet; the cron is installed by master-deploy.sh all (step 3 of $NOTES)"
    elif [ "$1" = plan ]; then
        pending=$((pending + 1)); NEED_PLATFORM=1
        row CRON "install the @reboot entry of $NEW_RAG (now ${m:-0}/1)"
    else
        plat="$(next_platform)"
        TIGER_PLATFORM="$plat" bash "$STACK_DIR/$NEW_RAG/deploy.sh" cron \
            || fail "Installing the cron of $NEW_RAG failed (the new path is still missing; fix it and re-run this script, it installs again)"
        row FIXED "cron now uses the $NEW_RAG path"
    fi
}

# --- 5. Old things that can be deleted (printed only) -------------------------
step_leftovers() {
    local m old d v
    echo "== 5. Old things you can delete (once the new version is stable, by hand)"
    for m in "${MOVES[@]}"; do
        old="${m%%|*}"; d="$STACK_DIR/$old"
        [ -d "$d" ] || continue
        if [ -f "$d/.env" ]; then
            row KEEP "$d (still has a .env; handle section 3 first)"
        else
            row OLD "$d ($(ls -A "$d" | tr '\n' ' '))"
            printf '            # sudo rm -rf %q\n' "$d"
        fi
    done
    if vol_exists "$NOCOPY_VOL"; then
        row OLD "volume $NOCOPY_VOL (the cache that is not moved)"
        printf '            # docker volume rm %s\n' "$NOCOPY_VOL"
    fi
    for v in ${DONE_VOLS[@]+"${DONE_VOLS[@]}"}; do
        row OLD "volume $v"
        printf '            # docker volume rm %s\n' "$v"
    done
}

run_all() {
    DONE_VOLS=()
    step_projects "$1"; echo
    step_volumes "$1"; echo
    step_env "$1"; echo
    step_ollama_env "$1"; echo
    step_host "$1"; echo
}

echo "#### plan"
step_backend; echo
run_all plan
if [ "$APPLY" -eq 0 ]; then
    step_leftovers
    echo
    if [ "$pending" -eq 0 ] && [ "$conflict" -eq 0 ]; then
        echo "Nothing pending. Next: step 2 of $NOTES (deploy 03-ai-core)."
        exit 0
    fi
    [ "$pending" -gt 0 ] && echo "${pending} item(s) pending. Once checked, run: sudo bash $0 --apply"
    [ "$conflict" -gt 0 ] && echo "${conflict} CONFLICT(s) need a human (see above); re-run this script once handled."
    exit 1
fi

# Any CONFLICT means nothing is done, so it never stops half-way (e.g. services down but volumes not movable).
if [ "$conflict" -gt 0 ]; then
    echo "${conflict} CONFLICT(s); --apply did nothing. Re-run this script once handled."
    exit 1
fi
# The platform is decided before acting: if it cannot be told, nothing is done, so it never leaves "old cron removed, new one not installed".
if [ "$NEED_PLATFORM" -eq 1 ] && [ -z "$(next_platform)" ]; then
    fail "Cannot tell the platform; --apply did nothing. Re-run with TIGER_PLATFORM={amd|nvidia|arm64}"
fi
echo "#### apply"
run_all apply
step_leftovers
echo
echo "Done. Next: step 2 of $NOTES deploys 03-ai-core (the backend INFERENCE_BACKEND selects), step 3 runs master-deploy.sh all (02 brings up the new redis)."
exit 0
