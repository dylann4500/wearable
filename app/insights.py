from __future__ import annotations

from statistics import mean
from typing import Any


INSIGHT_VERSION = "conversation-intelligence-v1"


def compute_insights(metrics: dict[str, Any]) -> dict[str, Any]:
    """Derive explainable conversation intelligence scores from raw metrics.

    Scores are 0-100 where higher is healthier for the user-facing coaching
    dimension. This is intentionally deterministic and transparent; model-based
    scoring can replace or calibrate these scores once labeled data exists.
    """
    features = flatten_metrics(metrics)
    middle = score_middle_layer(features)
    top = score_top_layer(middle, features)
    confidence = insight_confidence(features)

    scores = {}
    for name, value in top.items():
        scores[name] = {
            "score": round(value, 1),
            "confidence": round(confidence * confidence_modifier(name, features), 2),
            "drivers": drivers_for_score(name, features, middle),
            "practice": practice_for_score(name, value),
        }

    return {
        "version": INSIGHT_VERSION,
        "speaker_focus": features["speaker_focus"],
        "confidence": round(confidence, 2),
        "scores": scores,
        "middle_layer": {
            name: {"score": round(value, 1), "confidence": round(confidence, 2)}
            for name, value in middle.items()
        },
        "raw_feature_snapshot": {key: round(value, 4) if isinstance(value, float) else value for key, value in features.items()},
        "notes": [
            "Deterministic v1 scores are best used as explainable coaching hypotheses, not clinical or psychological labels.",
            "Confidence depends on duration, turn count, diarization quality, and audio-quality availability.",
        ],
    }


def flatten_metrics(metrics: dict[str, Any]) -> dict[str, Any]:
    summary = metrics.get("summary") or {}
    speakers = metrics.get("speakers") or {}
    turn_taking = metrics.get("turn_taking") or {}
    language = metrics.get("language") or {}
    pauses = metrics.get("silence_and_pauses") or {}
    sentiment = metrics.get("sentiment") or {}
    audio_quality = metrics.get("audio_quality") or {}
    interjections = metrics.get("interjections") or {}
    metadata = metrics.get("metadata") or {}
    diarization = metadata.get("diarization") or {}

    speaker_focus = summary.get("user_speaker_assumption") or next(iter(speakers), "Speaker 1")
    focus = speakers.get(speaker_focus) or {}
    total_words = as_float(summary.get("total_words"))
    focus_words = as_float(focus.get("word_count"))

    return {
        "speaker_focus": speaker_focus,
        "duration_seconds": as_float(summary.get("duration_seconds") or metadata.get("duration_seconds")),
        "speaker_count": as_float(summary.get("speaker_count"), 1.0),
        "total_words": total_words,
        "conversation_wpm": as_float(summary.get("conversation_wpm")),
        "silence_percent": as_float(summary.get("silence_percent")),
        "turn_count": as_float(turn_taking.get("turn_count") or summary.get("total_turns")),
        "average_turn_seconds": as_float(turn_taking.get("average_turn_seconds")),
        "longest_turn_seconds": as_float(turn_taking.get("longest_turn_seconds")),
        "monologues_over_45s": as_float(turn_taking.get("monologues_over_45s")),
        "average_response_latency_seconds": as_float(turn_taking.get("average_response_latency_seconds")),
        "fast_responses_under_300ms": as_float(turn_taking.get("fast_responses_under_300ms")),
        "slow_responses_over_2s": as_float(turn_taking.get("slow_responses_over_2s")),
        "estimated_interjections": as_float(interjections.get("estimated_count")),
        "long_pauses_over_2s": as_float(pauses.get("long_pauses_over_2s")),
        "fillers_per_minute": as_float(language.get("fillers_per_minute")),
        "questions_per_minute": as_float(language.get("questions_per_minute")),
        "question_count": as_float(language.get("question_count")),
        "follow_up_question_estimate": as_float(language.get("follow_up_question_estimate")),
        "backchannels_per_minute": as_float(language.get("backchannels_per_minute")),
        "validation_phrase_count": as_float(language.get("validation_phrase_count")),
        "advice_phrase_count": as_float(language.get("advice_phrase_count")),
        "lexical_diversity_type_token_ratio": as_float(language.get("lexical_diversity_type_token_ratio")),
        "average_sentence_words": as_float(language.get("average_sentence_words")),
        "sentiment_average": as_float(sentiment.get("average")),
        "sentiment_minimum": as_float(sentiment.get("minimum")),
        "sentiment_ending_average": as_float(sentiment.get("ending_average_last_3_turns")),
        "largest_sentiment_shift": as_float(sentiment.get("largest_shift")),
        "talk_time_percent_focus": as_float(focus.get("talk_time_percent")),
        "word_share_focus": percent_or_zero(focus_words, total_words),
        "wpm_focus": as_float(focus.get("words_per_minute")),
        "sentiment_focus": as_float(focus.get("sentiment_average")),
        "volume_dynamic_range_db": as_float(audio_quality.get("dynamic_range_db")),
        "pitch_variability_hz": as_float(audio_quality.get("pitch_variability_hz")),
        "audio_quality_confidence": confidence_value(audio_quality.get("audio_quality_confidence")),
        "diarization_enabled": 1.0 if diarization.get("enabled") else 0.0,
        "diarization_speaker_count": as_float(diarization.get("speaker_count"), as_float(summary.get("speaker_count"), 1.0)),
    }


def score_middle_layer(features: dict[str, Any]) -> dict[str, float]:
    speaker_count = max(features["speaker_count"], 1.0)
    target_share = 100.0 / speaker_count
    share_gap = abs(features["talk_time_percent_focus"] - target_share)
    word_share_gap = abs(features["word_share_focus"] - target_share)

    conversational_balance = weighted_mean(
        [
            score_low_is_good(share_gap, good=8, bad=32),
            score_low_is_good(word_share_gap, good=10, bad=35),
            score_low_is_good(features["monologues_over_45s"], good=0, bad=3),
        ],
        [0.45, 0.35, 0.2],
    )
    floor_dominance_control = weighted_mean(
        [
            score_low_is_good(features["longest_turn_seconds"], good=18, bad=75),
            score_low_is_good(features["monologues_over_45s"], good=0, bad=3),
            score_low_is_good(max(0.0, features["talk_time_percent_focus"] - target_share), good=8, bad=35),
        ],
        [0.3, 0.35, 0.35],
    )
    turn_exchange_smoothness = weighted_mean(
        [
            score_range(features["average_response_latency_seconds"], low=0.35, ideal_low=0.7, ideal_high=1.6, high=3.5),
            score_low_is_good(features["fast_responses_under_300ms"], good=0, bad=max(3, features["turn_count"] * 0.15)),
            score_low_is_good(features["estimated_interjections"], good=0, bad=max(3, features["turn_count"] * 0.12)),
            score_low_is_good(features["slow_responses_over_2s"], good=0, bad=max(4, features["turn_count"] * 0.2)),
        ],
        [0.3, 0.25, 0.25, 0.2],
    )
    curiosity = weighted_mean(
        [
            score_range(features["questions_per_minute"], low=0.05, ideal_low=0.35, ideal_high=1.2, high=2.6),
            score_high_is_good(ratio(features["follow_up_question_estimate"], features["question_count"]), good=0.35, poor=0.0),
        ],
        [0.55, 0.45],
    )
    active_listening = weighted_mean(
        [
            score_range(features["backchannels_per_minute"], low=0.05, ideal_low=0.25, ideal_high=1.4, high=3.0),
            score_high_is_good(features["validation_phrase_count"], good=3, poor=0),
            score_high_is_good(ratio(features["follow_up_question_estimate"], features["question_count"]), good=0.35, poor=0.0),
        ],
        [0.35, 0.35, 0.3],
    )
    validation = score_high_is_good(features["validation_phrase_count"], good=4, poor=0)
    premature_advice_control = weighted_mean(
        [
            score_low_is_good(max(0.0, features["advice_phrase_count"] - features["validation_phrase_count"]), good=0, bad=4),
            score_high_is_good(ratio(features["validation_phrase_count"], features["advice_phrase_count"]), good=1.0, poor=0.0),
        ],
        [0.55, 0.45],
    )
    emotional_stability = weighted_mean(
        [
            score_high_is_good(features["sentiment_average"], good=0.25, poor=-0.35),
            score_low_is_good(features["largest_sentiment_shift"], good=0.25, bad=1.0),
            score_high_is_good(features["sentiment_ending_average"], good=0.2, poor=-0.35),
        ],
        [0.35, 0.35, 0.3],
    )
    reactivity_control = weighted_mean(
        [
            score_low_is_good(features["fast_responses_under_300ms"], good=0, bad=max(3, features["turn_count"] * 0.15)),
            score_low_is_good(features["estimated_interjections"], good=0, bad=max(3, features["turn_count"] * 0.12)),
            score_low_is_good(max(0.0, -features["sentiment_minimum"]), good=0.05, bad=0.7),
        ],
        [0.35, 0.35, 0.3],
    )
    clarity = weighted_mean(
        [
            score_low_is_good(features["fillers_per_minute"], good=0.4, bad=4.0),
            score_range(features["wpm_focus"] or features["conversation_wpm"], low=80, ideal_low=105, ideal_high=170, high=230),
            score_range(features["average_sentence_words"], low=5, ideal_low=9, ideal_high=22, high=38),
        ],
        [0.35, 0.35, 0.3],
    )
    expressiveness = weighted_mean(
        [
            score_range(features["pitch_variability_hz"], low=5, ideal_low=18, ideal_high=65, high=130),
            score_range(features["volume_dynamic_range_db"], low=2, ideal_low=7, ideal_high=24, high=45),
        ],
        [0.55, 0.45],
    )

    return {
        "conversational_balance": conversational_balance,
        "floor_dominance_control": floor_dominance_control,
        "turn_exchange_smoothness": turn_exchange_smoothness,
        "curiosity": curiosity,
        "active_listening": active_listening,
        "validation": validation,
        "premature_advice_control": premature_advice_control,
        "emotional_stability": emotional_stability,
        "reactivity_control": reactivity_control,
        "clarity": clarity,
        "expressiveness": expressiveness,
    }


def score_top_layer(middle: dict[str, float], features: dict[str, Any]) -> dict[str, float]:
    return {
        "warmth": weighted_mean(
            [middle["active_listening"], middle["validation"], middle["emotional_stability"], sentiment_score(features)],
            [0.32, 0.28, 0.24, 0.16],
        ),
        "curiosity": weighted_mean(
            [middle["curiosity"], middle["active_listening"], middle["turn_exchange_smoothness"]],
            [0.58, 0.27, 0.15],
        ),
        "conversational_balance": weighted_mean(
            [middle["conversational_balance"], middle["floor_dominance_control"], middle["turn_exchange_smoothness"]],
            [0.45, 0.35, 0.2],
        ),
        "respectful_disagreeability": weighted_mean(
            [
                middle["reactivity_control"],
                middle["premature_advice_control"],
                middle["validation"],
                middle["emotional_stability"],
            ],
            [0.32, 0.26, 0.22, 0.2],
        ),
        "emotional_regulation": weighted_mean(
            [middle["emotional_stability"], middle["reactivity_control"], middle["turn_exchange_smoothness"]],
            [0.45, 0.35, 0.2],
        ),
        "clarity": weighted_mean([middle["clarity"], middle["turn_exchange_smoothness"]], [0.75, 0.25]),
        "conversational_generosity": weighted_mean(
            [middle["conversational_balance"], middle["active_listening"], middle["curiosity"]],
            [0.34, 0.36, 0.3],
        ),
    }


def insight_confidence(features: dict[str, Any]) -> float:
    duration = score_high_is_good(features["duration_seconds"], good=300, poor=30) / 100
    turns = score_high_is_good(features["turn_count"], good=30, poor=4) / 100
    diarization = 0.9 if features["diarization_enabled"] else 0.55
    audio = features["audio_quality_confidence"]
    words = score_high_is_good(features["total_words"], good=700, poor=60) / 100
    return clamp(weighted_mean([duration, turns, diarization, audio, words], [0.25, 0.25, 0.2, 0.15, 0.15]), 0.15, 0.95)


def confidence_modifier(name: str, features: dict[str, Any]) -> float:
    if name == "respectful_disagreeability":
        return 0.82
    if name in {"warmth", "curiosity"} and features["total_words"] < 120:
        return 0.88
    return 1.0


def drivers_for_score(name: str, features: dict[str, Any], middle: dict[str, float]) -> list[str]:
    candidates = {
        "warmth": [
            driver("Validation language was frequent", "Validation language was limited", middle["validation"]),
            driver("Active listening signals were strong", "Few active listening signals were detected", middle["active_listening"]),
            driver("Emotional tone stayed steady", "Emotional tone shifted sharply", middle["emotional_stability"]),
        ],
        "curiosity": [
            driver("Questions invited elaboration", "Question rate was low or uneven", middle["curiosity"]),
            driver("Follow-up questions appeared after partner turns", "Follow-up depth looked limited", score_high_is_good(ratio(features["follow_up_question_estimate"], features["question_count"]), 0.35, 0.0)),
            driver("Backchannels supported engagement", "Backchannel signals were sparse", middle["active_listening"]),
        ],
        "conversational_balance": [
            driver("Talk time was balanced", "Talk time or word share was lopsided", middle["conversational_balance"]),
            driver("Long turns stayed contained", "Long turns or monologues pulled the floor", middle["floor_dominance_control"]),
            driver("Turn transitions were smooth", "Turn transitions showed interruption or drag", middle["turn_exchange_smoothness"]),
        ],
        "respectful_disagreeability": [
            driver("Reactive replies were limited", "Fast interjections suggest reactive replies", middle["reactivity_control"]),
            driver("Advice followed enough validation", "Advice may be arriving before validation", middle["premature_advice_control"]),
            driver("Tone stayed regulated during shifts", "Negative or sharp sentiment shifts appeared", middle["emotional_stability"]),
        ],
        "emotional_regulation": [
            driver("Sentiment recovered or stayed stable", "Sentiment became volatile or ended low", middle["emotional_stability"]),
            driver("Interruptive responses were controlled", "Fast responses/interjections raised reactivity", middle["reactivity_control"]),
            driver("Pauses and response latency looked conversational", "Response timing was uneven", middle["turn_exchange_smoothness"]),
        ],
        "clarity": [
            driver("Pace and sentence length were in a clear range", "Pace, fillers, or sentence length may reduce clarity", middle["clarity"]),
            driver("Turn exchanges stayed orderly", "Turn exchange friction may reduce clarity", middle["turn_exchange_smoothness"]),
        ],
        "conversational_generosity": [
            driver("The floor was shared", "The floor was not shared evenly", middle["conversational_balance"]),
            driver("Listening signals were present", "Listening signals were limited", middle["active_listening"]),
            driver("Curiosity helped draw the partner out", "Curiosity signals were limited", middle["curiosity"]),
        ],
    }
    return [item for item in candidates.get(name, []) if item][:3]


def practice_for_score(name: str, score: float) -> str:
    if name == "warmth":
        return "Reflect the other person's feeling once before moving into explanation or advice."
    if name == "curiosity":
        return "Ask one short follow-up question that uses a word or detail the other person just said."
    if name == "conversational_balance":
        return "After a long turn, pause and invite the other person to add or correct something."
    if name == "respectful_disagreeability":
        return "State the disagreement clearly, then name the part of their view that makes sense."
    if name == "emotional_regulation":
        return "When tension rises, wait one beat and respond to the feeling before the facts."
    if name == "clarity":
        return "Use one sentence for the point, then one sentence for the reason."
    if score < 55:
        return "Pick one moment to slow down and make room for the other person's perspective."
    return "Keep the same pattern and look for one timestamp where it worked especially well."


def sentiment_score(features: dict[str, Any]) -> float:
    return weighted_mean(
        [
            score_high_is_good(features["sentiment_average"], good=0.25, poor=-0.35),
            score_high_is_good(features["sentiment_focus"], good=0.25, poor=-0.35),
            score_high_is_good(features["sentiment_ending_average"], good=0.2, poor=-0.35),
        ],
        [0.34, 0.33, 0.33],
    )


def driver(high_text: str, low_text: str, score: float) -> str:
    return high_text if score >= 65 else low_text


def score_low_is_good(value: float, *, good: float, bad: float) -> float:
    if bad <= good:
        return 50.0
    return clamp(100.0 - ((value - good) / (bad - good) * 100.0), 0.0, 100.0)


def score_high_is_good(value: float, good: float, poor: float) -> float:
    if good <= poor:
        return 50.0
    return clamp((value - poor) / (good - poor) * 100.0, 0.0, 100.0)


def score_range(value: float, *, low: float, ideal_low: float, ideal_high: float, high: float) -> float:
    if ideal_low <= value <= ideal_high:
        return 100.0
    if value < ideal_low:
        return score_high_is_good(value, good=ideal_low, poor=low)
    return score_low_is_good(value, good=ideal_high, bad=high)


def weighted_mean(values: list[float], weights: list[float]) -> float:
    clean = [(value, weight) for value, weight in zip(values, weights) if value is not None]
    if not clean:
        return 0.0
    total_weight = sum(weight for _, weight in clean)
    if total_weight <= 0:
        return mean(value for value, _ in clean)
    return clamp(sum(value * weight for value, weight in clean) / total_weight, 0.0, 100.0)


def ratio(numerator: float, denominator: float) -> float:
    if denominator <= 0:
        return 0.0
    return numerator / denominator


def percent_or_zero(value: float, total: float) -> float:
    if total <= 0:
        return 0.0
    return value / total * 100.0


def confidence_value(value: Any) -> float:
    if value == "high":
        return 0.9
    if value == "medium":
        return 0.65
    if value == "low":
        return 0.35
    if isinstance(value, (int, float)):
        return clamp(float(value), 0.0, 1.0)
    return 0.35


def as_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))

