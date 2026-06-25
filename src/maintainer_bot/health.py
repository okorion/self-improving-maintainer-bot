from __future__ import annotations

import compileall
import sys
from dataclasses import dataclass

from maintainer_bot.config import Settings
from maintainer_bot.docs_eval import run_docs_eval
from maintainer_bot.eval_store import validate_eval_file
from maintainer_bot.triage import suggest_labels


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
            name="openai-api-key",
            passed=True,
            detail="configured" if settings.openai_api_key else "optional missing; dry-run mode still works",
        ),
        Check(name="openai-model", passed=bool(settings.model), detail=settings.model),
    ]
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


def print_checks(checks: list[Check], *, require_api_key: bool = False) -> None:
    for check in checks:
        passed = check.passed
        if check.name == "openai-api-key" and require_api_key and check.detail != "configured":
            passed = False
        status = "PASS" if passed else "FAIL"
        print(f"{status} {check.name}: {check.detail}")


def checks_passed(checks: list[Check], *, require_api_key: bool = False) -> bool:
    for check in checks:
        if check.name == "openai-api-key" and require_api_key and check.detail != "configured":
            return False
        if not check.passed:
            return False
    return True
