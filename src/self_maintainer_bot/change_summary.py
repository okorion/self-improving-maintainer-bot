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
    diff_text = _combined_diff(root, changed_files)
    subject = _subject_for(resolved_kind, changed_files, diff_text)
    title = f"[{KIND_PREFIX[resolved_kind]}] {subject}"
    intent = _intent_for(resolved_kind, primary_area)
    file_lines = "\n".join(f"- `{path}`: {_file_summary(root, path, resolved_kind)}" for path in changed_files)
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


def _combined_diff(root: Path, changed_files: list[str]) -> str:
    if not changed_files:
        return ""
    return _git_text(root, ["diff", "--", *changed_files])


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


def _subject_for(kind: str, changed_files: list[str], diff_text: str = "") -> str:
    diff_lower = diff_text.lower()
    path_lower = " ".join(changed_files).lower()

    def has_any(*terms: str) -> bool:
        return any(term in diff_lower or term in path_lower for term in terms)

    if kind == "docs":
        if _has_file(changed_files, "README.md"):
            return "README 안내 보강"
        if _has_file(changed_files, "DESIGN.md"):
            return "디자인 문서 보강"
        if any(path.startswith("maintainer-bot/") for path in changed_files):
            return "유지보수 기준 정리"
        return "문서 설명 보강"
    if kind == "style":
        if has_any("@media", "max-width", "min-width", "container"):
            return "반응형 레이아웃 정돈"
        if has_any("focus-visible", ":focus", "aria-"):
            return "접근성 스타일 정돈"
        if any(path.startswith("src/") for path in changed_files) and any(
            path.endswith(".css") for path in changed_files
        ):
            return "화면 상태와 레이아웃 정돈"
        if any(path in {"styles.css", "index.html"} or path.startswith("design-system/") for path in changed_files):
            return "화면 스타일 정돈"
        return "시각 표현 정돈"
    if kind == "refactor":
        if any(path.startswith("scripts/") for path in changed_files):
            return "자동화 스크립트 구조 정리"
        if has_any("usememo", "reduce(", "map(", "type ", "interface ", "const "):
            return "컴포넌트 데이터 흐름 정리"
        if any(path.startswith("src/") for path in changed_files):
            return "앱 구현 구조 정리"
        return "구현 구조 정리"
    if has_any("period", "bucket", "metric", "insight"):
        return "기간별 활동 인사이트 추가"
    if has_any("hint", "progress", "room", "escape"):
        return "탈출 진행 힌트 기능 추가"
    if has_any("shader", "preset", "palette"):
        return "셰이더 프리셋 탐색 추가"
    if has_any("scroll", "snap", "chapter", "timeline"):
        return "스크롤 장면 탐색 기능 추가"
    if has_any("details", "summary", "dialog", "popover", "tab"):
        return "네이티브 UI 예시 탐색 추가"
    if has_any("checkbox", "radio", "css-only", "no-js"):
        return "노JS 인터랙션 예시 추가"
    if any(path in {"index.html", "styles.css"} or path.startswith("src/") for path in changed_files):
        return "화면 상호작용 기능 추가"
    return "프로젝트 기능 보강"


def _intent_for(kind: str, primary_area: str) -> str:
    if kind == "docs":
        return f"{primary_area}의 설명과 유지보수 맥락을 더 명확하게 만듭니다."
    if kind == "style":
        return f"{primary_area}의 시각 표현, 레이아웃, 접근성을 더 읽기 좋게 다듬습니다."
    if kind == "refactor":
        return f"{primary_area}의 구조를 정리해 이후 기능 개선과 검증 비용을 낮춥니다."
    return f"{primary_area}에 작고 검증 가능한 사용자 기능 개선을 추가합니다."


def _file_summary(root: Path, path: str, kind: str) -> str:
    diff_text = _git_text(root, ["diff", "--", path])
    added, removed = _diff_line_counts(diff_text)
    role = _path_role(path)
    change = _change_phrase(path, kind)
    semantic = _semantic_change_detail(path, diff_text, kind)
    detail = _first_added_signal(diff_text)
    size = f"+{added}/-{removed}"
    if semantic:
        return f"{role}에서 {semantic} 변경을 반영했습니다. 변경 규모는 {size}입니다."
    if detail:
        return f"{role}에서 {change} 변경을 반영했습니다. 변경 규모는 {size}이며, 핵심 추가 단서는 '{detail}'입니다."
    return f"{role}에서 {change} 변경을 반영했습니다. 변경 규모는 {size}입니다."


def _git_text(root: Path, args: list[str]) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=True,
    )
    return result.stdout


def _diff_line_counts(diff_text: str) -> tuple[int, int]:
    added = 0
    removed = 0
    for line in diff_text.splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            added += 1
        elif line.startswith("-"):
            removed += 1
    return added, removed


def _first_added_signal(diff_text: str) -> str:
    for line in diff_text.splitlines():
        if not line.startswith("+") or line.startswith("+++"):
            continue
        candidate = line[1:].strip()
        if not candidate or candidate in {"{", "}", ");", "};"}:
            continue
        candidate = " ".join(candidate.split())
        if len(candidate) > 96:
            candidate = candidate[:93].rstrip() + "..."
        return candidate
    return ""


def _added_lines(diff_text: str) -> list[str]:
    lines: list[str] = []
    for line in diff_text.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            candidate = line[1:].strip()
            if candidate:
                lines.append(candidate)
    return lines


def _semantic_change_detail(path: str, diff_text: str, kind: str) -> str:
    added = _added_lines(diff_text)
    joined = "\n".join(added).lower()
    class_names = _extract_css_class_names(added)
    labels = _extract_korean_labels(added)

    if "period" in joined and ("bucket" in joined or "metric" in joined):
        return "기간별 활동 지표와 유형별 분포를 한 화면에서 비교할 수 있는 요약 UI를 추가하는"
    if "shader" in joined or "preset" in joined:
        return "셰이더 프리셋을 더 쉽게 구분하고 탐색할 수 있는 화면 요소를 추가하는"
    if "scroll" in joined and ("chapter" in joined or "snap" in joined):
        return "스크롤 위치와 장면 흐름을 더 분명하게 확인할 수 있는 탐색 UI를 추가하는"
    if "hint" in joined or "progress" in joined or "escape" in joined:
        return "퍼즐 진행 상태와 다음 행동 단서를 더 쉽게 파악할 수 있는 게임 UI를 추가하는"
    if "details" in joined or "summary" in joined or "dialog" in joined or "popover" in joined:
        return "네이티브 HTML 컴포넌트의 상태와 사용 예시를 더 쉽게 비교할 수 있게 하는"
    if "focus-visible" in joined or "aria-" in joined:
        return "키보드 탐색과 보조기기 맥락을 더 분명하게 드러내는 접근성 상태를 추가하는"
    if "@media" in joined or "max-width" in joined or "container" in joined:
        return "화면 폭에 맞춰 정보가 겹치지 않도록 반응형 레이아웃을 다듬는"
    if class_names:
        return f"`{', '.join(class_names[:3])}` 화면 요소를 중심으로 표시 상태와 레이아웃을 다듬는"
    if labels:
        return f"`{', '.join(labels[:3])}` 정보를 사용자가 바로 읽을 수 있도록 화면에 추가하는"
    if kind == "refactor" and path.startswith("src/"):
        return "컴포넌트 데이터 계산과 렌더링 흐름을 분리해 이후 기능 추가가 쉬워지도록 정리하는"
    return ""


def _extract_css_class_names(lines: list[str]) -> list[str]:
    names: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("."):
            name = stripped[1:].split()[0].split("{")[0].strip()
            if name and name not in names:
                names.append(name)
        if "className=" in stripped:
            parts = stripped.split("className=", 1)[1]
            quote = '"' if '"' in parts[:2] else "'"
            if quote in parts:
                value = parts.split(quote, 2)[1]
                for name in value.split():
                    clean = name.strip("{}")
                    if clean and clean not in names:
                        names.append(clean)
    return names


def _extract_korean_labels(lines: list[str]) -> list[str]:
    labels: list[str] = []
    for line in lines:
        text = " ".join(line.replace("<", " ").replace(">", " ").split())
        if not any("가" <= char <= "힣" for char in text):
            continue
        text = text.strip("`'\"{}();,")
        if 2 <= len(text) <= 28 and text not in labels:
            labels.append(text)
    return labels


def _path_role(path: str) -> str:
    if path == "README.md":
        return "프로젝트 첫 안내"
    if path == "DESIGN.md":
        return "디자인 시스템 문서"
    if path == "index.html":
        return "기본 화면 구조"
    if path == "styles.css" or path.endswith(".css"):
        return "시각 스타일"
    if path.startswith("src/"):
        return "애플리케이션 구현"
    if path.startswith("scripts/"):
        return "자동화 스크립트"
    if path.startswith("docs/"):
        return "보조 문서"
    if path.startswith("maintainer-bot/"):
        return "자가 개선 설정"
    return "프로젝트 파일"


def _change_phrase(path: str, kind: str) -> str:
    if kind == "docs":
        return "설명과 유지보수 기준을 명확히 하는"
    if kind == "style":
        return "화면 가독성, 레이아웃, 접근성을 다듬는"
    if kind == "refactor":
        return "동작을 유지하면서 구조와 중복을 정리하는"
    if path in {"index.html", "styles.css"} or path.startswith("src/"):
        return "사용자 경험에 직접 영향을 주는"
    return "기능 개선을 뒷받침하는"


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
