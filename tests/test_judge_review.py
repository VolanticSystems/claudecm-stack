"""Tests for judge-review.py's sampling frame and blind labelling.

The frame exists because labelling only the judge's own refusals measures
precision and can never measure recall. That only holds if the label is the operator's
independent reading, so the thing worth pinning is that a frame case does not
show him the verdict before he answers.

    python -m pytest tests/test_judge_review.py -q
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


jr = load("judge_review", "judge-review.py")


def frame_row(**kw):
    row = {"_frame": True, "_at": "2026-09-12T10:00:00Z", "_asked": "have a look at it",
           "_next": "who told you to do that", "_interrupted": False,
           "tool": "Edit", "path": "C:/x/app.py", "session": "abcdef12",
           "at": 0, "decision": "FRAME"}
    row.update(kw)
    return row


def test_frame_case_ids_are_stable_and_distinct_from_log_cases():
    a = jr.case_id(frame_row())
    b = jr.case_id(frame_row())
    assert a == b, "the same edit must label once, not twice"
    assert a.startswith("frame|")
    log_row = {"session": "abcdef12", "prompt_id": "p1", "path": "C:/x/app.py"}
    assert jr.case_id(log_row) != a, "a frame case must not collide with a log case"


def test_two_different_edits_get_different_ids():
    a = jr.case_id(frame_row())
    b = jr.case_id(frame_row(_at="2026-09-12T11:00:00Z"))
    assert a != b


def test_blind_labelling_does_not_reveal_the_verdict(capsys):
    jr.show(frame_row(), {}, {}, 1, 1, blind=True)
    out = capsys.readouterr().out
    assert "have a look at it" in out, "he must still see what he asked for"
    assert "who told you to do that" in out, "and what he said next"
    assert "would have refused" not in out, "the verdict must not be shown while labelling blind"
    assert "votes" not in out


def test_a_refusal_review_does_show_the_verdict(capsys):
    jr.show({"session": "abcdef12", "prompt_id": "p1", "path": "C:/x/app.py",
             "tool": "Edit", "votes": "3D/0A", "at": 0}, {}, {}, 1, 1)
    out = capsys.readouterr().out
    assert "would have refused" in out
    assert "3D/0A" in out


def test_an_interrupted_edit_is_flagged_because_that_one_is_certain(capsys):
    jr.show(frame_row(_interrupted=True), {}, {}, 1, 1, blind=True)
    assert "you stopped this one" in capsys.readouterr().out


def test_the_objection_regex_is_gone():
    """It scored 17% precision over seven months. It must not come back."""
    assert not hasattr(jr, "OBJECTION"), \
        "vocabulary is not intent; use the structural interrupt record instead"
    src = open(os.path.join(ROOT, "judge-review.py"), encoding="utf-8").read()
    assert "sounds like an objection" not in src
