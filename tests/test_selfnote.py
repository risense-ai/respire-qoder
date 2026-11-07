"""T1-4 selfNote tests (no real engine): cadence trigger, evidence whitelist, host
validator, parent exemption, PreToolUse flow and SessionStart injection.

All engine traffic is stubbed at ``respire.run_rsrs``; every state/log file lives in a
per-test temporary directory (``RESPITE_SELFNOTE_STATE`` / ``RESPITE_LOG`` / ...).
"""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "hooks"))
import respire as R  # noqa: E402

OLD = "33333333-3333-3333-3333-333333333333"     # previous live selfNote
R1 = "11111111-1111-1111-1111-111111111111"      # older recent evidence
R2 = "22222222-2222-2222-2222-222222222222"      # newer recent evidence
R3 = "44444444-4444-4444-4444-444444444444"      # important but outside the window
R4 = "55555555-5555-5555-5555-555555555555"      # superseded
R5 = "66666666-6666-6666-6666-666666666666"      # trivial importance
REV1 = "sha256:" + "a" * 64
REV2 = "sha256:" + "b" * 64
REV3 = "sha256:" + "c" * 64
REV4 = "sha256:" + "d" * 64
OLD_CONTENT = "I keep answers plain and grounded, never dramatic."
NEW_CONTENT = "Every sentence cites an evidence id or the prior note."


def stamp(offset_hours):
    return time.strftime("%Y-%m-%dT%H:%M:%S",
                         time.gmtime(time.time() + offset_hours * 3600)) + ".000Z"


def cfg(**over):
    c = dict(R.DEFAULTS)
    c.update(over)
    return c


def ok(stdout):
    return SimpleNamespace(returncode=0, stdout=json.dumps(stdout), stderr="")


def list_doc():
    return {"status": "ok", "details": [
        {"id": OLD, "kind": "self", "project": "selfnote:qoder",
         "created_at": stamp(-50), "title": R.SELFNOTE_TITLE, "content": OLD_CONTENT},
        {"id": R2, "kind": "memory", "importance": "important",
         "created_at": stamp(-60), "title": "beta recent fact", "content": "b"},
        {"id": R1, "kind": "memory", "importance": "important",
         "created_at": stamp(-80), "title": "alpha recent fact", "content": "a"},
        {"id": R3, "kind": "memory", "importance": "important",
         "created_at": stamp(-400), "title": "stale fact", "content": "s"},
        {"id": R4, "kind": "memory", "importance": "important",
         "created_at": stamp(-70), "title": "gone fact", "content": "x",
         "superseded_by": "77777777-7777-7777-7777-777777777777"},
        {"id": R5, "kind": "memory", "importance": "trivial",
         "created_at": stamp(-65), "title": "trivial fact", "content": "t"},
    ]}


def recall_doc():
    return {"status": "ok", "details": [
        {"id": R2, "title": "beta recent fact",
         "evidence": {"id": R2, "record_revision": REV2}},
        {"id": R1, "title": "alpha recent fact",
         "evidence": {"id": R1, "record_revision": REV1}},
        {"id": R3, "title": "stale fact",
         "evidence": {"id": R3, "record_revision": REV3}},
        {"id": R4, "title": "gone fact", "superseded_by": "77777777-7777-7777-7777-777777777777",
         "evidence": {"id": R4, "record_revision": REV4}},
    ]}


def engine_stub(calls=None):
    def run(engine, args, timeout):
        if calls is not None:
            calls.append(list(args))
        if args[0] == "list":
            return ok(list_doc())
        if args[0] == "recall":
            return ok(recall_doc())
        raise AssertionError(f"unexpected engine call: {args}")
    return run


def deny_stub(*_args, **_kwargs):
    raise AssertionError("engine must not be called")


class SelfnoteCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="selfnote-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        env = patch.dict(os.environ, {
            "RESPITE_SELFNOTE_STATE": str(root / "selfnote.json"),
            "RESPITE_LOG": str(root / "hook.log"),
            "QODER_PLUGIN_DATA": str(root / "data"),
            "RESPITE_NUDGE_STATE": str(root / "nudge"),
            "RESPITE_TURN_STATE": str(root / "turns"),
        })
        env.start()
        self.addCleanup(env.stop)
        self.state_path = root / "selfnote.json"
        self.log_path = root / "hook.log"

    # -- helpers ----------------------------------------------------------
    def read_state(self):
        if not self.state_path.exists():
            return {}
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def write_state(self, **fields):
        self.state_path.write_text(json.dumps(fields), encoding="utf-8")

    def seed_awaiting(self, old_id=OLD, old_content=OLD_CONTENT, whitelist=None):
        self.write_state(
            awaiting=True,
            whitelist=whitelist if whitelist is not None
            else {R1: {"t": "alpha recent fact", "rev": REV1}},
            old_id=old_id,
            old_content=old_content,
            last_fire_ms=time.time() * 1000 - 200 * 3600 * 1000,
            sessions=0,
            last_session="seeded",
        )

    def seed_due(self, sessions=25, last_fire_hours=-200, session="sess-a"):
        self.write_state(
            awaiting=False,
            whitelist={},
            old_id="",
            old_content="",
            last_fire_ms=time.time() * 1000 + last_fire_hours * 3600 * 1000,
            sessions=sessions,
            last_session="previous-session",
        )


class DefaultsAndHelpers(SelfnoteCase):
    def test_defaults_are_off_and_dry(self):
        self.assertIs(R.DEFAULTS["selfnote"], False)
        self.assertIs(R.DEFAULTS["selfnote_dry_run"], True)
        self.assertIs(R.DEFAULTS["selfnote_inject"], False)
        self.assertEqual(R.DEFAULTS["selfnote_every_sessions"], 20)
        self.assertEqual(R.DEFAULTS["selfnote_every_hours"], 168)
        self.assertEqual(R.DEFAULTS["selfnote_min_hours"], 24)
        self.assertEqual(R.DEFAULTS["selfnote_max_chars"], 1200)
        self.assertEqual(R.DEFAULTS["selfnote_inject_chars"], 300)

    def test_extract_head_respects_cap(self):
        self.assertLessEqual(len(R.extract_head("x" * 500, 30)), 30)
        head = R.extract_head("Short fact stated! " + "padding words " * 10, 70)
        self.assertEqual(head, "Short fact stated!")   # first complete sentence wins

    def test_selfnote_type_detection(self):
        self.assertEqual(R._selfnote_type(["--type", "self"]), "self")
        self.assertEqual(R._selfnote_type(["--type=self"]), "self")
        self.assertEqual(R._selfnote_type(["--title", "t", "--type", "self", "--json"]), "self")
        self.assertEqual(R._selfnote_type(["--parent", "abc", "--type", "self"]), "self")
        self.assertEqual(R._selfnote_type(["content", "--importance", "important"]), "")
        # a value reading like "self" must be swallowed as an option value, never as --type
        self.assertEqual(R._selfnote_type(["--summary", "self"]), "")
        self.assertEqual(R._selfnote_type(["--summary", "self", "--type", "memory"]), "memory")

    def test_parse_valid_and_strict(self):
        fields = R._selfnote_parse([
            "body", "--type", "self", "--importance", "important",
            "--title", R.SELFNOTE_TITLE, "--project", "selfnote:qoder",
            "--source-refs", "[{\"id\": \"x\"}]", "--json"])
        self.assertEqual(fields["content"], "body")
        self.assertEqual(fields["--type"], "self")
        for bad in (["--force", "body"], ["body", "--merge-ids", "x"],
                    ["a", "b", "--type", "self"], ["--type"],
                    ["--title", "x", "--title", "y", "body"],
                    ["--content", "c", "positional"], []):
            with self.assertRaises(ValueError, msg=bad):
                R._selfnote_parse(bad)


class EvidencePipeline(SelfnoteCase):
    def test_ok_orders_by_recency_and_drops_non_citable(self):
        with patch.object(R, "run_rsrs", engine_stub()):
            wl, old_id, old_content, reason = R.selfnote_evidence(
                "engine", cfg(), time.time() - 168 * 3600)
        self.assertEqual(reason, "ok")
        self.assertEqual(list(wl), [R2, R1])           # recency order, old id excluded
        self.assertEqual(wl[R1]["rev"], REV1)
        self.assertEqual(wl[R2]["rev"], REV2)
        self.assertEqual(old_id, OLD)
        self.assertEqual(old_content, OLD_CONTENT)

    def test_no_recent_keeps_old_version(self):
        doc = list_doc()
        for row in doc["details"]:
            if row["id"] in (R1, R2, R4, R5):
                row["created_at"] = stamp(-400)        # everything recent falls out
        with patch.object(R, "run_rsrs",
                          lambda *a: ok(doc) if a[1][0] == "list" else ok(recall_doc())):
            wl, old_id, _, reason = R.selfnote_evidence("engine", cfg(), time.time())
        self.assertEqual(reason, "no_recent")
        self.assertEqual(wl, {})
        self.assertEqual(old_id, OLD)

    def test_no_citable_when_recall_confirms_nothing(self):
        with patch.object(R, "run_rsrs",
                          lambda *a: ok(list_doc()) if a[1][0] == "list"
                          else ok({"status": "skip", "details": []})):
            wl, _, _, reason = R.selfnote_evidence("engine", cfg(), time.time() - 168 * 3600)
        self.assertEqual(reason, "no_citable")
        self.assertEqual(wl, {})

    def test_list_failure_is_fail(self):
        with patch.object(R, "run_rsrs",
                          lambda *a: ok({"status": "fail", "errors": ["x"]})):
            wl, _, _, reason = R.selfnote_evidence("engine", cfg(), time.time())
        self.assertEqual(reason, "fail")
        self.assertEqual(wl, {})

    def test_evidence_cap(self):
        with patch.object(R, "run_rsrs", engine_stub()):
            wl, _, _, reason = R.selfnote_evidence(
                "engine", cfg(selfnote_evidence_limit=1), time.time() - 168 * 3600)
        self.assertEqual(reason, "ok")
        self.assertEqual(list(wl), [R2])               # newest only


class Directive(SelfnoteCase):
    def test_directive_carries_contract_evidence_and_command(self):
        wl = {R1: {"t": "alpha recent fact", "rev": REV1}}
        text = R.selfnote_directive(cfg(), wl, OLD, OLD_CONTENT)
        self.assertIn("【respire · selfNote generation】", text)
        self.assertIn(f"- [{R1[:8]}] alpha recent fact | id={R1} | rev={REV1}", text)
        self.assertIn(f"--supersedes {OLD}", text)
        self.assertIn(f'--title "{R.SELFNOTE_TITLE}" --type self --importance important',
                      text)
        self.assertIn("--project selfnote:qoder", text)
        self.assertIn("source_refs", text)
        self.assertIn("never add --force", text)
        self.assertIn(OLD_CONTENT, text)

    def test_directive_without_previous_version_omits_supersedes(self):
        wl = {R1: {"t": "alpha", "rev": REV1}}
        text = R.selfnote_directive(cfg(), wl, "", "")
        command = text.split("Run EXACTLY ONE command", 1)[1]
        self.assertNotIn("--supersedes", command)
        self.assertIn("first selfNote", text)


class StepCadence(SelfnoteCase):
    def test_off_returns_without_touching_engine_or_state(self):
        with patch.object(R, "run_rsrs", deny_stub):
            self.assertEqual(R.selfnote_step({"session_id": "s"}, dict(R.DEFAULTS), "e"), "")
        self.assertFalse(self.state_path.exists())

    def test_first_run_only_starts_the_clock(self):
        with patch.object(R, "run_rsrs", deny_stub):
            out = R.selfnote_step({"session_id": "s1"}, cfg(selfnote=True), "e")
        self.assertEqual(out, "")
        state = self.read_state()
        self.assertGreater(state["last_fire_ms"], 0)
        self.assertEqual(state["sessions"], 1)
        self.assertNotIn("awaiting", state)

    def test_not_due_is_one_file_write_no_subprocess(self):
        self.seed_due(sessions=3, last_fire_hours=-2)
        calls = []
        with patch.object(R, "run_rsrs", engine_stub(calls)):
            out = R.selfnote_step({"session_id": "s2"}, cfg(selfnote=True), "e")
        self.assertEqual(out, "")
        self.assertEqual(calls, [])
        self.assertEqual(self.read_state()["sessions"], 4)   # session counted

    def test_floor_blocks_due_but_not_permanently(self):
        self.seed_due(sessions=25, last_fire_hours=-2)       # due by sessions, inside 24h
        calls = []
        with patch.object(R, "run_rsrs", engine_stub(calls)):
            out = R.selfnote_step({"session_id": "s2"}, cfg(selfnote=True), "e")
        self.assertEqual(out, "")
        self.assertEqual(calls, [])
        state = self.read_state()
        self.assertFalse(state.get("awaiting"))
        self.assertLess(state["last_fire_ms"], time.time() * 1000 - 3600 * 1000)

    def test_due_fires_one_directive_and_resets_window(self):
        self.seed_due(sessions=25, last_fire_hours=-200)
        with patch.object(R, "run_rsrs", engine_stub()):
            out = R.selfnote_step({"session_id": "s2"}, cfg(selfnote=True), "e")
        self.assertIsInstance(out, str)
        payload = json.loads(out)
        self.assertEqual(payload["decision"], "deny")
        reason = payload["reason"]
        self.assertIn(f"id={R2}", reason)
        self.assertIn(f"id={R1}", reason)
        self.assertIn(f"--supersedes {OLD}", reason)
        state = self.read_state()
        self.assertTrue(state["awaiting"])
        self.assertEqual(list(state["whitelist"]), [R2, R1])
        self.assertEqual(state["old_id"], OLD)
        self.assertEqual(state["old_content"], OLD_CONTENT)
        self.assertEqual(state["sessions"], 0)
        self.assertGreater(state["last_fire_ms"], time.time() * 1000 - 60 * 1000)
        # window burned: an immediate second Stop never re-fires
        calls = []
        with patch.object(R, "run_rsrs", engine_stub(calls)):
            self.assertEqual(
                R.selfnote_step({"session_id": "s3"}, cfg(selfnote=True), "e"), "")
        self.assertEqual(calls, [])

    def test_weekly_trigger_without_session_threshold(self):
        self.seed_due(sessions=0, last_fire_hours=-200)
        with patch.object(R, "run_rsrs", engine_stub()):
            out = R.selfnote_step({"session_id": "s2"}, cfg(selfnote=True), "e")
        self.assertEqual(json.loads(out)["decision"], "deny")

    def test_engine_fault_burns_window_quietly(self):
        self.seed_due(sessions=25, last_fire_hours=-200)
        calls = []

        def boom(*_a):
            calls.append(1)
            raise RuntimeError("engine down")

        with patch.object(R, "run_rsrs", boom):
            self.assertEqual(R.selfnote_step({"session_id": "s2"}, cfg(selfnote=True), "e"), "")
        state = self.read_state()
        self.assertFalse(state.get("awaiting"))
        self.assertEqual(state.get("whitelist"), {})
        self.assertEqual(len(calls), 1)
        with patch.object(R, "run_rsrs", engine_stub(calls)):
            self.assertEqual(
                R.selfnote_step({"session_id": "s3"}, cfg(selfnote=True), "e"), "")
        self.assertEqual(len(calls), 1)                 # no refire inside the floor

    def test_no_recent_clears_awaiting(self):
        self.seed_due(sessions=25, last_fire_hours=-200)
        doc = list_doc()
        for row in doc["details"]:
            if row["id"] in (R1, R2, R4, R5):
                row["created_at"] = stamp(-400)
        with patch.object(R, "run_rsrs",
                          lambda *a: ok(doc) if a[1][0] == "list" else ok(recall_doc())):
            out = R.selfnote_step({"session_id": "s2"}, cfg(selfnote=True), "e")
        self.assertEqual(out, "")
        state = self.read_state()
        self.assertFalse(state.get("awaiting"))
        self.assertEqual(state.get("whitelist"), {})


class GuardValidation(SelfnoteCase):
    def guard(self, args, **over):
        return R.selfnote_guard(args, cfg(selfnote=True, **over))

    def valid_args(self, **replace):
        """The contract-shaped arg list; ``replace`` overrides an option value (None
        removes it), adds a new option (e.g. --parent), or sets ``content``."""
        opts = {
            "--title": R.SELFNOTE_TITLE,
            "--type": "self",
            "--importance": "important",
            "--project": "selfnote:qoder",
            "--summary": "short summary",
            "--source-refs": json.dumps([{"id": R1, "revision": REV1, "required": True}]),
            "--valid-until": "2027-06-01T00:00:00.000Z",
            "--supersedes": OLD,
        }
        content = NEW_CONTENT
        flags = ["--json"]
        for key, value in replace.items():
            name = key if key.startswith("--") else "--" + key
            if key == "content":
                content = value
            elif value is None:
                opts.pop(name, None)
                if name in flags:
                    flags.remove(name)
            else:
                opts[name] = value
        args = [content]
        for name, value in opts.items():
            args += [name, value]
        return args + flags

    def test_valid_write_passes(self):
        self.seed_awaiting()
        self.assertEqual(self.guard(self.valid_args()), "")

    def test_no_awaiting_denies(self):
        self.write_state(awaiting=False, whitelist={})
        self.assertIn("awaiting", self.guard(self.valid_args()))

    def test_empty_whitelist_denies(self):
        self.seed_awaiting(whitelist={})
        self.assertIn("awaiting", self.guard(self.valid_args()))

    def test_disabled_even_with_awaiting(self):
        self.seed_awaiting()
        self.assertIn("disabled", R.selfnote_guard(self.valid_args(), dict(R.DEFAULTS)))

    def test_fixed_fields_enforced(self):
        self.seed_awaiting()
        self.assertIn("title", self.guard(self.valid_args(title="persona")))
        self.assertIn("project", self.guard(self.valid_args(project="other:scope")))
        self.assertIn("importance", self.guard(self.valid_args(importance="trivial")))
        self.assertIn("type", self.guard(self.valid_args(type="memory")))

    def test_content_rules(self):
        self.seed_awaiting()
        self.assertIn("exceeds", self.guard(self.valid_args(content="x" * 1201)))
        self.assertIn("markers",
                      self.guard(self.valid_args(content="hi " + R.SELFNOTE_START)))
        self.assertIn("secret",
                      self.guard(self.valid_args(content="password: hunter2")))
        self.assertIn("empty", self.guard(self.valid_args(content="   ")))

    def test_source_refs_rules(self):
        self.seed_awaiting()
        self.assertIn("source_refs required", self.guard(self.valid_args(**{"--source-refs": None})))
        self.assertIn("not JSON",
                      self.guard(self.valid_args(**{"--source-refs": "{nope"})))
        self.assertIn("non-empty",
                      self.guard(self.valid_args(**{"--source-refs": "[]"})))
        self.assertIn("not in evidence whitelist",
                      self.guard(self.valid_args(**{
                          "--source-refs": json.dumps(
                              [{"id": R3, "revision": REV3, "required": True}])})))
        self.assertIn("revision mismatch",
                      self.guard(self.valid_args(**{
                          "--source-refs": json.dumps(
                              [{"id": R1, "revision": REV2, "required": True}])})))
        self.assertIn("duplicate",
                      self.guard(self.valid_args(**{
                          "--source-refs": json.dumps(
                              [{"id": R1, "revision": REV1, "required": True},
                               {"id": R1, "revision": REV1, "required": True}])})))
        self.assertIn("boolean",
                      self.guard(self.valid_args(**{
                          "--source-refs": json.dumps(
                              [{"id": R1, "revision": REV1, "required": "yes"}])})))
        self.assertIn("full uuid",
                      self.guard(self.valid_args(**{
                          "--source-refs": json.dumps(
                              [{"id": "deadbeef", "revision": REV1, "required": True}])})))

    def test_supersedes_chain(self):
        self.seed_awaiting()
        self.assertIn("supersedes required", self.guard(self.valid_args(**{"--supersedes": None})))
        self.assertIn("previous version",
                      self.guard(self.valid_args(supersedes=R2)))
        # no previous version -> the option must be absent
        self.seed_awaiting(old_id="", old_content="")
        self.assertIn("no previous version",
                      self.guard(self.valid_args(supersedes=OLD)))

    def test_valid_until_and_summary(self):
        self.seed_awaiting()
        self.assertIn("valid_until",
                      self.guard(self.valid_args(**{"--valid-until": "2027-06-01"})))
        self.assertIn("summary",
                      self.guard(self.valid_args(summary="s" * 121)))

    def test_duplicate_and_rephrase_of_old(self):
        self.seed_awaiting()
        self.assertIn("duplicate",
                      self.guard(self.valid_args(content=OLD_CONTENT)))
        rephrase = OLD_CONTENT + " indeed"
        self.assertIn("rephrase", self.guard(self.valid_args(content=rephrase)))

    def test_bypass_and_unknown_options(self):
        self.seed_awaiting()
        self.assertIn("bypass", self.guard(["--force"] + self.valid_args()[1:]))
        self.assertIn("unsupported", self.guard(self.valid_args(**{"--parent": R1})))
        self.assertIn("unsupported", self.guard(self.valid_args(**{"--merge-ids": R1})))

    def test_help_is_not_a_write(self):
        self.seed_awaiting()
        self.assertEqual(self.guard(["--help"]), "")

    def test_content_twice_denied(self):
        self.seed_awaiting()
        args = self.valid_args()
        args.extend(["--content", "second"])
        self.assertIn("twice", self.guard(args))


class WriteParentExemption(SelfnoteCase):
    def test_self_note_needs_no_parent(self):
        parent, target = R._write_parent("remember", [
            NEW_CONTENT, "--type", "self", "--importance", "important",
            "--title", R.SELFNOTE_TITLE, "--json"])
        self.assertIsNone(parent)
        self.assertIsNone(target)

    def test_ordinary_important_creation_still_requires_parent(self):
        with self.assertRaisesRegex(ValueError, "missing parent"):
            R._write_parent("remember", ["body", "--importance", "important"])
        with self.assertRaisesRegex(ValueError, "missing parent"):
            R._write_parent("remember", ["body", "--type", "memory",
                                         "--importance", "important"])

    def test_self_note_with_parent_keeps_it(self):
        parent, _ = R._write_parent("remember", [
            "body", "--type", "self", "--importance", "important", "--parent", R1])
        self.assertEqual(parent, R1)


class PreToolUseFlow(SelfnoteCase):
    def payload(self, command):
        return {"tool_name": "bash", "tool_input": {"command": command}}

    def command(self, **replace):
        args = GuardValidation.valid_args(self, **replace)
        parts = ["rsrs remember", f'"{args[0]}"']
        i = 1
        while i < len(args):
            name = args[i]
            if (name.startswith("--") and i + 1 < len(args)
                    and not args[i + 1].startswith("--")):
                value = args[i + 1]
                if any(ch.isspace() for ch in value) or value[:1] in "[{":
                    value = f"'{value}'"
                parts += [name, value]
                i += 2
            else:
                parts.append(name)
                i += 1
        return " ".join(parts)

    def test_passing_write_allows_and_consumes(self):
        self.seed_awaiting()
        with patch.object(R, "load_config", lambda: cfg(selfnote=True)):
            out = R.on_pre_tool_use(self.payload(self.command()))
        self.assertEqual(out, "")
        state = self.read_state()
        self.assertFalse(state["awaiting"])
        self.assertEqual(state["whitelist"], {})
        self.assertIn("last_ok_ms", state)

    def test_failing_write_denies_and_keeps_awaiting(self):
        self.seed_awaiting()
        bad = self.command(**{"--source-refs": json.dumps(
            [{"id": R1, "revision": REV2, "required": True}])})
        with patch.object(R, "load_config", lambda: cfg(selfnote=True)):
            out = R.on_pre_tool_use(self.payload(bad))
        self.assertEqual(
            out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("revision mismatch",
                      out["hookSpecificOutput"]["permissionDecisionReason"])
        state = self.read_state()
        self.assertTrue(state["awaiting"])            # unconsumed: retry stays guarded
        self.assertEqual(list(state["whitelist"]), [R1])

    def test_awaiting_missing_denies_even_well_formed(self):
        self.write_state(awaiting=False, whitelist={})
        with patch.object(R, "load_config", lambda: cfg(selfnote=True)):
            out = R.on_pre_tool_use(self.payload(self.command()))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("awaiting",
                      out["hookSpecificOutput"]["permissionDecisionReason"])

    def test_ordinary_important_write_without_parent_still_denied(self):
        self.seed_awaiting()                         # selfNote state must not loosen others
        with patch.object(R, "load_config", lambda: cfg(selfnote=True)):
            out = R.on_pre_tool_use(self.payload('rsrs remember "body" --importance important'))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("blocked this memory write",
                      out["hookSpecificOutput"]["permissionDecisionReason"])
        self.assertTrue(self.read_state()["awaiting"])


class Injection(SelfnoteCase):
    def test_default_config_never_calls_engine(self):
        with patch.object(R, "run_rsrs", deny_stub):
            self.assertEqual(R.selfnote_inject(dict(R.DEFAULTS), "e"), "")

    def test_dry_run_blocks_injection_even_when_enabled(self):
        with patch.object(R, "run_rsrs", deny_stub):
            self.assertEqual(
                R.selfnote_inject(cfg(selfnote=True, selfnote_inject=True), "e"), "")

    def test_renders_one_managed_block(self):
        c = cfg(selfnote=True, selfnote_inject=True, selfnote_dry_run=False)
        with patch.object(R, "run_rsrs",
                          lambda *a: ok(list_doc()) if a[1][0] == "list"
                          else ok(recall_doc())):
            block = R.selfnote_inject(c, "e")
        self.assertTrue(block.startswith(R.SELFNOTE_START + "\n"))
        self.assertTrue(block.endswith("\n" + R.SELFNOTE_END))
        brief = block[len(R.SELFNOTE_START) + 1:-(len(R.SELFNOTE_END) + 1)]
        self.assertEqual(len(brief), len(R.extract_head(OLD_CONTENT, 300)))
        self.assertLessEqual(len(brief), 300)

    def test_no_record_and_fault_skip_quietly(self):
        c = cfg(selfnote=True, selfnote_inject=True, selfnote_dry_run=False)
        empty = {"status": "ok", "details": []}
        with patch.object(R, "run_rsrs", lambda *a: ok(empty)):
            self.assertEqual(R.selfnote_inject(c, "e"), "")
        with patch.object(R, "run_rsrs", deny_stub):
            pass_gated = cfg(selfnote=False, selfnote_inject=True, selfnote_dry_run=False)
            self.assertEqual(R.selfnote_inject(pass_gated, "e"), "")


class OnStopIntegration(SelfnoteCase):
    def test_stop_hook_active_skips_everything(self):
        with patch.object(R, "run_rsrs", deny_stub):
            out = R.on_stop({"stop_hook_active": True, "session_id": "s"},
                            cfg(selfnote=True), "e")
        self.assertEqual(out, "")

    def test_default_config_falls_through_to_nudge_path(self):
        with patch.object(R, "run_rsrs", deny_stub):
            out = R.on_stop({"session_id": "s"}, dict(R.DEFAULTS), "e")
        self.assertEqual(out, "")                     # first Stop: n=1, every=4 -> skip

    def test_due_stop_returns_generation_directive(self):
        self.seed_due(sessions=25, last_fire_hours=-200)
        with patch.object(R, "run_rsrs", engine_stub()):
            out = R.on_stop({"session_id": "s2"}, cfg(selfnote=True), "e")
        payload = json.loads(out)
        self.assertEqual(payload["decision"], "deny")
        self.assertIn("selfNote generation", payload["reason"])
        self.assertTrue(self.read_state()["awaiting"])


if __name__ == "__main__":
    unittest.main()
