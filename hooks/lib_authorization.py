"""Decide whether a message from Bob authorises tool calls this turn.

WHAT THIS IS FOR
  Rule 1, work or words. It is the rule Bob's CLAUDE.md puts FIRST, and on
  2026-09-10 it was broken by the very session building the machinery to
  enforce it: he asked "was the shell shape thing we were talking about? Replay
  that", which is a question, and it was read as an instruction to go and do
  the thing.

  Every other guard asks "is this action forbidden". None of them asks "should
  this turn contain a tool call at all", which is the question that failure
  turned on.

THE BIAS IS DELIBERATE AND IT IS BOB'S
  "My preference is for you to come back and confirm that I am wanting you to
  go when I tell you to, as opposed to, in ambiguous cases, you deciding to
  fucking go off, because the latter happens more often."

  So AMBIGUOUS MEANS STOP. A false stop costs him one keystroke. A false start
  costs him a mess and his attention. The asymmetry is not close, and this
  module is tuned to it rather than to a balanced error rate.

THE THREE VERDICTS

  work      an unambiguous instruction to act. Tool calls allowed.
  words     a question, or a request to explain. The turn should be prose.
  name-it   a bare approval with nothing named: "go ahead", "yes", "do it".
            Authorisation is real but its SCOPE is not established, so the
            first tool call is refused and Claude must say what it is about
            to do. Bob: "Don't say, are we good to go? Say, are we agreed
            that I should build module X or do task Y."

THE TRAP THAT CAUGHT IT
  A speech verb is still an imperative. "Replay that", "tell me", "explain"
  are all grammatically instructions, and treating any imperative as work is
  exactly the mistake that broke rule 1. SPEECH_VERBS exists for that.
"""
import re

# Verbs that, used as an instruction, ask for ACTION.
ACTION_VERBS = {
    "go", "do", "build", "fix", "run", "make", "add", "remove", "delete",
    "install", "commit", "push", "pull", "write", "create", "update",
    "deploy", "revert", "archive", "merge", "rip", "ship", "start", "clean",
    "sweep", "generate", "implement", "refactor", "enable", "disable", "move",
    "copy", "rename", "apply", "finish", "continue", "proceed", "handle",
    "sort", "wire", "set", "put", "get", "take", "send", "kill", "stop",
    "restore", "rebuild", "deal", "address", "close", "open", "split",
    "extract", "convert", "migrate", "upgrade", "downgrade", "patch",
    # Read-only actions. Still work: they consume time and touch his machine.
    "explore", "investigate", "find", "search", "scan", "diagnose", "audit",
    "review", "measure", "count", "trace", "profile", "benchmark",
    # Things he asks for by name often enough to be worth listing.
    "save", "read", "prepare", "schedule", "register", "document", "zip",
    "back", "sync", "verify", "test", "cleanup", "quarantine", "narrow",
}

# Verbs that, used as an instruction, ask for WORDS. Grammatically imperative,
# and the whole point is that they are NOT authorisation to act.
SPEECH_VERBS = {
    "tell", "explain", "describe", "replay", "recap", "summarise", "summarize",
    "talk", "say", "remind", "clarify", "elaborate", "walk", "outline",
    "discuss", "confirm", "compare", "comment", "answer", "repeat",
}

# Openers that make a sentence a question even without a question mark.
QUESTION_OPENERS = {
    "what", "why", "how", "where", "when", "who", "whom", "which", "whose",
    "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
    "should", "would", "will", "shall", "have", "has", "had", "any",
}

# Phrases that ask for prose regardless of anything else in the sentence.
WORDS_PHRASES = (
    "tell me", "talk to me", "explain", "what about", "thoughts on",
    "your read", "what do you think", "walk me through", "how about",
    "replay", "recap", "where do we stand", "what's the story",
    "what is the story", "let me know", "give me your",
)

# Agreement tokens. On their own, with nothing named, these are `name-it`.
APPROVAL_WORDS = {
    "yes", "yep", "yeah", "ok", "okay", "sure", "agreed", "fine", "good",
    "right", "correct", "great", "perfect", "go", "proceed", "ahead",
    "please", "do", "it", "that", "this", "now", "then", "all", "them",
    "everything", "both", "and", "so", "well", "alright", "cool", "nice",
}

MAX_BARE_APPROVAL_WORDS = 8


def _sentences(text):
    """Split into clauses, not just sentences.

    "Explain what you did, then commit it" is one sentence carrying two
    instructions, and only the second is authorisation. Splitting on sentence
    marks alone hides it behind the speech verb, so `then` and `and then` count
    as boundaries. Over-splitting is harmless here: a fragment whose first word
    is not a verb simply contributes nothing.
    """
    parts = re.split(r"[.!?\n;]+|,?\s*\band\s+then\b|,?\s*\bthen\b|,\s*\band\b",
                     text, flags=re.IGNORECASE)
    return [p.strip() for p in parts if p and p.strip()]


def _words(text):
    return [w for w in re.sub(r"[^a-z0-9'\s-]", " ", text.lower()).split() if w]


def _leading_verb(sentence):
    """The first meaningful word of a sentence, skipping politeness and
    connectives, so "ok now go fix it" still surfaces `go`."""
    skip = {"ok", "okay", "so", "well", "now", "then", "and", "but", "also",
            "please", "just", "alright", "yeah", "yes", "sure", "fine",
            "lets", "let's", "let", "us", "we", "you", "i", "maybe", "perhaps"}
    for w in _words(sentence):
        if w not in skip:
            return w
    return None


def classify(prompt):
    """Return (verdict, reason). Verdict is 'work', 'words' or 'name-it'."""
    if prompt is None:
        return "words", "no prompt text was available"
    text = prompt.strip()
    if not text:
        return "words", "empty message"

    low = text.lower()
    words = _words(low)

    # 1. Bare approval: short, made only of agreement tokens, nothing named.
    #    Checked FIRST, because "go ahead" is both an imperative and a bare
    #    approval, and the scope is what is missing.
    if len(words) <= MAX_BARE_APPROVAL_WORDS and words:
        if all(w in APPROVAL_WORDS for w in words):
            return "name-it", "approval with nothing named: %r" % text[:60]

    # 2. An explicit words-request anywhere wins over a later imperative.
    for phrase in WORDS_PHRASES:
        if phrase in low:
            # ...unless an ACTION verb also leads a sentence, which makes it
            # both: answer first, then work. Rule 1's BOTH case.
            if not _has_action_imperative(text):
                return "words", "asks for prose (%r)" % phrase

    # 3. An action imperative anywhere is authorisation.
    if _has_action_imperative(text):
        return "work", "contains an action instruction"

    # 4. A question, by mark or by opener.
    if "?" in text:
        return "words", "is a question"
    for s in _sentences(text):
        v = _leading_verb(s)
        if v in QUESTION_OPENERS:
            return "words", "opens with %r" % v

    # 5. A speech imperative and nothing else: still words.
    for s in _sentences(text):
        if _leading_verb(s) in SPEECH_VERBS:
            return "words", "asks for an explanation"

    # 6. Anything left is ambiguous, and ambiguous stops. Bob's call.
    return "words", "no unambiguous instruction found"


def _has_action_imperative(text):
    """True when some sentence is an instruction to ACT.

    A sentence that opens as a question is skipped, because "should we fix
    this?" contains an action verb and is not an instruction. Without that,
    every question about doing something would read as permission to do it,
    which is the failure this whole module exists to stop.
    """
    for s in _sentences(text):
        w = _words(s)
        v = _leading_verb(s)
        if v is None:
            continue
        # "do" is both an action verb and a question opener. "do you think"
        # is a question; "do everything" is an instruction. The word after it
        # decides.
        if v == "do":
            idx = w.index(v) if v in w else 0
            nxt = w[idx + 1] if idx + 1 < len(w) else ""
            if nxt in ("you", "we", "i", "they"):
                continue
            return True
        if v in QUESTION_OPENERS:
            continue
        if v in ACTION_VERBS:
            return True
    return False
