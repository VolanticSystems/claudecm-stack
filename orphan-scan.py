"""Fingerprint every JSONL under ~/.claude/projects and say which are orphans.

Read-only. Prints one block per project key dir that holds an unregistered file.
An orphan is a .jsonl with no row in ~/.claudecm/sessions.txt (or the archive).

    python orphan-scan.py            every key dir with an orphan
    python orphan-scan.py <substr>   only key dirs matching substr
    python orphan-scan.py --sweep <key-dir-name> [...]
                                          MOVE that key dir's orphans to the
                                          quarantine root, never delete, and
                                          write a MANIFEST.md beside them

Sweep refuses to touch any file whose guid has a row in sessions.txt, and
names each key dir explicitly: there is no "sweep everything" switch, because
the point of the review is to decide per directory.
"""
import io
import codecs
import json
import os
import sys
import time

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
SESSIONS = os.path.join(HOME, ".claudecm", "sessions.txt")


def registered_guids():
    """Every guid claudecm knows about: live rows and archived rows."""
    out = {}
    for path in (SESSIONS, SESSIONS + ".archive"):
        try:
            for line in io.open(path, encoding="utf-8"):
                parts = line.strip().split("|")
                if len(parts) >= 3 and len(parts[0]) == 36:
                    out[parts[0].lower()] = parts[2]
        except Exception:
            continue
    return out


def fingerprint(path):
    f = {"size": os.path.getsize(path), "records": 0, "user_msgs": 0,
         "session_id": "", "cwd": "", "version": "", "model": "",
         "first_user": "", "first_ts": "", "last_ts": "", "sidechain": False,
         "compactions": 0, "agent": False, "types": {}}
    try:
        for line in io.open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            f["records"] += 1
            t = r.get("type") or "?"
            f["types"][t] = f["types"].get(t, 0) + 1
            if not f["session_id"] and r.get("sessionId"):
                f["session_id"] = r["sessionId"]
            if not f["cwd"] and r.get("cwd"):
                f["cwd"] = r["cwd"]
            if not f["version"] and r.get("version"):
                f["version"] = r["version"]
            if r.get("isSidechain"):
                f["sidechain"] = True
            if r.get("compactMetadata"):
                f["compactions"] += 1
            if r.get("agentId") or r.get("agent_id"):
                f["agent"] = True
            ts = r.get("timestamp")
            if ts:
                if not f["first_ts"]:
                    f["first_ts"] = ts
                f["last_ts"] = ts
            msg = r.get("message") or {}
            if t == "assistant" and not f["model"] and msg.get("model"):
                f["model"] = msg["model"]
            if t == "user" and not r.get("isMeta"):
                content = msg.get("content")
                text = ""
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            text = c.get("text") or ""
                            break
                        if isinstance(c, dict) and c.get("type") == "tool_result":
                            text = ""
                            break
                if text.strip():
                    f["user_msgs"] += 1
                    if not f["first_user"]:
                        f["first_user"] = " ".join(text.split())[:220]
    except Exception as exc:
        f["error"] = str(exc)
    return f


QUARANTINE = os.path.join(HOME, "documents", "github",
                          "claude-conversation-backup",
                          "orphan-archive-" + time.strftime("%Y-%m-%d"))


def prune_index(key):
    """Drop sessions-index.json entries whose transcript is gone.

    This is what ClaudeCM's own quarantine path does by calling
    Sync-SessionIndex: the index is Claude Code's cache of what is in the key
    dir, and after a move its entries point at nothing.
    """
    path = os.path.join(PROJECTS, key, "sessions-index.json")
    if not os.path.exists(path):
        return
    try:
        with io.open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        entries = data.get("entries") or []
        kept = [e for e in entries if os.path.exists(
            os.path.join(PROJECTS, key, "%s.jsonl" % e.get("sessionId", "")))]
        if len(kept) == len(entries):
            return
        data["entries"] = kept
        with io.open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
        print("INDEX %s: %d -> %d entries" % (key, len(entries), len(kept)))
    except Exception as exc:
        print("INDEX %s: could not prune (%s)" % (key, exc))


def sweep(keys):
    """Move the named key dirs' orphans to the quarantine root. Never deletes."""
    reg = registered_guids()
    moved = []
    for key in keys:
        d = os.path.join(PROJECTS, key)
        if not os.path.isdir(d):
            print("SKIP  no such key dir: %s" % key)
            continue
        dest = os.path.join(QUARANTINE, key)
        for name in sorted(os.listdir(d)):
            if not name.endswith(".jsonl"):
                continue
            guid = name[:-6]
            if guid.lower() in reg:
                print("KEEP  %s\\%s  (registered: %s)" % (key, name, reg[guid.lower()]))
                continue
            f = fingerprint(os.path.join(d, name))
            os.makedirs(dest, exist_ok=True)
            os.replace(os.path.join(d, name), os.path.join(dest, name))
            side = os.path.join(d, guid)
            if os.path.isdir(side):
                os.replace(side, os.path.join(dest, guid))
            moved.append((key, name, f))
            print("MOVED %s\\%s  -> %s" % (key, name, dest))
        prune_index(key)
    if not moved:
        print("nothing moved.")
        return
    os.makedirs(QUARANTINE, exist_ok=True)
    man = os.path.join(QUARANTINE, "MANIFEST.md")
    new = not os.path.exists(man)
    with io.open(man, "a", encoding="utf-8") as fh:
        if new:
            fh.write("# Orphan archive %s\n\nMoved, never deleted. To restore a "
                     "file, move it back to\n`~/.claude/projects/<key dir>/` and "
                     "it reappears to Claude Code.\n" % time.strftime("%Y-%m-%d"))
        fh.write("\n## Swept %s\n\n" % time.strftime("%H:%M"))
        for key, name, f in moved:
            fh.write("### %s\n\n" % name)
            fh.write("- key dir: `%s`\n- size: %d B, %d records, %d user message(s)\n"
                     % (key, f["size"], f["records"], f["user_msgs"]))
            fh.write("- cwd: `%s`\n- version %s, model %s\n"
                     % (f["cwd"], f["version"] or "-", f["model"] or "-"))
            fh.write("- span: %s .. %s\n- first user message: %s\n\n"
                     % (f["first_ts"] or "-", f["last_ts"] or "-",
                        f["first_user"] or "(none)"))
    print("")
    print("moved %d file(s). Manifest: %s" % (len(moved), man))


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if len(sys.argv) > 1 and sys.argv[1] == "--sweep":
        if len(sys.argv) < 3:
            print("--sweep needs at least one key dir name")
            return
        return sweep(sys.argv[2:])
    want = (sys.argv[1] if len(sys.argv) > 1 else "").lower()
    reg = registered_guids()
    total_orphans = 0
    total_bytes = 0
    for key in sorted(os.listdir(PROJECTS)):
        d = os.path.join(PROJECTS, key)
        if not os.path.isdir(d):
            continue
        if want and want not in key.lower():
            continue
        files = [x for x in sorted(os.listdir(d)) if x.endswith(".jsonl")]
        if not files:
            continue
        orphans = [x for x in files if x[:-6].lower() not in reg]
        if not orphans and want == "":
            continue
        print("")
        print("=" * 78)
        print("%s   (%d file(s), %d orphan(s))" % (key, len(files), len(orphans)))
        for name in files:
            p = os.path.join(d, name)
            guid = name[:-6]
            is_orph = guid.lower() not in reg
            f = fingerprint(p)
            tag = "ORPHAN " if is_orph else "in sessions.txt: %s" % reg.get(guid.lower(), "")
            if is_orph:
                total_orphans += 1
                total_bytes += f["size"]
            print("  %-38s %9d B  %s" % (guid, f["size"], tag))
            print("      recs %-5d user-msgs %-4d sidechain %-5s compactions %d" % (
                f["records"], f["user_msgs"], f["sidechain"], f["compactions"]))
            print("      cwd     %s" % (f["cwd"] or "(none)"))
            print("      ver %-10s model %s" % (f["version"] or "-", f["model"] or "-"))
            print("      span    %s  ..  %s" % (f["first_ts"] or "-", f["last_ts"] or "-"))
            if f["session_id"] and f["session_id"] != guid:
                print("      *** internal sessionId %s differs from filename (fork?)" % f["session_id"])
            print("      types   %s" % json.dumps(f["types"]))
            print("      first   %s" % (f["first_user"] or "(no user text at all)"))
    print("")
    print("TOTAL orphans %d, %.1f MB" % (total_orphans, total_bytes / 1048576.0))


if __name__ == "__main__":
    main()
