from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from self_maintainer_bot.config import Settings
from self_maintainer_bot.eval_store import validate_single_case
from self_maintainer_bot.target_repo import load_target_docs_text


@dataclass(frozen=True)
class EvalCase:
    id: str
    question: str
    must_include: list[str]
    must_not_include: list[str]


@dataclass(frozen=True)
class EvalResult:
    id: str
    question: str
    answer: str
    passed: bool
    missing: list[str]
    forbidden: list[str]


def load_eval_cases(path: Path) -> list[EvalCase]:
    cases: list[EvalCase] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        data = json.loads(line)
        validate_single_case(data)
        cases.append(
            EvalCase(
                id=data["id"],
                question=data["question"],
                must_include=list(data.get("must_include", [])),
                must_not_include=list(data.get("must_not_include", [])),
            )
        )
        if not cases[-1].id:
            raise ValueError(f"Missing eval id at {path}:{line_number}")
    return cases


def dry_run_answer(question: str, docs_text: str) -> str:
    sections = split_markdown_sections(docs_text)
    question_terms = {
        term.lower()
        for term in re.findall(r"[a-zA-Z0-9_`.-]+", question)
        if len(term) >= 3
    }

    scored: list[tuple[int, str]] = []
    for section in sections:
        section_terms = {term.lower() for term in re.findall(r"[a-zA-Z0-9_`.-]+", section)}
        score = len(question_terms & section_terms)
        if score:
            scored.append((score, section))

    if not scored:
        return "UNKNOWN: The provided documentation does not say."

    scored.sort(key=lambda item: item[0], reverse=True)
    return "\n\n".join(section for _, section in scored[:2])


def split_markdown_sections(docs_text: str) -> list[str]:
    sections: list[list[str]] = []
    current: list[str] = []

    for line in docs_text.splitlines():
        if line.startswith("#") and current:
            sections.append(current)
            current = [line]
        else:
            current.append(line)

    if current:
        sections.append(current)

    return ["\n".join(section).strip() for section in sections if "\n".join(section).strip()]


def answer_question(
    *,
    case: EvalCase,
    docs_text: str,
    system_prompt: str,
    settings: Settings,
    dry_run: bool,
) -> str:
    _ = system_prompt, settings, dry_run
    return dry_run_answer(case.question, docs_text)


def score_answer(case: EvalCase, answer: str) -> EvalResult:
    answer_lower = answer.lower()
    missing = [expected for expected in case.must_include if expected.lower() not in answer_lower]
    forbidden = [bad for bad in case.must_not_include if bad and bad.lower() in answer_lower]
    return EvalResult(
        id=case.id,
        question=case.question,
        answer=answer,
        passed=not missing and not forbidden,
        missing=missing,
        forbidden=forbidden,
    )


def run_docs_eval(settings: Settings, *, dry_run: bool) -> tuple[list[EvalResult], Path, Path]:
    settings.runs_dir.mkdir(parents=True, exist_ok=True)

    docs_text = load_target_docs_text(settings)
    system_prompt = settings.docs_prompt_path.read_text(encoding="utf-8")
    cases = load_eval_cases(settings.evals_path)

    results: list[EvalResult] = []
    for case in cases:
        answer = answer_question(
            case=case,
            docs_text=docs_text,
            system_prompt=system_prompt,
            settings=settings,
            dry_run=dry_run,
        )
        results.append(score_answer(case, answer))

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    jsonl_path = settings.runs_dir / f"docs-eval-{timestamp}.jsonl"
    md_path = settings.runs_dir / f"docs-eval-{timestamp}.md"

    jsonl_path.write_text(
        "\n".join(json.dumps(asdict(result), ensure_ascii=False) for result in results) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    md_path.write_text(
        render_markdown_report(results, dry_run=dry_run),
        encoding="utf-8",
        newline="\n",
    )
    return results, jsonl_path, md_path


def render_markdown_report(results: list[EvalResult], *, dry_run: bool) -> str:
    passed = sum(1 for result in results if result.passed)
    total = len(results)
    lines = [
        "# Documentation Eval Report",
        "",
        "- Mode: local-dry-run",
        f"- Passed: {passed}/{total}",
        "",
    ]

    for result in results:
        status = "PASS" if result.passed else "FAIL"
        lines.extend(
            [
                f"## {status}: {result.id}",
                "",
                f"Question: {result.question}",
                "",
                "Answer:",
                "",
                "```text",
                result.answer,
                "```",
                "",
            ]
        )
        if result.missing:
            lines.append(f"Missing: {', '.join(result.missing)}")
            lines.append("")
        if result.forbidden:
            lines.append(f"Forbidden: {', '.join(result.forbidden)}")
            lines.append("")

    return "\n".join(lines)
