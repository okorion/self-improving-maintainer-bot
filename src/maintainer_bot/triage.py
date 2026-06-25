from __future__ import annotations


LABEL_RULES = {
    "security": ("security", "vulnerability", "secret", "token", "credential", "exploit"),
    "bug": ("bug", "crash", "error", "failed", "broken", "traceback", "exception"),
    "docs": ("docs", "documentation", "readme", "typo", "guide"),
    "enhancement": ("feature", "enhancement", "request", "support", "add"),
    "question": ("how do i", "question", "help", "usage"),
}

LABEL_DEFINITIONS = {
    "bug": {
        "color": "d73a4a",
        "description": "Something is not working as expected.",
    },
    "docs": {
        "color": "0075ca",
        "description": "Documentation, guides, README, or examples.",
    },
    "enhancement": {
        "color": "a2eeef",
        "description": "New feature or improvement request.",
    },
    "question": {
        "color": "d876e3",
        "description": "Usage question or clarification request.",
    },
    "security": {
        "color": "b60205",
        "description": "Potential security issue. Avoid posting sensitive details publicly.",
    },
    "eval": {
        "color": "5319e7",
        "description": "A bot failure or expected behavior that should become an eval case.",
    },
    "needs-review": {
        "color": "fbca04",
        "description": "Needs human review before automation should act on it.",
    },
}


def suggest_labels(title: str, body: str) -> list[str]:
    text = f"{title}\n{body}".lower()
    labels = [
        label
        for label, keywords in LABEL_RULES.items()
        if any(keyword in text for keyword in keywords)
    ]
    return labels or ["question"]


def label_definitions() -> list[dict[str, str]]:
    return [
        {"name": name, **definition}
        for name, definition in sorted(LABEL_DEFINITIONS.items())
    ]
