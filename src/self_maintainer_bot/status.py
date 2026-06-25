from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from self_maintainer_bot.config import Settings
from self_maintainer_bot.docs_eval import load_eval_cases
from self_maintainer_bot.eval_store import validate_eval_file
from self_maintainer_bot.reports import load_eval_results
from self_maintainer_bot.target_repo import active_evals_path


def write_status_dashboard(settings: Settings, *, output_path: Path | None = None) -> Path:
    output = output_path or settings.root / "docs" / "PROJECT_STATUS.md"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_status_dashboard(settings), encoding="utf-8", newline="\n")
    return output


def render_status_dashboard(settings: Settings) -> str:
    evals_path = active_evals_path(settings)
    eval_cases = load_eval_cases(evals_path)
    validation = validate_eval_file(evals_path)
    latest_report = latest_report_path(settings.runs_dir)
    workflows = sorted((settings.root / ".github" / "workflows").glob("*.yml"))

    lines = [
        "# Project Status",
        "",
        f"Generated at: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}",
        "",
        "## Eval Coverage",
        "",
        f"- Eval cases: {len(eval_cases)}",
        f"- Eval file valid: {'yes' if validation.passed else 'no'}",
    ]
    if validation.errors:
        lines.append(f"- Validation errors: {len(validation.errors)}")
    lines.extend(["", "## Latest Eval Report", ""])

    if latest_report is None:
        lines.append("- No eval report found under `runs/`.")
    else:
        results = load_eval_results(latest_report)
        passed = sum(1 for result in results if result.passed)
        total = len(results)
        lines.extend(
            [
                f"- Report: `{relative_posix(latest_report, settings.root)}`",
                f"- Passed: {passed}/{total}",
            ]
        )
        failed = [result for result in results if not result.passed]
        if failed:
            lines.append("")
            lines.append("### Failed Cases")
            lines.append("")
            for result in failed[:20]:
                lines.append(f"- `{result.id}`: {result.question}")

    lines.extend(["", "## Automation", ""])
    if workflows:
        for workflow in workflows:
            lines.append(f"- `{relative_posix(workflow, settings.root)}`")
    else:
        lines.append("- No workflows found.")

    lines.extend(
        [
            "",
            "## Recommended Next Action",
            "",
            "- If eval coverage is below 20 cases, add more `Eval failure` issues.",
            "- If the latest eval report has failures, run `Self Improve Docs Proposal`.",
            "- If generated docs patch candidates exist, rewrite them before merge.",
            "",
        ]
    )
    return "\n".join(lines)


def latest_report_path(runs_dir: Path) -> Path | None:
    reports = sorted(runs_dir.glob("docs-eval-*.jsonl"), key=lambda path: path.stat().st_mtime)
    if not reports:
        return None
    return reports[-1]


def relative_posix(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()
