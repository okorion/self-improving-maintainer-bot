from __future__ import annotations

import os
import shutil
import subprocess
import sys
from fnmatch import fnmatchcase
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from self_maintainer_bot.config import Settings
from self_maintainer_bot.docs_eval import EvalResult, run_docs_eval
from self_maintainer_bot.reports import latest_eval_report, load_eval_results
from self_maintainer_bot.target_repo import target_root


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
    timeout_seconds: int | None = None,
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
    work_root = target_root(settings)
    baseline_dirty = git_changed_files(work_root)
    timeout = timeout_seconds or settings.codex_timeout_seconds

    command = [
        *status.command,
        "exec",
        "--cd",
        str(work_root),
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
    try:
        result = subprocess.run(
            command,
            input=task_text,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            cwd=work_root,
            timeout=timeout,
        )
        returncode = result.returncode
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
    except subprocess.TimeoutExpired as exc:
        returncode = 124
        stdout = (exc.stdout or "").strip() if isinstance(exc.stdout, str) else ""
        stderr_text = (exc.stderr or "").strip() if isinstance(exc.stderr, str) else ""
        stderr = f"Codex execution timed out after {timeout} seconds.\n{stderr_text}".strip()

    log_path.write_text(
        "\n".join(
            [
                "# Codex Local Run Log",
                "",
                f"Task: {task_path}",
                f"Work root: {work_root}",
                f"Command: {' '.join(command)}",
                f"Timeout seconds: {timeout}",
                f"Return code: {returncode}",
                "",
                "## stdout",
                "",
                stdout,
                "",
                "## stderr",
                "",
                stderr,
                "",
            ]
        ),
        encoding="utf-8",
        newline="\n",
    )

    verification_returncode = None
    if returncode == 0 and not skip_verify:
        scope = scope_from_task(task_path)
        guard_code = verify_allowed_changes(
            root=work_root,
            allowed_paths=effective_allowed_paths(settings, scope),
            denied_paths=settings.target_deny_paths,
            max_files=settings.target_max_files,
            max_lines=settings.target_max_lines,
            baseline_dirty=baseline_dirty,
            log_path=log_path,
        )
        verification_returncode = guard_code
        if guard_code == 0:
            verification_returncode = run_local_verification(settings, log_path=log_path)

    return CodexRunResult(
        returncode=returncode,
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
    execute: bool,
    model: str | None = None,
    sandbox: str = "workspace-write",
    skip_verify: bool = False,
    timeout_seconds: int | None = None,
) -> tuple[Path, CodexRunResult | None]:
    results, report_path, _ = run_docs_eval(settings, dry_run=True)
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
        timeout_seconds=timeout_seconds,
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
    allowed_paths = effective_allowed_paths(settings, scope)
    lines = [
        "# Local Codex Self-Improvement Task",
        "",
        "You are running inside the user's local Codex environment for this repository.",
        "Use the local Codex login/session for reasoning and code editing.",
        "Do not require or print API keys.",
        "Follow the target repository's AGENTS.md when it exists.",
        "Write user-facing summaries, commit explanations, and PR guidance in Korean by default.",
        "",
        "## Goal",
        "",
        goal.strip(),
        "",
        "## Repository",
        "",
        f"- Bot root: `{settings.root}`",
        f"- Work root: `{target_root(settings)}`",
        "- Do not require `OPENAI_API_KEY`; this project uses local Codex for model work.",
        "- Treat GitHub Actions as dry-run/check/report automation only.",
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
            "If you describe a commit or PR, write the title and body in Korean.",
            "",
            "## Required Workflow",
            "",
            "1. Run `git status --short` before editing and preserve unrelated changes.",
            "2. Inspect the eval report and the relevant docs/prompts/code.",
            "3. Make the smallest useful change within the allowed scope.",
            "4. Run `python -m self_maintainer_bot.cli smoke-check`.",
            "5. Run `python -m self_maintainer_bot.cli validate-evals`.",
            "6. Finish in Korean with changed files, verification, and remaining risk.",
            "",
            "## Eval Context",
            "",
        ]
    )

    if settings.target_deny_paths:
        lines.extend(["", "## Denied Scope", ""])
        lines.extend(f"- `{path}`" for path in settings.target_deny_paths)
        lines.extend(
            [
                "",
                "Treat denied paths as proposal-only. Do not edit them in an automated PR.",
                "",
            ]
        )

    if eval_report_path:
        lines.append(f"- Latest eval report: `{eval_report_path}`")
    else:
        lines.append("- Eval report가 없습니다. 보수적인 유지보수 점검을 수행하세요.")

    if failed:
        lines.extend(["", "### Failed Cases", ""])
        for result in failed:
            lines.extend(
                [
                    f"#### {result.id}",
                    "",
                    f"- 질문: {result.question}",
                    f"- 누락: {', '.join(result.missing) if result.missing else '없음'}",
                    f"- 금지어 포함: {', '.join(result.forbidden) if result.forbidden else '없음'}",
                    "",
                ]
            )
    else:
        lines.extend(
            [
                "",
                "실패한 eval case가 없습니다. no-op 또는 낮은 위험의 문서 정리를 선호하세요.",
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


def effective_allowed_paths(settings: Settings, scope: str) -> list[str]:
    if settings.target_repository and settings.target_allowed_paths:
        return settings.target_allowed_paths
    return allowed_paths_for_scope(scope)


def scope_from_task(task_path: Path) -> str:
    name = task_path.name
    for scope in ["docs", "prompts", "evals", "code", "mixed"]:
        if f"-{scope}-" in name:
            return scope
    return "mixed"


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


def git_changed_files(root: Path) -> set[str]:
    if not (root / ".git").exists():
        return set()
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    changed: set[str] = set()
    for line in result.stdout.splitlines():
        if not line:
            continue
        path = line[3:]
        if " -> " in path:
            _, path = path.rsplit(" -> ", 1)
        changed.add(path.replace("\\", "/"))
    return changed


def verify_allowed_changes(
    *,
    root: Path,
    allowed_paths: list[str],
    denied_paths: list[str],
    max_files: int,
    max_lines: int,
    baseline_dirty: set[str],
    log_path: Path,
) -> int:
    changed_after = git_changed_files(root)
    new_changes = changed_after - baseline_dirty
    denied = sorted(path for path in new_changes if any_path_matches(path, denied_paths))
    disallowed = sorted(
        path
        for path in new_changes
        if not any_path_matches(path, allowed_paths)
    )
    line_total = changed_line_total(root, sorted(new_changes)) if max_lines else 0
    with log_path.open("a", encoding="utf-8", newline="\n") as log:
        log.write("\n## verification: allowed change guard\n\n")
        if not new_changes:
            log.write("No new git changes detected.\n")
        else:
            log.write("New changed files:\n")
            for path in sorted(new_changes):
                log.write(f"- {path}\n")
        if disallowed:
            log.write("\nDisallowed files:\n")
            for path in disallowed:
                log.write(f"- {path}\n")
        if denied:
            log.write("\nDenied files:\n")
            for path in denied:
                log.write(f"- {path}\n")
        if max_files and len(new_changes) > max_files:
            log.write(f"\nToo many changed files: {len(new_changes)} > {max_files}\n")
        if max_lines and line_total > max_lines:
            log.write(f"\nToo many changed lines: {line_total} > {max_lines}\n")
        if disallowed or denied:
            return 1
        if max_files and len(new_changes) > max_files:
            return 1
        if max_lines and line_total > max_lines:
            return 1
    return 0


def any_path_matches(path: str, patterns: list[str]) -> bool:
    return any(path_matches(path, pattern) for pattern in patterns)


def path_matches(path: str, pattern: str) -> bool:
    normalized_path = path.replace("\\", "/")
    normalized_pattern = pattern.replace("\\", "/").strip()
    if not normalized_pattern:
        return False
    if normalized_pattern.endswith("/**"):
        prefix = normalized_pattern[:-3].rstrip("/")
        return normalized_path == prefix or normalized_path.startswith(f"{prefix}/")
    if normalized_pattern.endswith("/"):
        return normalized_path.startswith(normalized_pattern)
    if any(token in normalized_pattern for token in "*?[]"):
        return fnmatchcase(normalized_path, normalized_pattern)
    return normalized_path == normalized_pattern or normalized_path.startswith(
        f"{normalized_pattern.rstrip('/')}/"
    )


def changed_line_total(root: Path, files: list[str]) -> int:
    if not files:
        return 0
    result = subprocess.run(
        ["git", "diff", "--numstat", "--", *files],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    total = 0
    seen: set[str] = set()
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        added, deleted, path = parts[0], parts[1], parts[2]
        seen.add(path.replace("\\", "/"))
        if added.isdigit():
            total += int(added)
        if deleted.isdigit():
            total += int(deleted)

    for file_path in files:
        if file_path in seen:
            continue
        path = root / file_path
        if not path.is_file():
            continue
        try:
            total += len(path.read_text(encoding="utf-8").splitlines())
        except UnicodeDecodeError:
            total += 1
    return total
