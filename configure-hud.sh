#!/usr/bin/env bash
# configure-hud.sh - make the claude-hud statusline always show the weekly bar.
#
# Linux/macOS counterpart of configure-hud.ps1. Same reasoning, same result.
#
# WHY THIS EXISTS
#
# claude-hud 0.8.0 hides the weekly (7-day) usage bar unless it is at or above
# display.sevenDayThreshold, which defaults to 80. The 5-hour bar is almost
# always present, so in practice the weekly bar stays invisible until you have
# burned 80% of your week, which is roughly when it stops being useful as a
# planning aid. From src/render/lines/usage.ts:
#
#     const sevenDayPart = (sevenDay !== null
#         && (fiveHour === null || sevenDay >= sevenDayThreshold))
#
# Threshold 0 shows it always.
#
# It also wires the external usage snapshot. claude-hud reads its figures from
# the rate_limits block Claude Code passes on stdin, and there is none before
# the first API response, so a fresh window opens with empty gauges. Pointing
# the read and write paths at one file makes every render with real data leave
# a snapshot that the next new window picks up immediately.
#
# Those first-turn numbers are LAST KNOWN, not live. They correct themselves on
# the first real response. Better than a blank bar for a slow weekly window, but
# it is a cached figure and worth knowing.
#
# WHY IT IS GENERATED RATHER THAN COMMITTED
#
# claude-hud stores the path verbatim: validateOptionalPath in src/config.ts is
# a trim and nothing more. There is no tilde or environment expansion, and a
# "~/..." path fails SILENTLY, writing nothing anywhere. So the absolute path
# has to be produced on the machine it will run on.
#
# Existing settings are merged, never replaced, so anything set through
# /claude-hud:configure survives. The previous file is backed up first.
#
# Usage:
#   ./configure-hud.sh                 # apply
#   ./configure-hud.sh --what-if       # report only, write nothing
#   ./configure-hud.sh --no-snapshot   # threshold only
#   ./configure-hud.sh --keep-threshold

set -uo pipefail

what_if=0
no_snapshot=0
keep_threshold=0
for arg in "$@"; do
    case "$arg" in
        --what-if)        what_if=1 ;;
        --no-snapshot)    no_snapshot=1 ;;
        --keep-threshold) keep_threshold=1 ;;
        -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "  unknown option: $arg" >&2; exit 2 ;;
    esac
done

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ ! -d "$claude_dir" ]]; then
    echo "  Claude config dir not found: $claude_dir"
    echo "  Is Claude Code installed for this user? Nothing written."
    exit 0
fi

hud_config="$claude_dir/claude-hud.json"
snapshot="$claude_dir/claude-hud-usage.json"

# node is not an extra dependency here: claude-hud is a node program, so if it
# runs at all, node exists. Using it for the merge avoids depending on jq.
if ! command -v node >/dev/null 2>&1; then
    echo "  node not found on PATH. claude-hud itself needs node, so this is"
    echo "  worth fixing regardless. Nothing written."
    exit 1
fi

backup_dir="$HOME/.claudecm/backup"
mkdir -p "$backup_dir" 2>/dev/null

CFG="$hud_config" SNAP="$snapshot" BACKUP_DIR="$backup_dir" \
WHAT_IF="$what_if" NO_SNAPSHOT="$no_snapshot" KEEP_THRESHOLD="$keep_threshold" \
node <<'NODEJS'
const fs = require('node:fs');
const path = require('node:path');

const cfgPath  = process.env.CFG;
const snapPath = process.env.SNAP;
const whatIf   = process.env.WHAT_IF === '1';

let existing = {};
if (fs.existsSync(cfgPath)) {
  try {
    existing = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  } catch (e) {
    console.log('  Existing ' + cfgPath + ' is not valid JSON.');
    console.log('  Refusing to overwrite it. Fix or remove it, then re-run.');
    process.exit(0);
  }
  if (existing === null || typeof existing !== 'object' || Array.isArray(existing)) {
    console.log('  Existing ' + cfgPath + ' is not a JSON object. Refusing to overwrite.');
    process.exit(0);
  }
}
if (!existing.display || typeof existing.display !== 'object') existing.display = {};

const desired = {};
if (process.env.KEEP_THRESHOLD !== '1') desired.sevenDayThreshold = 0;
if (process.env.NO_SNAPSHOT !== '1') {
  desired.externalUsagePath = snapPath;
  desired.externalUsageWritePath = snapPath;
  // Seven days. The 5-minute default is useless here: the point is a snapshot
  // surviving from the previous session, possibly yesterday.
  desired.externalUsageFreshnessMs = 604800000;
}

const keys = Object.keys(desired);
if (keys.length === 0) { console.log('  Nothing to do (both features opted out).'); process.exit(0); }

const changes = keys
  .filter(k => existing.display[k] !== desired[k])
  .map(k => '    ' + k + ' : '
     + (existing.display[k] === undefined ? '(unset)' : existing.display[k])
     + ' -> ' + desired[k]);

if (changes.length === 0) { console.log('  claude-hud already configured; no change.'); process.exit(0); }

console.log('  claude-hud config: ' + cfgPath);
changes.forEach(c => console.log(c));
if (whatIf) { console.log('  (--what-if: nothing written)'); process.exit(0); }

if (fs.existsSync(cfgPath)) {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
  try {
    fs.copyFileSync(cfgPath, path.join(process.env.BACKUP_DIR, 'claude-hud.json.' + stamp + '.pre-deploy'));
  } catch (e) { /* a missing backup dir must not block the fix */ }
}

for (const k of keys) existing.display[k] = desired[k];
fs.writeFileSync(cfgPath, JSON.stringify(existing, null, 2) + '\n', 'utf8');

// Read back from DISK rather than announcing the intention to write. Same
// reasoning as ensure_cleanup_period_days in the main module: a message the
// user cannot verify is worse than no message at all.
let ok = false;
try {
  const after = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  ok = keys.every(k => after.display && after.display[k] === desired[k]);
} catch (e) { ok = false; }

if (ok) {
  console.log('  Weekly usage bar will now always show.');
  if (process.env.NO_SNAPSHOT !== '1') {
    console.log('  Gauges will also appear on the first turn, from the last snapshot.');
  }
  console.log('  Takes effect on the next statusline render; no restart needed.');
} else {
  console.log('  WARNING: wrote ' + cfgPath + ' but could not verify it read back correctly.');
  process.exitCode = 1;
}
NODEJS
