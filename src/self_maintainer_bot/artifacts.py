from __future__ import annotations

import os
import re
import uuid
from datetime import datetime, timezone
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from self_maintainer_bot.config import Settings


def artifact_slug(value: str | None) -> str:
    text = (value or "self").replace("\\", "/").strip("/")
    text = text.replace("/", "-")
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", text).strip("-._")
    return slug or "self"


def target_artifact_slug(settings: Settings) -> str:
    if settings.target_repository:
        return artifact_slug(settings.target_repository)
    return artifact_slug(settings.target_worktree.name)


def unique_artifact_name(settings: Settings, prefix: str, *, suffix: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    target = target_artifact_slug(settings)
    unique = uuid.uuid4().hex[:8]
    return f"{artifact_slug(prefix)}-{stamp}-{target}-{os.getpid()}-{unique}.{suffix.lstrip('.')}"
