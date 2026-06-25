from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from self_maintainer_bot.config import Settings
from self_maintainer_bot.docs_eval import EvalResult, run_docs_eval
from self_maintainer_bot.reports import latest_eval_report, load_eval_results


@dataclass(frozen=True)
class CodexStatus:
    available: bool
    authenticated: bool
    command: list[str]
    output: str
    error: str | None = None


@dataclass(frozen=True)
class CodexRunResult:
    returncode: int
    task_path: Path
    log_path: Path
    last_message_path: Path
    verification_returncode: int | None


def codex_command() -> list[str]:
    configured = os.getenv("CODEX_CLI")
    candidates = [configured] if configured else []
    candidates.extend([shutil.which("codex"), shutil.which("codex.exe")])

    for candidate in candidates:
        if not candidate:
            continue
        path = str(candidate)
        suffix = Path(path).suffix.lower()
        if suffix == ".ps1":
            return ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path]
        return [path]

    return ["codex"]


def check_codex_status() -> CodexStatus:
    command = codex_command()
    try:
        result = subprocess.run(
            [*command, "login", "status"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except OSError as exc:
        return CodexStatus(
            available=False,
            authenticated=False,
            command=command,
            output="",
            error=str(exc),
        )
    except subprocess.TimeoutExpired:
        return CodexStatus(
            available=True,
            authenticated=False,
            command=command,
            output="",
            error="codex login status timed out.",
        )

    output = (result.stdout + result.stderr).strip()
    return CodexStatus(
        available=result.returncode == 0 or bool(output),
        authenticated=result.returncode == 0 and "Logged in" in output,
        command=command,
        output=output,
        error=None if result.returncode == 0 else output,
    )


def write_codex_task(
    settings: Settings,
    *,
    goal: str,
    scope: str,
    output_path: Path | None = None,
    eval_report_path: Path | None = None,
) -> Path:
    task_dir = settings.runs_dir / "codex-tasks"
    task_dir.mkdir(parents=True, exist_ok=True)
    if output_path is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        output_path = task_dir / f"{stamp}-{scope}-self-improve.md"

    report_path, failed = _load_failed_results(settings, eval_report_path)
    body = render_codex_task(
        settings=settings,
        goal=goal,
        scope=scope,
        eval_report_path=report_path,
        failed=failed,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(body, encoding="utf-8", newline="\n")
    return output_path


def run_codex_task(
    settings: Settings,
    *,
    task_path: Path,
    model: str | None = None,
    sandbox: str = "workspace-write",
    full_auto: bool = True,
    skip_verify: bool = False,
) -> CodexRunResult:
    if sandbox not in {"read-only", "workspace-write"}:
        raise ValueError("Only read-only and workspace-write sandboxes are supported.")

    status = check_codex_status()
    if not status.available:
        raise RuntimeError(f"Codex CLI is not available: {status.error or status.command}")
    if not status.authenticated:
        raise RuntimeError(f"Codex CLI is not logged in: {status.output or status.error}")

    logs_dir = settings.runs_dir / "codex-logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_path = logs_dir / f"{stamp}-codex-exec.log"
    last_message_path = settings.runs_dir / "codex-last-message.md"

    command = [
        *status.command,
        "exec",
        "--cd",
        str(settings.root),
        "--sandbox",
        sandbox,
        "--output-last-message",
        str(last_message_path),
    ]
    if full_auto:
        command.append("--full-auto")
    if model:
        command.extend(["--model", model])
    command.append("-")

    task_text = task_path.read_text(encoding="utf-8")
    result = subprocess.run(
        command,
        input=task_text,
        capture_output=True,
        text=True,
        cwd=settings.root,
    )

    log_path.write_text(
        "\n".join(
            [
                "# Codex Local Run Log",
                "",
                f"Task: {task_path}",
                f"Command: {' '.join(command)}",
                f"Return code: {result.returncode}",
                "",
                "## stdout",
                "",
                result.stdout.strip(),
                "",
                "## stderr",
                "",
                result.stderr.strip(),
                "",
            ]
        ),
        encoding="utf-8",
        newline="\n",
    )

    verification_returncode = None
    if result.returncode == 0 and not skip_verify:
        verification_returncode = run_local_verification(settings, log_path=log_path)

    return CodexRunResult(
        returncode=result.returncode,
        task_path=task_path,
        log_path=log_path,
        last_message_path=last_message_path,
        verification_returncode=verification_returncode,
    )


def run_codex_local_loop(
    settings: Settings,
    *,
    goal: str,
    scope: str,
    api_eval: bool,
    execute: bool,
    model: str | None = None,
    sandbox: str = "workspace-write",
    skip_verify: bool = False,
) -> tuple[Path, CodexRunResult | None]:
    results, report_path, _ = run_docs_eval(settings, dry_run=not api_eval)
    passed = sum(1 for result in results if result.passed)
    print(f"Docs eval: {passed}/{len(results)} passed")
    print(f"Eval report: {report_path}")

    task_path = write_codex_task(
        settings,
        goal=goal,
        scope=scope,
        eval_report_path=report_path,
    )
    print(f"Codex task written: {task_path}")

    if not execute:
        print("Codex execution skipped. Re-run with --execute or use run-codex-task.")
        return task_path, None

    run_result = run_codex_task(
        settings,
        task_path=task_path,
        model=model,
        sandbox=sandbox,
        skip_verify=skip_verify,
    )
    return task_path, run_result


def render_codex_task(
    *,
    settings: Settings,
    goal: str,
    scope: str,
    eval_report_path: Path | None,
    failed: list[EvalResult],
) -> str:
    allowed_paths = allowed_paths_for_scope(scope)
    lines = [
        "# Local Codex Self-Improvement Task",
        "",
        "You are running inside the user's local Codex environment for this repository.",
        "Use the local Codex login/session for reasoning and code editing.",
        "Do not require or print API keys.",
        "",
        "## Goal",
        "",
        goal.strip(),
        "",
        "## Repository",
        "",
        f"- Root: `{settings.root}`",
        "- Keep the OpenAI API based automation path intact.",
        "- Treat this local Codex path as an optional human-approved backend.",
        "",
        "## Allowed Scope",
        "",
    ]
    lines.extend(f"- `{path}`" for path in allowed_paths)
    lines.extend(
        [
            "",
            "Do not modify files outside this scope unless the task is impossible without it.",
            "Do not commit, push, create pull requests, or read/print secrets.",
            "",
            "## Required Workflow",
            "",
            "1. Run `git status --short` before editing and preserve unrelated changes.",
            "2. Inspect the eval report and the relevant docs/prompts/code.",
            "3. Make the smallest useful change within the allowed scope.",
            "4. Run `python -m self_maintainer_bot.cli smoke-check`.",
            "5. Run `python -m self_maintainer_bot.cli validate-evals`.",
            "6. Finish with a concise summary of files changed, verification, and remaining risk.",
            "",
            "## Eval Context",
            "",
        ]
    )

    if eval_report_path:
        lines.append(f"- Latest eval report: `{eval_report_path}`")
    else:
        lines.append("- No eval report was found. Perform a conservative maintenance scan.")

    if failed:
        lines.extend(["", "### Failed Cases", ""])
        for result in failed:
            lines.extend(
                [
                    f"#### {result.id}",
                    "",
                    f"- Question: {result.question}",
                    f"- Missing: {', '.join(result.missing) if result.missing else 'None'}",
                    f"- Forbidden: {', '.join(result.forbidden) if result.forbidden else 'None'}",
                    "",
                ]
            )
    else:
        lines.extend(
            [
                "",
                "No failing eval cases were found. Prefer no-op or low-risk documentation cleanup.",
                "",
            ]
        )

    lines.extend(
        [
            "## Safety Policy",
            "",
            "Follow `policies/codex_local_policy.md` if present.",
            "Generated or local-only run artifacts under `runs/` should remain untracked.",
            "",
        ]
    )
    return "\n".join(lines)


def allowed_paths_for_scope(scope: str) -> list[str]:
    scopes = {
        "docs": ["docs/", "README.md", "CONTRIBUTING.md"],
        "prompts": ["prompts/", "evals/", "docs/", "README.md"],
        "evals": ["evals/", "docs/", "prompts/"],
        "code": ["src/self_maintainer_bot/", "scripts/", "docs/", "evals/", "prompts/"],
        "mixed": [
            "src/self_maintainer_bot/",
            "scripts/",
            "docs/",
            "evals/",
            "prompts/",
            "README.md",
        ],
    }
    if scope not in scopes:
        raise ValueError(f"Unsupported scope: {scope}")
    return scopes[scope]


def _load_failed_results(
    settings: Settings,
    eval_report_path: Path | None,
) -> tuple[Path | None, list[EvalResult]]:
    try:
        report_path = eval_report_path or latest_eval_report(settings.runs_dir)
    except FileNotFoundError:
        return None, []

    results = load_eval_results(report_path)
    return report_path, [result for result in results if not result.passed]


def run_local_verification(settings: Settings, *, log_path: Path) -> int:
    commands = [
        [sys.executable, "-m", "self_maintainer_bot.cli", "smoke-check"],
        [sys.executable, "-m", "self_maintainer_bot.cli", "validate-evals"],
    ]
    final_code = 0
    with log_path.open("a", encoding="utf-8", newline="\n") as log:
        for command in commands:
            log.write(f"\n## verification: {' '.join(command)}\n\n")
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                cwd=settings.root,
            )
            log.write(result.stdout)
            if result.stderr:
                log.write("\n### stderr\n\n")
                log.write(result.stderr)
            if result.returncode != 0 and final_code == 0:
                final_code = result.returncode
    return final_code
