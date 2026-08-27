# REVERT-CLAUDECM.md

**Read this if ClaudeCM has started misbehaving since 2026-08-27.**

You are probably a fresh Claude instance with no memory of the deployment. This
document is written so you can undo it without knowing anything else. Bob does
not need to explain the background to you; it is all below.

Everything here is a local file operation. Nothing needs the network, GitHub, or
any credential.

---

## The one-minute version

A deployment on **2026-08-27** replaced two files in `C:\Users\Bob\.claudecm\`.
The previous versions were backed up first. To undo it completely:

```
Copy-Item "C:\Users\Bob\.claudecm\pre-deploy-backup-20260827-120019\claudecm-powershell.ps1" "C:\Users\Bob\.claudecm\claudecm-powershell.ps1" -Force
Copy-Item "C:\Users\Bob\.claudecm\pre-deploy-backup-20260827-120019\register-late-guid.ps1"  "C:\Users\Bob\.claudecm\register-late-guid.ps1"  -Force
```

Then open a new PowerShell window, or run `. $PROFILE` in the current one.
**The change does not take effect until you do that**, because the profile
dot-sources the script once at startup.

Verify the revert worked:

```
(Get-Item "C:\Users\Bob\.claudecm\claudecm-powershell.ps1").Length    # 80369 = reverted, 86264 = still deployed
```

If the backup folder name above does not exist, list what does:

```
Get-ChildItem "C:\Users\Bob\.claudecm\pre-deploy-backup-*" -Directory
```

---

## What was deployed, and why the backup matters more than usual

`C:\Users\Bob\Documents\GitHub\claudecm-stack\` is the source of truth. The
script that actually **runs** is the deployed copy at
`C:\Users\Bob\.claudecm\claudecm-powershell.ps1`. Editing the repo changes
nothing until someone copies it across. That had not been done since **27 July
2026**, so this deployment carried a month of accumulated work, not just one
day's.

Two files changed:

| file | before | after |
|---|---|---|
| `claudecm-powershell.ps1` | 80,369 bytes, 27 Jul | 86,264 bytes, 27 Aug |
| `register-late-guid.ps1` | 2,062 bytes | 2,122 bytes |

`register-late-guid.ps1` differed **only in line endings** (LF vs CRLF). Its
behaviour is unchanged, so it is almost certainly not your problem.

**Important, and the reason the backup is the only safe route:** the previous
live `claudecm-powershell.ps1` matched **no commit in the repository's history**
(all 20 commits touching that file were checked). It carried local edits that
were never committed. So you cannot reconstruct it with `git checkout`. The file
backup is the only way back. Do not delete the backup folder.

The three commits that landed:

- `3c33eca` Confirm before creating a new project from list mode
- `8dda2ae` Add `-s` search, and stop one variable meaning two directories
- `135a555` `ensure_cleanup_period_days`: verify before announcing

147 lines changed in total. No functions were added or removed.

---

## The local tweak, and why the deployed file is not identical to the repo

The deployed copy differs from the repo by exactly **one line**, on purpose.

Line 22 of `claudecm-powershell.ps1` is:

```powershell
$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = "0"    # LOCAL TWEAK, see REVERT-CLAUDECM.md
```

In the repository that line is **commented out**, deliberately. Commit
`98c040a` made it opt-in because it is a personal preference and this repo is
public. That commit's own message warns that script updates overwrite the
runtime copy and the tweak has to be re-applied afterwards. It was re-applied as
part of this deployment.

`0` disables Claude Code's CLI suggested-prompt hints, the "do you want to..."
follow-ups. Bob wants them off. It is a binary-confirmed environment variable,
set here since 2026-05-20. Also documented in `docs/install.md`.

**If you ever redeploy from the repo, you must uncomment line 22 again**, or the
suggested prompts silently come back. That near-miss is the reason this document
exists.

---

## If only part of it is wrong

You do not have to revert everything. The three changes are independent.

**Suggested prompts have come back.** The tweak above was lost. Uncomment line
22 in `C:\Users\Bob\.claudecm\claudecm-powershell.ps1`, then reload the profile.
Do not change the repo copy.

**`claudecm -s <text>` misbehaves.** That flag is new in this deployment. It
filters the live list by name, case-insensitively, and does not search archived
sessions. It is read-only. Nothing else depends on it, so a full revert is safe
if it is causing trouble.

**A new project is created when you did not want one.** Commit `3c33eca` added a
confirmation before creating a project from list mode. If it is now confirming
when it should not, that commit is the one to look at.

**A message about `cleanupPeriodDays` or "Protected session transcripts".** That
is commit `135a555`. Before it, the function printed

```
Protected session transcripts from Claude Code's 30-day auto-delete.
```

unconditionally, even when the write had silently failed, so the user was told
their transcripts were safe when they were not. It now reads the value back off
disk and only says that if it is really `>= 1000`, warning explicitly otherwise.

At deploy time Bob's `cleanupPeriodDays` was already `100000`, so this function
returns immediately on his machine and should never print anything. **If it has
started printing a warning, that is a real finding, not a cosmetic one**: it
means something has since lowered or broken
`C:\Users\Bob\.claude\settings.json`. Check that file before reverting anything,
because the old code would have hidden the problem rather than fixed it.

---

## What was NOT touched

Reassurance, so you do not go looking:

- `sessions.txt` — not modified by the deployment.
- `machine-name.txt`, `notify.ps1`, `bgcolor.ps1`, `batch_guard.ps1`,
  `extract-skeleton.mjs` — untouched. `bgcolor.ps1` and `extract-skeleton.mjs`
  were already identical to the repo.
- `claudecm-linux.sh` and `register-late-guid.sh` — these exist only in the
  repo. They are for the Linux box and are **not** deployed on Windows. If you
  find yourself copying them into `.claudecm`, stop; that is wrong.
- `C:\Users\Bob\.claude\settings.json` — not modified.
- Nothing was deleted. Nothing was renamed.

---

## Verifying a healthy install

After any revert or redeploy, in a **new** PowerShell window:

```
claudecm -s zzzznotarealproject     # prints "No sessions matching '...'." and returns
claudecm                            # lists sessions; press q to quit
```

`-s` only exists in the deployed version. If you reverted and `-s` now creates a
project called `zzzznotarealproject` instead of searching, that is the old
behaviour and it is expected: the flag did not exist before 27 August.

Both were confirmed working immediately after this deployment, against the real
57-session list, with `sessions.txt` unmodified.

---

## Context, if you want it

The deployment followed a day of building test suites for both modules:
62 PowerShell tests and 40 bash tests, all passing, covering 32 of 32 PowerShell
functions. The `ensure_cleanup_period_days` fix came out of that work and was
approved by Bob before being made. Details in `tests/TESTPLAN.md` and
`LINUX-HANDOVER.md`.

The repo is clean and everything is pushed, so `git log` in
`C:\Users\Bob\Documents\GitHub\claudecm-stack\` will show you the full history
with reasoning in the commit messages.
