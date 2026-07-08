from __future__ import annotations

import unittest

from app.insights import compute_insights, flatten_metrics
from app.llm_interpreter import apply_contextualization, finalize_interpretation, infer_context_locally


def sample_metrics(**overrides):
    metrics = {
        "metadata": {
            "duration_seconds": 240,
            "diarization": {"enabled": True, "speaker_count": 2},
        },
        "summary": {
            "duration_seconds": 240,
            "speaker_count": 2,
            "total_words": 640,
            "conversation_wpm": 160,
            "total_turns": 42,
            "silence_percent": 9,
            "user_speaker_assumption": "Speaker 1",
        },
        "speakers": {
            "Speaker 1": {
                "talk_time_percent": 52,
                "word_count": 330,
                "words_per_minute": 155,
                "sentiment_average": 0.22,
            },
            "Speaker 2": {
                "talk_time_percent": 48,
                "word_count": 310,
                "words_per_minute": 150,
                "sentiment_average": 0.18,
            },
        },
        "turn_taking": {
            "turn_count": 42,
            "average_turn_seconds": 4.6,
            "longest_turn_seconds": 19,
            "monologues_over_45s": 0,
            "average_response_latency_seconds": 1.1,
            "fast_responses_under_300ms": 1,
            "slow_responses_over_2s": 2,
        },
        "interjections": {"estimated_count": 1},
        "silence_and_pauses": {"long_pauses_over_2s": 2},
        "language": {
            "fillers_per_minute": 0.8,
            "questions_per_minute": 0.7,
            "question_count": 8,
            "follow_up_question_estimate": 4,
            "backchannels_per_minute": 0.7,
            "validation_phrase_count": 4,
            "advice_phrase_count": 1,
            "lexical_diversity_type_token_ratio": 0.42,
            "average_sentence_words": 15,
        },
        "sentiment": {
            "average": 0.2,
            "minimum": -0.08,
            "ending_average_last_3_turns": 0.26,
            "largest_shift": 0.22,
        },
        "audio_quality": {
            "dynamic_range_db": 14,
            "pitch_variability_hz": 36,
            "audio_quality_confidence": "high",
        },
    }
    for section, values in overrides.items():
        if isinstance(values, dict) and isinstance(metrics.get(section), dict):
            metrics[section].update(values)
        else:
            metrics[section] = values
    return metrics


class InsightScoringTest(unittest.TestCase):
    def test_flatten_metrics_selects_focus_speaker_features(self) -> None:
        features = flatten_metrics(sample_metrics())

        self.assertEqual(features["speaker_focus"], "Speaker 1")
        self.assertAlmostEqual(features["talk_time_percent_focus"], 52)
        self.assertAlmostEqual(features["word_share_focus"], 51.5625)
        self.assertEqual(features["diarization_enabled"], 1.0)

    def test_warm_balanced_conversation_scores_above_reactive_one(self) -> None:
        warm = compute_insights(sample_metrics())
        reactive = compute_insights(
            sample_metrics(
                speakers={
                    "Speaker 1": {
                        "talk_time_percent": 82,
                        "word_count": 520,
                        "words_per_minute": 225,
                        "sentiment_average": -0.22,
                    },
                    "Speaker 2": {
                        "talk_time_percent": 18,
                        "word_count": 120,
                        "words_per_minute": 120,
                        "sentiment_average": -0.05,
                    },
                },
                turn_taking={
                    "turn_count": 28,
                    "average_turn_seconds": 8.8,
                    "longest_turn_seconds": 92,
                    "monologues_over_45s": 2,
                    "average_response_latency_seconds": 0.22,
                    "fast_responses_under_300ms": 8,
                    "slow_responses_over_2s": 0,
                },
                interjections={"estimated_count": 7},
                language={
                    "fillers_per_minute": 3.4,
                    "questions_per_minute": 0.12,
                    "question_count": 1,
                    "follow_up_question_estimate": 0,
                    "backchannels_per_minute": 0.05,
                    "validation_phrase_count": 0,
                    "advice_phrase_count": 5,
                    "lexical_diversity_type_token_ratio": 0.34,
                    "average_sentence_words": 31,
                },
                sentiment={
                    "average": -0.2,
                    "minimum": -0.74,
                    "ending_average_last_3_turns": -0.42,
                    "largest_shift": 0.82,
                },
            )
        )

        self.assertGreater(warm["scores"]["warmth"]["score"], reactive["scores"]["warmth"]["score"])
        self.assertGreater(
            warm["scores"]["conversational_balance"]["score"],
            reactive["scores"]["conversational_balance"]["score"],
        )
        self.assertGreater(
            warm["scores"]["emotional_regulation"]["score"],
            reactive["scores"]["emotional_regulation"]["score"],
        )
        self.assertGreaterEqual(warm["confidence"], 0.7)

    def test_contextualization_changes_variable_significance_without_changing_raw_scores(self) -> None:
        metrics = sample_metrics()
        metrics["insights"] = compute_insights(metrics)

        result = apply_contextualization(
            metrics,
            {
                "context": {
                    "type": "romantic date conversation",
                    "confidence": 0.82,
                    "why_it_matters": "Warmth and curiosity carry extra weight.",
                },
                "context_weighted_priorities": [],
            },
        )

        original_warmth = metrics["insights"]["scores"]["warmth"]["score"]
        contextual_warmth = result["insights"]["contextualized_scores"]["warmth"]

        self.assertEqual(contextual_warmth["score"], original_warmth)
        self.assertEqual(contextual_warmth["context_weight"], 0.95)
        self.assertEqual(result["insights"]["context"]["type"], "date")
        self.assertGreater(len(result["insights"]["primary_focus"]), 0)

    def test_direction_conversation_gets_brief_even_when_llm_context_is_unknown(self) -> None:
        metrics = sample_metrics(
            transcript=[
                {"speaker": "Speaker 1", "text": "Excuse me, how do I get to the station?"},
                {"speaker": "Speaker 2", "text": "Go straight two blocks and turn left on Pine Street."},
            ],
        )

        local_context = infer_context_locally(metrics)
        finalized = finalize_interpretation(
            {
                "context": {"type": "unknown", "confidence": 0.2, "signals": [], "why_it_matters": ""},
                "summary": "",
            },
            metrics,
        )

        self.assertEqual(local_context["type"], "service_interaction")
        self.assertIn("directions", finalized["context"]["brief"])
        self.assertEqual(finalized["context"]["type"], "service_interaction")


if __name__ == "__main__":
    unittest.main()
