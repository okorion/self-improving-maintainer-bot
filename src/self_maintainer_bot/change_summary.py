from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

from self_maintainer_bot.config import Settings
from self_maintainer_bot.target_repo import target_root


KIND_PREFIX = {
    "docs": "docs",
    "feat": "feat",
    "style": "style",
    "refactor": "refactor",
}


@dataclass(frozen=True)
class TargetChangeSummary:
    kind: str
    title: str
    intent: str
    summary_markdown: str
    commit_body: str
    primary_area: str

    def to_dict(self) -> dict[str, str]:
        return {
            "kind": self.kind,
            "title": self.title,
            "intent": self.intent,
            "summary_markdown": self.summary_markdown,
            "commit_body": self.commit_body,
            "primary_area": self.primary_area,
        }


def summarize_target_change(settings: Settings, *, kind: str = "auto") -> TargetChangeSummary:
    root = target_root(settings)
    changed_files = _git_lines(root, ["diff", "--name-only"])
    if not changed_files:
        changed_files = _git_lines(root, ["diff", "--cached", "--name-only"])
    resolved_kind = _resolve_kind(kind, changed_files)
    primary_area = _primary_area(changed_files)
    subject = _subject_for(resolved_kind, changed_files)
    title = f"[{KIND_PREFIX[resolved_kind]}] {subject}"
    intent = _intent_for(resolved_kind, primary_area)
    file_lines = "\n".join(f"- `{path}`: {_file_summary(path, resolved_kind)}" for path in changed_files)
    if not file_lines:
        file_lines = "- 변경 파일 없음"

    summary_markdown = "\n".join(
        [
            "## 변경 요약",
            "",
            f"- 변경 유형: `{resolved_kind}`",
            f"- 주된 영역: `{primary_area}`",
            f"- 변경 의도: {intent}",
            "",
            "### 주요 변경",
            "",
            file_lines,
        ]
    )
    commit_body = "\n".join(
        [
            f"- 변경 유형: {resolved_kind}",
            f"- 주된 영역: {primary_area}",
            f"- 변경 의도: {intent}",
        ]
    )
    return TargetChangeSummary(
        kind=resolved_kind,
        title=title,
        intent=intent,
        summary_markdown=summary_markdown,
        commit_body=commit_body,
        primary_area=primary_area,
    )


def write_target_change_summary(settings: Settings, *, kind: str, output_json: Path | None) -> TargetChangeSummary:
    summary = summarize_target_change(settings, kind=kind)
    if output_json:
        output_json.parent.mkdir(parents=True, exist_ok=True)
        output_json.write_text(json.dumps(summary.to_dict(), ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


def _git_lines(root: Path, args: list[str]) -> list[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=True,
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def _resolve_kind(kind: str, changed_files: list[str]) -> str:
    if kind in {"docs", "feat", "style", "refactor"}:
        return kind
    if changed_files and all(_is_docs_path(path) for path in changed_files):
        return "docs"
    if any(_is_style_path(path) for path in changed_files):
        return "style"
    if any(_is_refactor_path(path) for path in changed_files):
        return "refactor"
    return "feat"


def _primary_area(changed_files: list[str]) -> str:
    if not changed_files:
        return "unknown"
    if len(changed_files) == 1:
        return changed_files[0]
    dirs = []
    for path in changed_files:
        if "/" in path:
            dirs.append(path.split("/", 1)[0])
        else:
            dirs.append(path)
    first = dirs[0]
    if all(item == first for item in dirs):
        return f"{first}/"
    return f"{changed_files[0]} 외 {len(changed_files) - 1}개"


def _subject_for(kind: str, changed_files: list[str]) -> str:
    if kind == "docs":
        if _has_file(changed_files, "README.md"):
            return "README 안내 보강"
        if _has_file(changed_files, "DESIGN.md"):
            return "디자인 문서 보강"
        if any(path.startswith("maintainer-bot/") for path in changed_files):
            return "유지보수 기준 정리"
        return "문서 설명 보강"
    if kind == "style":
        if any(path in {"styles.css", "index.html"} or path.startswith("design-system/") for path in changed_files):
            return "화면 스타일 정돈"
        return "시각 표현 정돈"
    if kind == "refactor":
        if any(path.startswith("scripts/") for path in changed_files):
            return "자동화 스크립트 구조 정리"
        return "구현 구조 정리"
    if any(path in {"index.html", "styles.css"} or path.startswith("src/") for path in changed_files):
        return "사용자 기능 개선"
    return "프로젝트 기능 보강"


def _intent_for(kind: str, primary_area: str) -> str:
    if kind == "docs":
        return f"{primary_area}의 설명과 유지보수 맥락을 더 명확하게 만듭니다."
    if kind == "style":
        return f"{primary_area}의 시각 표현, 레이아웃, 접근성을 더 읽기 좋게 다듬습니다."
    if kind == "refactor":
        return f"{primary_area}의 구조를 정리해 이후 기능 개선과 검증 비용을 낮춥니다."
    return f"{primary_area}에 작고 검증 가능한 사용자 기능 개선을 추가합니다."


def _file_summary(path: str, kind: str) -> str:
    if kind == "docs":
        return "문서 설명 또는 유지보수 기준을 보강했습니다."
    if kind == "style":
        return "시각 표현이나 레이아웃 관련 변경을 반영했습니다."
    if kind == "refactor":
        return "동작을 유지하면서 구조를 정리했습니다."
    if path in {"index.html", "styles.css"} or path.startswith("src/"):
        return "사용자 경험에 영향을 주는 기능 개선을 반영했습니다."
    return "기능 개선에 필요한 보조 변경을 반영했습니다."


def _has_file(changed_files: list[str], filename: str) -> bool:
    return any(path == filename or path.endswith(f"/{filename}") for path in changed_files)


def _is_docs_path(path: str) -> bool:
    return (
        path in {"README.md", "DESIGN.md", "CONTRIBUTING.md"}
        or path.startswith("docs/")
        or path.startswith("maintainer-bot/")
    )


def _is_style_path(path: str) -> bool:
    return path.endswith(".css") or path in {"styles.css"} or path.startswith("design-system/")


def _is_refactor_path(path: str) -> bool:
    return path.startswith("scripts/") or path.startswith("src/") or path.endswith(".ts")
