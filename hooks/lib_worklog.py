"""Only Bob creates work. This module is the record of who asked for what.

WHAT WENT WRONG, AND WHY THE PREVIOUS DESIGN COULD NOT CATCH IT

  Bob, 2026-09-10: "The problem is not that you read shit. The problem is that
  then you go on and do shit. I say read the bug report. And you read the bug
  report, and I'm happy that you did it. Then you get this wild hair across your
  ass to decide to go fix the bug."

  The failure is not a single tool call. It is a SEQUENCE. Reading surfaces a
  defect, and the defect becomes its own instruction. Nothing said to fix it:
  not Bob, anyway. The report said it, or the code said it, or I said it to
  myself, and in the moment it feels obvious, which is exactly why no rule about
  individual actions catches it.

  The first attempt classified Bob's message with word lists and refused tool
  calls on turns it judged unauthorised. It produced four false positives in an
  afternoon, every one of them blocking a READ, and it never once caught the
  thing above. It was deleted.

THE RULE THIS ENCODES

  A finding is not a mandate. Only Bob creates work. Before changing anything on
  his machine there must be an open task naming what is being done and QUOTING
  THE WORDS OF HIS that asked for it.

  The citation is checked against what he actually typed. That is the whole
  mechanical strength here: it needs no judgement about phrasing, no vocabulary,
  and it cannot false-positive on how he writes, because it never tries to
  interpret him. It only asks whether the words being cited exist.

  A task spans turns, because real work does. It does NOT grow. Finding Y while
  doing X does not extend the licence to Y; Y is reported and waits.

WHAT THIS HONESTLY DOES AND DOES NOT DO

  It cannot stop a plausible-sounding citation. What it changes is that the
  claim becomes explicit and lands in front of Bob, where "you asked me to read
  this, so I fixed it" reads as thin as it actually is. Forcing the deliberation
  and recording it is the mechanism; prevention is not on offer.

READS ARE NEVER TOUCHED. Bob was explicit that reading was never the problem.
"""
import datetime
import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.join(HERE, "state")

# A task belongs to ONE session. The first version used a single global file,
# so three instances in three projects shared one licence: instance A opened a
# task and instance B inherited it, which is the opposite of what this is for.
# Found 2026-09-10 while investigating a hook collision in another project.
#
# The unkeyed name is still read when no session is given, so a task opened by
# hand keeps working.
TASK_FILE = os.path.join(STATE_DIR, "current-task.json")


def task_file(session_id=None):
    if not session_id:
        return TASK_FILE
    safe = re.sub(r"[^A-Za-z0-9_-]", "-", str(session_id))[:64]
    return os.path.join(STATE_DIR, "task-%s.json" % safe)
# TWO DIRECTORIES, BECAUSE THEY HOLD DIFFERENT KINDS OF THING.
#
# state/   is EPHEMERAL: task files, one per session. Deleting the lot is a
#          legitimate way to unstick something and must cost nothing.
# worklog/ is a RECORD: what Bob said, and every time he told me I went over
#          the line. It is the only evidence of the thing this exists to show.
#
# They shared a directory until 2026-09-10, when clearing stuck state also wiped
# the prompt history. Older authorisations then silently stopped being citable,
# and the guard refused a commit because the message authorising it no longer
# existed. Nothing in the layout had said one of them was precious.
RECORDS_DIR = os.path.join(HERE, "worklog")
PROMPTS_FILE = os.path.join(RECORDS_DIR, "prompts.jsonl")
LOG_FILE = os.path.join(RECORDS_DIR, "worklog.md")

# Where they used to live. Moved across on first use, so an existing machine
# keeps its history rather than appearing to have none.
_LEGACY_PROMPTS = os.path.join(STATE_DIR, "prompts.jsonl")
_LEGACY_LOG = os.path.join(STATE_DIR, "worklog.md")

# How many of a session's own messages a citation may be drawn from.
#
# THIS USED TO BE A SINGLE SHARED FILE, AND THAT WAS THE WORST BUG IN HERE.
# Every session appended to one 60-entry list, so a busy session evicted every
# other session's history. On 2026-09-10 a blikje session running overnight
# under an explicit multi-hour authorization from Bob was wedged: its licence
# had been pushed out of the file by a different session's traffic, so its
# genuine citation read as invented, and the task could not even be withdrawn.
#
# Per session now, so no session can starve another, and retained by AGE as
# well as count: a long task's authorization must outlive the chatter after it.
PROMPT_HISTORY = 400
PROMPT_MAX_AGE_DAYS = 30

# A task older than this is assumed abandoned rather than open. Long, because
# real work spans hours; the point is to expire a forgotten task, not to time
# anybody out.
TASK_MAX_AGE_HOURS = 12

# Tools that change Bob's machine. Everything absent from here is a read and is
# never gated: Read, Grep, Glob, WebFetch, WebSearch and the rest.
MUTATING_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")

# Bash is mixed, so it is matched rather than listed. These are the shapes that
# change something. Anything else (ls, cat, grep, find, git status, git log,
# running a test suite) is a read.
MUTATING_BASH = (
    r"\brm\b", r"\bmv\b", r"\bcp\b", r"\bmkdir\b", r"\brmdir\b",
    r"\btouch\b", r"\bchmod\b", r"\bchown\b", r"\bln\b",
    # A redirect that writes a FILE. The three exclusions are not cosmetic:
    # `2>/dev/null` and `2>&1` appear in most ordinary read commands, and the
    # first version of this pattern matched them, so `ls -la x 2>/dev/null` was
    # refused as a state change. That is the precise failure Bob banned, a guard
    # blocking a read, shipped by the guard built to stop it. Found 2026-09-10.
    # Three spellings of "discard this", one per shell: POSIX, cmd, PowerShell.
    r">>?\s*(?!&)(?!/dev/null)(?![Nn][Uu][Ll]\b)(?!\$[Nn]ull\b)[^\s&|>]+",
    r"\btee\b",
    r"\bgit\s+(commit|push|merge|rebase|reset|checkout|revert|clean|stash|tag|apply|cherry-pick)\b",
    r"\b(npm|pnpm|yarn|pip|pip3|poetry|cargo|gem|apt|apt-get|choco|winget)\s+(install|add|remove|uninstall|update|upgrade)\b",
    r"\bSet-Content\b", r"\bAdd-Content\b", r"\bRemove-Item\b", r"\bNew-Item\b",
    r"\bCopy-Item\b", r"\bMove-Item\b", r"\bOut-File\b", r"\bRename-Item\b",
    r"\bRegister-ScheduledTask\b", r"\bUnregister-ScheduledTask\b",
    r"\bdocker\s+(run|rm|build|push)\b", r"\bsystemctl\s+(start|stop|restart|enable|disable)\b",
    r"\bsed\s+-i\b", r"\bcurl\b[^|]*\s-(o|O)\b", r"\bwget\b",
    # An inline interpreter that opens a file for writing. Found on 2026-09-10
    # while dogfooding this guard: `python -c "...open(p,'w')..."` changes the
    # machine and matched none of the patterns above, so it walked straight
    # through a gate that had just refused the identical edit.
    # The comma before the mode is load-bearing. Without it, open('x.md')
    # matched, because the filename began with one of the mode letters, and
    # reading a file read as writing it.
    r"(?is)\b(python3?|pwsh|powershell|node|ruby|perl)\b.*?-c\b.*?"
    r"(open\s*\([^)]*,\s*['\"][wax]|\.write\(|writeText|Set-Content|Out-File|"
    r"writeFileSync|os\.remove|shutil\.|os\.replace|os\.rename)",
)

# THE HONEST LIMIT, stated here rather than discovered later.
#
# Detecting what an arbitrary script does is not possible from its command
# line. `python somescript.py` may read or may rewrite the disk, and nothing
# above can tell which. The inline case is covered because that is the shape
# actually reached for when writing a quick file, but a named script is not.
#
# This is a real hole and it is not closable by pattern matching. What limits
# it is that running a script to change things IS the work, so the task should
# already be open; the gate is a reminder at the moment of action, not a sandbox.

# Things Bob says when I have gone past the line. Recorded loudly, because he
# asked for exactly that: "one thing I definitely want you to record with big
# red letters is Bob said I went over the line here."
STOP_MARKERS = (
    r"\bstop\b", r"\bwait\b", r"\bhold on\b", r"\bhold up\b",
    r"\bwho (told|asked) you\b", r"\bi (didn'?t|never) (ask|say|tell)\b",
    r"\bnot authori[sz]ed\b", r"\bwhy (the fuck )?(are|did) you\b",
    r"\bknock it off\b", r"\bback off\b", r"\bstand down\b",
    r"\bwent over the line\b", r"\bout of scope\b", r"\bunauthori[sz]ed\b",
)


# Envelopes the harness puts on its own events. Kept from the deleted
# classifier, where it was the one part that earned its place: a task-completion
# notification arrives on the same channel Bob's messages do, and treating it as
# something he said would poison the citation history.
_ENVELOPES = (
    r"(?is)<task-notification>.*?</task-notification>",
    r"(?is)<system-reminder>.*?</system-reminder>",
    r"(?is)<local-command-[a-z-]+>.*?</local-command-[a-z-]+>",
    r"(?is)<command-(?:name|message|args)>.*?</command-(?:name|message|args)>",
)
_NOT_USER_INPUT = "[SYSTEM NOTIFICATION - NOT USER INPUT]"


def strip_harness_envelopes(text):
    """Return (human_text, was_machine_event)."""
    if not text:
        return text, False
    if _NOT_USER_INPUT in text:
        return "", True
    stripped = text
    for pattern in _ENVELOPES:
        stripped = re.sub(pattern, " ", stripped)
    if not stripped.strip():
        return "", True
    return stripped, False


def _now():
    return datetime.datetime.now()


def _ensure_dir():
    """Both directories, plus a one-time migration of the old shared layout.

    Migration is best-effort and idempotent: if the new file already exists the
    legacy one is left alone rather than merged, because appending an old
    history onto a newer one would put entries out of order and the ordering is
    what `recent_prompts` relies on.
    """
    os.makedirs(STATE_DIR, exist_ok=True)
    os.makedirs(RECORDS_DIR, exist_ok=True)
    for legacy, current in ((_LEGACY_PROMPTS, PROMPTS_FILE),
                            (_LEGACY_LOG, LOG_FILE)):
        try:
            if os.path.isfile(legacy) and not os.path.exists(current):
                os.replace(legacy, current)
        except Exception:
            pass


def _rotate(path, keep_bytes=2 * 1024 * 1024):
    """Roll a record by month once it gets large.

    The worklog is an append-only audit trail. Left alone it grows without
    limit; rotated by month it stays readable and a corrupted tail costs one
    month rather than everything.

    IT IS STILL THE ONLY COPY. The nightly job backs up Documents\\GitHub, and
    this lives under ~/.claude, which nothing backs up. Rotation limits the
    damage from growth, not from loss.
    """
    try:
        if not os.path.isfile(path) or os.path.getsize(path) < keep_bytes:
            return
        stamp = _now().strftime("%Y-%m")
        base, ext = os.path.splitext(path)
        dest = "%s-%s%s" % (base, stamp, ext)
        if os.path.exists(dest):
            n = 2
            while os.path.exists("%s-%s-%d%s" % (base, stamp, n, ext)):
                n += 1
            dest = "%s-%s-%d%s" % (base, stamp, n, ext)
        os.replace(path, dest)
    except Exception:
        pass


def normalise(text):
    """Lowercase, collapse whitespace, drop punctuation.

    Citation matching has to survive Bob's typing and speech-to-text: smart
    quotes, stray commas, doubled spaces. Matching on normalised text means a
    citation is checked for substance rather than for transcription.
    """
    if not text:
        return ""
    text = text.replace("’", "'").replace("‘", "'")
    text = text.replace("“", '"').replace("”", '"')
    text = re.sub(r"[^a-z0-9\s']", " ", text.lower())
    return re.sub(r"\s+", " ", text).strip()


# ------------------------------------------------------------------ prompts

def prompts_file(session_id=None):
    """One history per session. See PROMPT_HISTORY for why."""
    if not session_id:
        return PROMPTS_FILE
    safe = re.sub(r"[^A-Za-z0-9_-]", "-", str(session_id))[:64]
    return os.path.join(RECORDS_DIR, "prompts-%s.jsonl" % safe)


def record_prompt(text, session_id, prompt_id):
    """Append one of Bob's messages, so a citation can be checked against it."""
    _ensure_dir()
    entry = {
        "at": _now().timestamp(),
        "session": session_id,
        "prompt_id": prompt_id,
        "text": (text or "")[:4000],
    }
    path = prompts_file(session_id)
    try:
        with io.open(path, "a", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(entry) + "\n")
    except Exception:
        return
    _trim_prompts(path)


def _trim_prompts(path):
    """Drop by age first, then by count.

    Age matters more than count here: an overnight authorization has to still
    be citable after a day of chatter, and it is the OLD entries that carry the
    licence while the new ones are usually acknowledgements.
    """
    try:
        with io.open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
        if len(lines) <= PROMPT_HISTORY * 2:
            return
        cutoff = _now().timestamp() - PROMPT_MAX_AGE_DAYS * 86400
        kept = []
        for line in lines:
            try:
                if float(json.loads(line).get("at") or 0) >= cutoff:
                    kept.append(line)
            except Exception:
                continue
        with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.writelines(kept[-PROMPT_HISTORY:])
    except Exception:
        pass


def recent_prompts(limit=PROMPT_HISTORY, session_id=None):
    """This session's messages, plus the shared file for anything written
    before histories were split per session."""
    out = []
    if session_id:
        # A named session sees its own history plus anything written before
        # histories were split. It must NOT see other sessions, or one
        # session's licence would authorise another's work.
        paths = [prompts_file(session_id), PROMPTS_FILE]
    else:
        # Session unknown, which is the hand-opened `current-task.json` case.
        # Scan everything, because refusing a real quote for want of a session
        # id is the failure mode this whole change exists to remove.
        paths = [PROMPTS_FILE]
        try:
            for name in sorted(os.listdir(RECORDS_DIR)):
                if name.startswith("prompts-") and name.endswith(".jsonl"):
                    paths.append(os.path.join(RECORDS_DIR, name))
        except Exception:
            pass
    for path in paths:
        try:
            with io.open(path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        out.append(json.loads(line))
                    except Exception:
                        continue
        except Exception:
            continue
    return out[-limit:]


def citation_matches(citation, session_id=None):
    """(found, why). Is this quote actually something Bob said recently?

    Substring match on normalised text. Deliberately not fuzzy: the point is
    that the words exist, and a paraphrase is not a citation.

    A SHORT citation is accepted only when it is his ENTIRE message. "Yes, do
    that" is real authorisation and is under the length floor, so requiring
    twelve characters of substring would have made his most common approval
    uncitable. Requiring it to be the whole message keeps it unambiguous:
    he said that and nothing else, in reply to something named.

    Found 2026-09-10, immediately after a task was opened citing words CLAUDE
    had written rather than Bob.
    """
    c = normalise(citation)
    if not c:
        return False, "a citation cannot be empty"
    for entry in recent_prompts(session_id=session_id):
        whole = normalise(entry.get("text"))
        if not whole:
            continue
        if c == whole:
            return True, "his whole message at %s" % _stamp(entry.get("at"))
        if len(c) >= 12 and c in whole:
            return True, "matched a message from %s" % _stamp(entry.get("at"))
    if len(c) < 12:
        return False, ("a short citation must be his entire message; %r is not"
                       % citation[:40])
    return False, "those words do not appear in anything Bob has said recently"


def _stamp(ts):
    try:
        return datetime.datetime.fromtimestamp(float(ts)).strftime("%H:%M")
    except Exception:
        return "?"


# -------------------------------------------------------------------- tasks

def open_task(what, citation, session_id=None, prompt_id=None):
    """(ok, message). Refuses a task whose citation Bob did not say."""
    if not what or len(what.strip()) < 8:
        return False, "a task must say what is being done"
    ok, why = citation_matches(citation, session_id)
    if not ok:
        return False, why
    _ensure_dir()
    task = {
        "what": what.strip(),
        "citation": citation.strip(),
        "opened_at": _now().timestamp(),
        "session": session_id,
        "prompt_id": prompt_id,
    }
    dest = task_file(session_id)
    tmp = dest + ".tmp-%d" % os.getpid()
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(task, indent=2))
    os.replace(tmp, dest)               # the rename is the publish
    log("OPENED", what.strip(), citation.strip())
    return True, why


def current_task(session_id=None):
    """This session's task, falling back to an unkeyed one opened by hand."""
    task = None
    for path in (task_file(session_id), TASK_FILE):
        try:
            with io.open(path, encoding="utf-8") as fh:
                task = json.load(fh)
            break
        except Exception:
            continue
    if task is None:
        return None
    try:
        age = (_now().timestamp() - float(task.get("opened_at") or 0)) / 3600.0
    except Exception:
        return None
    if age > TASK_MAX_AGE_HOURS or age < -1:
        return None                     # abandoned, or the clock moved
    return task


def close_task(reason="finished", session_id=None):
    task = current_task(session_id)
    if task:
        log("CLOSED", task.get("what", ""), task.get("citation", ""), reason)
    for path in (task_file(session_id), TASK_FILE):
        try:
            os.remove(path)
        except Exception:
            pass


# ---------------------------------------------------------------- the gate

def is_mutating(tool_name, tool_input):
    """Does this call change Bob's machine?"""
    if tool_name in MUTATING_TOOLS:
        return True
    if tool_name in ("Bash", "PowerShell"):
        cmd = (tool_input or {}).get("command") or ""
        for pattern in MUTATING_BASH:
            if re.search(pattern, cmd, re.IGNORECASE):
                return True
    return False


# ------------------------------------------------------------------- log

def log(kind, what, citation="", extra=""):
    """One line per event, in a file Bob can read without tooling."""
    _ensure_dir()
    _rotate(LOG_FILE)
    try:
        with io.open(LOG_FILE, "a", encoding="utf-8", newline="\n") as fh:
            fh.write("- **%s** `%s` %s\n" % (
                _now().strftime("%Y-%m-%d %H:%M:%S"), kind,
                (what or "").replace("\n", " ")[:150]))
            if citation:
                fh.write("  - citing: %r\n" % (citation.replace("\n", " ")[:150],))
            if extra:
                fh.write("  - %s\n" % extra.replace("\n", " ")[:200])
    except Exception:
        pass


def record_stop(message, task):
    """BOB SAID I WENT OVER THE LINE. Recorded with the claim I was making.

    His request, in his words: "if I end up saying stop, one thing I definitely
    want you to record with big red letters is Bob said I went over the line
    here. So you'll know exactly when you fucked up."

    Logging the word "stop" alone would be nearly useless. What makes this worth
    keeping is the CITATION sitting next to the objection: if the licence being
    claimed is routinely thin, that shows up as a pattern instead of a feeling.
    """
    _ensure_dir()
    _rotate(LOG_FILE)
    try:
        with io.open(LOG_FILE, "a", encoding="utf-8", newline="\n") as fh:
            fh.write("\n")
            fh.write("## !!! BOB SAID I WENT OVER THE LINE !!!\n\n")
            fh.write("**%s**\n\n" % _now().strftime("%Y-%m-%d %H:%M:%S"))
            fh.write("- he said: %r\n" % (message or "").replace("\n", " ")[:300])
            if task:
                fh.write("- I was doing: %s\n" % (task.get("what") or "")[:200])
                fh.write("- claiming: %r\n" % (task.get("citation") or "")[:200])
                fh.write("- opened at: %s\n" % _stamp(task.get("opened_at")))
            else:
                fh.write("- no task was open, so I was acting on nothing at all\n")
            fh.write("\n")
    except Exception:
        pass


def looks_like_stop(text):
    low = normalise(text)
    for pattern in STOP_MARKERS:
        if re.search(pattern, low):
            return True
    return False
