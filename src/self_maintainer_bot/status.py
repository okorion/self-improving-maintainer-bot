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
        "# 프로젝트 상태",
        "",
        f"생성 시각: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}",
        "",
        "## Eval Coverage",
        "",
        f"- Eval case 수: {len(eval_cases)}",
        f"- Eval 파일 유효성: {'yes' if validation.passed else 'no'}",
    ]
    if validation.errors:
        lines.append(f"- 검증 오류: {len(validation.errors)}")
    lines.extend(["", "## 최신 Eval Report", ""])

    if latest_report is None:
        lines.append("- `runs/` 아래에서 eval report를 찾지 못했습니다.")
    else:
        results = load_eval_results(latest_report)
        passed = sum(1 for result in results if result.passed)
        total = len(results)
        lines.extend(
            [
                f"- Report: `{relative_posix(latest_report, settings.root)}`",
                f"- 통과: {passed}/{total}",
            ]
        )
        failed = [result for result in results if not result.passed]
        if failed:
            lines.append("")
            lines.append("### 실패 Case")
            lines.append("")
            for result in failed[:20]:
                lines.append(f"- `{result.id}`: {result.question}")

    lines.extend(["", "## Automation", ""])
    if workflows:
        for workflow in workflows:
            lines.append(f"- `{relative_posix(workflow, settings.root)}`")
    else:
        lines.append("- workflow를 찾지 못했습니다.")

    lines.extend(
        [
            "",
            "## 권장 다음 작업",
            "",
            "- eval coverage가 20 case 미만이면 `Eval failure` 이슈를 더 추가합니다.",
            "- 최신 eval report에 실패가 있으면 `Self Improve Docs Proposal`을 실행합니다.",
            "- 생성된 docs patch 후보가 있으면 병합 전 사람이 문장을 다시 다듬습니다.",
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
