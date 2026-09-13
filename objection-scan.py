"""Every time the operator stopped Claude, pulled from the transcripts themselves.

Claude Code already records this by default. Three signals, all machine
readable, all present in the .jsonl whether or not any hook was installed:

  INTERRUPT-TOOL   "[Request interrupted by user for tool use]" - he hit escape
                   while a tool was running. The strongest signal there is:
                   something was in flight and he stopped it.
  INTERRUPT        "[Request interrupted by user]" - he cut a reply short.
  DENIED           a tool_result saying the user does not want to proceed with
                   this tool use - he answered no at a permission prompt.

Each carries interruptedMessageId or tool_use_id, so the tool that was stopped
can be named, and the last thing the operator actually asked for can be read back.

This covers Bash, reads and subagents, which the edit judge does not see.
It is free, it needs no model, and it works retroactively on everything on
disk.

    python objection-scan.py                    summary across all projects
    python objection-scan.py --list             every event, newest first
    python objection-scan.py --list <substr>    only projects matching substr
    python objection-scan.py --since 2026-09-01 from that date on
"""
import argparse
import io
import json
import os
import sys
from collections import Counter, defaultdict

PROJECTS = os.path.join(os.path.expanduser("~"), ".claude", "projects")

INTERRUPT = "[Request interrupted by user]"
INTERRUPT_TOOL = "[Request interrupted by user for tool use]"
DENIED = "doesn't want to proceed with this tool use"
DENIED_ALT = "doesn't want to take this action"


def text_of(content):
    """Flatten a message content field to plain text."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    out = []
    for c in content:
        if not isinstance(c, dict):
            continue
        if c.get("type") == "text":
            out.append(c.get("text") or "")
        elif c.get("type") == "tool_result":
            inner = c.get("content")
            out.append(inner if isinstance(inner, str) else json.dumps(inner)[:400])
    return "\n".join(out)


def typed_by_operator(r):
    """The text the operator actually typed, or "" for anything else.

    A tool result comes back as a `user` record too, so flattening content
    blindly reads a Bash stdout dump as "what he asked for". First version of
    this file did exactly that and put `File created successfully at...` in the
    column headed THE OPERATOR. Only `text` blocks count, and any record carrying a
    tool_result is disqualified outright.
    """
    if r.get("type") != "user" or r.get("isMeta") or r.get("toolUseResult"):
        return ""
    content = (r.get("message") or {}).get("content")
    if isinstance(content, str):
        out = content
    elif isinstance(content, list):
        if any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
            return ""
        out = "\n".join(c.get("text") or "" for c in content
                        if isinstance(c, dict) and c.get("type") == "text")
    else:
        return ""
    out = out.strip()
    if not out or out.startswith("<") or out.startswith("[Request interrupted"):
        return ""
    return " ".join(out.split())


def tool_summary(block):
    """One short line describing a tool_use block."""
    name = block.get("name") or "?"
    inp = block.get("input") or {}
    for key in ("command", "file_path", "path", "pattern", "url", "prompt", "description"):
        if isinstance(inp.get(key), str) and inp[key].strip():
            return "%s: %s" % (name, " ".join(inp[key].split())[:120])
    return name


def scan_file(path, project, session):
    """Yield one dict per objection event in this transcript."""
    by_msg_id = {}      # assistant message id -> [tool summaries]
    by_tool_id = {}     # tool_use id -> summary
    last_user = ""      # last real thing the operator typed
    last_tools = []     # fallback when interruptedMessageId does not resolve
    pending = []
    events = []
    for line in io.open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        rtype = r.get("type")
        msg = r.get("message") or {}
        if rtype == "assistant":
            tools = []
            for c in (msg.get("content") or []):
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    s = tool_summary(c)
                    tools.append(s)
                    if c.get("id"):
                        by_tool_id[c["id"]] = s
            if msg.get("id"):
                by_msg_id[msg["id"]] = tools
            if tools:
                last_tools = tools
            continue
        if rtype != "user":
            continue
        body = text_of(msg.get("content"))
        kind = None
        stopped = []
        if INTERRUPT_TOOL in body:
            kind = "INTERRUPT-TOOL"
        elif INTERRUPT in body:
            kind = "INTERRUPT"
        elif DENIED in body or DENIED_ALT in body:
            kind = "DENIED"
        if kind:
            if kind.startswith("INTERRUPT"):
                stopped = by_msg_id.get(r.get("interruptedMessageId") or "", [])
                # An interrupt DURING a tool always had one in flight, so an
                # unresolved id means the assistant record was written without
                # a matching message.id, not that nothing was running.
                if not stopped and kind == "INTERRUPT-TOOL":
                    stopped = ["~" + t for t in last_tools]
            else:
                for c in (msg.get("content") or []):
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        s = by_tool_id.get(c.get("tool_use_id") or "")
                        if s:
                            stopped.append(s)
            ev = {"kind": kind, "at": r.get("timestamp") or "", "project": project,
                  "session": session, "asked": last_user, "stopped": stopped,
                  "next": ""}
            events.append(ev)
            pending.append(ev)
            continue
        typed = typed_by_operator(r)
        if not typed:
            continue
        last_user = typed
        for ev in pending:
            ev["next"] = typed
        pending = []
    return events


EDIT_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")


def edit_pairs(since="", want=""):
    """Every (what the operator asked, edit that followed, what he said next) on disk.

    The sampling frame the judge should be measured against. Seven months of
    real traffic, not a fixture set drawn by whoever is grading. Labelling only
    the judge's own refusals can measure precision and can NEVER measure recall,
    because an edit the judge allowed never appears in its log as a case.
    """
    out = []
    for key in sorted(os.listdir(PROJECTS)):
        d = os.path.join(PROJECTS, key)
        if not os.path.isdir(d) or (want and want.lower() not in key.lower()):
            continue
        for root, _dirs, files in os.walk(d):
            for name in files:
                if not name.endswith(".jsonl"):
                    continue
                last_typed, open_edit = "", None
                try:
                    fh = io.open(os.path.join(root, name), encoding="utf-8",
                                 errors="replace")
                except Exception:
                    continue
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    if r.get("type") == "assistant":
                        for c in (r.get("message") or {}).get("content") or []:
                            if isinstance(c, dict) and c.get("type") == "tool_use" \
                                    and c.get("name") in EDIT_TOOLS:
                                open_edit = {"at": r.get("timestamp") or "",
                                             "project": key, "session": name[:-6],
                                             "tool": c.get("name"),
                                             "action": tool_summary(c),
                                             "asked": last_typed, "next": ""}
                        continue
                    typed = typed_by_operator(r)
                    if not typed:
                        continue
                    if open_edit:
                        open_edit["next"] = typed
                        if open_edit["asked"] and (not since or open_edit["at"][:10] >= since):
                            out.append(open_edit)
                        open_edit = None
                    last_typed = typed
    out.sort(key=lambda e: e["at"], reverse=True)
    return out


def interrupted_actions(since=""):
    """(session, action) pairs the operator actually stopped. Certain, and rare."""
    keys = set()
    for ev in collect(since, ""):
        for s in ev["stopped"]:
            keys.add((ev["session"], s.lstrip("~")))
    return keys


def collect(since, want):
    events = []
    for key in sorted(os.listdir(PROJECTS)):
        d = os.path.join(PROJECTS, key)
        if not os.path.isdir(d):
            continue
        if want and want.lower() not in key.lower():
            continue
        for root, _dirs, files in os.walk(d):
            for name in files:
                if not name.endswith(".jsonl"):
                    continue
                try:
                    for ev in scan_file(os.path.join(root, name), key, name[:-6]):
                        if since and ev["at"][:10] < since:
                            continue
                        events.append(ev)
                except Exception as exc:
                    print("could not read %s (%s)" % (name, exc))
    events.sort(key=lambda e: e["at"], reverse=True)
    return events


def show(ev):
    print("")
    print("-" * 78)
    print("  %s  %s" % (ev["at"][:19].replace("T", " "), ev["kind"]))
    print("  project : %s" % ev["project"].replace("C--Users-you-", ""))
    print("  stopped : %s" % ("; ".join(ev["stopped"]) or "(no tool in flight)"))
    print("  THE OPERATOR had asked : %s" % (ev["asked"][:300] or "(nothing before it)"))
    if ev["next"]:
        print("  then said     : %s" % ev["next"][:200])


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--since", default="")
    ap.add_argument("project", nargs="?", default="")
    args = ap.parse_args()

    events = collect(args.since, args.project)
    if args.list:
        for ev in events:
            show(ev)
        print("")

    print("objections found : %d" % len(events))
    if not events:
        return 0
    print("span             : %s .. %s" % (events[-1]["at"][:10], events[0]["at"][:10]))
    kinds = Counter(e["kind"] for e in events)
    for k, n in kinds.most_common():
        print("  %-16s %d" % (k, n))

    print("")
    print("what was in flight when he stopped it:")
    tools = Counter()
    for e in events:
        for s in e["stopped"]:
            tools[s.split(":")[0]] += 1
        if not e["stopped"]:
            tools["(nothing, mid-reply)"] += 1
    for t, n in tools.most_common(12):
        print("  %-24s %d" % (t, n))

    print("")
    print("by month:")
    months = Counter(e["at"][:7] for e in events if e["at"])
    for m in sorted(months):
        print("  %-10s %s %d" % (m, "#" * min(40, months[m]), months[m]))

    print("")
    print("noisiest projects:")
    projs = Counter(e["project"].replace("C--Users-you-", "") for e in events)
    for p, n in projs.most_common(8):
        print("  %-46s %d" % (p[:46], n))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
