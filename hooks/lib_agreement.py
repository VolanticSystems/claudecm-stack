"""Loads the work agreement: the table of prohibitions Bob owns and edits.

WHY THIS IS A FILE AND NOT CODE
  The rules have to be changeable without editing Python and without asking
  Claude. Patterns living in code means every rule change is a code change,
  which is the opposite of a work agreement. It also means the written rule and
  the thing enforcing it drift apart over time; here they are the same row.

THE FORMAT
  A markdown table in agreement.md. Five columns:

    | slug | surface | pattern | action | why |

  slug     short stable name, cited in the guard's message. Names, not numbers,
           because numbered rules get renumbered and every citation breaks.
  surface  where it applies: bash, write, output. Comma-separated for several.
  pattern  a Python regular expression, matched case-insensitively.
  action   deny (refuse it), ask (hold it for Bob), warn (allow, say so).
  why      shown to Claude when it fires. This is the teaching, so write it as
           the reason, not the rule number.

  Rows that do not parse are SKIPPED AND NAMED, never fatal. A typo in one row
  must not disarm the other rows, and must not wedge the machine.

FAIL OPEN, ALWAYS
  Every guard that uses this exits 0 no matter what. Decisions travel as JSON,
  never as an exit code, because a non-zero exit from a PreToolUse hook blocks
  the tool call. That is the failure that leaves a session alive but unable to
  act, so an internal error here must never be able to cause it. A missing
  agreement file means no rules, said loudly, not silent disarmament.
"""
import os
import re

# ---------------------------------------------------------------- constants

VALID_ACTIONS = ("deny", "ask", "warn")

# bash   the shell command text
# write  the CONTENT being written to a file
# path   WHERE a write is going (the target path, not its content)
# tool   the tool's own name, for tools that must never be used at all
# output the assistant's prose
VALID_SURFACES = ("bash", "write", "path", "tool", "output")

# Surfaces that no installed guard reads yet. A rule on one of these is VALID
# but INERT: it would sit above the marker looking enforced and never fire.
# That is the worst failure this system can have, because it is invisible, so
# every active rule on an unwired surface is reported as a problem by name.
# `output` needs a Stop hook with access to the assistant's own message; the
# documented route to that is the transcript, which can lag the turn, so it was
# left unbuilt rather than shipped unproven. Remove a surface from here the day
# a guard reads it.
UNWIRED_SURFACES = ("output",)

# Rules are read only from between these. See load().
BEGIN_MARKER = "AGREEMENT:BEGIN"
END_MARKER = "AGREEMENT:END"

# The intensity dial, borrowed from ponytail's /ponytail lite|full|off.
#   off   nothing fires. The guards load and decide nothing.
#   lite  only `deny` rules fire: the never-do-this set, all exact matches.
#         Judgement calls (`ask`, `warn`) stay silent.
#   full  every rule fires as written. The default.
VALID_MODES = ("off", "lite", "full")
DEFAULT_MODE = "full"
MODE_MARKER = "AGREEMENT-MODE:"

HERE = os.path.dirname(os.path.abspath(__file__))


def default_agreement_path():
    """Where the agreement lives, most specific first.

    1. CLAUDE_AGREEMENT_PATH, so tests run against fixtures and never against
       Bob's real rules.
    2. ~/.claude/agreement.md, the deployed location. Beside CLAUDE.md rather
       than buried in hooks/, because it is a document he edits, not plumbing.
    3. beside this script, which is what the repo checkout looks like.
    """
    override = os.environ.get("CLAUDE_AGREEMENT_PATH")
    if override:
        return override
    home = os.path.join(os.path.expanduser("~"), ".claude", "agreement.md")
    if os.path.isfile(home):
        return home
    return os.path.join(HERE, "agreement.md")


DEFAULT_AGREEMENT = os.path.join(HERE, "agreement.md")  # kept for reference


class Rule(object):
    __slots__ = ("slug", "surfaces", "pattern", "regex", "action", "why")

    def __init__(self, slug, surfaces, pattern, regex, action, why):
        self.slug = slug
        self.surfaces = surfaces
        self.pattern = pattern
        self.regex = regex
        self.action = action
        self.why = why

    def __repr__(self):
        return "<Rule %s %s %s>" % (self.slug, "/".join(self.surfaces), self.action)


def _split_row(line):
    """Split a markdown table row into cells, tolerating optional edge pipes.

    A pipe escaped as \\| is NOT a cell boundary. This matters more here than in
    ordinary markdown: alternation in a regex is a pipe, so a rule like
    (honestly|frankly) would otherwise be chopped into three cells and skipped
    as malformed. Escaped pipes are unescaped once split, so the pattern the
    author wrote is the pattern that compiles.
    """
    line = line.strip()
    if not line.startswith("|"):
        return None
    body = line[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    cells = re.split(r"(?<!\\)\|", body)
    return [c.strip().replace("\\|", "|") for c in cells]


def _is_separator(cells):
    for c in cells:
        if c and set(c) - set("-: "):
            return False
    return True


def read_mode(lines):
    """The intensity dial. Env var wins so a session can be turned down without
    editing the file; otherwise an `AGREEMENT-MODE: x` line anywhere in it.

    An unrecognised value falls back to the default rather than disarming
    everything: a typo in the dial must not silently switch the guards off.
    """
    env = (os.environ.get("CLAUDE_AGREEMENT_MODE") or "").strip().lower()
    if env in VALID_MODES:
        return env, None
    if env:
        return DEFAULT_MODE, "CLAUDE_AGREEMENT_MODE=%r is not one of %s; using %s" % (
            env, ", ".join(VALID_MODES), DEFAULT_MODE)
    for line in lines:
        if MODE_MARKER in line:
            value = line.split(MODE_MARKER, 1)[1]
            value = value.replace("-->", "").strip().lower()
            if value in VALID_MODES:
                return value, None
            return DEFAULT_MODE, "mode %r is not one of %s; using %s" % (
                value, ", ".join(VALID_MODES), DEFAULT_MODE)
    return DEFAULT_MODE, None


def load(path=None):
    """Return (rules, problems). Never raises.

    problems is a list of human-readable strings naming every row that was
    skipped and why, so a bad row is visible rather than silently inert.
    """
    path = path or default_agreement_path()
    rules = []
    problems = []

    if not os.path.isfile(path):
        return rules, ["no agreement file at %s, so NO rules are in force" % path]

    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except Exception as exc:
        return rules, ["could not read %s (%s), so NO rules are in force" % (path, exc)]

    mode, mode_problem = read_mode(lines)
    if mode_problem:
        problems.append(mode_problem)
    if mode == "off":
        problems.append("agreement mode is 'off', so NO rules are in force")
        return rules, problems

    # Only rows between the markers are in force. Everything outside is
    # documentation, which lets the file carry a menu of ready-made rules that
    # are visibly NOT enabled. Enabling one is moving a line, not learning a
    # syntax. If the markers are absent the whole file is read, so a file
    # written before this existed still works.
    active = lines
    begin = end = None
    for i, line in enumerate(lines):
        if BEGIN_MARKER in line and begin is None:
            begin = i
        elif END_MARKER in line and begin is not None and end is None:
            end = i
    if begin is not None:
        active = lines[begin + 1:end if end is not None else len(lines)]
        offset = begin + 1
    else:
        offset = 0

    seen_slugs = set()
    for idx, line in enumerate(active):
        lineno = idx + offset + 1
        cells = _split_row(line)
        if cells is None or len(cells) < 5:
            continue
        if _is_separator(cells):
            continue
        slug, surface, pattern, action, why = [c.strip() for c in cells[:5]]
        if slug.lower() == "slug":          # header
            continue
        if not slug or not pattern:
            continue

        action = action.lower()
        if action not in VALID_ACTIONS:
            problems.append("line %d (%s): action '%s' is not one of %s"
                            % (lineno, slug, action, ", ".join(VALID_ACTIONS)))
            continue

        surfaces = tuple(s.strip().lower() for s in surface.split(",") if s.strip())
        bad = [s for s in surfaces if s not in VALID_SURFACES]
        if bad or not surfaces:
            problems.append("line %d (%s): surface '%s' is not one of %s"
                            % (lineno, slug, surface, ", ".join(VALID_SURFACES)))
            continue

        # A backtick-quoted pattern is a convenience for editing the table in
        # markdown; strip the fences rather than matching them literally.
        if len(pattern) > 1 and pattern.startswith("`") and pattern.endswith("`"):
            pattern = pattern[1:-1]

        try:
            regex = re.compile(pattern, re.IGNORECASE)
        except Exception as exc:
            problems.append("line %d (%s): pattern does not compile (%s)" % (lineno, slug, exc))
            continue

        if slug in seen_slugs:
            problems.append("line %d: duplicate slug '%s', the later row wins" % (lineno, slug))
        seen_slugs.add(slug)

        # lite keeps only the never-do-this set. Filtered here rather than at
        # match time so --list shows exactly what is live in this mode.
        if mode == "lite" and action != "deny":
            continue

        # An enabled rule that nothing reads is worse than no rule, because it
        # looks enforced. Say so, by name, every time the agreement loads.
        inert = [s for s in surfaces if s in UNWIRED_SURFACES]
        if inert:
            problems.append(
                "line %d (%s): surface '%s' has no guard reading it yet, so this "
                "rule is IN FORCE BUT INERT and will never fire"
                % (lineno, slug, ", ".join(inert)))

        rules.append(Rule(slug, surfaces, pattern, regex, action, why))

    return rules, problems


def evaluate(text, surface, path=None):
    """Match text against every rule for one surface.

    Returns (hits, problems). hits are (Rule, matched_text) in file order, so
    the table reads top to bottom the way Bob wrote it.
    """
    rules, problems = load(path)
    hits = []
    if not text:
        return hits, problems
    for rule in rules:
        if surface not in rule.surfaces:
            continue
        try:
            m = rule.regex.search(text)
        except Exception as exc:
            problems.append("rule %s failed while matching (%s)" % (rule.slug, exc))
            continue
        if m:
            hits.append((rule, m.group(0)))
    return hits, problems


def worst(hits):
    """deny beats ask beats warn. Returns the action, or None for no hits."""
    order = {"deny": 3, "ask": 2, "warn": 1}
    best = None
    for rule, _ in hits:
        if best is None or order.get(rule.action, 0) > order.get(best, 0):
            best = rule.action
    return best


# ---------------------------------------------------------------------- CLI

def _cli():
    """Bob's tool, not Claude's: check a pattern before trusting it to a session.

        python lib_agreement.py --list
        python lib_agreement.py --test "git commit -m x" --surface bash
    """
    import argparse
    import time

    ap = argparse.ArgumentParser(description="Inspect and test the work agreement.")
    ap.add_argument("--agreement", default=None, help="path to agreement.md")
    ap.add_argument("--list", action="store_true", help="list the rules in force")
    ap.add_argument("--test", default=None, help="text to test against the rules")
    ap.add_argument("--surface", default="bash", help="bash, write or output")
    args = ap.parse_args()

    rules, problems = load(args.agreement)

    for p in problems:
        print("PROBLEM: %s" % p)

    if args.list or args.test is None:
        try:
            with open(args.agreement or default_agreement_path(), encoding="utf-8") as fh:
                mode, _ = read_mode(fh.read().splitlines())
        except Exception:
            mode = DEFAULT_MODE
        print("agreement: %s" % (args.agreement or default_agreement_path()))
        print("mode: %s" % mode)
        print("%d rule(s) in force:" % len(rules))
        for r in rules:
            print("  %-18s %-14s %-5s %s" % (r.slug, ",".join(r.surfaces), r.action, r.pattern))
        if args.test is None:
            return 0

    started = time.time()
    hits, more = evaluate(args.test, args.surface.lower(), args.agreement)
    elapsed = time.time() - started
    for p in more:
        print("PROBLEM: %s" % p)

    if not hits:
        print("no rule matches on surface '%s'  (%.0f ms)" % (args.surface, elapsed * 1000))
    else:
        print("%d match(es) on surface '%s'  (%.0f ms)" % (len(hits), args.surface, elapsed * 1000))
        for rule, matched in hits:
            print("  %-18s %-5s matched %r" % (rule.slug, rule.action, matched))
        print("decision: %s" % worst(hits))
    if elapsed > 1.0:
        print("WARNING: that took over a second. A slow pattern can hit the hook")
        print("         timeout, and a timed-out hook blocks the tool call.")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
