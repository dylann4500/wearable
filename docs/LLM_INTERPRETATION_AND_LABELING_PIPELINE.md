# LLM Interpretation and Labeling Pipeline

The conversation intelligence stack now has two loops:

```text
audio -> raw metrics -> deterministic insight scores -> LLM context classification
        -> context-weighted priorities -> user coaching
                                      |
                                      v
                         labels + feature snapshots -> supervised model training
```

## Why The LLM Exists

The numeric ML layer can estimate variables such as warmth, balance, curiosity, and emotional regulation. Those scores are not enough on their own because context changes their meaning.

Examples:

- In a job interview, equal talk time is not always desirable; clarity and concise self-presentation may matter more.
- On a date, curiosity and warmth matter more than assertive efficiency.
- In a service interaction, clarity, patience, and emotional regulation matter more than deep emotional disclosure.
- In conflict, respectful disagreeability and repair attempts become higher priority.

The LLM layer is now part of the normal analysis flow. A completed upload automatically classifies the conversation context, reweights the significance of scores, and turns metrics into actionable narrative feedback. The deterministic scores remain preserved; the contextual layer adds `context_weight`, `priority`, and `importance` so the UI can show both the underlying score and how much that score matters in this specific conversation.

## Implemented API Routes

### Analyze A Recording

```http
POST /api/recordings
POST /api/device/recordings/raw
```

Behavior:

- Converts/transcribes/diarizes the recording.
- Computes raw metrics.
- Computes deterministic middle-layer and top-layer scores.
- Runs `app.llm_interpreter.interpret_conversation` when `AUTO_INTERPRET_ANALYSIS` is enabled.
- Applies `app.llm_interpreter.apply_contextualization`.
- Persists `result.interpretation`, `result.insights.context`, `result.insights.contextualized_scores`, and `result.insights.primary_focus`.

Disable automatic interpretation only for debugging:

```bash
AUTO_INTERPRET_ANALYSIS=0
```

### Reinterpret A Completed Recording

```http
POST /api/recordings/{recording_id}/interpret
```

Requirements:

- Recording status must be `complete`.
- Recording must have a stored analyzer result.

Behavior:

- Reads the existing result JSON.
- Runs `app.llm_interpreter.interpret_conversation`.
- Persists the output under `result.interpretation`.
- Rebuilds context-aware score weights under `result.insights.contextualized_scores`.
- Returns the updated recording.

This route is useful after changing provider settings, prompt/schema behavior, or transcript limits. It is no longer required for the normal happy path.

### Add A Curated Label

```http
POST /api/recordings/{recording_id}/labels
Content-Type: application/json
```

Example:

```json
{
  "scope": "conversation",
  "target": "warmth",
  "value": 72,
  "source": "human",
  "confidence": 0.9,
  "rationale": "Warm and validating overall."
}
```

Supported scopes:

- `conversation`
- `segment`
- `turn_pair`
- `turn`

Optional timestamp fields:

- `start_seconds`
- `end_seconds`

### List Labels For A Recording

```http
GET /api/recordings/{recording_id}/labels
```

### Export Training Rows

```http
GET /api/training/labels
GET /api/training/labels.jsonl
```

Each export row includes:

- `recording_id`
- recording source/device metadata
- deterministic raw feature snapshot
- deterministic scores
- interpretation context
- contextualized score priorities
- curated labels

This is the starting point for supervised training.

## Provider Modes

### Local Fallback

Default:

```bash
INTERPRETATION_PROVIDER=mock
```

This mode:

- Uses deterministic scores and simple transcript keyword heuristics.
- Requires no external API.
- Is stable for tests and local development.
- Produces label suggestions but should not be treated as final ground truth.

### OpenAI Responses API

Enable:

```bash
OPENAI_API_KEY=...
INTERPRETATION_PROVIDER=openai
OPENAI_INTERPRETATION_MODEL=gpt-5.4-nano
```

The code calls:

```http
POST https://api.openai.com/v1/responses
```

Request behavior:

- Uses `store: false`.
- Sends compact metrics, deterministic insights, and transcript excerpts.
- Requests a structured JSON response with `text.format`.
- Persists the structured result under `result.interpretation`.

The structured output includes:

- `context`
- `context_weighted_priorities`
- `summary`
- `strengths`
- `growth_areas`
- `action_plan`
- `label_suggestions`
- `limitations`

### Groq Chat Completions API

Enable:

```bash
GROQ_API_KEY=...
INTERPRETATION_PROVIDER=groq
GROQ_INTERPRETATION_MODEL=openai/gpt-oss-20b
```

The code calls:

```http
POST https://api.groq.com/openai/v1/chat/completions
```

Request behavior:

- Sends compact metrics, deterministic insights, and transcript excerpts.
- Requests JSON object output.
- Normalizes the response into the same interpretation shape used by the UI.
- Falls back to the deterministic local interpreter if the provider fails and `INTERPRETATION_FALLBACK_ON_ERROR=1`.

## Validation Plan

### 1. Raw Signal Validation

Before trusting context or emotional variables:

- Spot-check transcripts against audio.
- Check diarization quality.
- Verify turn boundaries.
- Verify interruption/latency estimates.
- Track audio-quality confidence.

### 2. LLM Context Validation

Create a small hand-labeled set with conversation contexts:

- interview
- date
- service interaction
- work meeting
- supportive personal conversation
- conflict/disagreement
- casual social

Measure:

- context accuracy
- confusion matrix
- confidence calibration
- cases where context is genuinely ambiguous

### 3. Label Quality Validation

For each target variable:

- Use two independent human raters on a subset.
- Measure agreement.
- Compare LLM suggestions to human labels.
- Keep labels with disagreement visible instead of flattening prematurely.

### 4. Model Validation

Train baseline models from exported JSONL:

- Ridge
- ElasticNet
- histogram gradient boosting
- Extra Trees

Compare against deterministic scoring:

- MAE
- R2/correlation
- calibration by confidence
- per-context performance
- feature ablations

### 5. Product Validation

The final test is not just model accuracy. It is whether users understand and can act on the feedback.

Measure:

- perceived accuracy
- usefulness
- whether the suggested practice is concrete
- whether repeated sessions improve target variables
