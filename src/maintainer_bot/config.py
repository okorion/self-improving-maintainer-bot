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
    model: str
    reasoning_effort: str
    openai_api_key: str | None


def load_settings() -> Settings:
    load_dotenv()
    return Settings(
        root=ROOT,
        docs_path=ROOT / "docs" / "knowledge.md",
        evals_path=ROOT / "evals" / "docs_qa.jsonl",
        runs_dir=ROOT / "runs",
        proposals_dir=ROOT / "proposals",
        docs_prompt_path=ROOT / "prompts" / "docs_qa_system.md",
        improvement_prompt_path=ROOT / "prompts" / "improvement_planner.md",
        model=os.getenv("OPENAI_MODEL", "gpt-5.5"),
        reasoning_effort=os.getenv("OPENAI_REASONING_EFFORT", "low"),
        openai_api_key=os.getenv("OPENAI_API_KEY") or None,
    )
