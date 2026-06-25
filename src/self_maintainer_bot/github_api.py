from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


API_ROOT = "https://api.github.com"


class GitHubApiError(RuntimeError):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"GitHub API request failed with HTTP {status}: {message}")
        self.status = status
        self.message = message


@dataclass(frozen=True)
class LabelSyncResult:
    name: str
    action: str


def _request(
    method: str,
    path: str,
    *,
    token: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any] | list[Any] | None:
    data = None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(
        f"{API_ROOT}{path}",
        data=data,
        headers=headers,
        method=method,
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
            if not body:
                return None
            return json.loads(body.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise GitHubApiError(exc.code, body) from exc


def sync_labels(
    *,
    repo: str,
    token: str,
    labels: list[dict[str, str]],
) -> list[LabelSyncResult]:
    results: list[LabelSyncResult] = []
    for label in labels:
        name = label["name"]
        payload = {
            "name": name,
            "color": label["color"],
            "description": label["description"],
        }
        encoded_name = urllib.parse.quote(name, safe="")
        try:
            _request("PATCH", f"/repos/{repo}/labels/{encoded_name}", token=token, payload=payload)
            results.append(LabelSyncResult(name=name, action="updated"))
        except GitHubApiError as exc:
            if exc.status != 404:
                raise
            _request("POST", f"/repos/{repo}/labels", token=token, payload=payload)
            results.append(LabelSyncResult(name=name, action="created"))
    return results


def add_issue_labels(
    *,
    repo: str,
    issue_number: int,
    token: str,
    labels: list[str],
) -> list[str]:
    if not labels:
        return []
    _request(
        "POST",
        f"/repos/{repo}/issues/{issue_number}/labels",
        token=token,
        payload={"labels": labels},
    )
    return labels


def upsert_issue_comment(
    *,
    repo: str,
    issue_number: int,
    token: str,
    marker: str,
    body: str,
) -> str:
    comments = _request("GET", f"/repos/{repo}/issues/{issue_number}/comments", token=token)
    if not isinstance(comments, list):
        comments = []

    for comment in comments:
        if not isinstance(comment, dict):
            continue
        comment_body = str(comment.get("body", ""))
        comment_id = comment.get("id")
        if marker in comment_body and comment_id:
            _request(
                "PATCH",
                f"/repos/{repo}/issues/comments/{comment_id}",
                token=token,
                payload={"body": body},
            )
            return "updated"

    _request(
        "POST",
        f"/repos/{repo}/issues/{issue_number}/comments",
        token=token,
        payload={"body": body},
    )
    return "created"
