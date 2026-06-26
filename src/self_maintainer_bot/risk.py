from __future__ import annotations

import json
import subprocess
from dataclasses import asdict, dataclass
from enum import IntEnum
from fnmatch import fnmatchcase
from pathlib import Path


class RiskLevel(IntEnum):
    R0 = 0
    R1 = 1
    R2 = 2
    R3 = 3

    @classmethod
    def parse(cls, value: str) -> "RiskLevel":
        normalized = value.strip().upper()
        if normalized not in cls.__members__:
            raise ValueError(f"Unsupported risk level: {value}")
        return cls[normalized]


@dataclass(frozen=True)
class FileRisk:
    path: str
    risk: str
    allowed: bool
    denied: bool
    reason: str


@dataclass(frozen=True)
class RiskReport:
    max_risk: str
    publish_mode: str
    changed_files: list[str]
    files: list[FileRisk]
    denied_files: list[str]
    disallowed_files: list[str]
    changed_file_count: int
    changed_line_count: int
    max_files: int
    max_lines: int
    limit_exceeded: bool

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


DEFAULT_R2_PATTERNS = [
    "package.json",
    "pnpm-lock.yaml",
    "package-lock.json",
    "yarn.lock",
    "bun.lockb",
    "maintainer-bot/project.json",
    "vite.config.*",
    "tsconfig*.json",
    "eslint.config.*",
    "scripts/**",
]

DEFAULT_R3_PATTERNS = [
    ".github/workflows/**",
    ".github/CODEOWNERS",
    "CODEOWNERS",
    ".env*",
    ".npmrc",
    "infra/**",
    "terraform/**",
    "k8s/**",
    "migrations/**",
    "**/auth/**",
    "**/security/**",
    "*.pem",
    "*.key",
]


def classify_changes(
    *,
    root: Path,
    changed_files: list[str],
    allowed_paths: list[str],
    denied_paths: list[str],
    max_files: int = 0,
    max_lines: int = 0,
    r2_patterns: list[str] | None = None,
    r3_patterns: list[str] | None = None,
) -> RiskReport:
    normalized_files = sorted(path.replace("\\", "/") for path in changed_files if path)
    r2_patterns = r2_patterns or DEFAULT_R2_PATTERNS
    r3_patterns = unique_patterns([*DEFAULT_R3_PATTERNS, *(r3_patterns or []), *denied_paths])

    file_risks: list[FileRisk] = []
    denied_files: list[str] = []
    disallowed_files: list[str] = []

    for path in normalized_files:
        allowed = any_path_matches(path, allowed_paths)
        denied = any_path_matches(path, denied_paths)
        if denied:
            denied_files.append(path)
        if not allowed:
            disallowed_files.append(path)

        risk = RiskLevel.R1
        reason = "allowed R1 target path"
        if denied or any_path_matches(path, r3_patterns):
            risk = RiskLevel.R3
            reason = "R3 denied or protected path"
        elif not allowed:
            risk = RiskLevel.R3
            reason = "outside target allowPaths"
        elif any_path_matches(path, r2_patterns):
            risk = RiskLevel.R2
            reason = "R2 dependency, build, or validation surface"

        file_risks.append(
            FileRisk(path=path, risk=risk.name, allowed=allowed, denied=denied, reason=reason)
        )

    changed_line_count = changed_line_total(root, normalized_files) if normalized_files else 0
    limit_exceeded = False
    if max_files and len(normalized_files) > max_files:
        limit_exceeded = True
    if max_lines and changed_line_count > max_lines:
        limit_exceeded = True

    if not normalized_files:
        max_risk = RiskLevel.R0
    else:
        max_risk = max(RiskLevel.parse(item.risk) for item in file_risks)
        if limit_exceeded and max_risk < RiskLevel.R3:
            max_risk = RiskLevel.R3

    publish_mode = publish_mode_for_risk(max_risk)
    if limit_exceeded:
        publish_mode = "proposal_only"

    return RiskReport(
        max_risk=max_risk.name,
        publish_mode=publish_mode,
        changed_files=normalized_files,
        files=file_risks,
        denied_files=denied_files,
        disallowed_files=disallowed_files,
        changed_file_count=len(normalized_files),
        changed_line_count=changed_line_count,
        max_files=max_files,
        max_lines=max_lines,
        limit_exceeded=limit_exceeded,
    )


def publish_mode_for_risk(risk: RiskLevel) -> str:
    if risk == RiskLevel.R0:
        return "report_only"
    if risk == RiskLevel.R1:
        return "pull_request"
    if risk == RiskLevel.R2:
        return "draft_pull_request"
    return "proposal_only"


def write_risk_report(report: RiskReport, *, json_path: Path | None, markdown_path: Path | None) -> None:
    if json_path:
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(
            json.dumps(report.to_dict(), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
    if markdown_path:
        markdown_path.parent.mkdir(parents=True, exist_ok=True)
        markdown_path.write_text(render_risk_markdown(report), encoding="utf-8", newline="\n")


def render_risk_markdown(report: RiskReport) -> str:
    lines = [
        "# Target Change Risk Report",
        "",
        f"- max risk: `{report.max_risk}`",
        f"- publish mode: `{report.publish_mode}`",
        f"- changed files: `{report.changed_file_count}`",
        f"- changed lines: `{report.changed_line_count}`",
        f"- max files: `{report.max_files or 'unlimited'}`",
        f"- max lines: `{report.max_lines or 'unlimited'}`",
        f"- limit exceeded: `{'yes' if report.limit_exceeded else 'no'}`",
        "",
        "## Files",
        "",
    ]
    if not report.files:
        lines.append("- no target changes")
    else:
        for item in report.files:
            marker = "denied" if item.denied else "allowed" if item.allowed else "outside allowPaths"
            lines.append(f"- `{item.path}`: `{item.risk}` ({marker}; {item.reason})")

    if report.denied_files:
        lines.extend(["", "## Denied Files", ""])
        lines.extend(f"- `{path}`" for path in report.denied_files)

    if report.disallowed_files:
        lines.extend(["", "## Outside allowPaths", ""])
        lines.extend(f"- `{path}`" for path in report.disallowed_files)

    return "\n".join(lines).strip() + "\n"


def git_changed_files(root: Path) -> list[str]:
    if not (root / ".git").exists():
        return []
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    )
    changed: list[str] = []
    for line in result.stdout.splitlines():
        if not line:
            continue
        path = line[3:]
        if " -> " in path:
            _, path = path.rsplit(" -> ", 1)
        changed.append(path.replace("\\", "/"))
    return sorted(set(changed))


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
    if normalized_pattern.startswith("**/"):
        suffix = normalized_pattern[3:]
        if any(token in suffix for token in "*?[]"):
            return fnmatchcase(normalized_path, suffix) or fnmatchcase(
                normalized_path, normalized_pattern
            )
        return normalized_path == suffix or normalized_path.endswith(f"/{suffix}")
    if any(token in normalized_pattern for token in "*?[]"):
        return fnmatchcase(normalized_path, normalized_pattern)
    return normalized_path == normalized_pattern or normalized_path.startswith(
        f"{normalized_pattern.rstrip('/')}/"
    )


def changed_line_total(root: Path, files: list[str]) -> int:
    if not files:
        return 0
    has_git = (root / ".git").exists()
    diff_args = ["git", "diff", "--numstat", "--", *files]
    if has_git:
        diff_args = ["git", "diff", "--numstat", "HEAD", "--", *files]
    result = subprocess.run(
        diff_args,
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

    untracked_files: set[str] = set()
    if has_git:
        status = subprocess.run(
            ["git", "status", "--porcelain", "--", *files],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
        for line in status.stdout.splitlines():
            if not line.startswith("?? "):
                continue
            untracked_files.add(line[3:].replace("\\", "/"))

    for file_path in files:
        if file_path in seen:
            continue
        if has_git and file_path not in untracked_files:
            continue
        path = root / file_path
        if not path.is_file():
            continue
        try:
            total += len(path.read_text(encoding="utf-8").splitlines())
        except UnicodeDecodeError:
            total += 1
    return total


def unique_patterns(patterns: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for pattern in patterns:
        if pattern in seen:
            continue
        seen.add(pattern)
        result.append(pattern)
    return result
