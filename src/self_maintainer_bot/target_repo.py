from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from self_maintainer_bot.config import Settings


@dataclass(frozen=True)
class TargetRepoStatus:
    configured: bool
    repository: str | None
    default_branch: str
    root: Path
    exists: bool
    is_git_repo: bool
    docs: list[Path]


def target_root(settings: Settings) -> Path:
    if settings.target_repository:
        return settings.target_worktree
    return settings.root


def target_status(settings: Settings) -> TargetRepoStatus:
    root = target_root(settings)
    return TargetRepoStatus(
        configured=bool(settings.target_repository),
        repository=settings.target_repository,
        default_branch=settings.target_default_branch,
        root=root,
        exists=root.exists(),
        is_git_repo=(root / ".git").exists(),
        docs=find_target_docs(settings, root=root) if root.exists() else [],
    )


def prepare_target_repo(settings: Settings) -> Path:
    if not settings.target_repository:
        return settings.root

    root = settings.target_worktree
    remote = normalize_repository_url(settings.target_repository)
    if (root / ".git").exists():
        run_git(["fetch", "origin", settings.target_default_branch], cwd=root)
        run_git(["checkout", settings.target_default_branch], cwd=root)
        run_git(["pull", "--ff-only", "origin", settings.target_default_branch], cwd=root)
        return root

    if root.exists() and any(root.iterdir()):
        raise RuntimeError(f"TARGET_WORKTREE exists but is not a git repository: {root}")

    root.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "git",
            "clone",
            "--branch",
            settings.target_default_branch,
            "--depth",
            "1",
            remote,
            str(root),
        ],
        check=True,
        text=True,
    )
    return root


def normalize_repository_url(repository: str) -> str:
    if repository.startswith(("https://", "git@", "ssh://")):
        return repository
    if "/" not in repository:
        raise ValueError("TARGET_REPOSITORY must be owner/repo or a git URL.")
    return f"https://github.com/{repository}.git"


def find_target_docs(settings: Settings, *, root: Path | None = None) -> list[Path]:
    repo_root = root or target_root(settings)
    docs: list[Path] = []
    for raw_path in settings.target_doc_paths:
        path = repo_root / raw_path
        if path.is_file():
            docs.append(path)
        elif path.is_dir():
            docs.extend(
                item
                for item in sorted(path.rglob("*.md"))
                if ".git" not in item.parts and item.is_file()
            )
    return unique_paths(docs)


def load_target_docs_text(settings: Settings) -> str:
    if not settings.target_repository:
        return settings.docs_path.read_text(encoding="utf-8")

    root = target_root(settings)
    if not root.exists():
        raise FileNotFoundError(
            f"Target repository is not prepared: {root}. Run prepare-target first."
        )

    docs = find_target_docs(settings, root=root)
    if not docs:
        joined_paths = ", ".join(settings.target_doc_paths)
        raise FileNotFoundError(f"No target docs found under: {joined_paths}")

    chunks: list[str] = []
    for path in docs:
        relative = path.relative_to(root).as_posix()
        chunks.extend(
            [
                f"# Source: {relative}",
                "",
                path.read_text(encoding="utf-8", errors="replace").strip(),
                "",
            ]
        )
    return "\n".join(chunks).strip() + "\n"


def run_git(args: list[str], *, cwd: Path) -> None:
    subprocess.run(["git", *args], cwd=cwd, check=True, text=True)


def unique_paths(paths: list[Path]) -> list[Path]:
    seen: set[Path] = set()
    result: list[Path] = []
    for path in paths:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        result.append(path)
    return result
