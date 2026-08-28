# Statusline: the little gas gauges

The bar along the bottom of the terminal, showing context usage and rate-limit
gauges, is not part of ClaudeCM and not something Claude Code ships with. It is
**claude-hud**, a Claude Code plugin by
[Jarrod Watts](https://github.com/jarrodwatts/claude-hud).

It renders a compact HUD from the JSON that Claude Code feeds its statusline
command on stdin: model name, a context-window bar, session usage against the
5-hour and weekly limits, tool activity, and todo progress.

It is included here because it belongs to the same category as the rest of the
stack: small tools that make long multi-project sessions survivable. It is
independent of ClaudeCM and either can be used without the other.

---

## Setting up a new machine, in order

The whole sequence, because the pieces have to happen in this order and
`deploy` only does the last one:

    claude plugin marketplace add jarrodwatts/claude-hud
    claude plugin install claude-hud@claude-hud
    # restart Claude Code, then inside it:
    /claude-hud:setup
    # then, from the repo:
    .\deploy.ps1          # Windows   (or ./deploy.sh on Linux)

`deploy` runs `configure-hud`, which sets the weekly-bar threshold and the
first-turn snapshot described below. Running it before the plugin exists is
harmless: it writes the config, then tells you exactly what is still missing
rather than claiming the bar will show.

After `/claude-hud:setup`, check `settings.json` for an absolute node path and
replace it with plain `node`. See the warning at the end of the next section.

---

## Install

Three commands, then restart Claude Code.

    claude plugin marketplace add jarrodwatts/claude-hud
    claude plugin install claude-hud@claude-hud
    claude plugin list

Then wire it to the statusline. The plugin ships a command that does it for you:

    /claude-hud:setup

If you would rather set it by hand, or want to know what that command wrote,
it adds a `statusLine` key to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "bash -c 'plugin_dir=$(ls -d \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/plugins/cache/claude-hud/claude-hud/*/ 2>/dev/null | awk -F/ '\"'\"'{ print $(NF-1) \"\\t\" $(0) }'\"'\"' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-); exec node \"${plugin_dir}dist/index.js\"'"
}
```

The glob-and-sort is doing real work: plugin upgrades leave the old version
directory in place, so the command lists every installed version, sorts the
dotted parts numerically, and takes the highest. Without the numeric sort a
plain string sort puts `0.0.12` after `0.8.0` and you would silently keep
running the old build after every update.

**Use plain `node`, not an absolute path.** The setup command may write the
full path to whichever node it found, for example
`"/c/Program Files/nodejs/node"`. That works on the machine it was generated on
and nowhere else: it is a Git-Bash-style path, so it breaks on Linux outright
and on any Windows box with node installed somewhere else. If node is on your
PATH, plain `node` is portable and behaves identically.

To display options, run `/claude-hud:configure`. With no config file present it
runs on defaults, which is a perfectly good place to leave it.

---

## Updating

Plugins do not update themselves.

    claude plugin marketplace update claude-hud
    claude plugin update claude-hud@claude-hud

**Restart Claude Code afterwards**; the running process keeps the old build
loaded. Verify what you actually got:

    ls ~/.claude/plugins/cache/claude-hud/claude-hud/

More than one directory is normal and harmless. The statusline command picks
the highest version, and the older directory is a usable fallback.

Worth checking occasionally rather than assuming. Nothing warns you that the
plugin is stale, and it is easy to sit several versions behind for months
without noticing, since an old build still renders a perfectly convincing HUD.

---

## The weekly bar disappears in 0.8.0, and that is deliberate

If you had the weekly usage bar and it vanished after upgrading, nothing is
broken. `src/render/lines/usage.ts` decides it like this:

```ts
const sevenDayPart = (sevenDay !== null
    && (fiveHour === null || sevenDay >= sevenDayThreshold))
```

`display.sevenDayThreshold` defaults to **80**. The 5-hour figure is almost
always present, so in practice the weekly bar stays hidden until you have burned
80% of your week, which is roughly the point at which it stops being useful for
planning and starts being an alarm.

Setting the threshold to **0** shows it always. Run:

    ./configure-hud.ps1        # Windows
    ./configure-hud.sh         # Linux, macOS

`deploy.ps1` and `deploy.sh` call it for you, so a normal deploy already does
this. Both scripts merge into any existing `claude-hud.json` rather than
replacing it, so settings made with `/claude-hud:configure` survive, and both
back the file up first. Both are idempotent, and `-WhatIfOnly` / `--what-if`
shows what would change without writing.

### Why it is a generated script and not a config file in the repo

The same script also wires the **external usage snapshot**, which is what makes
the gauges appear on the very first turn instead of after the first response:

```json
"externalUsagePath":       "<abs>/.claude/claude-hud-usage.json",
"externalUsageWritePath":  "<abs>/.claude/claude-hud-usage.json",
"externalUsageFreshnessMs": 604800000
```

Point the read and write paths at one file and every render that has real data
leaves a snapshot behind, which the next new window reads immediately. Freshness
is seven days because the default of five minutes defeats the purpose: the whole
point is a snapshot surviving from the previous session, possibly yesterday.

**Those paths must be absolute and are stored verbatim.** `validateOptionalPath`
in `src/config.ts` is a `trim()` and nothing else. There is no `~` expansion and
no environment expansion, and a `~/...` path **fails silently**, writing nothing
anywhere and reporting no error. That is precisely why this is generated per
machine rather than committed as a fixed file: a checked-in config would carry
one machine's home directory and quietly do nothing everywhere else.

**Be clear about what the first-turn numbers are.** They are the LAST KNOWN
figures, not live ones. If you have been away a day, the weekly figure is
yesterday's until the first real response lands, at which point it corrects
itself. For a slow-moving weekly window that is a better answer than a blank
bar, but it is a cached number and you should know that rather than discover it.

---

## Known behaviour, not a fault

**Without the snapshot configured above, a fresh window shows only the context
bar; the 5-hour and weekly gauges appear after the first response.**

This is by design and will not be fixed, because it is not broken. Usage
figures come from the `rate_limits` block that Claude Code passes to the
statusline command on stdin, and before the first API call of a session there
is no such block to read. Earlier versions polled OAuth in the background to
fill the gap; that was removed in favour of relying only on Claude Code's
official stdin fields, which is the more honest design. The cost is a few
seconds of empty gauges at startup, and the snapshot above is the supported way
to paper over it.

---

## If it stops rendering

Run the statusline command by hand. It reads JSON on stdin and writes the HUD
to stdout, so it can be tested outside Claude Code:

    plugin_dir=$(ls -d ~/.claude/plugins/cache/claude-hud/claude-hud/*/ | sort -V | tail -1)
    echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"},"transcript_path":""}' \
      | node "${plugin_dir}dist/index.js"

A HUD line means the plugin is fine and the problem is in the `settings.json`
wiring. An error names the cause directly, usually node not being found or a
version directory that no longer exists after an upgrade.
