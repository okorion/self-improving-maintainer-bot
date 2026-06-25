from __future__ import annotations

from pathlib import Path

from self_maintainer_bot.config import Settings
from self_maintainer_bot.docs_eval import EvalResult
from self_maintainer_bot.reports import latest_eval_report, load_eval_results


SECTION_HEADING = "## 실패 eval 기반 문서 후보"


def propose_docs_patch(settings: Settings) -> Path | None:
    report_path = latest_eval_report(settings.runs_dir)
    results = load_eval_results(report_path)
    failed = [result for result in results if not result.passed and result.missing]
    if not failed:
        return None

    docs_text = settings.docs_path.read_text(encoding="utf-8")
    additions = render_candidate_additions(failed)

    if SECTION_HEADING in docs_text:
        before, _, _ = docs_text.partition(SECTION_HEADING)
        docs_text = before.rstrip() + "\n\n" + additions
    else:
        docs_text = docs_text.rstrip() + "\n\n" + additions

    settings.docs_path.write_text(docs_text.rstrip() + "\n", encoding="utf-8", newline="\n")
    return settings.docs_path


def render_candidate_additions(failed: list[EvalResult]) -> str:
    lines = [
        SECTION_HEADING,
        "",
        "아래 항목은 실패한 eval case에서 생성된 초안입니다. 병합 전에 검토하고 다듬으세요.",
        "",
    ]

    for result in failed:
        lines.extend(
            [
                f"### {result.id}",
                "",
                f"질문: {result.question}",
                "",
                "필요한 답변 내용:",
                "",
            ]
        )
        for missing in result.missing:
            lines.append(f"- {missing}")
        lines.append("")
    return "\n".join(lines)
