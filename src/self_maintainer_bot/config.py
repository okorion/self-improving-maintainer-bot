from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_dotenv(path: Path | None = None) -> None:
    env_path = path or ROOT / ".env"
    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


@dataclass(frozen=True)
class Settings:
    root: Path
    docs_path: Path
    evals_path: Path
    runs_dir: Path
    proposals_dir: Path
    docs_prompt_path: Path
    improvement_prompt_path: Path
    target_repository: str | None
    target_default_branch: str
    target_worktree: Path
    target_doc_paths: list[str]
    target_evals_path: Path | None
    codex_timeout_seconds: int


def load_settings() -> Settings:
    load_dotenv()
    target_repository = os.getenv("TARGET_REPOSITORY") or None
    target_worktree_raw = os.getenv("TARGET_WORKTREE")
    target_doc_paths = parse_csv(os.getenv("TARGET_DOC_PATHS"), default=["README.md", "docs"])
    target_worktree = resolve_root_path(
        target_worktree_raw,
        default=ROOT / "targets" / "active",
    )
    target_evals_path_raw = os.getenv("TARGET_EVALS_PATH") or None
    return Settings(
        root=ROOT,
        docs_path=ROOT / "docs" / "knowledge.md",
        evals_path=ROOT / "evals" / "docs_qa.jsonl",
        runs_dir=ROOT / "runs",
        proposals_dir=ROOT / "proposals",
        docs_prompt_path=ROOT / "prompts" / "docs_qa_system.md",
        improvement_prompt_path=ROOT / "prompts" / "improvement_planner.md",
        target_repository=target_repository,
        target_default_branch=os.getenv("TARGET_DEFAULT_BRANCH", "main"),
        target_worktree=target_worktree,
        target_doc_paths=target_doc_paths,
        target_evals_path=Path(target_evals_path_raw) if target_evals_path_raw else None,
        codex_timeout_seconds=parse_int(os.getenv("CODEX_TIMEOUT_SECONDS"), default=3600),
    )


def parse_csv(value: str | None, *, default: list[str]) -> list[str]:
    if not value:
        return default
    parsed = [item.strip() for item in value.split(",") if item.strip()]
    return parsed or default


def parse_int(value: str | None, *, default: int) -> int:
    if not value:
        return default
    try:
        parsed = int(value)
    except ValueError:
        return default
    return parsed if parsed > 0 else default


def resolve_root_path(value: str | None, *, default: Path) -> Path:
    if not value:
        return default
    path = Path(value)
    return path if path.is_absolute() else ROOT / path
