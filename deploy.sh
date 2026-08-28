#!/usr/bin/env bash
# deploy.sh - Install/update ClaudeCM runtime files on Linux.
#
# Idempotent: safe to re-run after every `git pull`. Byte-identical files
# are skipped, changed files get a timestamped backup in ~/.claudecm/backup/
# before being overwritten.
#
# Files this script owns:
#   ~/.claudecm/extract-skeleton.mjs
#   ~/.claudecm/register-late-guid.sh
#   /usr/local/bin/claudecm  (from claudecm-linux.sh; requires sudo)
#
# Files this script does NOT touch:
#   ~/.bashrc or profile fragments (initial setup only, per docs/install.md)
#   ~/.claudecm/sessions.txt, machine-name.txt, notes/, backup/
#
# There is no bgcolor.sh yet. When one is written, add it to $claudecm_files.
#
# Usage (from the repo root):
#   ./deploy.sh

set -e

repo_root="$(cd "$(dirname "$0")" && pwd)"
cm_dir="$HOME/.claudecm"
backup_dir="$cm_dir/backup"
stamp="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$cm_dir" "$backup_dir"

claudecm_files=(
    extract-skeleton.mjs
    register-late-guid.sh
)

copied=()
skipped=()

for f in "${claudecm_files[@]}"; do
    src="$repo_root/$f"
    dst="$cm_dir/$f"
    if [[ ! -f "$src" ]]; then
        echo "  MISSING in repo: $f (skipped)"
        continue
    fi
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        skipped+=("$f")
        continue
    fi
    if [[ -f "$dst" ]]; then
        cp "$dst" "$backup_dir/$f.$stamp.pre-deploy"
    fi
    cp "$src" "$dst"
    copied+=("$f")
done

# register-late-guid.sh must be executable.
[[ -f "$cm_dir/register-late-guid.sh" ]] && chmod +x "$cm_dir/register-late-guid.sh"

# The main script lives at /usr/local/bin/claudecm and needs sudo.
main_src="$repo_root/claudecm-linux.sh"
main_dst="/usr/local/bin/claudecm"

if [[ ! -f "$main_src" ]]; then
    echo "  MISSING in repo: claudecm-linux.sh"
elif [[ -f "$main_dst" ]] && cmp -s "$main_src" "$main_dst"; then
    skipped+=("claudecm-linux.sh -> $main_dst")
else
    echo ""
    echo "  Installing $main_dst (requires sudo)..."
    if [[ -f "$main_dst" ]]; then
        sudo cp "$main_dst" "$backup_dir/claudecm.$stamp.pre-deploy"
    fi
    sudo cp "$main_src" "$main_dst"
    sudo chmod +x "$main_dst"
    copied+=("claudecm-linux.sh -> $main_dst")
fi

echo ""
if [[ ${#copied[@]} -gt 0 ]]; then
    echo "  Deployed:"
    for f in "${copied[@]}"; do echo "    - $f"; done
else
    echo "  Nothing to do -- all files already match the repo."
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
    echo "  Unchanged: ${skipped[*]}"
fi

echo ""
echo "  Backups (if written): $backup_dir/*.pre-deploy"
echo "  Open a new shell to pick up changes."
