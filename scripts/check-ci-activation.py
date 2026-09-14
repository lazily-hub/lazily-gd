#!/usr/bin/env python3
"""Fail closed when a counted GitHub Actions workflow cannot enforce its gates."""

from __future__ import annotations

import fnmatch
import re
import sys
from pathlib import Path


def scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def values(value: str, where: str) -> list[str]:
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        body = value[1:-1].strip()
        return [] if not body else [scalar(part) for part in body.split(",")]
    if value:
        return [scalar(value)]
    raise ValueError(f"{where}: expected a scalar or flow list")


def load_config(path: Path) -> dict[str, list[str]]:
    allowed = {
        "workflow",
        "expected-triggers",
        "expected-trigger-filter",
        "expected-gate-job",
        "expected-job-activation",
        "expected-job-matrix",
        "required-blocking-leg",
    }
    out = {key: [] for key in allowed}
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.rstrip("\r")
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            raise ValueError(f"{path}:{number}: expected key: value")
        key, value = line.split(":", 1)
        value = value.strip()
        if key not in allowed:
            raise ValueError(f"{path}:{number}: unknown key {key!r}")
        if not value:
            raise ValueError(f"{path}:{number}: empty {key}")
        out[key].append(value)
    if not out["workflow"]:
        raise ValueError(f"{path}: no workflow entries")
    return out


def parse_workflow(path: Path) -> tuple[dict[str, dict[str, list[str]]], dict[str, dict[str, object]]]:
    triggers: dict[str, dict[str, list[str]]] = {}
    jobs: dict[str, dict[str, object]] = {}
    section = ""
    trigger = ""
    pending_filter = ""
    job = ""
    job_mode = ""
    in_matrix = False
    pending_axis = ""

    def bad(number: int, text: str, reason: str) -> ValueError:
        return ValueError(f"{path}:{number}: {reason}: {text.strip()}")

    for number, raw in enumerate(path.read_text().splitlines(), 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise bad(number, raw, "tabs are unsupported in YAML indentation")
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        text = line.strip()

        if indent == 0:
            trigger = pending_filter = job = job_mode = pending_axis = ""
            in_matrix = False
            if text == "on:":
                section = "on"
            elif text.startswith("on:"):
                raise bad(number, raw, "inline/flow-style on is unsupported")
            elif text == "jobs:":
                section = "jobs"
            elif re.fullmatch(r"[A-Za-z0-9_.-]+:.*", text):
                section = "other"
            else:
                raise bad(number, raw, "unsupported top-level YAML shape")
            continue

        if section == "on":
            if indent == 2:
                pending_filter = ""
                match = re.fullmatch(r"  ([A-Za-z0-9_.-]+):", line)
                if not match:
                    raise bad(number, raw, "trigger must be a two-space block key")
                trigger = match.group(1)
                if trigger in triggers:
                    raise bad(number, raw, "duplicate trigger")
                triggers[trigger] = {}
                continue
            if not trigger:
                raise bad(number, raw, "filter appears before a trigger")
            if indent == 4:
                match = re.fullmatch(r"    ([A-Za-z0-9_.-]+):(.*)", line)
                if not match:
                    raise bad(number, raw, "unsupported trigger-filter shape")
                key, value = match.group(1), match.group(2).strip()
                if key in triggers[trigger]:
                    raise bad(number, raw, "duplicate trigger filter")
                if value:
                    triggers[trigger][key] = values(value, f"{path}:{number}")
                    pending_filter = ""
                else:
                    triggers[trigger][key] = []
                    pending_filter = key
                continue
            if indent == 6 and text.startswith("-"):
                if not pending_filter:
                    raise bad(number, raw, "list item has no trigger filter")
                value = text[1:].strip()
                if not value or re.search(r":\s", value):
                    raise bad(number, raw, "trigger-filter maps are unsupported")
                triggers[trigger][pending_filter].append(scalar(value))
                continue
            raise bad(number, raw, "unsupported trigger-filter indentation")

        if section == "jobs":
            if indent == 2:
                pending_axis = ""
                match = re.fullmatch(r"  ([A-Za-z0-9_.-]+):", line)
                if not match:
                    raise bad(number, raw, "job must be a two-space block key")
                job = match.group(1)
                if job in jobs:
                    raise bad(number, raw, "duplicate job")
                jobs[job] = {"activation": {}, "matrix": {}}
                job_mode = ""
                in_matrix = False
                continue
            if not job:
                raise bad(number, raw, "job content appears before a job")
            if indent == 4:
                pending_axis = ""
                match = re.fullmatch(r"    ([A-Za-z0-9_.-]+):(.*)", line)
                if not match:
                    raise bad(number, raw, "unsupported job-level shape")
                key, value = match.group(1), match.group(2).strip()
                job_mode = "strategy" if key == "strategy" else "other"
                in_matrix = False
                if key in {"if", "needs", "continue-on-error"}:
                    if not value:
                        raise bad(number, raw, f"block-valued {key} is unsupported")
                    activation = jobs[job]["activation"]
                    assert isinstance(activation, dict)
                    if key in activation:
                        raise bad(number, raw, f"duplicate {key}")
                    activation[key] = ",".join(values(value, f"{path}:{number}"))
                continue
            if job_mode != "strategy":
                continue
            if indent == 6:
                pending_axis = ""
                match = re.fullmatch(r"      ([A-Za-z0-9_.-]+):(.*)", line)
                if not match:
                    raise bad(number, raw, "unsupported strategy shape")
                in_matrix = match.group(1) == "matrix"
                continue
            if not in_matrix:
                continue
            if indent == 8:
                match = re.fullmatch(r"        ([A-Za-z0-9_.-]+):(.*)", line)
                if not match:
                    raise bad(number, raw, "unsupported matrix shape")
                axis, value = match.group(1), match.group(2).strip()
                if axis in {"include", "exclude"}:
                    raise bad(number, raw, "matrix include/exclude is unsupported")
                matrix = jobs[job]["matrix"]
                assert isinstance(matrix, dict)
                if axis in matrix:
                    raise bad(number, raw, "duplicate matrix axis")
                matrix[axis] = values(value, f"{path}:{number}") if value else []
                pending_axis = axis if not value else ""
                continue
            if indent == 10 and text.startswith("-"):
                if not pending_axis:
                    raise bad(number, raw, "matrix item has no axis")
                value = text[1:].strip()
                if not value or re.search(r":\s", value):
                    raise bad(number, raw, "matrix maps are unsupported")
                matrix = jobs[job]["matrix"]
                assert isinstance(matrix, dict)
                matrix[pending_axis].append(scalar(value))
                continue
            raise bad(number, raw, "unsupported matrix indentation")

    if not triggers:
        raise ValueError(f"{path}: no top-level on: triggers parsed")
    if not jobs:
        raise ValueError(f"{path}: no jobs parsed")
    return triggers, jobs


def keyed(entries: list[str], fields: int, label: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for entry in entries:
        parts = entry.split("|", fields)
        if len(parts) != fields + 1:
            raise ValueError(f"{label}: malformed entry {entry!r}")
        key = "|".join(parts[:fields])
        if key in out:
            raise ValueError(f"{label}: duplicate key {key!r}")
        out[key] = parts[fields]
    return out


def canonical_filters(filters: dict[str, list[str]]) -> str:
    return ";".join(f"{key}={','.join(filters[key])}" for key in sorted(filters))


def canonical_activation(values_: dict[str, str]) -> str:
    return ";".join(f"{key}={values_.get(key, '')}" for key in ("continue-on-error", "if", "needs"))


def canonical_matrix(values_: dict[str, list[str]]) -> str:
    return ";".join(f"{key}={','.join(values_[key])}" for key in sorted(values_))


def main() -> int:
    config_path = Path(sys.argv[1] if len(sys.argv) > 1 else "scripts/ci-activation.conf")
    config = load_config(config_path)
    expected_triggers = keyed(config["expected-triggers"], 1, "expected-triggers")
    expected_filters = keyed(config["expected-trigger-filter"], 2, "expected-trigger-filter")
    expected_jobs = set(config["expected-gate-job"])
    expected_activation = keyed(config["expected-job-activation"], 2, "expected-job-activation")
    expected_matrix = keyed(config["expected-job-matrix"], 2, "expected-job-matrix")
    errors: list[str] = []
    parsed: dict[str, tuple[dict[str, dict[str, list[str]]], dict[str, dict[str, object]]]] = {}

    workflow_set = set(config["workflow"])
    if len(workflow_set) != len(config["workflow"]):
        errors.append("workflow contains a duplicate entry")
    if set(expected_triggers) != workflow_set:
        errors.append("expected-triggers keys must exactly match workflow entries")
    if len(expected_jobs) != len(config["expected-gate-job"]):
        errors.append("expected-gate-job contains a duplicate entry")

    for workflow in config["workflow"]:
        path = Path(workflow)
        if not path.is_file():
            errors.append(f"listed workflow does not exist: {workflow}")
            continue
        triggers, jobs = parse_workflow(path)
        parsed[workflow] = (triggers, jobs)
        got_triggers = ",".join(sorted(triggers))
        if expected_triggers.get(workflow) != got_triggers:
            errors.append(f"{workflow}: triggers expected {expected_triggers.get(workflow)!r}, got {got_triggers!r}")
        for trigger, filters in triggers.items():
            key = f"{workflow}|{trigger}"
            got = canonical_filters(filters)
            if expected_filters.get(key) != got:
                errors.append(f"{key}: filters expected {expected_filters.get(key)!r}, got {got!r}")
        for required in ("push", "pull_request"):
            if required not in triggers:
                errors.append(f"{workflow}: required trigger {required!r} is absent")
                continue
            filters = triggers[required]
            for key in ("paths", "paths-ignore"):
                if key in filters:
                    errors.append(f"{workflow}|{required}: {key} filter makes gate reach conditional")
            branches = filters.get("branches")
            if branches is not None:
                if any(pattern.startswith("!") for pattern in branches):
                    errors.append(f"{workflow}|{required}: negated branches cannot prove main is included")
                elif not any(fnmatch.fnmatchcase("main", pattern) for pattern in branches):
                    errors.append(f"{workflow}|{required}: branches do not include main")
            for pattern in filters.get("branches-ignore", []):
                if not pattern.startswith("!") and fnmatch.fnmatchcase("main", pattern):
                    errors.append(f"{workflow}|{required}: branches-ignore excludes main")

        got_jobs = {f"{workflow}|{job}" for job in jobs}
        wanted_jobs = {entry for entry in expected_jobs if entry.startswith(f"{workflow}|")}
        if got_jobs != wanted_jobs:
            errors.append(f"{workflow}: gate jobs expected {sorted(wanted_jobs)}, got {sorted(got_jobs)}")
        for job, data in jobs.items():
            key = f"{workflow}|{job}"
            activation = data["activation"]
            matrix = data["matrix"]
            assert isinstance(activation, dict) and isinstance(matrix, dict)
            got_activation = canonical_activation(activation)
            if expected_activation.get(key) != got_activation:
                errors.append(f"{key}: activation expected {expected_activation.get(key)!r}, got {got_activation!r}")
            got_matrix = canonical_matrix(matrix)
            if expected_matrix.get(key) != got_matrix:
                errors.append(f"{key}: matrix expected {expected_matrix.get(key)!r}, got {got_matrix!r}")
            if activation.get("if") in {"false", "${{ false }}", "${{false}}", "'false'"}:
                errors.append(f"{key}: job-level if is always false")
            if activation.get("continue-on-error") in {"true", "${{ true }}", "${{true}}"}:
                errors.append(f"{key}: job-level continue-on-error makes the gate advisory")

    expected_filter_keys = set(expected_filters)
    actual_filter_keys = {
        f"{workflow}|{trigger}" for workflow, (triggers, _) in parsed.items() for trigger in triggers
    }
    if expected_filter_keys != actual_filter_keys:
        errors.append("expected-trigger-filter keys do not exactly match parsed triggers")
    if set(expected_activation) != expected_jobs or set(expected_matrix) != expected_jobs:
        errors.append("job activation/matrix pin keys must exactly match expected-gate-job")

    for entry in config["required-blocking-leg"]:
        parts = entry.split("|")
        if len(parts) != 4:
            errors.append(f"required-blocking-leg: malformed entry {entry!r}")
            continue
        workflow, job, axis, leg = parts
        if workflow not in parsed or job not in parsed[workflow][1]:
            errors.append(f"{entry}: required blocking leg names no parsed job")
            continue
        data = parsed[workflow][1][job]
        matrix = data["matrix"]
        activation = data["activation"]
        assert isinstance(matrix, dict) and isinstance(activation, dict)
        if leg not in matrix.get(axis, []):
            errors.append(f"{entry}: required blocking leg is absent from the matrix")
            continue
        coe = activation.get("continue-on-error", "")
        match = re.fullmatch(r"\$\{\{\s*matrix\.([A-Za-z0-9_.-]+)\s*==\s*'([^']+)'\s*}}", coe)
        if coe and not match:
            errors.append(f"{entry}: cannot decide non-canonical continue-on-error expression {coe!r}")
        elif match and (match.group(1), match.group(2)) == (axis, leg):
            errors.append(f"{entry}: required leg is advisory")

    if errors:
        for error in errors:
            print(f"check-ci-activation: {error}", file=sys.stderr)
        return 1
    print(
        f"check-ci-activation: OK — {len(parsed)} workflow(s), "
        f"{len(expected_jobs)} gate job(s), exact triggers/filters/activation/matrices"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"check-ci-activation: {error}", file=sys.stderr)
        raise SystemExit(1)
