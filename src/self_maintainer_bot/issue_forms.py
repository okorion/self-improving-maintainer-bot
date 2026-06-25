from __future__ import annotations

import re
from dataclasses import dataclass

from self_maintainer_bot.eval_store import normalize_assertion_lines


@dataclass(frozen=True)
class EvalIssue:
    case_id: str
    question: str
    must_include: list[str]
    must_not_include: list[str]


HEADING_RE = re.compile(r"^###\s+(.+?)\s*$")


def parse_issue_form_sections(body: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current_heading: str | None = None

    for raw_line in body.splitlines():
        heading_match = HEADING_RE.match(raw_line)
        if heading_match:
            current_heading = normalize_heading(heading_match.group(1))
            sections.setdefault(current_heading, [])
            continue
        if current_heading is not None:
            sections[current_heading].append(raw_line)

    return {heading: "\n".join(lines).strip() for heading, lines in sections.items()}


def parse_eval_issue(body: str) -> EvalIssue:
    sections = parse_issue_form_sections(body)
    case_id = first_present(sections, ["suggested eval id", "eval id", "id"])
    question = first_present(sections, ["user question", "question"])
    required = first_present(sections, ["required answer content", "must include"], required=False)
    forbidden = first_present(
        sections,
        ["forbidden answer content", "must not include"],
        required=False,
    )

    must_include = normalize_assertion_lines(required)
    must_not_include = normalize_assertion_lines(forbidden)
    return EvalIssue(
        case_id=case_id.strip(),
        question=question.strip(),
        must_include=must_include,
        must_not_include=must_not_include,
    )


def normalize_heading(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip().lower())


def first_present(sections: dict[str, str], keys: list[str], *, required: bool = True) -> str:
    for key in keys:
        value = sections.get(key, "").strip()
        if value:
            return value
    if required:
        raise ValueError(f"Missing required issue form section: {keys[0]}")
    return ""
