from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any


INTERPRETATION_VERSION = "conversation-llm-interpretation-v1"
CONTEXT_TYPES = [
    "interview",
    "date",
    "service_interaction",
    "sales_or_negotiation",
    "work_meeting",
    "supportive_personal_conversation",
    "conflict_or_disagreement",
    "casual_social",
    "unknown",
]


def interpret_conversation(metrics: dict[str, Any], *, provider: str | None = None) -> dict[str, Any]:
    provider_name = (provider or os.getenv("INTERPRETATION_PROVIDER", "mock")).strip().lower()
    if provider_name in {"openai", "responses"} and os.getenv("OPENAI_API_KEY"):
        try:
            return interpret_with_openai(metrics)
        except RuntimeError as exc:
            if os.getenv("INTERPRETATION_FALLBACK_ON_ERROR", "1").strip().lower() in {"1", "true", "yes", "on"}:
                fallback = interpret_locally(metrics, provider_name="openai_failed_local_fallback")
                fallback["llm_error"] = str(exc)
                fallback["limitations"].insert(
                    0,
                    "OpenAI interpretation failed, so this response used the local deterministic fallback.",
                )
                return fallback
            raise
    if provider_name == "groq" and os.getenv("GROQ_API_KEY"):
        try:
            return interpret_with_groq(metrics)
        except RuntimeError as exc:
            if os.getenv("INTERPRETATION_FALLBACK_ON_ERROR", "1").strip().lower() in {"1", "true", "yes", "on"}:
                fallback = interpret_locally(metrics, provider_name="groq_failed_local_fallback")
                fallback["llm_error"] = str(exc)
                fallback["limitations"].insert(
                    0,
                    "Groq interpretation failed, so this response used the local deterministic fallback.",
                )
                return fallback
            raise
    return interpret_locally(metrics, provider_name=provider_name)


def apply_contextualization(metrics: dict[str, Any], interpretation: dict[str, Any]) -> dict[str, Any]:
    """Attach context-aware score significance to an analyzer result.

    The original scores remain unchanged. Contextualization answers a different
    question: given this conversation type, which scores matter most right now?
    """
    updated = dict(metrics)
    insights = dict(updated.get("insights") or {})
    scores = insights.get("scores") or {}
    context = interpretation.get("context") or {}
    context_type = canonical_context_type(context.get("type") or "unknown")
    context_weights = weights_for_context(context_type)
    priority_overrides = {
        item.get("variable"): item
        for item in interpretation.get("context_weighted_priorities") or []
        if item.get("variable")
    }

    contextualized_scores = {}
    for name, item in scores.items():
        score = as_number(item.get("score"), 50.0)
        weight = as_number(
            (priority_overrides.get(name) or {}).get("context_weight"),
            context_weights.get(name, 0.55),
        )
        priority = as_number((priority_overrides.get(name) or {}).get("priority"), (100.0 - score) * weight)
        contextualized_scores[name] = {
            "score": score,
            "confidence": item.get("confidence"),
            "context_weight": round(weight, 3),
            "priority": round(priority, 1),
            "importance": importance_label(weight),
            "drivers": item.get("drivers") or [],
            "practice": item.get("practice"),
        }

    ranked = sorted(contextualized_scores.items(), key=lambda pair: pair[1]["priority"], reverse=True)
    strengths = sorted(contextualized_scores.items(), key=lambda pair: pair[1]["score"], reverse=True)
    insights["context"] = {
        "type": context_type,
        "confidence": context.get("confidence"),
        "brief": context.get("brief") or interpretation.get("discussion_brief") or interpretation.get("summary"),
        "signals": context.get("signals") or [],
        "why_it_matters": context.get("why_it_matters") or context_note(context_type),
    }
    insights["contextualized_scores"] = contextualized_scores
    insights["primary_focus"] = [
        {
            "variable": name,
            "score": item["score"],
            "priority": item["priority"],
            "importance": item["importance"],
            "practice": item.get("practice"),
        }
        for name, item in ranked[:3]
    ]
    insights["contextual_strengths"] = [
        {
            "variable": name,
            "score": item["score"],
            "importance": item["importance"],
        }
        for name, item in strengths[:3]
    ]
    updated["insights"] = insights
    return updated


def interpret_locally(metrics: dict[str, Any], *, provider_name: str = "mock") -> dict[str, Any]:
    context = infer_context_locally(metrics)
    insights = metrics.get("insights") or {}
    scores = insights.get("scores") or {}
    strengths = sorted(scores.items(), key=lambda item: item[1].get("score", 0), reverse=True)[:2]
    growth = sorted(scores.items(), key=lambda item: item[1].get("score", 0))[:2]
    context_weights = weights_for_context(context["type"])
    weighted_priorities = sorted(
        [
            {
                "variable": name,
                "score": value.get("score"),
                "context_weight": context_weights.get(name, 0.5),
                "priority": round((100 - float(value.get("score", 50))) * context_weights.get(name, 0.5), 1),
            }
            for name, value in scores.items()
        ],
        key=lambda item: item["priority"],
        reverse=True,
    )

    return {
        "version": INTERPRETATION_VERSION,
        "provider": provider_name,
        "model": None,
        "generated_at": utc_now(),
        "context": context,
        "discussion_brief": context.get("brief"),
        "context_weighted_priorities": weighted_priorities[:5],
        "summary": build_local_summary(context, strengths, growth),
        "strengths": [
            {
                "variable": name,
                "score": item.get("score"),
                "reason": first_driver(item, "This was one of the stronger patterns in the conversation."),
            }
            for name, item in strengths
        ],
        "growth_areas": [
            {
                "variable": name,
                "score": item.get("score"),
                "reason": first_driver(item, "This is a useful place to focus next."),
                "practice": item.get("practice"),
            }
            for name, item in growth
        ],
        "action_plan": [
            item.get("practice")
            for _, item in growth
            if item.get("practice")
        ][:3],
        "label_suggestions": suggest_labels(metrics, context),
        "limitations": [
            "Local interpretation uses deterministic scores and simple context heuristics.",
            "Use INTERPRETATION_PROVIDER=openai with OPENAI_API_KEY for transcript-aware context classification and richer narrative analysis.",
        ],
    }


def interpret_with_openai(metrics: dict[str, Any]) -> dict[str, Any]:
    model = os.getenv("OPENAI_INTERPRETATION_MODEL", "gpt-5.4-nano")
    payload = {
        "model": model,
        "store": False,
        "input": [
            {
                "role": "system",
                "content": [
                    {
                        "type": "input_text",
                        "text": (
                            "You are a conversation intelligence analyst. Classify the conversation context, "
                            "write a short plain-language brief of what the conversation is about, "
                            "decide which emotional-intelligence variables matter most in that context, and "
                            "turn raw metrics into specific, actionable coaching. Avoid clinical diagnosis. "
                            "Ground every claim in provided metrics or transcript evidence."
                        ),
                    }
                ],
            },
            {
                "role": "user",
                "content": [{"type": "input_text", "text": json.dumps(compact_metrics_for_llm(metrics), ensure_ascii=False)}],
            },
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "conversation_interpretation",
                "strict": True,
                "schema": interpretation_schema(),
            }
        },
    }
    request = urllib.request.Request(
        "https://api.openai.com/v1/responses",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}",
            "Content-Type": "application/json",
            "User-Agent": "wearable-conversation-analytics/0.1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=float(os.getenv("OPENAI_INTERPRETATION_TIMEOUT", "45"))) as response:
            response_payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI interpretation request failed: {exc.code} {detail[:1200]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"OpenAI interpretation request failed: {exc}") from exc

    parsed = parse_response_json(response_payload)
    parsed = finalize_interpretation(parsed, metrics)
    parsed["version"] = INTERPRETATION_VERSION
    parsed["provider"] = "openai"
    parsed["model"] = model
    parsed["generated_at"] = utc_now()
    return parsed


def interpret_with_groq(metrics: dict[str, Any]) -> dict[str, Any]:
    model = os.getenv("GROQ_INTERPRETATION_MODEL", "openai/gpt-oss-20b")
    prompt = (
        "You are a conversation intelligence analyst. Classify the conversation context, "
        "write a short plain-language brief of what the conversation is about, "
        "decide which emotional-intelligence variables matter most in that context, and "
        "turn raw metrics into specific, actionable coaching. Avoid clinical diagnosis. "
        "Ground every claim in provided metrics or transcript evidence. Return only JSON. "
        f"The context.type must be one of: {', '.join(CONTEXT_TYPES)}. "
        "Always include context.brief and discussion_brief. If the context.type is unknown, "
        "the brief must still describe the concrete topic, such as 'simple conversation asking for directions'."
    )
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": json.dumps(compact_metrics_for_llm(metrics), ensure_ascii=False)},
        ],
        "temperature": 0.2,
        "response_format": {"type": "json_object"},
    }
    request = urllib.request.Request(
        "https://api.groq.com/openai/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {os.environ['GROQ_API_KEY']}",
            "Content-Type": "application/json",
            "User-Agent": "wearable-conversation-analytics/0.1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=float(os.getenv("GROQ_INTERPRETATION_TIMEOUT", "45"))) as response:
            response_payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Groq interpretation request failed: {exc.code} {detail[:1200]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Groq interpretation request failed: {exc}") from exc

    content = (((response_payload.get("choices") or [{}])[0].get("message") or {}).get("content"))
    if not isinstance(content, str):
        raise RuntimeError("Groq response did not contain message content.")
    try:
        parsed = normalize_interpretation(json.loads(content))
    except (json.JSONDecodeError, TypeError, ValueError) as exc:
        raise RuntimeError(f"Groq response was not valid interpretation JSON: {str(exc)[:400]}") from exc
    parsed = finalize_interpretation(parsed, metrics)
    parsed["version"] = INTERPRETATION_VERSION
    parsed["provider"] = "groq"
    parsed["model"] = model
    parsed["generated_at"] = utc_now()
    return parsed


def normalize_interpretation(parsed: dict[str, Any]) -> dict[str, Any]:
    if isinstance(parsed, str):
        parsed = json.loads(parsed)
    if not isinstance(parsed, dict):
        parsed = {"summary": str(parsed)}
    parsed.setdefault(
        "context",
        {
            "type": "unknown",
            "confidence": 0.2,
            "signals": [],
            "why_it_matters": context_note("unknown"),
        },
    )
    context = parsed["context"]
    if isinstance(context, str):
        context = {"type": context}
        parsed["context"] = context
    if not isinstance(context, dict):
        context = {"type": "unknown"}
        parsed["context"] = context
    raw_type = context.get("type", "unknown")
    context["type"] = canonical_context_type(raw_type)
    if raw_type != context["type"] and raw_type:
        context.setdefault("signals", [])
        if isinstance(context["signals"], list):
            context["signals"].insert(0, f"LLM raw context: {raw_type}")
    context.setdefault("confidence", 0.2)
    context.setdefault("signals", [])
    context.setdefault("brief", "")
    context.setdefault("why_it_matters", context_note(context.get("type", "unknown")))
    if not context.get("why_it_matters"):
        context["why_it_matters"] = context_note(context.get("type", "unknown"))
    parsed.setdefault("discussion_brief", context.get("brief") or parsed.get("summary") or "")
    parsed.setdefault("context_weighted_priorities", [])
    parsed.setdefault("summary", "")
    parsed.setdefault("strengths", [])
    parsed.setdefault("growth_areas", [])
    parsed.setdefault("action_plan", [])
    parsed.setdefault("label_suggestions", [])
    parsed.setdefault("limitations", [])
    return parsed


def finalize_interpretation(parsed: dict[str, Any], metrics: dict[str, Any]) -> dict[str, Any]:
    parsed = normalize_interpretation(parsed)
    context = parsed["context"]
    brief = first_nonempty(
        context.get("brief"),
        parsed.get("discussion_brief"),
        parsed.get("conversation_brief"),
        parsed.get("topic_summary"),
        parsed.get("summary"),
        infer_discussion_brief(metrics),
    )
    context["brief"] = brief
    parsed["discussion_brief"] = brief
    if not parsed.get("summary"):
        parsed["summary"] = build_summary_from_brief(parsed, metrics)
    if context.get("type") == "unknown":
        inferred = infer_context_locally(metrics)
        if inferred["type"] != "unknown":
            context["type"] = inferred["type"]
            context["confidence"] = max(as_number(context.get("confidence"), 0.2), inferred["confidence"])
            context["why_it_matters"] = context_note(inferred["type"])
            context["signals"] = list(dict.fromkeys((context.get("signals") or []) + inferred.get("signals", [])))
    return parsed


def importance_label(weight: float) -> str:
    if weight >= 0.9:
        return "central"
    if weight >= 0.75:
        return "high"
    if weight >= 0.6:
        return "moderate"
    return "low"


def as_number(value: Any, default: float) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def first_nonempty(*values: Any) -> str:
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "Brief unavailable from the transcript excerpt."


def build_summary_from_brief(parsed: dict[str, Any], metrics: dict[str, Any]) -> str:
    context = parsed.get("context") or {}
    context_type = human_context_label(context.get("type", "unknown"))
    brief = context.get("brief") or infer_discussion_brief(metrics)
    return f"This appears to be a {context_type}. Topic: {brief}"


def infer_discussion_brief(metrics: dict[str, Any]) -> str:
    text = " ".join((turn.get("text") or "").lower() for turn in metrics.get("transcript") or [])
    if not text:
        return "Audio conversation with limited transcript evidence."

    direction_terms = ["direction", "directions", "where do i", "how do i get", "turn left", "turn right", "go straight", "street", "road", "walk", "drive"]
    if any(term in text for term in direction_terms):
        return "Simple conversation asking for or giving directions."

    service_terms = ["order", "refund", "reservation", "account", "customer", "store", "support"]
    if any(term in text for term in service_terms):
        return "Service-style conversation about a practical request or transaction."

    work_terms = ["project", "deadline", "team", "manager", "client", "roadmap"]
    if any(term in text for term in work_terms):
        return "Work conversation about tasks, plans, or coordination."

    question_count = sum(1 for turn in metrics.get("transcript") or [] if "?" in (turn.get("text") or ""))
    if question_count >= 2:
        return "Conversation centered on questions and information exchange."

    first_turns = [
        (turn.get("text") or "").strip()
        for turn in (metrics.get("transcript") or [])[:3]
        if (turn.get("text") or "").strip()
    ]
    if first_turns:
        excerpt = " ".join(first_turns)
        return truncate_text(f"Conversation beginning with: {excerpt}", 180)
    return "General conversation with limited topic evidence."


def human_context_label(context_type: Any) -> str:
    value = str(context_type or "unknown").replace("_", " ").strip()
    return value if value else "unknown context"


def canonical_context_type(value: Any) -> str:
    text = str(value or "unknown").strip().lower().replace("-", "_").replace(" ", "_")
    if text in CONTEXT_TYPES:
        return text
    compact = text.replace("_", " ")
    aliases = [
        ("interview", ["interview", "hiring", "candidate", "resume"]),
        ("date", ["date", "dating", "romantic", "relationship"]),
        ("service_interaction", ["service", "support", "customer", "worker", "navigation", "instruction", "transaction", "directions", "asking for directions"]),
        ("sales_or_negotiation", ["sales", "negotiation", "deal", "contract", "price"]),
        ("work_meeting", ["meeting", "work", "team", "manager", "project"]),
        ("supportive_personal_conversation", ["supportive", "personal", "emotional support", "comfort"]),
        ("conflict_or_disagreement", ["conflict", "disagreement", "argument", "tense"]),
        ("casual_social", ["casual", "social", "small talk", "friend"]),
    ]
    for context_type, keywords in aliases:
        if any(keyword in compact for keyword in keywords):
            return context_type
    return "unknown"


def compact_metrics_for_llm(metrics: dict[str, Any]) -> dict[str, Any]:
    transcript = metrics.get("transcript") or []
    max_turns = int(os.getenv("LLM_TRANSCRIPT_TURN_LIMIT", "35"))
    max_chars = int(os.getenv("LLM_TRANSCRIPT_TURN_CHARS", "260"))
    compact_turns = [
        {
            "speaker": turn.get("speaker"),
            "start": turn.get("start"),
            "duration": turn.get("duration"),
            "sentiment": turn.get("sentiment"),
            "text": truncate_text(turn.get("text") or "", max_chars),
        }
        for turn in transcript[:max_turns]
    ]
    insights = metrics.get("insights") or {}
    return {
        "summary": metrics.get("summary"),
        "speakers": metrics.get("speakers"),
        "turn_taking": metrics.get("turn_taking"),
        "language": metrics.get("language"),
        "sentiment": compact_sentiment(metrics.get("sentiment") or {}),
        "interjections": compact_interjections(metrics.get("interjections") or {}),
        "audio_quality": metrics.get("audio_quality"),
        "insights": {
            "version": insights.get("version"),
            "speaker_focus": insights.get("speaker_focus"),
            "confidence": insights.get("confidence"),
            "scores": insights.get("scores"),
            "middle_layer": insights.get("middle_layer"),
        },
        "transcript_excerpt": compact_turns,
        "transcript_truncated": len(transcript) > len(compact_turns),
    }


def compact_sentiment(sentiment: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in sentiment.items() if key != "series"}


def compact_interjections(interjections: dict[str, Any]) -> dict[str, Any]:
    compact = dict(interjections)
    events = compact.get("events") or []
    compact["events"] = events[:10]
    return compact


def truncate_text(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 3)].rstrip() + "..."


def interpretation_schema() -> dict[str, Any]:
    score_item = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "variable": {"type": "string"},
            "score": {"type": ["number", "null"]},
            "context_weight": {"type": "number"},
            "priority": {"type": "number"},
            "reason": {"type": "string"},
        },
        "required": ["variable", "score", "context_weight", "priority", "reason"],
    }
    return {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "context": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "type": {"type": "string", "enum": CONTEXT_TYPES},
                    "confidence": {"type": "number"},
                    "brief": {"type": "string"},
                    "signals": {"type": "array", "items": {"type": "string"}},
                    "why_it_matters": {"type": "string"},
                },
                "required": ["type", "confidence", "brief", "signals", "why_it_matters"],
            },
            "discussion_brief": {"type": "string"},
            "context_weighted_priorities": {"type": "array", "items": score_item},
            "summary": {"type": "string"},
            "strengths": {"type": "array", "items": score_item},
            "growth_areas": {"type": "array", "items": score_item},
            "action_plan": {"type": "array", "items": {"type": "string"}},
            "label_suggestions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "scope": {"type": "string"},
                        "target": {"type": "string"},
                        "value": {"type": ["number", "string", "boolean"]},
                        "confidence": {"type": "number"},
                        "rationale": {"type": "string"},
                    },
                    "required": ["scope", "target", "value", "confidence", "rationale"],
                },
            },
            "limitations": {"type": "array", "items": {"type": "string"}},
        },
        "required": [
            "context",
            "discussion_brief",
            "context_weighted_priorities",
            "summary",
            "strengths",
            "growth_areas",
            "action_plan",
            "label_suggestions",
            "limitations",
        ],
    }


def parse_response_json(payload: dict[str, Any]) -> dict[str, Any]:
    if isinstance(payload.get("output_text"), str):
        return json.loads(payload["output_text"])
    for item in payload.get("output", []):
        for content in item.get("content", []):
            text = content.get("text")
            if isinstance(text, str):
                return json.loads(text)
    raise RuntimeError("OpenAI response did not contain parseable JSON output.")


def infer_context_locally(metrics: dict[str, Any]) -> dict[str, Any]:
    text = " ".join((turn.get("text") or "").lower() for turn in metrics.get("transcript") or [])
    language = metrics.get("language") or {}
    sentiment = metrics.get("sentiment") or {}
    signals = []
    context_type = "unknown"

    keyword_contexts = [
        ("interview", ["interview", "resume", "candidate", "position", "salary", "hiring"]),
        ("date", ["date", "dating", "relationship", "chemistry", "dinner", "text me"]),
        (
            "service_interaction",
            [
                "order",
                "refund",
                "reservation",
                "account",
                "customer",
                "store",
                "support",
                "directions",
                "direction",
                "how do i get",
                "where do i",
                "turn left",
                "turn right",
                "go straight",
            ],
        ),
        ("sales_or_negotiation", ["price", "contract", "deal", "discount", "proposal", "budget"]),
        ("work_meeting", ["project", "deadline", "team", "manager", "client", "roadmap"]),
    ]
    for candidate, keywords in keyword_contexts:
        matches = [keyword for keyword in keywords if keyword in text]
        if matches:
            context_type = candidate
            signals.extend(matches[:3])
            break

    if context_type == "unknown" and sentiment.get("minimum", 0) < -0.45:
        context_type = "conflict_or_disagreement"
        signals.append("negative sentiment trough")
    if context_type == "unknown" and language.get("validation_phrase_count", 0) >= 2:
        context_type = "supportive_personal_conversation"
        signals.append("validation language")
    if context_type == "unknown":
        context_type = "casual_social" if metrics.get("summary", {}).get("total_words", 0) > 80 else "unknown"
        signals.append("limited context evidence")

    return {
        "type": context_type,
        "confidence": 0.55 if signals and context_type != "unknown" else 0.3,
        "brief": infer_discussion_brief(metrics),
        "signals": signals[:5],
        "why_it_matters": context_note(context_type),
    }


def weights_for_context(context_type: str) -> dict[str, float]:
    base = {
        "warmth": 0.75,
        "curiosity": 0.7,
        "conversational_balance": 0.75,
        "respectful_disagreeability": 0.65,
        "emotional_regulation": 0.75,
        "clarity": 0.7,
        "conversational_generosity": 0.7,
    }
    overrides = {
        "interview": {"clarity": 0.95, "curiosity": 0.85, "warmth": 0.65},
        "date": {"warmth": 0.95, "curiosity": 0.95, "conversational_generosity": 0.9},
        "service_interaction": {"clarity": 0.95, "emotional_regulation": 0.9, "warmth": 0.75},
        "sales_or_negotiation": {"clarity": 0.9, "respectful_disagreeability": 0.9, "conversational_balance": 0.8},
        "work_meeting": {"clarity": 0.85, "conversational_balance": 0.85, "respectful_disagreeability": 0.75},
        "supportive_personal_conversation": {"warmth": 1.0, "curiosity": 0.9, "conversational_generosity": 0.95},
        "conflict_or_disagreement": {"respectful_disagreeability": 1.0, "emotional_regulation": 1.0, "warmth": 0.8},
    }
    updated = dict(base)
    updated.update(overrides.get(context_type, {}))
    return updated


def suggest_labels(metrics: dict[str, Any], context: dict[str, Any]) -> list[dict[str, Any]]:
    scores = (metrics.get("insights") or {}).get("scores") or {}
    labels = [
        {
            "scope": "conversation",
            "target": "context_type",
            "value": context["type"],
            "confidence": context["confidence"],
            "rationale": ", ".join(context.get("signals") or ["context heuristic"]),
        }
    ]
    for name, item in scores.items():
        labels.append(
            {
                "scope": "conversation",
                "target": name,
                "value": item.get("score"),
                "confidence": item.get("confidence", 0.5),
                "rationale": "; ".join((item.get("drivers") or [])[:2]),
            }
        )
    return labels


def build_local_summary(context: dict[str, Any], strengths: list[tuple[str, Any]], growth: list[tuple[str, Any]]) -> str:
    strongest = strengths[0][0].replace("_", " ") if strengths else "one strength"
    focus = growth[0][0].replace("_", " ") if growth else "one growth area"
    return (
        f"This looks most like a {context['type'].replace('_', ' ')}. "
        f"The strongest current signal is {strongest}; the most useful next coaching focus is {focus}."
    )


def context_note(context_type: str) -> str:
    notes = {
        "interview": "Clarity, confidence, curiosity, and concise warmth matter more than equal talk time.",
        "date": "Warmth, curiosity, and conversational generosity carry extra weight.",
        "service_interaction": "Clarity, emotional regulation, and respectful efficiency are central.",
        "sales_or_negotiation": "Assertive clarity and respectful disagreement matter more than pure warmth.",
        "work_meeting": "Balance, clarity, and disagreement style affect collaboration quality.",
        "supportive_personal_conversation": "Validation, warmth, and follow-up depth matter most.",
        "conflict_or_disagreement": "Regulation, repair, and respectful disagreeability become highest priority.",
        "casual_social": "Warmth, curiosity, and balance are useful general-purpose signals.",
        "unknown": "Variable weighting is provisional because context evidence is weak.",
    }
    return notes.get(context_type, notes["unknown"])


def first_driver(item: dict[str, Any], fallback: str) -> str:
    drivers = item.get("drivers") or []
    return drivers[0] if drivers else fallback


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
