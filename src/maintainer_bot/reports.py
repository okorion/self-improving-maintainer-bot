from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from maintainer_bot.config import Settings
from maintainer_bot.docs_eval import EvalResult
from maintainer_bot.llm import LlmConfig, call_openai_text


def latest_eval_report(runs_dir: Path) -> Path:
    reports = sorted(runs_dir.glob("docs-eval-*.jsonl"), key=lambda path: path.stat().st_mtime)
    if not reports:
        raise FileNotFoundError("No docs eval report found. Run eval-docs first.")
    return reports[-1]


def load_eval_results(path: Path) -> list[EvalResult]:
    results: list[EvalResult] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip():
            continue
        data = json.loads(raw_line)
        results.append(
            EvalResult(
                id=data["id"],
                question=data["question"],
                answer=data["answer"],
                passed=bool(data["passed"]),
                missing=list(data.get("missing", [])),
                forbidden=list(data.get("forbidden", [])),
            )
        )
    return results


def write_improvement_proposal(settings: Settings, *, dry_run: bool) -> Path | None:
    settings.proposals_dir.mkdir(parents=True, exist_ok=True)
    report_path = latest_eval_report(settings.runs_dir)
    results = load_eval_results(report_path)
    failed = [result for result in results if not result.passed]

    proposal_path = settings.proposals_dir / "docs-improvement-plan.md"
    if not failed:
        if proposal_path.exists():
            proposal_path.unlink()
        return None

    docs_text = settings.docs_path.read_text(encoding="utf-8")
    prompt = settings.improvement_prompt_path.read_text(encoding="utf-8")

    if dry_run or not settings.openai_api_key:
        body = render_static_improvement_plan(report_path=report_path, failed=failed)
    else:
        user_input = f"""Current documentation:

{docs_text}

Failed eval cases:

{json.dumps([asdict(result) for result in failed], ensure_ascii=False, indent=2)}
"""
        body = call_openai_text(
            api_key=settings.openai_api_key,
            config=LlmConfig(model=settings.model, reasoning_effort=settings.reasoning_effort),
            instructions=prompt,
            user_input=user_input,
        )

    proposal_path.write_text(body.strip() + "\n", encoding="utf-8", newline="\n")
    return proposal_path


def render_static_improvement_plan(*, report_path: Path, failed: list[EvalResult]) -> str:
    lines = [
        "# Documentation Improvement Plan",
        "",
        f"Source report: `{report_path}`",
        "",
        "## Summary",
        "",
        "One or more documentation eval cases failed. Review whether the documentation, prompt, or eval case should change.",
        "",
        "## Failed Cases",
        "",
    ]

    for result in failed:
        lines.extend(
            [
                f"### {result.id}",
                "",
                f"- Question: {result.question}",
                f"- Missing: {', '.join(result.missing) if result.missing else 'None'}",
                f"- Forbidden: {', '.join(result.forbidden) if result.forbidden else 'None'}",
                "",
            ]
        )

    lines.extend(
        [
            "## Recommended Change",
            "",
            "Start by checking `docs/knowledge.md`. If the expected answer is missing or ambiguous, update the docs first.",
            "",
            "If the docs are clear but the answer is wrong, update `prompts/docs_qa_system.md`.",
            "",
            "## Manual Review Checklist",
            "",
            "- [ ] The change does not delete or weaken eval coverage without explanation.",
            "- [ ] The change keeps the bot from pushing directly to main.",
            "- [ ] The change does not expose secrets to external pull requests.",
            "- [ ] The eval suite was run again after the change.",
            "",
        ]
    )
    return "\n".join(lines)
