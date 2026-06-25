from __future__ import annotations

from pathlib import Path

from self_maintainer_bot.config import Settings
from self_maintainer_bot.docs_eval import EvalResult
from self_maintainer_bot.reports import latest_eval_report, load_eval_results


SECTION_HEADING = "## Candidate Additions From Failed Evals"


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
        "These entries were generated from failed eval cases. Review and edit them before merge.",
        "",
    ]

    for result in failed:
        lines.extend(
            [
                f"### {result.id}",
                "",
                f"Question: {result.question}",
                "",
                "Required answer content:",
                "",
            ]
        )
        for missing in result.missing:
            lines.append(f"- {missing}")
        lines.append("")
    return "\n".join(lines)
