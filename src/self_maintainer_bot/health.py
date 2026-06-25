from __future__ import annotations

import compileall
import sys
from dataclasses import dataclass

from self_maintainer_bot.config import Settings
from self_maintainer_bot.docs_eval import run_docs_eval
from self_maintainer_bot.eval_store import validate_eval_file
from self_maintainer_bot.target_repo import target_status
from self_maintainer_bot.triage import suggest_labels


@dataclass(frozen=True)
class Check:
    name: str
    passed: bool
    detail: str


def doctor_checks(settings: Settings) -> list[Check]:
    required_paths = [
        settings.docs_path,
        settings.evals_path,
        settings.docs_prompt_path,
        settings.improvement_prompt_path,
        settings.root / "policies" / "self_improvement_policy.md",
    ]
    checks = [
        Check(
            name="python-version",
            passed=sys.version_info >= (3, 10),
            detail=f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        ),
        Check(
            name="codex-timeout",
            passed=True,
            detail=f"{settings.codex_timeout_seconds}s",
        ),
    ]
    target = target_status(settings)
    checks.append(
        Check(
            name="target-repository",
            passed=True,
            detail=target.repository or "self",
        )
    )
    checks.append(
        Check(
            name="target-worktree",
            passed=target.exists if target.configured else True,
            detail=str(target.root),
        )
    )
    for path in required_paths:
        checks.append(
            Check(
                name=f"file:{path.relative_to(settings.root)}",
                passed=path.exists(),
                detail="present" if path.exists() else "missing",
            )
        )
    eval_validation = validate_eval_file(settings.evals_path)
    checks.append(
        Check(
            name="eval-file",
            passed=eval_validation.passed,
            detail="valid" if eval_validation.passed else "; ".join(eval_validation.errors),
        )
    )
    return checks


def run_smoke_check(settings: Settings) -> list[Check]:
    checks = doctor_checks(settings)
    compiled = compileall.compile_dir(settings.root / "src", quiet=1)
    checks.append(Check(name="compileall", passed=compiled, detail="src compiled"))

    results, jsonl_path, _ = run_docs_eval(settings, dry_run=True)
    passed = sum(1 for result in results if result.passed)
    total = len(results)
    checks.append(
        Check(
            name="docs-eval-dry-run",
            passed=passed == total,
            detail=f"{passed}/{total} passed; report={jsonl_path}",
        )
    )

    labels = suggest_labels("Docs typo in README", "The installation guide has a typo.")
    checks.append(
        Check(
            name="issue-triage",
            passed=labels == ["docs"],
            detail=",".join(labels),
        )
    )
    return checks


def print_checks(checks: list[Check]) -> None:
    for check in checks:
        status = "PASS" if check.passed else "FAIL"
        print(f"{status} {check.name}: {check.detail}")


def checks_passed(checks: list[Check]) -> bool:
    for check in checks:
        if not check.passed:
            return False
    return True
