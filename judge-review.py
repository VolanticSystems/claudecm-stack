"""Review what the edit judge would have refused, and find out if it was right.

    python judge-review.py              the summary, and what is still unlabelled
    python judge-review.py --list       every unlabelled case, newest first
    python judge-review.py --review     label them one at a time
    python judge-review.py --all        include cases already labelled

WHY THIS EXISTS
  The judge was measured at 14% wrong refusals against 100 fixtures I drew and
  labelled myself. Its first day on real traffic said 46%. The fixtures were
  drawn from messages that were actually followed by a disk change, which
  stacked them with obvious directives, and the labels were my opinion. This
  tool replaces both with the operator's traffic and the operator's verdict.

THE TWO SIGNALS IT JOINS
  VOTES. Each verdict is three parallel calls and the split is recorded. 3D/0A
  is a unanimous refusal, 2D/1A one the judge nearly did not make. If unanimous
  refusals are mostly right and split ones mostly wrong, requiring unanimity
  fixes the rate with no prompt rewriting, and that is a measurement.

  WHAT THE OPERATOR SAID NEXT. In warn mode the edit goes ahead anyway, so his next
  message is evidence about whether he wanted it. It is printed beside the
  case and he decides; nothing is inferred from it automatically.

  A REGEX USED TO GUESS AT THAT AND IT IS GONE (2026-09-13). It flagged a next
  message as an objection when it contained stop, wait, revert, "I said" and so
  on. Run over seven months of transcripts it fired 47 times and about 8 were
  real: it was matching "as I said", "wait until day five", "she asked and I
  said no", and once a pasted terminal dump. 17% precision. Same disease as the
  word-list classifier this project already refuted: vocabulary is not intent.
  What replaced it is the structural record. Claude Code writes an interrupt
  record when the operator hits escape and a denial when he answers no at a prompt, and
  those are facts rather than guesses. They are also rare on edits, three in
  seven months, because an Edit finishes before anyone can react. Certain and
  rare beats frequent and wrong.

THE SAMPLING FRAME
  --frame draws cases from every edit on disk, not from the judge's own log.
  Labelling only what the judge refused measures precision and can never
  measure recall, because an edit it allowed never appears as a case. 1,182
  real (asked, edit, said next) triples exist across seven months.

Read-only except for the label file it writes next to the log.
"""
import argparse
import glob
import importlib.util
import io
import json
import os
import random
import sys
from collections import Counter, defaultdict

WORKLOG = os.path.join(os.path.expanduser("~"), ".claude", "hooks", "worklog")
COSTS = os.path.join(WORKLOG, "judge-costs.jsonl")
LABELS = os.path.join(WORKLOG, "judge-labels.json")


def _objection_scan():
    """objection-scan.py, imported by path because of the hyphen."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "objection-scan.py")
    spec = importlib.util.spec_from_file_location("objection_scan", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_rows():
    rows = []
    try:
        for line in io.open(COSTS, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
    except Exception as exc:
        print("no judge cost log at %s (%s)" % (COSTS, exc))
    return rows


def load_messages():
    """{session: [(timestamp, text), ...]} from the per-session prompt logs."""
    out = defaultdict(list)
    for path in glob.glob(os.path.join(WORKLOG, "prompts-*.jsonl")):
        sid = os.path.basename(path)[len("prompts-"):-len(".jsonl")]
        try:
            for line in io.open(path, encoding="utf-8"):
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if r.get("text"):
                    out[sid].append((float(r.get("at") or 0), r["text"]))
        except Exception:
            continue
    for sid in out:
        out[sid].sort()
    return out


def message_at(msgs, session, at):
    """(the message that triggered this, the message that came next)."""
    seq = msgs.get(session) or []
    triggered, nxt = "", ""
    for i, (ts, text) in enumerate(seq):
        if ts <= at:
            triggered = text
            nxt = seq[i + 1][1] if i + 1 < len(seq) else ""
        else:
            break
    return triggered, nxt


def case_id(r):
    if r.get("_frame"):
        return "frame|%s|%s|%s" % (r.get("_at", ""), r.get("session", "")[:8],
                                   (r.get("path") or "").lower())
    return "%s|%s|%s" % (r.get("session", "")[:8], r.get("prompt_id", ""),
                         (r.get("path") or "").lower())


def frame_cases(n, since, project):
    """A random sample of real edits from every transcript on disk.

    Blind on purpose: the judge's verdict is not shown while labelling these,
    so the label is the operator's reading of his own words rather than agreement with
    a verdict he has just been told.
    """
    osc = _objection_scan()
    pairs = osc.edit_pairs(since, project)
    stopped = osc.interrupted_actions(since)
    random.shuffle(pairs)
    rows = []
    for p in pairs[:n]:
        action = p["action"]
        path = action.split(": ", 1)[1] if ": " in action else ""
        rows.append({"_frame": True, "_at": p["at"], "_asked": p["asked"],
                     "_next": p["next"], "_interrupted": (p["session"], action) in stopped,
                     "tool": p["tool"], "path": path, "session": p["session"],
                     "at": 0, "decision": "FRAME"})
    return rows


def refusals(rows):
    return [r for r in rows if r.get("decision") in ("WOULD_DENY", "DENY")]


def load_labels():
    try:
        with io.open(LABELS, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_labels(d):
    with io.open(LABELS, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=1, ensure_ascii=False)


def one_line(t, n=150):
    return " ".join((t or "").split())[:n]


def show(r, msgs, labels, n=None, total=None, blind=False):
    trig, nxt = message_at(msgs, r.get("session", ""), r.get("at") or 0)
    if r.get("_frame"):
        trig, nxt = r.get("_asked", ""), r.get("_next", "")
    head = "  [%s/%s]" % (n, total) if n else ""
    print("")
    print("-" * 78)
    print("%s %s  %s  %s  %s" % (
        head, r.get("tool"), os.path.basename(r.get("path") or ""),
        "" if blind else "votes %s" % (r.get("votes") or "?"),
        r.get("session", "")[:8]))
    print("  path   : %s" % (r.get("path") or ""))
    print("  THE OPERATOR    : %s" % one_line(trig, 400))
    if not blind:
        print("  JUDGE  : would have refused")
    if r.get("_interrupted"):
        print("  NOTE   : you stopped this one at the time")
    if nxt:
        print("  NEXT   : %s" % one_line(nxt, 200))
    lab = labels.get(case_id(r))
    if lab:
        print("  LABEL  : %s" % ("SHOULD have been refused" if lab == "right"
                                 else "should NOT have been refused"))


def run_review(cases, msgs, labels, blind=False):
    for i, r in enumerate(cases, 1):
        show(r, msgs, labels, i, len(cases), blind=blind)
        try:
            a = input("  [r]efuse / [w]as fine / [s]kip / [q]uit: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            a = "q"
        if a.startswith("q"):
            return
        if a.startswith("r"):
            labels[case_id(r)] = "right"
        elif a.startswith("w"):
            labels[case_id(r)] = "wrong"


def summary(rows, labels, msgs):
    ref = refusals(rows)
    judged = [r for r in rows if r.get("decision") in ("ALLOW", "DENY", "WOULD_DENY")]
    errors = [r for r in rows if r.get("decision") == "ERROR"]
    print("judge calls with a verdict : %d" % len(judged))
    if judged:
        print("would-have-refused         : %d (%.0f%% of those that returned one)" % (
            len(ref), 100.0 * len(ref) / len(judged)))
    # The denominator matters. A judge that fails open leaves no verdict, so a
    # rate computed without this line is a share of the calls that worked.
    print("failed open, no verdict    : %d%s" % (
        len(errors),
        "" if not errors else "  (%.0f%% of all calls, edits allowed unchecked)"
        % (100.0 * len(errors) / (len(judged) + len(errors)))))
    if errors:
        why = Counter(str(r.get("error", ""))[:60] for r in errors)
        for w, n in why.most_common(3):
            print("    %-50s %d" % (w or "(no reason recorded)", n))
    repeats = [r for r in rows if str(r.get("decision", "")).endswith("_REPEAT")]
    if repeats:
        print("retries served from cache  : %d (model calls saved)" % len(repeats))
    cost = sum(float(r.get("cost") or 0) for r in rows)
    lat = sorted(r.get("latency_s") or 0 for r in judged)
    if lat:
        print("latency                    : median %.1fs  p90 %.1fs" % (
            lat[len(lat) // 2], lat[int(len(lat) * 0.9)]))
    print("list-price equivalent       : $%.2f" % cost)

    by_proj = Counter()
    for r in ref:
        by_proj[os.path.basename(os.path.dirname(r.get("path") or "")) or "?"] += 1
    if by_proj:
        print("")
        print("where the refusals landed:")
        for p, n in by_proj.most_common(8):
            print("  %-34s %d" % (p[:34], n))

    print("")
    print("BY VOTE SPLIT  (the question: is a unanimous refusal a better refusal?)")
    print("  %-10s %7s %8s %8s %9s" % ("split", "cases", "right", "wrong", "unlabelled"))
    per = defaultdict(lambda: [0, 0, 0])
    for r in ref:
        v = r.get("votes") or "?"
        lab = labels.get(case_id(r))
        per[v][0] += 1
        if lab == "right":
            per[v][1] += 1
        elif lab == "wrong":
            per[v][2] += 1
    for v in sorted(per):
        c, right, wrong = per[v]
        print("  %-10s %7d %8d %8d %9d" % (v, c, right, wrong, c - right - wrong))
    labelled = sum(1 for r in ref if case_id(r) in labels)
    print("")
    print("labelled %d of %d refusals. Run --review to label the rest." % (labelled, len(ref)))
    frame = [k for k in labels if k.startswith("frame|")]
    if frame:
        right = sum(1 for k in frame if labels[k] == "right")
        print("plus %d case(s) labelled from the seven-month frame, %d of which "
              "you said should have been refused." % (len(frame), right))
    print("Run --frame N to draw N edits from every transcript on disk, which is "
          "the only way to see what the judge is LETTING through.")


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--review", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--frame", type=int, default=0,
                    help="label N random edits drawn from every transcript on "
                         "disk, blind to the judge's verdict")
    ap.add_argument("--since", default="", help="YYYY-MM-DD, for --frame")
    ap.add_argument("--project", default="", help="substring, for --frame")
    args = ap.parse_args()

    labels = load_labels()
    if args.frame:
        cases = [c for c in frame_cases(args.frame * 3, args.since, args.project)
                 if case_id(c) not in labels][:args.frame]
        if not cases:
            print("no unlabelled edits in that frame.")
            return 0
        print("%d edit(s) drawn from seven months of transcripts. You are NOT "
              "being shown what the judge said." % len(cases))
        print("r = this SHOULD have been refused, w = this was fine, s = skip, q = quit")
        run_review(cases, {}, labels, blind=True)
        save_labels(labels)
        print("")
        print("saved %d label(s) to %s" % (len(labels), LABELS))
        return 0

    rows = load_rows()
    if not rows:
        return 1
    msgs = load_messages()
    ref = sorted(refusals(rows), key=lambda r: -(r.get("at") or 0))
    todo = [r for r in ref if args.all or case_id(r) not in labels]

    if args.list:
        for i, r in enumerate(todo, 1):
            show(r, msgs, labels, i, len(todo))
        return 0

    if args.review:
        if not todo:
            print("nothing left to label.")
            return 0
        print("r = the judge was RIGHT to refuse, w = WRONG, s = skip, q = save and quit")
        run_review(todo, msgs, labels)
        save_labels(labels)
        print("")
        print("saved %d label(s) to %s" % (len(labels), LABELS))
        print("")

    summary(rows, labels, msgs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
