#!/usr/bin/env python
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from statistics import mean
from typing import Any

import numpy as np
from sklearn.base import clone
from sklearn.cluster import KMeans
from sklearn.cross_decomposition import PLSRegression
from sklearn.ensemble import ExtraTreesRegressor, HistGradientBoostingRegressor, RandomForestRegressor
from sklearn.linear_model import ElasticNet, Ridge
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score, silhouette_score
from sklearn.model_selection import train_test_split
from sklearn.multioutput import MultiOutputRegressor
from sklearn.neighbors import KNeighborsRegressor
from sklearn.neural_network import MLPRegressor
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVR

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.insights import compute_insights, flatten_metrics


TARGETS = [
    "warmth",
    "curiosity",
    "conversational_balance",
    "respectful_disagreeability",
    "emotional_regulation",
    "clarity",
    "conversational_generosity",
]

FEATURE_EXCLUDE = {"speaker_focus", "audio_quality_confidence", "diarization_enabled", "diarization_speaker_count"}


def main() -> None:
    parser = argparse.ArgumentParser(description="Survey lightweight conversation-intelligence modeling approaches.")
    parser.add_argument("--samples", type=int, default=1200, help="Synthetic conversations to generate.")
    parser.add_argument("--seed", type=int, default=7, help="Random seed.")
    parser.add_argument("--out", type=Path, default=Path("docs/CONVERSATION_INTELLIGENCE_EXPERIMENT_RESULTS.md"))
    parser.add_argument("--json-out", type=Path, default=Path("analysis_runs/conversation_intelligence_survey.json"))
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)
    records = [generate_conversation(rng) for _ in range(args.samples)]
    feature_names = numeric_feature_names(records)
    x = np.array([[record["features"][name] for name in feature_names] for record in records], dtype=float)
    y = np.array([[record["labels"][target] for target in TARGETS] for record in records], dtype=float)
    deterministic = np.array(
        [[record["deterministic_scores"][target] for target in TARGETS] for record in records],
        dtype=float,
    )

    indices = np.arange(len(records))
    train_idx, test_idx = train_test_split(indices, test_size=0.25, random_state=args.seed)
    x_train, x_test = x[train_idx], x[test_idx]
    y_train, y_test = y[train_idx], y[test_idx]

    results = []
    results.append(evaluate_predictions("Deterministic scoring rules", y_test, deterministic[test_idx]))
    results.append(evaluate_predictions("Mean training baseline", y_test, np.repeat(y_train.mean(axis=0, keepdims=True), len(y_test), axis=0)))

    model_specs = [
        ("Ridge regression", make_pipeline(StandardScaler(), Ridge(alpha=12.0))),
        ("ElasticNet regression", make_pipeline(StandardScaler(), MultiOutputRegressor(ElasticNet(alpha=0.035, l1_ratio=0.25, max_iter=5000)))),
        ("Partial least squares", make_pipeline(StandardScaler(), PLSRegression(n_components=6))),
        ("k-nearest neighbors", make_pipeline(StandardScaler(), KNeighborsRegressor(n_neighbors=18, weights="distance"))),
        ("Random forest", RandomForestRegressor(n_estimators=120, min_samples_leaf=7, random_state=args.seed, n_jobs=-1)),
        ("Extra trees", ExtraTreesRegressor(n_estimators=160, min_samples_leaf=5, random_state=args.seed, n_jobs=-1)),
        (
            "Histogram gradient boosting",
            MultiOutputRegressor(
                HistGradientBoostingRegressor(max_iter=120, learning_rate=0.055, l2_regularization=0.08, random_state=args.seed)
            ),
        ),
        ("RBF support vector regression", make_pipeline(StandardScaler(), MultiOutputRegressor(SVR(C=18.0, epsilon=2.0, gamma="scale")))),
        (
            "Small MLP regressor",
            make_pipeline(
                StandardScaler(),
                MLPRegressor(
                    hidden_layer_sizes=(48, 24),
                    alpha=0.015,
                    learning_rate_init=0.004,
                    max_iter=700,
                    random_state=args.seed,
                    early_stopping=True,
                ),
            ),
        ),
    ]

    fitted_models = {}
    for name, model in model_specs:
        model_instance = clone(model)
        model_instance.fit(x_train, y_train)
        fitted_models[name] = model_instance
        predictions = np.clip(model_instance.predict(x_test), 0, 100)
        results.append(evaluate_predictions(name, y_test, predictions))

    cluster_result = cluster_profiles(x, y, args.seed)
    feature_importance = top_feature_importance(fitted_models.get("Extra trees"), feature_names)
    report = build_report(
        sample_count=args.samples,
        seed=args.seed,
        feature_names=feature_names,
        results=results,
        cluster_result=cluster_result,
        feature_importance=feature_importance,
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report, encoding="utf-8")
    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.write_text(
        json.dumps(
            {
                "samples": args.samples,
                "seed": args.seed,
                "targets": TARGETS,
                "features": feature_names,
                "results": results,
                "cluster_result": cluster_result,
                "feature_importance": feature_importance,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    best = min(results[2:], key=lambda item: item["mae"])
    print(f"Wrote {args.out}")
    print(f"Wrote {args.json_out}")
    print(f"Best supervised model: {best['approach']} MAE={best['mae']:.2f}, R2={best['r2']:.3f}")


def generate_conversation(rng: np.random.Generator) -> dict[str, Any]:
    latent = {
        "warmth": beta_score(rng, 5.5, 2.6),
        "curiosity": beta_score(rng, 4.8, 3.0),
        "conversational_balance": beta_score(rng, 5.0, 2.7),
        "respectful_disagreeability": beta_score(rng, 4.7, 3.2),
        "emotional_regulation": beta_score(rng, 5.0, 2.8),
        "clarity": beta_score(rng, 5.2, 2.7),
    }
    latent["conversational_generosity"] = clip(
        0.38 * latent["warmth"]
        + 0.28 * latent["curiosity"]
        + 0.24 * latent["conversational_balance"]
        + rng.normal(0, 7),
        0,
        100,
    )

    duration = clip(rng.normal(255, 95), 55, 720)
    turn_count = int(clip(duration / rng.normal(6.5, 1.5), 8, 110))
    total_words = int(clip(duration * rng.normal(2.55, 0.42), 80, 2200))
    speaker_count = 2
    target_share = 50
    share_gap = (100 - latent["conversational_balance"]) * 0.38 + rng.normal(0, 4.5)
    talk_time_percent = clip(target_share + rng.choice([-1, 1]) * abs(share_gap), 12, 88)
    word_share = clip(talk_time_percent + rng.normal(0, 5), 10, 90)
    focus_words = int(total_words * word_share / 100)

    metrics = {
        "metadata": {
            "duration_seconds": round(duration, 2),
            "diarization": {"enabled": rng.random() > 0.12, "speaker_count": speaker_count},
        },
        "summary": {
            "duration_seconds": round(duration, 2),
            "speaker_count": speaker_count,
            "total_words": total_words,
            "conversation_wpm": round(total_words / duration * 60, 1),
            "total_turns": turn_count,
            "silence_percent": round(clip(rng.normal(11, 5), 1, 38), 1),
            "user_speaker_assumption": "Speaker 1",
        },
        "speakers": {
            "Speaker 1": {
                "talk_time_percent": round(talk_time_percent, 1),
                "word_count": focus_words,
                "words_per_minute": round(
                    clip(140 + (100 - latent["clarity"]) * 0.85 + rng.normal(0, 19), 70, 255),
                    1,
                ),
                "sentiment_average": round(scaled_sentiment(latent["warmth"], rng), 3),
            },
            "Speaker 2": {
                "talk_time_percent": round(100 - talk_time_percent, 1),
                "word_count": total_words - focus_words,
                "words_per_minute": round(clip(rng.normal(148, 22), 75, 240), 1),
                "sentiment_average": round(scaled_sentiment(latent["warmth"], rng) + rng.normal(0, 0.05), 3),
            },
        },
        "turn_taking": {
            "turn_count": turn_count,
            "average_turn_seconds": round(duration / turn_count, 2),
            "longest_turn_seconds": round(clip(95 - latent["conversational_balance"] * 0.65 + rng.normal(0, 12), 8, 150), 2),
            "monologues_over_45s": int(clip(round((100 - latent["conversational_balance"]) / 35 + rng.normal(0, 0.7)), 0, 6)),
            "average_response_latency_seconds": round(clip(1.2 + rng.normal(0, 0.55) + (50 - latent["emotional_regulation"]) / 100, 0.05, 5), 2),
            "fast_responses_under_300ms": int(clip(round((100 - latent["emotional_regulation"]) * turn_count / 450 + rng.normal(0, 1.1)), 0, turn_count)),
            "slow_responses_over_2s": int(clip(round((100 - latent["clarity"]) * turn_count / 600 + rng.normal(0, 1.0)), 0, turn_count)),
        },
        "interjections": {
            "estimated_count": int(clip(round((100 - latent["emotional_regulation"]) * turn_count / 430 + rng.normal(0, 1.0)), 0, turn_count))
        },
        "silence_and_pauses": {
            "long_pauses_over_2s": int(clip(round((100 - latent["clarity"]) * turn_count / 650 + rng.normal(0, 1.0)), 0, turn_count))
        },
        "language": {
            "fillers_per_minute": round(clip((100 - latent["clarity"]) / 24 + rng.normal(0, 0.45), 0, 6.5), 2),
            "questions_per_minute": round(clip(latent["curiosity"] / 90 + rng.normal(0, 0.2), 0, 3.1), 2),
            "question_count": 0,
            "follow_up_question_estimate": 0,
            "backchannels_per_minute": round(clip(latent["warmth"] / 85 + rng.normal(0, 0.18), 0, 3.2), 2),
            "validation_phrase_count": int(clip(round(latent["warmth"] / 22 + rng.normal(0, 1.0)), 0, 9)),
            "advice_phrase_count": int(clip(round((100 - latent["respectful_disagreeability"]) / 24 + rng.normal(0, 1.0)), 0, 8)),
            "lexical_diversity_type_token_ratio": round(clip(0.32 + latent["clarity"] / 500 + rng.normal(0, 0.035), 0.24, 0.65), 3),
            "average_sentence_words": round(clip(27 - latent["clarity"] * 0.12 + rng.normal(0, 4.0), 5, 45), 2),
        },
        "sentiment": {
            "average": round(scaled_sentiment(latent["warmth"], rng), 3),
            "minimum": round(clip(-0.75 + latent["emotional_regulation"] / 145 + rng.normal(0, 0.12), -1, 0.25), 3),
            "ending_average_last_3_turns": round(clip(-0.35 + latent["emotional_regulation"] / 130 + latent["warmth"] / 300 + rng.normal(0, 0.12), -1, 1), 3),
            "largest_shift": round(clip(1.05 - latent["emotional_regulation"] / 105 + rng.normal(0, 0.12), 0, 1.5), 3),
        },
        "audio_quality": {
            "dynamic_range_db": round(clip(5 + latent["clarity"] / 7 + rng.normal(0, 5), 1, 48), 2),
            "pitch_variability_hz": round(clip(8 + latent["warmth"] / 2.3 + rng.normal(0, 17), 1, 155), 2),
            "audio_quality_confidence": rng.choice(["high", "medium", "low"], p=[0.63, 0.29, 0.08]).item(),
        },
    }

    question_count = int(clip(round(metrics["language"]["questions_per_minute"] * duration / 60), 0, 30))
    metrics["language"]["question_count"] = question_count
    metrics["language"]["follow_up_question_estimate"] = int(
        clip(round(question_count * latent["curiosity"] / 140 + rng.normal(0, 1.0)), 0, question_count)
    )

    features = flatten_metrics(metrics)
    deterministic_scores = {
        target: compute_insights(metrics)["scores"][target]["score"]
        for target in TARGETS
    }
    labels = {target: clip(value + rng.normal(0, 4.0), 0, 100) for target, value in latent.items()}
    return {"metrics": metrics, "features": features, "labels": labels, "deterministic_scores": deterministic_scores}


def numeric_feature_names(records: list[dict[str, Any]]) -> list[str]:
    names = []
    for key, value in records[0]["features"].items():
        if key in FEATURE_EXCLUDE:
            continue
        if isinstance(value, (int, float)):
            names.append(key)
    return names


def evaluate_predictions(name: str, y_true: np.ndarray, y_pred: np.ndarray) -> dict[str, Any]:
    per_target = {}
    for index, target in enumerate(TARGETS):
        per_target[target] = {
            "mae": float(mean_absolute_error(y_true[:, index], y_pred[:, index])),
            "rmse": float(math.sqrt(mean_squared_error(y_true[:, index], y_pred[:, index]))),
            "r2": float(r2_score(y_true[:, index], y_pred[:, index])),
            "corr": float(correlation(y_true[:, index], y_pred[:, index])),
        }
    return {
        "approach": name,
        "mae": float(mean(item["mae"] for item in per_target.values())),
        "rmse": float(mean(item["rmse"] for item in per_target.values())),
        "r2": float(mean(item["r2"] for item in per_target.values())),
        "corr": float(mean(item["corr"] for item in per_target.values())),
        "per_target": per_target,
    }


def cluster_profiles(x: np.ndarray, y: np.ndarray, seed: int) -> dict[str, Any]:
    scaled = StandardScaler().fit_transform(x)
    best = None
    for clusters in range(3, 7):
        model = KMeans(n_clusters=clusters, random_state=seed, n_init=20)
        labels = model.fit_predict(scaled)
        score = float(silhouette_score(scaled, labels))
        if best is None or score > best["silhouette"]:
            best = {"clusters": clusters, "silhouette": score, "labels": labels}

    assert best is not None
    profiles = []
    for cluster in range(best["clusters"]):
        mask = best["labels"] == cluster
        target_means = {target: float(y[mask, index].mean()) for index, target in enumerate(TARGETS)}
        profiles.append(
            {
                "cluster": cluster,
                "share": float(mask.mean()),
                "profile": target_means,
                "name": cluster_name(target_means),
            }
        )
    profiles.sort(key=lambda item: item["share"], reverse=True)
    return {"clusters": best["clusters"], "silhouette": best["silhouette"], "profiles": profiles}


def top_feature_importance(model: Any, feature_names: list[str]) -> list[dict[str, Any]]:
    if model is None or not hasattr(model, "feature_importances_"):
        return []
    importances = model.feature_importances_
    rows = sorted(zip(feature_names, importances), key=lambda item: item[1], reverse=True)
    return [{"feature": name, "importance": float(value)} for name, value in rows[:15]]


def build_report(
    *,
    sample_count: int,
    seed: int,
    feature_names: list[str],
    results: list[dict[str, Any]],
    cluster_result: dict[str, Any],
    feature_importance: list[dict[str, Any]],
) -> str:
    rows = "\n".join(
        f"| {item['approach']} | {item['mae']:.2f} | {item['rmse']:.2f} | {item['r2']:.3f} | {item['corr']:.3f} |"
        for item in sorted(results, key=lambda row: row["mae"])
    )
    deterministic = next(item for item in results if item["approach"] == "Deterministic scoring rules")
    best = min(results[2:], key=lambda item: item["mae"])
    per_target_rows = "\n".join(
        f"| {target} | {best['per_target'][target]['mae']:.2f} | {best['per_target'][target]['r2']:.3f} | "
        f"{deterministic['per_target'][target]['mae']:.2f} | {deterministic['per_target'][target]['r2']:.3f} |"
        for target in TARGETS
    )
    cluster_rows = "\n".join(
        f"| {item['cluster']} | {item['name']} | {item['share'] * 100:.1f}% | "
        f"{item['profile']['warmth']:.1f} | {item['profile']['curiosity']:.1f} | "
        f"{item['profile']['conversational_balance']:.1f} | {item['profile']['emotional_regulation']:.1f} |"
        for item in cluster_result["profiles"]
    )
    importance_rows = "\n".join(
        f"| {item['feature']} | {item['importance']:.4f} |"
        for item in feature_importance
    )
    feature_list = ", ".join(f"`{name}`" for name in feature_names)

    return f"""# Conversation Intelligence Experiment Results

Generated by `scripts/survey_insight_models.py`.

## Test Setup

- Samples: `{sample_count}` synthetic conversations
- Seed: `{seed}`
- Train/test split: 75% / 25%
- Targets: {", ".join(f"`{target}`" for target in TARGETS)}
- Raw metric features: {feature_list}

No real labeled conversation corpus or audio file was available in the workspace. This experiment therefore tests the modeling pipeline and relative behavior of approaches on simulated raw metrics. The absolute accuracy numbers should not be interpreted as production performance.

## Approaches Tested

- Deterministic scoring rules from `app.insights`
- Mean training baseline
- Ridge regression
- ElasticNet regression
- Partial least squares
- k-nearest neighbors
- Random forest
- Extra trees
- Histogram gradient boosting
- RBF support vector regression
- Small multilayer perceptron
- K-means clustering for unsupervised profile discovery

## Overall Results

Lower MAE/RMSE is better. Higher R2/correlation is better.

| Approach | MAE | RMSE | R2 | Corr |
|---|---:|---:|---:|---:|
{rows}

## Best Supervised Model By Target

Best overall supervised model: `{best['approach']}`.

| Target | Best MAE | Best R2 | Deterministic MAE | Deterministic R2 |
|---|---:|---:|---:|---:|
{per_target_rows}

## Unsupervised Profile Survey

K-means selected `{cluster_result['clusters']}` clusters by silhouette score `{cluster_result['silhouette']:.3f}`.

| Cluster | Profile Name | Share | Warmth | Curiosity | Balance | Regulation |
|---:|---|---:|---:|---:|---:|---:|
{cluster_rows}

## Extra Trees Feature Importance

| Feature | Importance |
|---|---:|
{importance_rows}

## Interpretation

The deterministic layer is useful as a transparent product baseline. It gives stable directionality and human-readable drivers immediately, but it cannot discover subtle feature interactions or recalibrate itself from user feedback.

Linear models are strong when raw metrics have mostly monotonic relationships with the target dimensions. Tree ensembles handle threshold effects and interactions better, especially for balance, regulation, and generosity. The small MLP is worth keeping in the survey, but it is not the right production default until real labels exist because it is less explainable and easier to overfit.

The recommended near-term architecture is:

1. Keep deterministic scoring as the default production interpretation layer.
2. Persist raw feature snapshots and deterministic outputs for every completed recording.
3. Add human/LLM-assisted labels for turn pairs, windows, and whole conversations.
4. Train calibrated ridge/ElasticNet and tree ensemble baselines on real labels.
5. Use model predictions to calibrate or override deterministic scores only when confidence improves.
6. Defer larger neural fusion models until there is enough labeled text/audio data to justify them.

"""


def cluster_name(profile: dict[str, float]) -> str:
    if profile["warmth"] > 70 and profile["conversational_balance"] > 68:
        return "warm balanced"
    if profile["curiosity"] > 70:
        return "curious engager"
    if profile["emotional_regulation"] < 45:
        return "reactive/tension-prone"
    if profile["conversational_balance"] < 45:
        return "floor-dominant"
    if profile["clarity"] > 70:
        return "clear but neutral"
    return "mixed/ordinary"


def beta_score(rng: np.random.Generator, alpha: float, beta: float) -> float:
    return float(rng.beta(alpha, beta) * 100)


def scaled_sentiment(score: float, rng: np.random.Generator) -> float:
    return float(clip((score - 50) / 90 + rng.normal(0, 0.09), -1, 1))


def correlation(left: np.ndarray, right: np.ndarray) -> float:
    if np.std(left) == 0 or np.std(right) == 0:
        return 0.0
    return np.corrcoef(left, right)[0, 1]


def clip(value: float, low: float, high: float) -> float:
    return float(max(low, min(high, value)))


if __name__ == "__main__":
    main()
