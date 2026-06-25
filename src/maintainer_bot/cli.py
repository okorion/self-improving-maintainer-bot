from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict

from maintainer_bot.config import load_settings
from maintainer_bot.docs_eval import run_docs_eval
from maintainer_bot.docs_patch import propose_docs_patch
from maintainer_bot.eval_store import append_eval_case, validate_eval_file
from maintainer_bot.github_api import add_issue_labels, sync_labels
from maintainer_bot.health import checks_passed, doctor_checks, print_checks, run_smoke_check
from maintainer_bot.issue_forms import parse_eval_issue
from maintainer_bot.pr_summary import comment_pr_summary, write_pr_summary
from maintainer_bot.reports import write_improvement_proposal
from maintainer_bot.status import write_status_dashboard
from maintainer_bot.triage import label_definitions, suggest_labels


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="maintainer-bot")
    subparsers = parser.add_subparsers(dest="command", required=True)

    eval_docs = subparsers.add_parser("eval-docs", help="Run documentation QA evals.")
    eval_docs.add_argument("--dry-run", action="store_true", help="Run without OpenAI API calls.")
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
    improve.add_argument("--dry-run", action="store_true", help="Do not call the OpenAI API.")

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

    doctor = subparsers.add_parser("doctor", help="Check local setup and required files.")
    doctor.add_argument(
        "--require-api-key",
        action="store_true",
        help="Fail when OPENAI_API_KEY is not configured.",
    )

    subparsers.add_parser("smoke-check", help="Run local compile, dry-run eval, and triage checks.")

    sync = subparsers.add_parser("sync-labels", help="Create or update standard GitHub labels.")
    sync.add_argument("--repo", default=os.getenv("GITHUB_REPOSITORY"), help="owner/repo")
    sync.add_argument("--token-env", default="GITHUB_TOKEN", help="Environment variable containing token.")

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
    pr_summary.add_argument("--use-openai", action="store_true")

    comment_summary = subparsers.add_parser(
        "comment-pr-summary",
        help="Create or update a PR summary comment.",
    )
    comment_summary.add_argument("--repo", default=os.getenv("GITHUB_REPOSITORY"), help="owner/repo")
    comment_summary.add_argument("--pr-number", type=int, required=True)
    comment_summary.add_argument("--summary-file", default="runs/pr-summary.md")
    comment_summary.add_argument("--token-env", default="GITHUB_TOKEN")

    status = subparsers.add_parser("update-status", help="Write docs/PROJECT_STATUS.md.")
    status.add_argument("--output", default="docs/PROJECT_STATUS.md")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    settings = load_settings()

    if args.command == "eval-docs":
        results, jsonl_path, md_path = run_docs_eval(settings, dry_run=args.dry_run)
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
            path=settings.evals_path,
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
            path=settings.evals_path,
            case_id=issue.case_id,
            question=issue.question,
            must_include=issue.must_include,
            must_not_include=issue.must_not_include,
        )
        suffix = f" from issue #{args.issue_number}" if args.issue_number else ""
        print(f"Added eval case: {issue.case_id}{suffix}")
        return 0

    if args.command == "validate-evals":
        result = validate_eval_file(settings.evals_path)
        if result.passed:
            print(f"Eval file is valid: {settings.evals_path}")
            return 0
        for error in result.errors:
            print(error, file=sys.stderr)
        return 1

    if args.command == "doctor":
        checks = doctor_checks(settings)
        print_checks(checks, require_api_key=args.require_api_key)
        return 0 if checks_passed(checks, require_api_key=args.require_api_key) else 1

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
            use_openai=args.use_openai,
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
