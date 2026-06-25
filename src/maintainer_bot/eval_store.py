from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class EvalValidationResult:
    passed: bool
    errors: list[str]


def normalize_assertion_lines(text: str) -> list[str]:
    values: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.lower() in {"none", "n/a", "na", "_no response_"}:
            continue
        if line.startswith("- "):
            line = line[2:].strip()
        if line:
            values.append(line)
    return values


def append_eval_case(
    *,
    path: Path,
    case_id: str,
    question: str,
    must_include: list[str],
    must_not_include: list[str],
) -> None:
    case = {
        "id": case_id.strip(),
        "question": question.strip(),
        "must_include": [item.strip() for item in must_include if item.strip()],
        "must_not_include": [item.strip() for item in must_not_include if item.strip()],
    }
    validate_single_case(case)
    existing_ids = load_eval_ids(path)
    if case["id"] in existing_ids:
        raise ValueError(f"Eval id already exists: {case['id']}")

    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(case, ensure_ascii=False) + "\n")


def load_eval_ids(path: Path) -> set[str]:
    ids: set[str] = set()
    if not path.exists():
        return ids
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        data = json.loads(line)
        case_id = str(data.get("id", "")).strip()
        if case_id:
            ids.add(case_id)
    return ids


def validate_eval_file(path: Path) -> EvalValidationResult:
    errors: list[str] = []
    ids: set[str] = set()
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
            validate_single_case(data)
        except (json.JSONDecodeError, ValueError, TypeError) as exc:
            errors.append(f"{path}:{line_number}: {exc}")
            continue

        case_id = data["id"]
        if case_id in ids:
            errors.append(f"{path}:{line_number}: duplicate eval id: {case_id}")
        ids.add(case_id)

    return EvalValidationResult(passed=not errors, errors=errors)


def validate_single_case(case: dict[str, object]) -> None:
    case_id = case.get("id")
    question = case.get("question")
    must_include = case.get("must_include")
    must_not_include = case.get("must_not_include")

    if not isinstance(case_id, str) or not case_id.strip():
        raise ValueError("id must be a non-empty string")
    if not isinstance(question, str) or not question.strip():
        raise ValueError("question must be a non-empty string")
    if not isinstance(must_include, list):
        raise ValueError("must_include must be a list")
    if not isinstance(must_not_include, list):
        raise ValueError("must_not_include must be a list")
    if not all(isinstance(item, str) and item.strip() for item in must_include):
        raise ValueError("must_include items must be non-empty strings")
    if not all(isinstance(item, str) and item.strip() for item in must_not_include):
        raise ValueError("must_not_include items must be non-empty strings")
    if not must_include and not must_not_include:
        raise ValueError("at least one assertion is required")
