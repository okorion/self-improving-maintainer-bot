from __future__ import annotations

import json
from pathlib import Path

from self_maintainer_bot.config import Settings
from self_maintainer_bot.docs_eval import EvalResult


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

    _ = docs_text, prompt, dry_run
    body = render_static_improvement_plan(report_path=report_path, failed=failed)

    proposal_path.write_text(body.strip() + "\n", encoding="utf-8", newline="\n")
    return proposal_path


def render_static_improvement_plan(*, report_path: Path, failed: list[EvalResult]) -> str:
    lines = [
        "# 문서 개선 계획",
        "",
        f"기준 보고서: `{report_path}`",
        "",
        "## 요약",
        "",
        (
            "하나 이상의 문서 eval case가 실패했습니다. 문서, 프롬프트, eval case 중 "
            "무엇을 수정해야 하는지 검토하세요."
        ),
        "",
        "## 실패 case",
        "",
    ]

    for result in failed:
        lines.extend(
            [
                f"### {result.id}",
                "",
                f"- 질문: {result.question}",
                f"- 누락: {', '.join(result.missing) if result.missing else '없음'}",
                f"- 금지어 포함: {', '.join(result.forbidden) if result.forbidden else '없음'}",
                "",
            ]
        )

    lines.extend(
        [
            "## 권장 변경",
            "",
            (
                "`docs/knowledge.md`부터 확인하세요. 기대 답변이 없거나 모호하면 "
                "문서를 먼저 수정합니다."
            ),
            "",
            "문서가 명확한데 답변이 틀렸다면 `prompts/docs_qa_system.md`를 수정합니다.",
            "",
            "## 수동 검토 체크리스트",
            "",
            "- [ ] 설명 없이 eval coverage를 삭제하거나 약화하지 않았습니다.",
            "- [ ] bot이 main에 직접 push하지 않는 원칙을 유지합니다.",
            "- [ ] 외부 pull request에 secret을 노출하지 않습니다.",
            "- [ ] 변경 후 eval suite를 다시 실행했습니다.",
            "",
        ]
    )
    return "\n".join(lines)
