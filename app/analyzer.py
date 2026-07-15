from __future__ import annotations

import math
import os
import re
import shutil
import subprocess
import uuid
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from statistics import mean, median
from typing import Any

import numpy as np
import soundfile as sf
from faster_whisper import WhisperModel
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer

from app.insights import compute_insights
from app.llm_interpreter import apply_contextualization, interpret_conversation


UPLOAD_DIR = Path(os.getenv("UPLOAD_DIR", "uploads"))
RUN_DIR = Path(os.getenv("RUN_DIR", "analysis_runs"))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
RUN_DIR.mkdir(parents=True, exist_ok=True)

FILLERS = {
    "um",
    "uh",
    "like",
    "you know",
    "i mean",
    "basically",
    "literally",
    "kind of",
    "sort of",
    "right",
    "okay",
    "so",
    "well",
    "actually",
    "just",
    "you see",
    "at the end of the day",
}

BACKCHANNELS = {
    "yeah",
    "yep",
    "mhm",
    "mm-hmm",
    "uh-huh",
    "right",
    "wow",
    "really",
    "no way",
    "i see",
    "totally",
    "interesting",
    "sure",
    "okay",
}

VALIDATION_PHRASES = {
    "that makes sense",
    "i get that",
    "i hear you",
    "that sounds hard",
    "that must be",
    "i understand",
    "totally understandable",
}

ADVICE_PHRASES = {
    "you should",
    "you need to",
    "why don't you",
    "why don’t you",
    "have you tried",
    "you could",
    "i would",
    "my advice",
}

WORD_RE = re.compile(r"[a-zA-Z][a-zA-Z']*")
SENTENCE_RE = re.compile(r"[.!?]+")


@dataclass
class WordToken:
    word: str
    start: float
    end: float
    speaker: str | None = None


@dataclass
class Turn:
    speaker: str
    start: float
    end: float
    text: str
    words: list[WordToken]
    sentiment: float = 0.0
    volume_db: float | None = None
    pitch_hz: float | None = None

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)

    @property
    def word_count(self) -> int:
        return len(tokenize(self.text))


def analyze_audio(input_path: Path, original_name: str) -> dict[str, Any]:
    run_id = str(uuid.uuid4())
    run_path = RUN_DIR / run_id
    run_path.mkdir(parents=True, exist_ok=True)
    wav_path = run_path / "audio.wav"

    convert_to_wav(input_path, wav_path)
    duration = audio_duration(wav_path)
    transcript_segments = transcribe(wav_path)
    diarization_segments, diarization_status = diarize_audio(wav_path)
    turns = build_turns(transcript_segments, diarization_segments)
    if not diarization_segments and diarization_mode() != "off":
        pyannote_status = diarization_status
        diarization_status = assign_speakers(wav_path, turns)
        diarization_status["fallback_reason"] = pyannote_status
    smooth_speaker_flips(turns)
    enrich_turns(wav_path, turns)

    metrics = compute_metrics(turns, duration)
    diarization_status = sync_diarization_status(diarization_status, turns)
    metrics["metadata"] = {
        "file_name": original_name,
        "duration_seconds": round(duration, 2),
        "turns_analyzed": len(turns),
        "diarization": diarization_status,
        "model": os.getenv("WHISPER_MODEL", "base.en"),
        "run_id": run_id,
    }
    metrics["insights"] = compute_insights(metrics)
    if auto_interpret_enabled():
        interpretation = interpret_conversation(metrics)
        metrics["interpretation"] = interpretation
        metrics = apply_contextualization(metrics, interpretation)

    return metrics


def auto_interpret_enabled() -> bool:
    value = os.getenv("AUTO_INTERPRET_ANALYSIS", "1").strip().lower()
    return value not in {"0", "false", "no", "off"}


def diarization_mode() -> str:
    mode = os.getenv("DIARIZATION_MODE", "auto").strip().lower()
    if mode in {"off", "none", "disabled", "0", "false", "no"}:
        return "off"
    if mode in {"pyannote", "timeline"}:
        return "pyannote"
    if mode in {"fallback", "resemblyzer", "local"}:
        return "fallback"
    return "auto"


def convert_to_wav(input_path: Path, wav_path: Path) -> None:
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg is required. Install it with `brew install ffmpeg`.")

    cmd = [
        "ffmpeg",
        "-y",
        "-i",
        str(input_path),
        "-ac",
        "1",
        "-ar",
        "16000",
        "-vn",
        str(wav_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {result.stderr[-1200:]}")


def audio_duration(wav_path: Path) -> float:
    info = sf.info(str(wav_path))
    return float(info.frames / info.samplerate)


def transcribe(wav_path: Path) -> list[dict[str, Any]]:
    model_size = os.getenv("WHISPER_MODEL", "base.en")
    device = os.getenv("WHISPER_DEVICE", "cpu")
    compute_type = os.getenv("WHISPER_COMPUTE_TYPE", "int8")
    model = WhisperModel(model_size, device=device, compute_type=compute_type)
    segments, info = model.transcribe(
        str(wav_path),
        beam_size=5,
        vad_filter=True,
        word_timestamps=True,
        condition_on_previous_text=True,
    )

    output: list[dict[str, Any]] = []
    for segment in segments:
        words = []
        for word in segment.words or []:
            clean = word.word.strip()
            if clean:
                words.append({"word": clean, "start": float(word.start), "end": float(word.end)})
        output.append(
            {
                "start": float(segment.start),
                "end": float(segment.end),
                "text": segment.text.strip(),
                "words": words,
            }
        )
    if not output and info.duration:
        return []
    return output


def build_turns(
    segments: list[dict[str, Any]], diarization_segments: list[dict[str, Any]] | None = None
) -> list[Turn]:
    turns: list[Turn] = []
    for segment in segments:
        words = [
            WordToken(
                word=item["word"],
                start=item["start"],
                end=item["end"],
                speaker=speaker_for_interval(item["start"], item["end"], diarization_segments or []),
            )
            for item in segment.get("words", [])
        ]
        if not words:
            continue

        current_words: list[WordToken] = []
        for word in words:
            if current_words:
                gap = word.start - current_words[-1].end
                previous_text = current_words[-1].word
                speaker_changed = (
                    word.speaker is not None
                    and current_words[-1].speaker is not None
                    and word.speaker != current_words[-1].speaker
                )
                should_break = (
                    speaker_changed
                    or gap > 0.9
                    or (gap > 0.45 and previous_text.endswith((".", "?", "!")))
                )
                if should_break:
                    turns.append(words_to_turn(current_words))
                    current_words = []
            current_words.append(word)
        if current_words:
            turns.append(words_to_turn(current_words))

    return merge_tiny_turns(turns)


def words_to_turn(words: list[WordToken]) -> Turn:
    text = " ".join(word.word for word in words)
    text = re.sub(r"\s+([,.?!:;])", r"\1", text).strip()
    speaker = most_common_speaker([word.speaker for word in words]) or "Speaker 1"
    return Turn(speaker=speaker, start=words[0].start, end=words[-1].end, text=text, words=words)


def merge_tiny_turns(turns: list[Turn]) -> list[Turn]:
    if not turns:
        return []
    merged = [turns[0]]
    for turn in turns[1:]:
        previous = merged[-1]
        gap = turn.start - previous.end
        same_speaker = previous.speaker == turn.speaker
        if same_speaker and gap < 0.35 and previous.duration < 1.0 and not previous.text.endswith(("?", "!", ".")):
            previous.end = turn.end
            previous.text = f"{previous.text} {turn.text}".strip()
            previous.words.extend(turn.words)
        else:
            merged.append(turn)
    return merged


def diarize_audio(wav_path: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Return a speaker timeline when a stronger diarization backend is configured."""
    mode = diarization_mode()
    if mode == "off":
        return [], {
            "enabled": False,
            "backend": "disabled",
            "status": "disabled",
            "detail": "Set DIARIZATION_MODE=auto, fallback, or pyannote to enable speaker diarization.",
            "speaker_count": 1,
        }
    if mode == "fallback":
        return [], {
            "enabled": False,
            "backend": "resemblyzer",
            "status": "fallback_requested",
            "detail": "Skipping pyannote and using local speaker embedding fallback.",
        }
    segments, status = diarize_with_pyannote(wav_path)
    if segments:
        return segments, status
    return [], status


def diarize_with_pyannote(wav_path: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    hf_token = os.getenv("HF_TOKEN") or os.getenv("HUGGINGFACE_TOKEN")
    if not hf_token:
        return [], {
            "enabled": False,
            "backend": "pyannote.audio",
            "status": "huggingface_token_missing",
            "detail": "Set HF_TOKEN after accepting the pyannote model terms to enable timeline diarization.",
        }

    try:
        from pyannote.audio import Pipeline
    except Exception as exc:  # pragma: no cover - optional dependency
        return [], {
            "enabled": False,
            "backend": "pyannote.audio",
            "status": "optional_dependency_missing",
            "detail": "Install with ./scripts/install_diarization.sh",
            "error": str(exc),
        }

    try:
        pipeline_name = os.getenv("PYANNOTE_PIPELINE", "pyannote/speaker-diarization-3.1")
        pipeline = Pipeline.from_pretrained(pipeline_name, use_auth_token=hf_token)
        if pipeline is None:
            return [], {
                "enabled": False,
                "backend": "pyannote.audio",
                "status": "pipeline_unavailable",
                "detail": "pyannote could not load the diarization pipeline. Check HF_TOKEN and accept the model terms on Hugging Face.",
            }
        diarization = pipeline(str(wav_path))
    except Exception as exc:
        return [], {
            "enabled": False,
            "backend": "pyannote.audio",
            "status": "pipeline_failed",
            "detail": "Check HF_TOKEN, pyannote model access, and local torch installation.",
            "error": str(exc),
        }

    label_map: dict[str, str] = {}
    timeline: list[dict[str, Any]] = []
    for segment, _, raw_label in diarization.itertracks(yield_label=True):
        if raw_label not in label_map:
            label_map[raw_label] = f"Speaker {len(label_map) + 1}"
        if segment.end - segment.start < 0.05:
            continue
        timeline.append(
            {
                "start": float(segment.start),
                "end": float(segment.end),
                "speaker": label_map[raw_label],
            }
        )

    timeline.sort(key=lambda item: (item["start"], item["end"]))
    timeline = merge_adjacent_diarization_segments(timeline)
    return timeline, {
        "enabled": True,
        "backend": "pyannote.audio",
        "status": "timeline_diarization",
        "speaker_count": len({item["speaker"] for item in timeline}),
        "segments": len(timeline),
        "note": "Whisper words are assigned to the pyannote speaker timeline by timestamp overlap.",
    }


def merge_adjacent_diarization_segments(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not segments:
        return []
    merged = [segments[0].copy()]
    for segment in segments[1:]:
        previous = merged[-1]
        if segment["speaker"] == previous["speaker"] and segment["start"] - previous["end"] <= 0.25:
            previous["end"] = max(previous["end"], segment["end"])
        else:
            merged.append(segment.copy())
    return merged


def speaker_for_interval(start: float, end: float, segments: list[dict[str, Any]]) -> str | None:
    if not segments:
        return None
    midpoint = (start + end) / 2
    overlap_by_speaker: dict[str, float] = defaultdict(float)
    for segment in segments:
        overlap = min(end, segment["end"]) - max(start, segment["start"])
        if overlap > 0:
            overlap_by_speaker[segment["speaker"]] += overlap
    if overlap_by_speaker:
        return max(overlap_by_speaker.items(), key=lambda item: item[1])[0]

    nearest = min(
        segments,
        key=lambda segment: min(abs(midpoint - segment["start"]), abs(midpoint - segment["end"])),
    )
    if min(abs(midpoint - nearest["start"]), abs(midpoint - nearest["end"])) <= 0.6:
        return nearest["speaker"]
    return None


def most_common_speaker(speakers: list[str | None]) -> str | None:
    clean = [speaker for speaker in speakers if speaker]
    if not clean:
        return None
    return Counter(clean).most_common(1)[0][0]


def assign_speakers(wav_path: Path, turns: list[Turn]) -> dict[str, Any]:
    if len(turns) < 3:
        return {"enabled": False, "status": "too_few_turns", "speaker_count": 1}

    try:
        from resemblyzer import VoiceEncoder, preprocess_wav
        from sklearn.cluster import AgglomerativeClustering
        from sklearn.metrics import silhouette_score
    except Exception as exc:  # pragma: no cover - depends on optional install
        for turn in turns:
            turn.speaker = "Speaker 1"
        return {
            "enabled": False,
            "status": "optional_dependency_missing",
            "detail": "Install with ./scripts/install_diarization.sh",
            "error": str(exc),
            "speaker_count": 1,
        }

    wav = preprocess_wav(str(wav_path))
    sample_rate = 16000
    encoder = VoiceEncoder()
    embeddable_turns: list[Turn] = []
    embeddings = []

    for turn in turns:
        start = max(0, int(turn.start * sample_rate))
        end = min(len(wav), int(turn.end * sample_rate))
        if end - start < sample_rate * 0.75:
            continue
        chunk = wav[start:end]
        try:
            embeddings.append(encoder.embed_utterance(chunk))
            embeddable_turns.append(turn)
        except Exception:
            continue

    if len(embeddings) < 3:
        return {"enabled": True, "status": "not_enough_speech_for_clustering", "speaker_count": 1}

    matrix = np.vstack(embeddings)
    labels = choose_speaker_labels(matrix, AgglomerativeClustering, silhouette_score)
    ordered_labels = order_labels_by_first_turn(labels)

    for turn, label in zip(embeddable_turns, labels):
        turn.speaker = f"Speaker {ordered_labels[label]}"

    nearest_labels = [(known.start, known.speaker) for known in embeddable_turns]
    for turn in turns:
        if turn in embeddable_turns:
            continue
        closest = min(nearest_labels, key=lambda item: abs(item[0] - turn.start))
        turn.speaker = closest[1]

    return {
        "enabled": True,
        "backend": "resemblyzer",
        "status": "speaker_embeddings_clustered",
        "speaker_count": len(set(labels)),
        "note": "Fallback speaker labels are clustered turn-level estimates. Speaker 1 is the first detected speaker.",
    }


def smooth_speaker_flips(turns: list[Turn]) -> None:
    """Reduce isolated, low-confidence speaker islands between same-speaker turns.

    This is intentionally conservative: it only rewrites A-B-A patterns where the
    middle turn is short and surrounded closely by the same speaker.
    """
    if len(turns) < 3:
        return

    for index in range(1, len(turns) - 1):
        previous = turns[index - 1]
        current = turns[index]
        following = turns[index + 1]
        if previous.speaker != following.speaker or current.speaker == previous.speaker:
            continue

        surrounded_by_same_speaker = (
            current.start - previous.end <= 1.0 and following.start - current.end <= 1.0
        )
        short_island = current.duration <= 2.2 or current.word_count <= 7
        lacks_terminal_boundary = not current.text.strip().endswith(("?", "!", "."))
        if surrounded_by_same_speaker and short_island and lacks_terminal_boundary:
            current.speaker = previous.speaker


def sync_diarization_status(status: dict[str, Any], turns: list[Turn]) -> dict[str, Any]:
    displayed_speakers = sorted({turn.speaker for turn in turns})
    updated = dict(status)
    updated["displayed_speaker_count"] = len(displayed_speakers)
    updated["displayed_speakers"] = displayed_speakers
    if updated.get("speaker_count") != len(displayed_speakers):
        updated["raw_speaker_count"] = updated.get("speaker_count")
        updated["speaker_count"] = len(displayed_speakers)
        updated["count_note"] = "Speaker count reflects the final displayed transcript after smoothing."
    return updated


def choose_speaker_labels(matrix: np.ndarray, clustering_cls: Any, silhouette_score: Any) -> np.ndarray:
    max_speakers = min(4, len(matrix) - 1)
    best_score = -1.0
    best_labels: np.ndarray | None = None
    for k in range(2, max_speakers + 1):
        try:
            clusterer = clustering_cls(n_clusters=k, metric="cosine", linkage="average")
        except TypeError:
            clusterer = clustering_cls(n_clusters=k, affinity="cosine", linkage="average")
        labels = clusterer.fit_predict(matrix)
        if len(set(labels)) < 2:
            continue
        try:
            score = float(silhouette_score(matrix, labels, metric="cosine"))
        except Exception:
            score = -1.0
        if score > best_score:
            best_score = score
            best_labels = labels

    if best_labels is None or best_score < 0.05:
        return np.zeros(len(matrix), dtype=int)
    return best_labels


def order_labels_by_first_turn(labels: np.ndarray) -> dict[int, int]:
    ordered: dict[int, int] = {}
    for label in labels:
        label = int(label)
        if label not in ordered:
            ordered[label] = len(ordered) + 1
    return ordered


def enrich_turns(wav_path: Path, turns: list[Turn]) -> None:
    analyzer = SentimentIntensityAnalyzer()
    audio, sample_rate = sf.read(str(wav_path), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    for turn in turns:
        turn.sentiment = analyzer.polarity_scores(turn.text)["compound"]
        start = max(0, int(turn.start * sample_rate))
        end = min(len(audio), int(turn.end * sample_rate))
        chunk = audio[start:end]
        if len(chunk) == 0:
            continue
        rms = float(np.sqrt(np.mean(np.square(chunk))) + 1e-9)
        turn.volume_db = round(20 * math.log10(rms), 2)
        turn.pitch_hz = estimate_pitch(chunk, sample_rate)


def estimate_pitch(chunk: np.ndarray, sample_rate: int) -> float | None:
    if len(chunk) < sample_rate // 2:
        return None
    try:
        import librosa

        trimmed, _ = librosa.effects.trim(chunk, top_db=30)
        if len(trimmed) < sample_rate // 2:
            return None
        y = librosa.yin(trimmed, fmin=55, fmax=420, sr=sample_rate)
        voiced = y[np.isfinite(y)]
        if len(voiced) == 0:
            return None
        return round(float(np.median(voiced)), 2)
    except Exception:
        return None


def compute_metrics(turns: list[Turn], duration: float) -> dict[str, Any]:
    speakers = sorted({turn.speaker for turn in turns}) or ["Speaker 1"]
    user_speaker = speakers[0]
    words = tokenize(" ".join(turn.text for turn in turns))
    gaps = turn_gaps(turns)
    speaker_changes = response_latencies(turns)
    interjections = detect_interjections(turns)
    filler_counts = count_phrases(" ".join(turn.text for turn in turns), FILLERS)
    backchannels = detect_backchannels(turns)
    questions = detect_questions(turns)

    by_speaker = {}
    for speaker in speakers:
        speaker_turns = [turn for turn in turns if turn.speaker == speaker]
        talk_time = sum(turn.duration for turn in speaker_turns)
        speaker_words = sum(turn.word_count for turn in speaker_turns)
        by_speaker[speaker] = {
            "turns": len(speaker_turns),
            "talk_time_seconds": round(talk_time, 2),
            "talk_time_percent": percent(talk_time, duration),
            "word_count": speaker_words,
            "words_per_minute": round(speaker_words / max(talk_time, 1e-9) * 60, 1),
            "average_turn_seconds": round(mean([t.duration for t in speaker_turns]), 2)
            if speaker_turns
            else 0,
            "average_volume_db": rounded_mean([t.volume_db for t in speaker_turns]),
            "average_pitch_hz": rounded_mean([t.pitch_hz for t in speaker_turns]),
            "sentiment_average": round(mean([t.sentiment for t in speaker_turns]), 3)
            if speaker_turns
            else 0,
        }

    sentiment_series = [
        {
            "speaker": turn.speaker,
            "start": round(turn.start, 2),
            "sentiment": round(turn.sentiment, 3),
            "text": turn.text,
        }
        for turn in turns
    ]
    sentiment_values = [turn.sentiment for turn in turns]

    return {
        "summary": {
            "duration_seconds": round(duration, 2),
            "speaker_count": len(speakers),
            "total_words": len(words),
            "conversation_wpm": round(len(words) / max(duration, 1e-9) * 60, 1),
            "total_turns": len(turns),
            "silence_seconds": round(sum(gaps), 2),
            "silence_percent": percent(sum(gaps), duration),
            "user_speaker_assumption": user_speaker,
        },
        "speakers": by_speaker,
        "turn_taking": {
            "turn_count": len(turns),
            "average_turn_seconds": round(mean([t.duration for t in turns]), 2) if turns else 0,
            "median_turn_seconds": round(median([t.duration for t in turns]), 2) if turns else 0,
            "longest_turn_seconds": round(max([t.duration for t in turns], default=0), 2),
            "shortest_turn_seconds": round(min([t.duration for t in turns], default=0), 2),
            "very_short_responses": len([t for t in turns if t.duration < 2.0 and t.word_count <= 5]),
            "monologues_over_45s": len([t for t in turns if t.duration >= 45.0]),
            "speaker_changes": len(speaker_changes),
            "average_response_latency_seconds": rounded_mean(speaker_changes),
            "fast_responses_under_300ms": len([latency for latency in speaker_changes if latency <= 0.3]),
            "slow_responses_over_2s": len([latency for latency in speaker_changes if latency >= 2.0]),
        },
        "interjections": {
            "estimated_count": len(interjections),
            "note": "Estimated from near-zero response latency and short acknowledgment turns; true overlap needs stronger diarization.",
            "events": interjections[:25],
        },
        "silence_and_pauses": {
            "total_silence_seconds": round(sum(gaps), 2),
            "average_between_turn_pause_seconds": rounded_mean(gaps),
            "long_pauses_over_2s": len([gap for gap in gaps if gap >= 2.0]),
            "intra_speech_pauses_over_500ms": count_intra_speech_pauses(turns, 0.5),
            "intra_speech_pauses_over_1s": count_intra_speech_pauses(turns, 1.0),
        },
        "language": {
            "filler_words_total": sum(filler_counts.values()),
            "fillers_per_minute": round(sum(filler_counts.values()) / max(duration, 1e-9) * 60, 2),
            "filler_breakdown": filler_counts,
            "question_count": len(questions),
            "questions_per_minute": round(len(questions) / max(duration, 1e-9) * 60, 2),
            "follow_up_question_estimate": count_follow_up_questions(turns),
            "backchannel_count": len(backchannels),
            "backchannels_per_minute": round(len(backchannels) / max(duration, 1e-9) * 60, 2),
            "validation_phrase_count": sum(count_phrases(" ".join(t.text for t in turns), VALIDATION_PHRASES).values()),
            "advice_phrase_count": sum(count_phrases(" ".join(t.text for t in turns), ADVICE_PHRASES).values()),
            "lexical_diversity_type_token_ratio": lexical_diversity(words),
            "average_word_length": round(mean([len(word) for word in words]), 2) if words else 0,
            "average_sentence_words": average_sentence_words(" ".join(t.text for t in turns)),
        },
        "sentiment": {
            "average": round(mean(sentiment_values), 3) if sentiment_values else 0,
            "minimum": round(min(sentiment_values), 3) if sentiment_values else 0,
            "maximum": round(max(sentiment_values), 3) if sentiment_values else 0,
            "ending_average_last_3_turns": round(mean(sentiment_values[-3:]), 3) if sentiment_values else 0,
            "largest_shift": largest_sentiment_shift(sentiment_values),
            "series": sentiment_series,
        },
        "audio_quality": estimate_audio_quality(turns, duration),
        "transcript": [
            {
                "speaker": turn.speaker,
                "start": round(turn.start, 2),
                "end": round(turn.end, 2),
                "duration": round(turn.duration, 2),
                "sentiment": round(turn.sentiment, 3),
                "volume_db": turn.volume_db,
                "pitch_hz": turn.pitch_hz,
                "text": turn.text,
            }
            for turn in turns
        ],
    }


def tokenize(text: str) -> list[str]:
    return [match.group(0).lower() for match in WORD_RE.finditer(text)]


def turn_gaps(turns: list[Turn]) -> list[float]:
    return [max(0.0, turns[i].start - turns[i - 1].end) for i in range(1, len(turns))]


def response_latencies(turns: list[Turn]) -> list[float]:
    latencies = []
    for i in range(1, len(turns)):
        if turns[i].speaker != turns[i - 1].speaker:
            latencies.append(max(0.0, turns[i].start - turns[i - 1].end))
    return latencies


def detect_interjections(turns: list[Turn]) -> list[dict[str, Any]]:
    events = []
    for i in range(1, len(turns)):
        previous = turns[i - 1]
        current = turns[i]
        if previous.speaker == current.speaker:
            continue
        latency = current.start - previous.end
        text_norm = " ".join(tokenize(current.text))
        is_short_ack = current.duration <= 1.6 and text_norm in BACKCHANNELS
        is_fast_take = latency <= 0.3 and current.word_count <= 8
        if is_short_ack or is_fast_take:
            events.append(
                {
                    "time": round(current.start, 2),
                    "speaker": current.speaker,
                    "previous_speaker": previous.speaker,
                    "latency_seconds": round(max(0.0, latency), 2),
                    "type": "backchannel" if is_short_ack else "fast interjection",
                    "text": current.text,
                }
            )
    return events


def detect_backchannels(turns: list[Turn]) -> list[dict[str, Any]]:
    events = []
    for turn in turns:
        text_norm = " ".join(tokenize(turn.text))
        if turn.duration <= 2.0 and (text_norm in BACKCHANNELS or any(text_norm == item for item in BACKCHANNELS)):
            events.append({"time": round(turn.start, 2), "speaker": turn.speaker, "text": turn.text})
    return events


def detect_questions(turns: list[Turn]) -> list[Turn]:
    question_starters = ("who", "what", "when", "where", "why", "how", "do", "does", "did", "can", "could", "would", "should", "is", "are")
    questions = []
    for turn in turns:
        words = tokenize(turn.text)
        if "?" in turn.text or (words and words[0] in question_starters):
            questions.append(turn)
    return questions


def count_follow_up_questions(turns: list[Turn]) -> int:
    count = 0
    for i in range(1, len(turns)):
        if turns[i].speaker != turns[i - 1].speaker and turns[i].start - turns[i - 1].end < 20:
            if turns[i] in detect_questions([turns[i]]):
                count += 1
    return count


def count_intra_speech_pauses(turns: list[Turn], threshold: float) -> int:
    count = 0
    for turn in turns:
        for i in range(1, len(turn.words)):
            if turn.words[i].start - turn.words[i - 1].end >= threshold:
                count += 1
    return count


def count_phrases(text: str, phrases: set[str]) -> dict[str, int]:
    normalized = " ".join(tokenize(text))
    counts = {}
    for phrase in sorted(phrases):
        phrase_norm = " ".join(tokenize(phrase))
        if not phrase_norm:
            continue
        pattern = rf"\b{re.escape(phrase_norm)}\b"
        matches = re.findall(pattern, normalized)
        if matches:
            counts[phrase] = len(matches)
    return counts


def lexical_diversity(words: list[str]) -> float:
    if not words:
        return 0
    return round(len(set(words)) / len(words), 3)


def average_sentence_words(text: str) -> float:
    sentences = [part.strip() for part in SENTENCE_RE.split(text) if part.strip()]
    if not sentences:
        return 0
    return round(mean([len(tokenize(sentence)) for sentence in sentences]), 2)


def largest_sentiment_shift(values: list[float]) -> float:
    if len(values) < 2:
        return 0
    return round(max(abs(values[i] - values[i - 1]) for i in range(1, len(values))), 3)


def estimate_audio_quality(turns: list[Turn], duration: float) -> dict[str, Any]:
    volumes = [turn.volume_db for turn in turns if turn.volume_db is not None]
    pitches = [turn.pitch_hz for turn in turns if turn.pitch_hz is not None]
    if not volumes:
        return {"average_volume_db": None, "dynamic_range_db": None, "audio_quality_confidence": "low"}
    dynamic_range = max(volumes) - min(volumes)
    confidence = "high" if duration > 30 and len(turns) >= 8 else "medium" if turns else "low"
    return {
        "average_volume_db": round(mean(volumes), 2),
        "dynamic_range_db": round(dynamic_range, 2),
        "pitch_range_hz": round(max(pitches) - min(pitches), 2) if len(pitches) >= 2 else None,
        "pitch_variability_hz": round(float(np.std(pitches)), 2) if len(pitches) >= 2 else None,
        "audio_quality_confidence": confidence,
    }


def percent(value: float, total: float) -> float:
    return round(value / max(total, 1e-9) * 100, 1)


def rounded_mean(values: list[float | None]) -> float | None:
    clean = [value for value in values if value is not None]
    if not clean:
        return None
    return round(mean(clean), 2)
