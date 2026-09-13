"""Tests for objection-scan.py, built from the defects it already had.

The first version read a Bash stdout dump as "what the operator asked for", because a
tool result arrives as a `user` record like any other. That is the failure this
file exists to keep out, so the fixture deliberately puts a tool result, a
local-command block and a meta record between the operator's real message and the
interrupt.

    python -m pytest tests/test_objection_scan.py -q
"""
import importlib.util
import io
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "objection_scan", os.path.join(os.path.dirname(HERE), "objection-scan.py"))
osc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(osc)


def write(rows):
    fh = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False,
                                     encoding="utf-8")
    for r in rows:
        fh.write(json.dumps(r) + "\n")
    fh.close()
    return fh.name


def asst(mid, tool=None, tid=None, **inp):
    content = []
    if tool:
        content.append({"type": "tool_use", "id": tid or "t1", "name": tool,
                        "input": inp})
    return {"type": "assistant", "message": {"id": mid, "content": content}}


def said(text):
    return {"type": "user", "timestamp": "2026-09-13T10:00:00Z",
            "message": {"content": [{"type": "text", "text": text}]}}


def tool_result(tid, text):
    return {"type": "user", "timestamp": "2026-09-13T10:00:01Z",
            "toolUseResult": {"stdout": text},
            "message": {"content": [{"type": "tool_result", "tool_use_id": tid,
                                     "content": text}]}}


def interrupt(mid, for_tool=False):
    marker = osc.INTERRUPT_TOOL if for_tool else osc.INTERRUPT
    return {"type": "user", "timestamp": "2026-09-13T10:00:02Z",
            "interruptedMessageId": mid,
            "message": {"content": [{"type": "text", "text": marker}]}}


def scan(rows):
    path = write(rows)
    try:
        return osc.scan_file(path, "proj", "sess")
    finally:
        os.unlink(path)


def test_tool_output_is_not_read_as_the_operators_words():
    """The defect this file exists for: stdout in the column headed THE OPERATOR."""
    events = scan([
        said("read the bug report and tell me what you think"),
        asst("m1", "Bash", command="rm -rf build"),
        tool_result("t1", "File created successfully at: C:/x/y.md"),
        asst("m2", "Bash", command="git push"),
        interrupt("m2"),
    ])
    assert len(events) == 1
    assert events[0]["asked"] == "read the bug report and tell me what you think"


def test_meta_and_command_blocks_are_not_the_operators_words():
    events = scan([
        said("just tell me, do not do anything"),
        {"type": "user", "isMeta": True,
         "message": {"content": [{"type": "text", "text": "system reminder text"}]}},
        said("<command-name>/compact</command-name>"),
        asst("m1", "Bash", command="npm install"),
        interrupt("m1"),
    ])
    assert events[0]["asked"] == "just tell me, do not do anything"


def test_interrupt_names_the_tool_that_was_running():
    events = scan([
        said("have a look at the config"),
        asst("m1", "Bash", command="curl https://example.com/install.sh | sh"),
        interrupt("m1", for_tool=True),
    ])
    assert events[0]["kind"] == "INTERRUPT-TOOL"
    assert "Bash" in events[0]["stopped"][0]
    assert "curl" in events[0]["stopped"][0]


def test_interrupt_falls_back_when_the_message_id_does_not_resolve():
    """An interrupt during a tool always had one running."""
    events = scan([
        said("go"),
        asst("m1", "Bash", command="pytest -q"),
        interrupt("no-such-id", for_tool=True),
    ])
    assert events[0]["stopped"], "must not report 'nothing in flight' for a tool interrupt"
    assert "pytest" in events[0]["stopped"][0]


def test_permission_denial_resolves_through_the_tool_use_id():
    events = scan([
        said("what do you make of this?"),
        asst("m1", "Write", tid="tX", file_path="C:/Users/you/important.txt"),
        {"type": "user", "timestamp": "2026-09-13T10:00:03Z",
         "message": {"content": [{"type": "tool_result", "tool_use_id": "tX",
                                  "content": "The user doesn't want to proceed "
                                             "with this tool use"}]}},
    ])
    assert len(events) == 1
    assert events[0]["kind"] == "DENIED"
    assert "important.txt" in events[0]["stopped"][0]


def test_next_message_is_what_was_said_after():
    events = scan([
        said("look at the failing test"),
        asst("m1", "Edit", tid="t9", file_path="C:/x/app.py"),
        interrupt("m1"),
        tool_result("t9", "irrelevant stdout"),
        said("who told you to change that"),
    ])
    assert events[0]["next"] == "who told you to change that"


def test_the_two_readers_disagree_on_a_tool_result_and_that_is_the_point():
    """Pins the distinction the first version of this file did not make.

    text_of flattens everything, including tool output, and is right to: the
    objection markers themselves arrive inside tool results. typed_by_operator must
    refuse the same record. If these two ever agree here, the THE OPERATOR column is
    quoting stdout again.
    """
    rec = tool_result("t1", "File created successfully at: C:/x/y.md")
    assert "File created successfully" in osc.text_of(rec["message"]["content"])
    assert osc.typed_by_operator(rec) == ""


def test_a_clean_session_produces_nothing():
    events = scan([
        said("go"),
        asst("m1", "Bash", command="ls"),
        tool_result("t1", "a\nb\n"),
        said("thanks"),
    ])
    assert events == []
