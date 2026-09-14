#!/usr/bin/env python3
"""Mutation checks for check-ci-activation.py."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check-ci-activation.py"
CONFIG = ROOT / "scripts/ci-activation.conf"
WORKFLOW = ROOT / ".github/workflows/ci.yml"


def on_block(text: str) -> tuple[int, int]:
    match = re.search(r"(?m)^on:\n", text)
    if not match:
        raise AssertionError("workflow has no block-style on:")
    end = re.search(r"(?m)^[A-Za-z0-9_.-]+:", text[match.end() :])
    if not end:
        raise AssertionError("workflow on: block has no following top-level key")
    return match.start(), match.end() + end.start()


def replace_on(text: str, replacement: str) -> str:
    start, end = on_block(text)
    return text[:start] + replacement + text[end:]


def change_main_branch(text: str) -> str:
    start, end = on_block(text)
    block = text[start:end]
    changed = block.replace("main", "release", 1)
    if changed == block:
        raise AssertionError("on: block has no main branch to mutate")
    return text[:start] + changed + text[end:]


def add_path_filter(text: str) -> str:
    start, end = on_block(text)
    lines = text[start:end].splitlines(keepends=True)
    push = next(i for i, line in enumerate(lines) if line == "  push:\n")
    stop = next((i for i in range(push + 1, len(lines)) if re.match(r"^  [^ ]", lines[i])), len(lines))
    lines.insert(stop, "    paths: [src/**]\n")
    return text[:start] + "".join(lines) + text[end:]


def add_job_key(text: str, key: str, value: str) -> str:
    jobs = re.search(r"(?m)^jobs:\n", text)
    if not jobs:
        raise AssertionError("workflow has no jobs:")
    match = re.search(r"(?m)^  ([A-Za-z0-9_.-]+):\n", text[jobs.end() :])
    if not match:
        raise AssertionError("workflow has no block-style job")
    insert = jobs.end() + match.end()
    return text[:insert] + f"    {key}: {value}\n" + text[insert:]


def reduce_matrix(text: str) -> str:
    changed = re.sub(r"(?m)^(        [A-Za-z0-9_.-]+:) \[[^\]]*,[^\]]*\]$", r"\1 [beta]", text, count=1)
    if changed == text:
        raise AssertionError("workflow has no multi-leg flow matrix")
    return changed


def run_case(name: str, workflow: str, should_pass: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="ci-activation-") as raw:
        root = Path(raw)
        (root / ".github/workflows").mkdir(parents=True)
        (root / "scripts").mkdir()
        (root / ".github/workflows/ci.yml").write_text(workflow)
        (root / "scripts/ci-activation.conf").write_text(CONFIG.read_text())
        result = subprocess.run(
            [sys.executable, str(CHECKER)],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if (result.returncode == 0) != should_pass:
        raise AssertionError(f"{name}: exit {result.returncode}\n{result.stdout}")


def main() -> None:
    workflow = WORKFLOW.read_text()
    cases = {
        "baseline": (workflow, True),
        "dispatch-only": (replace_on(workflow, "on:\n  workflow_dispatch:\n\n"), False),
        "branch-away-from-main": (change_main_branch(workflow), False),
        "path-filter": (add_path_filter(workflow), False),
        "job-if-false": (add_job_key(workflow, "if", "false"), False),
        "job-if-nonobvious": (
            add_job_key(workflow, "if", "${{ github.event_name == 'schedule' }}"),
            False,
        ),
        "job-continue-on-error": (add_job_key(workflow, "continue-on-error", "true"), False),
        "job-needs": (add_job_key(workflow, "needs", "never-runs"), False),
        "unsupported-flow-on": (replace_on(workflow, "on: [push, pull_request]\n\n"), False),
    }
    if re.search(r"(?m)^        [A-Za-z0-9_.-]+: \[[^\]]*,[^\]]*\]$", workflow):
        cases["matrix-reduced"] = (reduce_matrix(workflow), False)
    for name, (text, should_pass) in cases.items():
        run_case(name, text, should_pass)
    print(f"test-ci-activation: OK — {len(cases)} baseline/mutation cases")


if __name__ == "__main__":
    main()
