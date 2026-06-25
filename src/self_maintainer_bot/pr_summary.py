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
        "## Maintainer Bot PR 요약",
        "",
        f"- 변경 파일: {len(changed_files)}",
        f"- 추가 라인: {total_additions}",
        f"- 삭제 라인: {total_deletions}",
        "",
        "### 변경 파일",
        "",
    ]
    if not changed_files:
        lines.append("감지된 파일 변경이 없습니다.")
    else:
        for item in changed_files[:30]:
            lines.append(f"- `{item.path}` (+{item.additions}/-{item.deletions})")
        if len(changed_files) > 30:
            lines.append(f"- 그 외 {len(changed_files) - 30}개 파일")

    lines.extend(
        [
            "",
            "### 검토 체크리스트",
            "",
            "- [ ] eval 변경이 의도적이며 설명 없이 약화되지 않았습니다.",
            "- [ ] workflow 권한 변경은 최소 범위입니다.",
            "- [ ] 생성된 proposal 파일을 병합 전에 사람이 검토했습니다.",
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
