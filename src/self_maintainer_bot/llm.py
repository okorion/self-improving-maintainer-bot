from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class LlmConfig:
    model: str
    reasoning_effort: str = "low"


def call_openai_text(
    *,
    api_key: str,
    config: LlmConfig,
    instructions: str,
    user_input: str,
) -> str:
    try:
        from openai import OpenAI
    except ImportError as exc:
        raise RuntimeError("The openai package is not installed. Run: python -m pip install -e .") from exc

    client = OpenAI(api_key=api_key)
    response = client.responses.create(
        model=config.model,
        reasoning={"effort": config.reasoning_effort},
        input=[
            {"role": "developer", "content": instructions},
            {"role": "user", "content": user_input},
        ],
    )
    return response.output_text.strip()
