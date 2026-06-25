from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from self_maintainer_bot.github_api import upsert_issue_comment


MARKER = "<!-- maintainer-bot:pr-summary -->"


@dataclass(frozen=True)
class ChangedFile:
    path: str
    additions: int
    deletions: int


def collect_changed_files(*, base_ref: str, head_ref: str) -> list[ChangedFile]:
    output = subprocess.check_output(
        ["git", "diff", "--numstat", f"{base_ref}...{head_ref}"],
        text=True,
        encoding="utf-8",
    )
    changed: list[ChangedFile] = []
    for raw_line in output.splitlines():
        parts = raw_line.split("\t")
        if len(parts) < 3:
            continue
        additions_raw, deletions_raw, path = parts[0], parts[1], parts[2]
        additions = int(additions_raw) if additions_raw.isdigit() else 0
        deletions = int(deletions_raw) if deletions_raw.isdigit() else 0
        changed.append(ChangedFile(path=path, additions=additions, deletions=deletions))
    return changed


def collect_diff(*, base_ref: str, head_ref: str, max_chars: int = 12000) -> str:
    diff = subprocess.check_output(
        ["git", "diff", "--unified=3", f"{base_ref}...{head_ref}"],
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if len(diff) <= max_chars:
        return diff
    return diff[:max_chars] + "\n\n[diff truncated]\n"


def render_static_summary(changed_files: list[ChangedFile]) -> str:
    total_additions = sum(item.additions for item in changed_files)
    total_deletions = sum(item.deletions for item in changed_files)
    lines = [
        MARKER,
        "## Maintainer Bot PR Summary",
        "",
        f"- Files changed: {len(changed_files)}",
        f"- Additions: {total_additions}",
        f"- Deletions: {total_deletions}",
        "",
        "### Changed Files",
        "",
    ]
    if not changed_files:
        lines.append("No file changes detected.")
    else:
        for item in changed_files[:30]:
            lines.append(f"- `{item.path}` (+{item.additions}/-{item.deletions})")
        if len(changed_files) > 30:
            lines.append(f"- ...and {len(changed_files) - 30} more files")

    lines.extend(
        [
            "",
            "### Review Checklist",
            "",
            "- [ ] Eval changes are intentional and not weaker without explanation.",
            "- [ ] Workflow permission changes are minimal.",
            "- [ ] Generated proposal files were reviewed before merge.",
        ]
    )
    return "\n".join(lines)


def write_pr_summary(
    *,
    base_ref: str,
    head_ref: str,
    output_path: Path,
) -> Path:
    changed_files = collect_changed_files(base_ref=base_ref, head_ref=head_ref)
    body = render_static_summary(changed_files)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(body.strip() + "\n", encoding="utf-8", newline="\n")
    return output_path


def comment_pr_summary(
    *,
    repo: str,
    pr_number: int,
    token: str,
    summary_path: Path,
) -> str:
    body = summary_path.read_text(encoding="utf-8")
    if MARKER not in body:
        body = f"{MARKER}\n{body}"
    return upsert_issue_comment(
        repo=repo,
        issue_number=pr_number,
        token=token,
        marker=MARKER,
        body=body,
    )
