# Conversation Intelligence Variable Plan

This plan describes how to move from the current low-level speech metrics toward user-facing emotional intelligence coaching. The central product shift is:

```text
raw acoustic/transcript metrics -> middle-layer social behaviors -> high-level growth dimensions -> concrete coaching
```

The app should not stop at "talk slower" or "use fewer fillers." Those are inputs. The user-facing output should name interpersonal patterns such as warmth, curiosity, dominance, receptivity, repair, and disagreement style.

## Current Backend Signals

The current analyzer already produces a useful primitive feature set:

- Transcript turns with speaker, start/end time, duration, sentiment, volume, pitch, and text.
- Per-speaker talk time, word count, words per minute, average turn duration, volume, pitch, and sentiment.
- Turn-taking metrics: response latency, short responses, monologues, fast responses, slow responses.
- Language metrics: fillers, questions, follow-up questions, backchannels, validation phrases, advice phrases, lexical diversity, sentence length.
- Sentiment trajectory: average, min/max, ending sentiment, largest shift, turn-level series.
- Audio quality and prosody estimates: volume, dynamic range, pitch range, pitch variability.

Important limitations:

- `user_speaker_assumption` is currently the first sorted speaker label, not a real identity signal.
- Interruption is a heuristic based on fast turn transfer and short acknowledgments; true overlap requires stronger diarization or frame-level speech activity.
- VADER sentiment is useful for coarse valence, but it is not enough for warmth, empathy, tension, sarcasm, or disagreement.
- Current validation/advice phrase detection is phrase-list based and will miss paraphrases.

## Variable Hierarchy

### Raw Layer

These are direct measurements or near-direct measurements. They should remain inspectable and versioned.

- `talk_time_share`
- `turn_count`
- `turn_duration_mean`
- `turn_duration_variance`
- `response_latency_mean`
- `response_latency_distribution`
- `interjection_count`
- `overlap_count` once true overlap detection exists
- `question_count`
- `follow_up_question_count`
- `backchannel_count`
- `validation_phrase_count`
- `advice_phrase_count`
- `filler_rate`
- `speech_rate_wpm`
- `pause_rate`
- `long_pause_count`
- `sentiment_turn_values`
- `sentiment_shift_magnitude`
- `volume_mean`
- `volume_variability`
- `pitch_mean`
- `pitch_variability`
- `lexical_diversity`
- `sentence_length_mean`

### Middle Layer

Middle-layer variables should describe observable conversational behaviors. They should be computed per speaker and per conversation.

#### Participation and Balance

- `conversational_balance`: how evenly speaking time and turn ownership are distributed.
- `floor_dominance`: degree to which one speaker holds long turns or repeated turns.
- `turn_exchange_smoothness`: latency, overlap, and abrupt transition quality.
- `space_making`: whether the user leaves room for the other speaker after emotionally meaningful turns.

Raw inputs: talk-time share, word share, turn share, longest turn, monologues, response latency, pauses, interruptions.

#### Curiosity and Engagement

- `curiosity`: use of questions that invite elaboration.
- `follow_up_depth`: whether questions respond to what the other person just said.
- `active_listening`: backchannels, validations, and semantically relevant references to prior turns.
- `topic_continuity`: whether the speaker builds on the partner's content or pivots away.

Raw inputs: question count, follow-up estimate, backchannels, validation phrases, transcript embeddings, adjacency pairs.

#### Empathy and Validation

- `emotional_attunement`: whether responses match the emotional tone and content of the partner.
- `validation`: explicit recognition of the other person's feeling or viewpoint.
- `supportiveness`: comfort, encouragement, or constructive help without taking over.
- `premature_advice`: advice or fixing before validation or understanding.

Raw inputs: sentiment trajectory, validation phrases, advice phrases, semantic labels for feeling acknowledgement, response timing.

#### Disagreement and Friction

- `disagreement_directness`: how explicitly disagreement is stated.
- `disagreement_softening`: use of hedges, acknowledgments, uncertainty, and respectful framing.
- `defensiveness`: self-justification, blame shifting, refusal to engage, repeated contradiction.
- `repair_attempts`: apologies, clarification, reframing, concession, or bids to reconnect.
- `tension_escalation`: whether sentiment, speed, volume, interruption, and contradiction worsen over time.

Raw inputs: sentiment shifts, transcript labels, interruption/latency, volume/pitch change, contradiction markers, repair phrase/semantic labels.

#### Emotional Regulation

- `composure`: stability of pace, volume, pitch, and sentiment during difficult moments.
- `reactivity`: fast, negative, or interruptive responses after partner turns.
- `recovery`: return toward neutral/positive affect after a negative shift.
- `expressiveness`: prosodic and lexical variation without dysregulation.

Raw inputs: sentiment series, volume/pitch variability, WPM changes, response latency, negative-turn adjacency.

#### Clarity and Conversational Load

- `clarity`: concise, understandable phrasing without excessive filler or sprawl.
- `specificity`: concrete details versus vague abstractions.
- `cognitive_load`: disfluency, long pauses, filler clustering, and unfinished phrasing.
- `actionability`: whether suggestions are clear, grounded, and appropriately timed.

Raw inputs: fillers, sentence length, lexical diversity, pauses, advice phrases, transcript semantic tags.

### High-Level Layer

These are the user-facing growth dimensions. They should be stable over sessions but decomposable into middle-layer explanations.

- `warmth`: friendliness, validation, positive regard, supportive tone.
- `curiosity`: genuine interest in the other person's perspective.
- `empathy`: recognizing and responding to emotional content.
- `respectful_disagreeability`: ability to disagree clearly without contempt, dismissal, or over-softening.
- `assertiveness`: clear self-expression without dominating.
- `receptivity`: openness to being influenced, corrected, or informed.
- `emotional_regulation`: steadiness under tension.
- `conversational_generosity`: making space, following up, and helping the other person feel heard.
- `repair_orientation`: tendency to recover after friction.
- `clarity`: making one's thoughts easy to understand.

For MVP, prioritize:

1. `warmth`
2. `curiosity`
3. `conversational_balance`
4. `respectful_disagreeability`
5. `emotional_regulation`

These give the product a strong coaching surface without pretending to infer every emotional trait immediately.

## Recommended Output Shape

Add a new top-level field to analyzer results:

```json
{
  "insights": {
    "version": "conversation-intelligence-v1",
    "speaker_focus": "Speaker 1",
    "scores": {
      "warmth": {
        "score": 72,
        "confidence": 0.64,
        "drivers": [
          "Frequent brief acknowledgments",
          "Low validation before advice",
          "Ending sentiment recovered"
        ],
        "practice": "Reflect the other person's feeling before offering a solution."
      }
    },
    "middle_layer": {
      "active_listening": {"score": 68, "confidence": 0.7},
      "premature_advice": {"score": 42, "confidence": 0.58}
    }
  }
}
```

Each high-level score should include:

- `score`: 0-100, calibrated so 50 is ordinary/neutral.
- `confidence`: 0-1 based on audio quality, transcript length, diarization quality, and model agreement.
- `drivers`: short observable explanations.
- `evidence`: optional transcript snippets or timestamps.
- `practice`: one coaching action.

## Modeling Strategy

### Phase 1: Explainable Scoring Rules

Start with deterministic or lightly statistical scoring for middle-layer variables. This is the fastest way to ship a useful product and collect feedback.

Use robust transforms instead of brittle thresholds:

- Convert raw metrics into z-scores or percentiles against a growing internal baseline.
- Apply clipping and smoothing so one weird turn does not dominate.
- Score per speaker, then compare to conversation context.
- Attach confidence based on sample length, diarization status, and feature availability.

Recommended algorithms:

- Weighted linear scoring.
- Logistic transforms for threshold-like behaviors.
- Rolling-window trend detection for escalation and recovery.
- Simple embedding similarity for topic continuity and follow-up relevance.

This phase should produce interpretable "drivers" that users can trust.

### Phase 2: Weak Supervision and LLM-Assisted Labels

Before expensive human labeling, create a weakly supervised dataset.

Sources:

- Rule-based labels from Phase 1.
- LLM rubric labels on transcript windows.
- Human spot checks on a small subset.
- User feedback such as "this was accurate" or "not accurate."

Use labels at multiple levels:

- Turn pair labels: validation, interruption, advice, repair, disagreement, topic shift.
- Segment labels: escalating, supportive, dismissive, curious, defensive.
- Conversation labels: warmth, curiosity, balance, regulation.

Recommended algorithms:

- Calibrated logistic regression for each score as a baseline.
- Gradient boosted trees for tabular raw and middle features.
- Sentence/turn embeddings plus shallow classifiers for semantic behaviors.
- Multi-label classification for turn-pair social acts.

Do not start with a large neural network as the core product model. It will be harder to debug, harder to calibrate, and hungry for labels you do not yet have.

### Phase 3: Hybrid Neural Model

Once you have enough labeled data, introduce a hybrid model:

- Audio branch: prosody, speaker overlap, pitch/energy contours.
- Text branch: transcript embeddings and conversation-act labels.
- Structure branch: turn-taking graph and temporal patterns.
- Fusion layer: predicts middle-layer behaviors and high-level dimensions.

Recommended architecture:

- Pretrained text embeddings for each turn.
- Acoustic feature extractor using openSMILE/eGeMAPS or a pretrained speech model.
- Temporal pooling over turn pairs and segments.
- Multi-task heads for middle-layer variables and top-level scores.

Keep the rule-based system as a fallback and calibration layer. The neural model should improve semantic sensitivity, not erase explainability.

## Additional Data To Collect

### Audio and Timing

- Frame-level voice activity detection.
- True overlap duration by speaker.
- Speaking-rate changes across the conversation, not just global WPM.
- Pitch slope, pitch range per turn, energy slope, jitter/shimmer if quality allows.
- Laughter, sighs, long inhalations, and audible stress markers where feasible.

### Transcript and Semantics

- Turn embeddings.
- Partner-reference features: does the user mention or paraphrase the other speaker's content?
- Emotion labels per turn.
- Dialogue act labels: question, answer, validation, challenge, apology, repair, advice, boundary, disclosure.
- Disagreement markers: "but", "I don't think", "not really", "I disagree", softened versus blunt framing.
- Hedging and certainty markers.
- Gratitude, apology, reassurance, and affirmation markers.

### Context and Personalization

- Conversation type: conflict, casual check-in, sales, therapy-like support, team meeting, dating, family.
- User goal: be warmer, more assertive, less reactive, more concise.
- Relationship context, if the user provides it.
- Session-level trend history.
- User feedback on insight accuracy.

## Evaluation Plan

Evaluate at three levels:

- Feature validity: are transcripts, speakers, timing, and overlap accurate?
- Label validity: do human raters agree with middle-layer labels?
- Coaching usefulness: does the user understand and act on the feedback?

Metrics:

- Diarization error rate on a small hand-labeled set.
- Turn boundary F1.
- Correlation with human ratings for each high-level dimension.
- Calibration curves for model confidence.
- User-rated helpfulness and perceived accuracy.
- Longitudinal improvement over repeated sessions.

## Implementation Roadmap

### Step 1: Add Insight Schema

Create an `app/insights.py` module that accepts the existing metrics JSON and returns `insights`. Begin with versioned, explainable scoring rules.

### Step 2: Store Feature Snapshots

Persist anonymized feature JSON separately from raw audio. This will become the training set substrate.

### Step 3: Add Transcript Window Labels

Add a batch process that labels turn pairs and 30-90 second windows for:

- validation
- curiosity
- disagreement
- defensiveness
- repair
- premature advice
- emotional escalation

### Step 4: Train Baseline Models

Train calibrated logistic regression and gradient boosted models on feature snapshots. Compare against the rule system before replacing any score.

### Step 5: Add Semantic Embeddings

Use turn embeddings for follow-up relevance, topic continuity, validation paraphrases, and repair detection.

### Step 6: Build the Coaching UI

Change the primary dashboard from raw metrics to:

- top 3 strengths
- top 1-2 growth areas
- one timestamped example
- one practice suggestion
- expandable raw metrics for trust/debugging

## Product Guidance

The strongest user experience is not "your warmth is 72." It is:

- "You made space well."
- "You asked questions, but rarely followed up on emotional content."
- "When tension rose, your replies became faster and more corrective."
- "Try reflecting the feeling once before giving advice."

Scores are useful for tracking, but the product should lead with patterns and practice.

