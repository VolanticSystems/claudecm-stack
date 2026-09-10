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

TASK_FILE = os.path.join(STATE_DIR, "current-task.json")
PROMPTS_FILE = os.path.join(STATE_DIR, "prompts.jsonl")
LOG_FILE = os.path.join(STATE_DIR, "worklog.md")

# How many recent messages a citation may be drawn from. Generous, because a
# task legitimately spans many turns of back-and-forth.
PROMPT_HISTORY = 60

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
    r">>?\s*[^&|\s]", r"\btee\b",
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
    os.makedirs(STATE_DIR, exist_ok=True)


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

def record_prompt(text, session_id, prompt_id):
    """Append one of Bob's messages, so a citation can be checked against it."""
    _ensure_dir()
    entry = {
        "at": _now().timestamp(),
        "session": session_id,
        "prompt_id": prompt_id,
        "text": (text or "")[:4000],
    }
    try:
        with io.open(PROMPTS_FILE, "a", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(entry) + "\n")
    except Exception:
        return
    _trim_prompts()


def _trim_prompts():
    try:
        with io.open(PROMPTS_FILE, encoding="utf-8") as fh:
            lines = fh.readlines()
        if len(lines) <= PROMPT_HISTORY * 2:
            return
        with io.open(PROMPTS_FILE, "w", encoding="utf-8", newline="\n") as fh:
            fh.writelines(lines[-PROMPT_HISTORY:])
    except Exception:
        pass


def recent_prompts(limit=PROMPT_HISTORY):
    out = []
    try:
        with io.open(PROMPTS_FILE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        return []
    return out[-limit:]


def citation_matches(citation):
    """(found, why). Is this quote actually something Bob said recently?

    Substring match on normalised text. Deliberately not fuzzy: the point is
    that the words exist, and a paraphrase is not a citation.
    """
    c = normalise(citation)
    if len(c) < 12:
        return False, "a citation must be a real quote, not a few words"
    for entry in recent_prompts():
        if c in normalise(entry.get("text")):
            return True, "matched a message from %s" % _stamp(entry.get("at"))
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
    ok, why = citation_matches(citation)
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
    tmp = TASK_FILE + ".tmp-%d" % os.getpid()
    with io.open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(task, indent=2))
    os.replace(tmp, TASK_FILE)          # the rename is the publish
    log("OPENED", what.strip(), citation.strip())
    return True, why


def current_task():
    try:
        with io.open(TASK_FILE, encoding="utf-8") as fh:
            task = json.load(fh)
    except Exception:
        return None
    try:
        age = (_now().timestamp() - float(task.get("opened_at") or 0)) / 3600.0
    except Exception:
        return None
    if age > TASK_MAX_AGE_HOURS or age < -1:
        return None                     # abandoned, or the clock moved
    return task


def close_task(reason="finished"):
    task = current_task()
    if task:
        log("CLOSED", task.get("what", ""), task.get("citation", ""), reason)
    try:
        os.remove(TASK_FILE)
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
