#!/usr/bin/env bash
# register-late-guid.sh — Crash-safe background registration helper
# Spawned detached by __cm_invoke_claude_launch for genuinely-new sessions.
# Polls for a new JSONL file and registers it in sessions.txt if the main
# process died before it could. See spec Section 14.5.

proj_dir_claude="$1"
project_dir="$2"
desc="$3"
sessions_file="$4"
lock_file="$5"
before_csv="$6"

interval=30
total_window=300
uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

is_in_before() {
    [[ -z "$before_csv" ]] && return 1
    local IFS=','
    local g
    for g in $before_csv; do
        [[ "$g" == "$1" ]] && return 0
    done
    return 1
}

elapsed=0
new_guid=""

while (( elapsed < total_window )); do
    sleep "$interval"
    elapsed=$((elapsed + interval))
    [[ -d "$proj_dir_claude" ]] || continue
    for f in "$proj_dir_claude"/*.jsonl; do
        [[ -f "$f" ]] || continue
        bn=$(basename "$f" .jsonl)
        [[ "$bn" =~ $uuid_re ]] || continue
        is_in_before "$bn" && continue
        new_guid="$bn"
        break
    done
    [[ -n "$new_guid" ]] && break
done

[[ -z "$new_guid" ]] && exit 0

# Acquire lock (10s timeout, same lock file as main script)
exec 9>>"$lock_file" 2>/dev/null || exit 0
lock_tries=0
locked=0
while (( lock_tries < 50 )); do
    if flock -n 9 2>/dev/null; then locked=1; break; fi
    sleep 0.2
    lock_tries=$((lock_tries + 1))
done
if (( ! locked )); then
    exec 9>&- 2>/dev/null
    exit 0
fi

# Re-check under lock: skip if main process already registered it
if grep -q "^${new_guid}|" "$sessions_file" 2>/dev/null; then
    exec 9>&- 2>/dev/null
    exit 0
fi

# Atomic prepend: new entry at top, preserve everything else (including [archived])
tmp_file="${sessions_file}.late-tmp"
{
    printf '%s\n' "${new_guid}|${project_dir}|${desc}|"
    cat "$sessions_file" 2>/dev/null
} > "$tmp_file" && mv -f "$tmp_file" "$sessions_file"

exec 9>&- 2>/dev/null
exit 0
