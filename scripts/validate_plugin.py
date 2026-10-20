#!/usr/bin/env python3
"""respire-qoder 包自检（零第三方依赖）。

用法: python3 scripts/validate_plugin.py
退出码 0 = 通过；任一 FAIL = 1。
"""
from __future__ import annotations

import json
import os
import py_compile
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
failed = False


def ok(msg: str) -> None:
    print(f"OK: {msg}")


def fail(msg: str) -> None:
    global failed
    failed = True
    print(f"FAIL: {msg}", file=sys.stderr)


def load_json(rel: str):
    p = os.path.join(ROOT, rel)
    if not os.path.isfile(p):
        fail(f"missing {rel}")
        return None
    try:
        with open(p, encoding="utf-8") as f:
            doc = json.load(f)
        ok(rel)
        return doc
    except Exception as e:
        fail(f"{rel}: {e}")
        return None


def check_path(field: str, rel) -> None:
    if not isinstance(rel, str):
        fail(f"{field}: not a string")
        return
    if not rel.startswith("./"):
        fail(f"{field}: must start with ./ ({rel})")
        return
    if ".." in rel:
        fail(f"{field}: must not contain .. ({rel})")
        return
    p = os.path.join(ROOT, rel[2:])
    if not os.path.exists(p):
        fail(f"{field}: missing target {rel}")
    else:
        ok(f"{field} -> {rel}")


def main() -> None:
    manifest = load_json(".qoder-plugin/plugin.json")
    if manifest:
        for key in ("name", "version"):
            if not manifest.get(key):
                fail(f"manifest missing {key}")
        name = str(manifest.get("name", ""))
        if name != os.path.basename(ROOT):
            fail(f"manifest name {name} != folder {os.path.basename(ROOT)}")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
            fail("manifest name must be kebab-case")
        for key in ("skills", "hooks", "mcpServers"):
            if key in manifest:
                check_path(key, manifest[key])

    market = load_json(".qoder-plugin/marketplace.json")
    if market:
        if not market.get("name") or not market.get("owner"):
            fail("marketplace.json missing name/owner")
        names = [p.get("name") for p in (market.get("plugins") or []) if isinstance(p, dict)]
        if manifest and manifest.get("name") not in names:
            fail("marketplace.json does not list the plugin")

    hooks = load_json("hooks/hooks.json")
    if hooks:
        events = hooks.get("hooks") or {}
        for ev in ("SessionStart", "UserPromptSubmit", "Stop"):
            if ev not in events:
                fail(f"hooks.json missing event {ev}")
        text = json.dumps(events, ensure_ascii=False)
        if "${QODER_PLUGIN_ROOT}" not in text:
            fail("hooks.json must use ${QODER_PLUGIN_ROOT}")
        for ev, groups in events.items():
            if not isinstance(groups, list):
                fail(f"hooks.json {ev} must be a list")
                continue
            for g in groups:
                for h in (g.get("hooks") or []):
                    if h.get("type") == "command" and not h.get("command"):
                        fail(f"hooks.json {ev} command missing")

    skill = os.path.join(ROOT, "skills", "respire", "SKILL.md")
    if not os.path.isfile(skill):
        fail("missing skills/respire/SKILL.md")
    else:
        text = open(skill, encoding="utf-8").read()
        if not text.startswith("---"):
            fail("SKILL.md missing frontmatter")
        else:
            fm = text.split("---", 2)[1]
            for key in ("name:", "description:"):
                if key not in fm:
                    fail(f"SKILL.md frontmatter missing {key}")
            ok("skills/respire/SKILL.md")

    hook_py = os.path.join(ROOT, "hooks", "respire.py")
    try:
        py_compile.compile(hook_py, doraise=True)
        ok("hooks/respire.py compiles")
    except Exception as e:
        fail(f"hook compile: {e}")

    src = open(hook_py, encoding="utf-8").read()
    if '"decision": "deny"' not in src:
        fail("Stop hook must return decision deny for Qoder")
    if "fail-open" not in src and "fail_open" not in src:
        fail("hook should document fail-open behavior")

    for bad in (".codex-plugin", ".claude-plugin", ".cursor-plugin"):
        if os.path.exists(os.path.join(ROOT, bad)):
            fail(f"non-Qoder manifest directory present: {bad}")

    for required in ("README.md", "LICENSE", "tests/test_hooks.sh"):
        if os.path.isfile(os.path.join(ROOT, required)):
            ok(required)
        else:
            fail(f"missing {required}")

    secret = re.compile(r"(sk-[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)")
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__")]
        for fn in filenames:
            if fn.startswith(".") and fn != ".gitignore":
                continue
            p = os.path.join(dirpath, fn)
            try:
                text = open(p, encoding="utf-8", errors="ignore").read()
            except Exception:
                continue
            if secret.search(text):
                fail(f"possible secret in {os.path.relpath(p, ROOT)}")

    if failed:
        print("VALIDATION FAILED", file=sys.stderr)
        sys.exit(1)
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
