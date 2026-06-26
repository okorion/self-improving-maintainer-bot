from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict
from pathlib import Path

from self_maintainer_bot.codex_local import (
    check_codex_status,
    effective_allowed_paths,
    run_codex_local_loop,
    run_codex_task,
    write_codex_task,
)
from self_maintainer_bot.change_summary import write_target_change_summary
from self_maintainer_bot.config import load_settings
from self_maintainer_bot.docs_eval import run_docs_eval
from self_maintainer_bot.docs_patch import propose_docs_patch
from self_maintainer_bot.eval_store import append_eval_case, validate_eval_file
from self_maintainer_bot.github_api import add_issue_labels, sync_labels
from self_maintainer_bot.health import checks_passed, doctor_checks, print_checks, run_smoke_check
from self_maintainer_bot.issue_forms import parse_eval_issue
from self_maintainer_bot.pr_summary import comment_pr_summary, write_pr_summary
from self_maintainer_bot.reports import write_improvement_proposal
from self_maintainer_bot.risk import classify_changes, git_changed_files, write_risk_report
from self_maintainer_bot.status import write_status_dashboard
from self_maintainer_bot.target_repo import active_evals_path, prepare_target_repo, target_status
from self_maintainer_bot.triage import label_definitions, suggest_labels


def _goal_from_args(args: argparse.Namespace) -> str:
    goal_file = getattr(args, "goal_file", None)
    if goal_file:
        return Path(goal_file).read_text(encoding="utf-8")
    return args.goal


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="maintainer-bot")
    subparsers = parser.add_subparsers(dest="command", required=True)

    eval_docs = subparsers.add_parser("eval-docs", help="Run documentation QA evals.")
    eval_docs.add_argument(
        "--dry-run",
        action="store_true",
        help="Run local dry-run evals. This is the default.",
    )
    eval_docs.add_argument(
        "--fail-under",
        type=float,
        default=1.0,
        help="Minimum pass ratio required before exiting with status 1.",
    )

    improve = subparsers.add_parser(
        "propose-improvement",
        help="Create a proposal from the latest documentation eval report.",
    )
    improve.add_argument("--dry-run", action="store_true", help="Keep static proposal behavior.")

    subparsers.add_parser(
        "propose-docs-patch",
        help="Append candidate documentation additions from failed eval cases.",
    )

    triage = subparsers.add_parser("triage-issue", help="Suggest labels for a GitHub issue.")
    triage.add_argument("--title", required=True)
    triage.add_argument("--body", default="")

    add_eval = subparsers.add_parser("add-eval", help="Append a documentation QA eval case.")
    add_eval.add_argument("--id", required=True)
    add_eval.add_argument("--question", required=True)
    add_eval.add_argument("--must-include", action="append", default=[])
    add_eval.add_argument("--must-not-include", action="append", default=[])

    add_eval_from_issue = subparsers.add_parser(
        "add-eval-from-issue",
        help="Append a docs QA eval case from a GitHub issue form body.",
    )
    add_eval_from_issue.add_argument("--body-file", required=True)
    add_eval_from_issue.add_argument("--issue-number", type=int)

    subparsers.add_parser("validate-evals", help="Validate eval JSONL format and duplicate ids.")

    subparsers.add_parser("doctor", help="Check local setup and required files.")

    subparsers.add_parser("smoke-check", help="Run local compile, dry-run eval, and triage checks.")

    sync = subparsers.add_parser("sync-labels", help="Create or update standard GitHub labels.")
    sync.add_argument("--repo", default=os.getenv("GITHUB_REPOSITORY"), help="owner/repo")
    sync.add_argument(
        "--token-env",
        default="GITHUB_TOKEN",
        help="Environment variable containing token.",
    )

    apply_labels = subparsers.add_parser(
        "apply-issue-labels",
        help="Suggest and apply labels to a GitHub issue.",
    )
    apply_labels.add_argument("--repo", default=os.getenv("GITHUB_REPOSITORY"), help="owner/repo")
    apply_labels.add_argument("--issue-number", type=int, required=True)
    apply_labels.add_argument("--title", required=True)
    apply_labels.add_argument("--body", default="")
    apply_labels.add_argument(
        "--token-env",
        default="GITHUB_TOKEN",
        help="Environment variable containing token.",
    )

    pr_summary = subparsers.add_parser("summarize-pr", help="Write a Markdown PR summary.")
    pr_summary.add_argument("--base-ref", required=True)
    pr_summary.add_argument("--head-ref", required=True)
    pr_summary.add_argument("--output", default="runs/pr-summary.md")

    comment_summary = subparsers.add_parser(
        "comment-pr-summary",
        help="Create or update a PR summary comment.",
    )
    comment_summary.add_argument(
        "--repo",
        default=os.getenv("GITHUB_REPOSITORY"),
        help="owner/repo",
    )
    comment_summary.add_argument("--pr-number", type=int, required=True)
    comment_summary.add_argument("--summary-file", default="runs/pr-summary.md")
    comment_summary.add_argument("--token-env", default="GITHUB_TOKEN")

    status = subparsers.add_parser("update-status", help="Write docs/PROJECT_STATUS.md.")
    status.add_argument("--output", default="docs/PROJECT_STATUS.md")

    subparsers.add_parser("target-status", help="Show target repository configuration.")
    subparsers.add_parser("prepare-target", help="Clone or update TARGET_REPOSITORY locally.")

    subparsers.add_parser(
        "codex-status",
        help="Check whether the local Codex CLI is available and logged in.",
    )

    codex_task = subparsers.add_parser(
        "make-codex-task",
        help="Write a local Codex task prompt from the latest eval report.",
    )
    codex_task.add_argument(
        "--goal",
        default="Improve the repository based on the latest documentation eval signal.",
    )
    codex_task.add_argument(
        "--goal-file",
        help="Read the Codex task goal from a UTF-8 text file.",
    )
    codex_task.add_argument(
        "--scope",
        choices=["docs", "prompts", "evals", "code", "mixed"],
        default="docs",
    )
    codex_task.add_argument(
        "--improvement-kind",
        choices=["auto", "docs", "feat", "style", "refactor"],
        default="auto",
    )
    codex_task.add_argument("--output", help="Output task file path.")

    run_codex = subparsers.add_parser(
        "run-codex-task",
        help="Run a local Codex task with the authenticated Codex CLI.",
    )
    run_codex.add_argument("--task-file", required=True)
    run_codex.add_argument("--model")
    run_codex.add_argument(
        "--sandbox",
        choices=["read-only", "workspace-write"],
        default="workspace-write",
    )
    run_codex.add_argument("--no-full-auto", action="store_true")
    run_codex.add_argument("--skip-verify", action="store_true")
    run_codex.add_argument("--timeout-seconds", type=int)

    codex_loop = subparsers.add_parser(
        "codex-local-loop",
        help="Run evals, write a local Codex task, and optionally execute it.",
    )
    codex_loop.add_argument(
        "--goal",
        default="Improve the repository based on the latest documentation eval signal.",
    )
    codex_loop.add_argument(
        "--goal-file",
        help="Read the Codex task goal from a UTF-8 text file.",
    )
    codex_loop.add_argument(
        "--scope",
        choices=["docs", "prompts", "evals", "code", "mixed"],
        default="docs",
    )
    codex_loop.add_argument(
        "--improvement-kind",
        choices=["auto", "docs", "feat", "style", "refactor"],
        default="auto",
    )
    codex_loop.add_argument(
        "--execute",
        action="store_true",
        help="Execute the generated task with Codex CLI.",
    )
    codex_loop.add_argument("--model")
    codex_loop.add_argument(
        "--sandbox",
        choices=["read-only", "workspace-write"],
        default="workspace-write",
    )
    codex_loop.add_argument("--skip-verify", action="store_true")
    codex_loop.add_argument("--timeout-seconds", type=int)

    classify = subparsers.add_parser(
        "classify-target-changes",
        help="Classify target repository changes as R0/R1/R2/R3.",
    )
    classify.add_argument("--scope", choices=["docs", "prompts", "evals", "code", "mixed"], default="docs")
    classify.add_argument("--output-json")
    classify.add_argument("--output-md")
    classify.add_argument("--path", action="append", default=[])

    summarize_change = subparsers.add_parser(
        "summarize-target-change",
        help="Write a title and PR summary from the current target diff.",
    )
    summarize_change.add_argument(
        "--kind",
        choices=["auto", "docs", "feat", "style", "refactor"],
        default="auto",
    )
    summarize_change.add_argument("--output-json")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    settings = load_settings()

    if args.command == "eval-docs":
        results, jsonl_path, md_path = run_docs_eval(
            settings,
            dry_run=True,
        )
        passed = sum(1 for result in results if result.passed)
        total = len(results)
        ratio = passed / total if total else 0.0
        print(f"Docs eval: {passed}/{total} passed")
        print(f"JSONL report: {jsonl_path}")
        print(f"Markdown report: {md_path}")
        return 0 if ratio >= args.fail_under else 1

    if args.command == "propose-improvement":
        proposal_path = write_improvement_proposal(settings, dry_run=args.dry_run)
        if proposal_path is None:
            print("All eval cases passed. No proposal written.")
        else:
            print(f"Proposal written: {proposal_path}")
        return 0

    if args.command == "propose-docs-patch":
        docs_path = propose_docs_patch(settings)
        if docs_path is None:
            print("No failed evals with missing required content. No docs patch written.")
        else:
            print(f"Docs patch candidate written: {docs_path}")
        return 0

    if args.command == "triage-issue":
        print(json.dumps({"labels": suggest_labels(args.title, args.body)}, indent=2))
        return 0

    if args.command == "add-eval":
        append_eval_case(
            path=active_evals_path(settings),
            case_id=args.id,
            question=args.question,
            must_include=args.must_include,
            must_not_include=args.must_not_include,
        )
        print(f"Added eval case: {args.id}")
        return 0

    if args.command == "add-eval-from-issue":
        with open(args.body_file, encoding="utf-8") as file:
            issue = parse_eval_issue(file.read())
        append_eval_case(
            path=active_evals_path(settings),
            case_id=issue.case_id,
            question=issue.question,
            must_include=issue.must_include,
            must_not_include=issue.must_not_include,
        )
        suffix = f" from issue #{args.issue_number}" if args.issue_number else ""
        print(f"Added eval case: {issue.case_id}{suffix}")
        return 0

    if args.command == "validate-evals":
        evals_path = active_evals_path(settings)
        result = validate_eval_file(evals_path)
        if result.passed:
            print(f"Eval file is valid: {evals_path}")
            return 0
        for error in result.errors:
            print(error, file=sys.stderr)
        return 1

    if args.command == "doctor":
        checks = doctor_checks(settings)
        print_checks(checks)
        return 0 if checks_passed(checks) else 1

    if args.command == "smoke-check":
        checks = run_smoke_check(settings)
        print_checks(checks)
        return 0 if checks_passed(checks) else 1

    if args.command == "sync-labels":
        token = token_from_env(args.token_env)
        repo = require_repo(args.repo)
        results = sync_labels(repo=repo, token=token, labels=label_definitions())
        print(json.dumps([asdict(result) for result in results], indent=2))
        return 0

    if args.command == "apply-issue-labels":
        token = token_from_env(args.token_env)
        repo = require_repo(args.repo)
        labels = suggest_labels(args.title, args.body)
        sync_labels(repo=repo, token=token, labels=label_definitions())
        applied = add_issue_labels(
            repo=repo,
            issue_number=args.issue_number,
            token=token,
            labels=labels,
        )
        print(json.dumps({"labels": applied}, indent=2))
        return 0

    if args.command == "summarize-pr":
        path = write_pr_summary(
            settings=settings,
            base_ref=args.base_ref,
            head_ref=args.head_ref,
            output_path=settings.root / args.output,
        )
        print(f"PR summary written: {path}")
        return 0

    if args.command == "comment-pr-summary":
        token = token_from_env(args.token_env)
        repo = require_repo(args.repo)
        action = comment_pr_summary(
            repo=repo,
            pr_number=args.pr_number,
            token=token,
            summary_path=settings.root / args.summary_file,
        )
        print(f"PR summary comment {action}")
        return 0

    if args.command == "update-status":
        path = write_status_dashboard(settings, output_path=settings.root / args.output)
        print(f"Status dashboard written: {path}")
        return 0

    if args.command == "target-status":
        status = target_status(settings)
        print(f"Configured: {'yes' if status.configured else 'no'}")
        print(f"Repository: {status.repository or '(self)'}")
        print(f"Default branch: {status.default_branch}")
        print(f"Root: {status.root}")
        print(f"Exists: {'yes' if status.exists else 'no'}")
        print(f"Git repo: {'yes' if status.is_git_repo else 'no'}")
        print(f"Doc files: {len(status.docs)}")
        print(f"Eval file: {status.evals_path}")
        print(f"Eval file exists: {'yes' if status.evals_exists else 'no'}")
        for path in status.docs[:20]:
            print(f"- {path}")
        return 0

    if args.command == "prepare-target":
        path = prepare_target_repo(settings)
        print(f"Target ready: {path}")
        return 0

    if args.command == "codex-status":
        status = check_codex_status()
        command_text = " ".join(status.command)
        print(f"{'PASS' if status.available else 'FAIL'} codex-cli: {command_text}")
        login_status = status.output or status.error
        print(f"{'PASS' if status.authenticated else 'FAIL'} codex-login: {login_status}")
        return 0 if status.available and status.authenticated else 1

    if args.command == "make-codex-task":
        output_path = settings.root / args.output if args.output else None
        path = write_codex_task(
            settings,
            goal=_goal_from_args(args),
            scope=args.scope,
            improvement_kind=args.improvement_kind,
            output_path=output_path,
        )
        print(f"Codex task written: {path}")
        print(f"Run: python -m self_maintainer_bot.cli run-codex-task --task-file {path}")
        return 0

    if args.command == "run-codex-task":
        result = run_codex_task(
            settings,
            task_path=Path(args.task_file),
            model=args.model,
            sandbox=args.sandbox,
            full_auto=not args.no_full_auto,
            skip_verify=args.skip_verify,
            timeout_seconds=args.timeout_seconds,
        )
        print(f"Codex task: {result.task_path}")
        print(f"Codex log: {result.log_path}")
        print(f"Codex last message: {result.last_message_path}")
        if result.verification_returncode is not None:
            print(f"Verification exit code: {result.verification_returncode}")
        if result.returncode != 0:
            return result.returncode
        return result.verification_returncode or 0

    if args.command == "codex-local-loop":
        task_path, result = run_codex_local_loop(
            settings,
            goal=_goal_from_args(args),
            scope=args.scope,
            improvement_kind=args.improvement_kind,
            execute=args.execute,
            model=args.model,
            sandbox=args.sandbox,
            skip_verify=args.skip_verify,
            timeout_seconds=args.timeout_seconds,
        )
        if result is None:
            print(f"Run: python -m self_maintainer_bot.cli run-codex-task --task-file {task_path}")
            return 0
        print(f"Codex log: {result.log_path}")
        print(f"Codex last message: {result.last_message_path}")
        if result.verification_returncode is not None:
            print(f"Verification exit code: {result.verification_returncode}")
        if result.returncode != 0:
            return result.returncode
        return result.verification_returncode or 0

    if args.command == "classify-target-changes":
        status = target_status(settings)
        root = status.root
        changed = args.path or git_changed_files(root)
        report = classify_changes(
            root=root,
            changed_files=changed,
            allowed_paths=effective_allowed_paths(settings, args.scope),
            denied_paths=settings.target_deny_paths,
            max_files=settings.target_max_files,
            max_lines=settings.target_max_lines,
        )
        write_risk_report(
            report,
            json_path=Path(args.output_json) if args.output_json else None,
            markdown_path=Path(args.output_md) if args.output_md else None,
        )
        print(json.dumps(report.to_dict(), ensure_ascii=False, indent=2))
        return 0

    if args.command == "summarize-target-change":
        summary = write_target_change_summary(
            settings,
            kind=args.kind,
            output_json=Path(args.output_json) if args.output_json else None,
        )
        print(json.dumps(summary.to_dict(), ensure_ascii=False, indent=2))
        return 0

    raise AssertionError(f"Unhandled command: {args.command}")


def token_from_env(env_name: str) -> str:
    token = os.getenv(env_name)
    if not token:
        raise RuntimeError(f"{env_name} is required.")
    return token


def require_repo(repo: str | None) -> str:
    if not repo:
        raise RuntimeError("--repo or GITHUB_REPOSITORY is required.")
    if "/" not in repo:
        raise RuntimeError("Repository must use owner/repo format.")
    return repo


if __name__ == "__main__":
    sys.exit(main())
