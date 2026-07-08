import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Activity,
  AudioLines,
  Brain,
  CheckCircle2,
  Clock3,
  Database,
  FileJson,
  HardDriveUpload,
  Layers3,
  LoaderCircle,
  MessageSquareQuote,
  Mic2,
  Pause,
  Radio,
  RefreshCw,
  Save,
  SlidersHorizontal,
  Sparkles,
  Tags,
  Upload,
  Users,
  Volume2,
  WandSparkles,
  Workflow,
  XCircle,
} from "lucide-react";
import "./styles.css";

const cards = [
  ["Speakers", "speaker_count", Users],
  ["Words", "total_words", MessageSquareQuote],
  ["Turns", "total_turns", Activity],
  ["Conversation WPM", "conversation_wpm", AudioLines],
  ["Silence", "silence_percent", Pause, "%"],
  ["Interjections", "interjections", Radio],
  ["Fillers / min", "fillers_per_minute", Brain],
  ["Questions", "question_count", Sparkles],
];

const API_BASE_URL = (import.meta.env.VITE_API_BASE_URL || "").replace(/\/$/, "");
const apiUrl = (path) => `${API_BASE_URL}${path}`;

async function fetchJson(path, options) {
  const response = await fetch(apiUrl(path), options);
  const contentType = response.headers.get("content-type") || "";
  const payload = contentType.includes("application/json") ? await response.json() : null;
  if (!payload) {
    throw new Error("Backend API did not return JSON.");
  }
  if (!response.ok) {
    throw new Error(payload?.detail || `API request failed with status ${response.status}.`);
  }
  return payload;
}

function App() {
  const [file, setFile] = useState(null);
  const [recordings, setRecordings] = useState([]);
  const [selectedId, setSelectedId] = useState(null);
  const [selectedRecording, setSelectedRecording] = useState(null);
  const [status, setStatus] = useState("Ready for a wearable or browser recording.");
  const [isUploading, setIsUploading] = useState(false);
  const [isRefreshing, setIsRefreshing] = useState(false);

  const hasActiveJob = useMemo(
    () => recordings.some((recording) => ["uploaded", "processing"].includes(recording.status)),
    [recordings],
  );

  useEffect(() => {
    refreshRecordings();
  }, []);

  useEffect(() => {
    if (!selectedId) {
      setSelectedRecording(null);
      return;
    }
    refreshRecording(selectedId);
  }, [selectedId]);

  useEffect(() => {
    if (!hasActiveJob && !selectedId) return;
    const interval = window.setInterval(() => {
      refreshRecordings({ quiet: true });
      if (selectedId) refreshRecording(selectedId, { quiet: true });
    }, 2500);
    return () => window.clearInterval(interval);
  }, [hasActiveJob, selectedId]);

  async function refreshRecordings(options = {}) {
    if (!options.quiet) setIsRefreshing(true);
    try {
      const payload = await fetchJson("/api/recordings");
      setRecordings(payload);
      if (!selectedId && payload.length > 0) setSelectedId(payload[0].id);
    } catch (error) {
      if (!options.quiet) setStatus(apiErrorMessage(error));
    } finally {
      if (!options.quiet) setIsRefreshing(false);
    }
  }

  async function refreshRecording(id, options = {}) {
    try {
      const payload = await fetchJson(`/api/recordings/${id}`);
      setSelectedRecording(payload);
    } catch (error) {
      if (!options.quiet) setStatus(apiErrorMessage(error));
    }
  }

  async function analyze(event) {
    event.preventDefault();
    if (!file) return;
    setIsUploading(true);
    setStatus("Uploading recording and starting analysis.");

    try {
      const body = new FormData();
      body.append("file", file);
      const payload = await fetchJson("/api/recordings", { method: "POST", body });
      setSelectedId(payload.id);
      setSelectedRecording(payload);
      setFile(null);
      await refreshRecordings({ quiet: true });
      setStatus("Recording uploaded. Analysis is running in the background.");
    } catch (error) {
      setStatus(apiErrorMessage(error));
    } finally {
      setIsUploading(false);
    }
  }

  return (
    <main className="shell">
      <aside className="sidebar">
        <div>
          <p className="eyebrow">Wearable speech analytics</p>
          <h1>Conversation analyzer</h1>
        </div>

        <form className="uploadBox" onSubmit={analyze}>
          <label htmlFor="audioFile">Browser test upload</label>
          <input
            id="audioFile"
            type="file"
            accept="audio/*,.mp3"
            onChange={(event) => setFile(event.target.files?.[0] || null)}
          />
          <button type="submit" disabled={!file || isUploading}>
            <Upload size={18} />
            Upload recording
          </button>
        </form>

        <div className="status">{status}</div>

        <section className="recordingList">
          <div className="sectionHeader">
            <h2>Recordings</h2>
            <button type="button" onClick={() => refreshRecordings()} disabled={isRefreshing} aria-label="Refresh recordings">
              <RefreshCw size={16} />
            </button>
          </div>
          {recordings.length === 0 ? (
            <p className="smallNote">Wearable uploads and browser test uploads will appear here.</p>
          ) : (
            <div className="recordingButtons">
              {recordings.map((recording) => (
                <button
                  type="button"
                  className={recording.id === selectedId ? "recordingButton active" : "recordingButton"}
                  key={recording.id}
                  onClick={() => setSelectedId(recording.id)}
                >
                  <span>{sourceIcon(recording.source)} {recording.original_filename}</span>
                  <strong>{statusLabel(recording.status)}</strong>
                </button>
              ))}
            </div>
          )}
        </section>

        <section className="sideNote">
          <h2>Wearable MVP</h2>
          <p>
            The XIAO can upload finished SD-card recordings to the new device endpoint.
            This screen follows each upload from arrival through processing to completed
            metrics.
          </p>
        </section>
      </aside>

      <section className="content">
        {!selectedRecording ? (
          <EmptyState />
        ) : selectedRecording.result ? (
          <Results
            recording={selectedRecording}
            data={selectedRecording.result}
            onRefresh={() => refreshRecording(selectedRecording.id, { quiet: true })}
            setStatus={setStatus}
          />
        ) : (
          <RecordingState recording={selectedRecording} />
        )}
      </section>
    </main>
  );
}

function EmptyState() {
  return (
    <div className="empty">
      <Mic2 size={38} />
      <h2>Upload a conversation to see metrics.</h2>
      <p>Speaker analytics, timing, interjections, transcript turns, sentiment, and acoustic summaries will appear here.</p>
    </div>
  );
}

function RecordingState({ recording }) {
  const Icon = recording.status === "failed"
    ? XCircle
    : recording.status === "complete"
      ? CheckCircle2
      : recording.status === "processing"
        ? LoaderCircle
        : HardDriveUpload;

  return (
    <div className="jobState">
      <Icon size={42} className={recording.status === "processing" ? "spin" : ""} />
      <p className="eyebrow">{recording.source} upload</p>
      <h2>{recording.original_filename}</h2>
      <KeyValues values={{
        "Status": statusLabel(recording.status),
        "Device": recording.device_id || "browser",
        "Created": formatDate(recording.created_at),
        "Updated": formatDate(recording.updated_at),
        "Error": recording.error,
      }} />
    </div>
  );
}

function Results({ recording, data, onRefresh, setStatus }) {
  const metadata = data.metadata || {};
  const summary = data.summary || {};
  const speakers = data.speakers || {};
  const turnTaking = data.turn_taking || {};
  const language = data.language || {};
  const pauses = data.silence_and_pauses || {};
  const audioQuality = data.audio_quality || {};
  const sentiment = data.sentiment || {};
  const interjections = data.interjections || { events: [], estimated_count: 0 };
  const transcript = data.transcript || [];
  const insights = data.insights || {};
  const interpretation = data.interpretation || null;
  const summaryValues = {
    ...summary,
    interjections: interjections.estimated_count,
    fillers_per_minute: language.fillers_per_minute,
    question_count: language.question_count,
  };

  return (
    <div className="results">
      <header className="resultHeader">
        <div>
          <p className="eyebrow">{metadata.file_name || "Recording"}</p>
          <h2>{Math.round(summary.duration_seconds || metadata.duration_seconds || 0)} second conversation</h2>
        </div>
        <div className="badge">{diarizationLabel(metadata.diarization)}</div>
      </header>

      <section className="cardGrid">
        {cards.map(([label, key, Icon, suffix]) => (
          <article className="statCard" key={key}>
            <div className="statTop">
              <span>{label}</span>
              <Icon size={18} />
            </div>
            <strong>{format(summaryValues[key], suffix)}</strong>
          </article>
        ))}
      </section>

      <PipelineExplorer
        recording={recording}
        insights={insights}
        interpretation={interpretation}
        onRefresh={onRefresh}
        setStatus={setStatus}
      />

      <Panel title="Speaker Breakdown">
        <SpeakerTable speakers={speakers} />
      </Panel>

      <section className="metricGrid">
        <MetricPanel icon={Clock3} title="Turn Taking" values={{
          "Total turns": turnTaking.turn_count,
          "Average turn": sec(turnTaking.average_turn_seconds),
          "Median turn": sec(turnTaking.median_turn_seconds),
          "Longest turn": sec(turnTaking.longest_turn_seconds),
          "Very short responses": turnTaking.very_short_responses,
          "Monologues over 45s": turnTaking.monologues_over_45s,
          "Avg response latency": sec(turnTaking.average_response_latency_seconds),
          "Fast responses under 300ms": turnTaking.fast_responses_under_300ms,
        }} />
        <MetricPanel icon={MessageSquareQuote} title="Language" values={{
          "Filler words": language.filler_words_total,
          "Fillers per minute": language.fillers_per_minute,
          "Questions": language.question_count,
          "Follow-up estimate": language.follow_up_question_estimate,
          "Backchannels": language.backchannel_count,
          "Validation phrases": language.validation_phrase_count,
          "Advice phrases": language.advice_phrase_count,
          "Type-token ratio": language.lexical_diversity_type_token_ratio,
        }} />
        <MetricPanel icon={Pause} title="Pauses" values={{
          "Total silence": sec(pauses.total_silence_seconds),
          "Silence share": pct(summary.silence_percent),
          "Avg between-turn pause": sec(pauses.average_between_turn_pause_seconds),
          "Long pauses over 2s": pauses.long_pauses_over_2s,
          "Intra-speech pauses >500ms": pauses.intra_speech_pauses_over_500ms,
        }} />
        <MetricPanel icon={Volume2} title="Audio Quality" values={{
          "Average volume": db(audioQuality.average_volume_db),
          "Dynamic range": db(audioQuality.dynamic_range_db),
          "Pitch range": hz(audioQuality.pitch_range_hz),
          "Pitch variability": hz(audioQuality.pitch_variability_hz),
          "Confidence": audioQuality.audio_quality_confidence,
        }} />
      </section>

      <section className="metricGrid">
        <Panel title="Sentiment">
          <KeyValues values={{
            "Average": sentiment.average,
            "Most negative": sentiment.minimum,
            "Most positive": sentiment.maximum,
            "Ending average": sentiment.ending_average_last_3_turns,
            "Largest shift": sentiment.largest_shift,
          }} />
        </Panel>
        <Panel title="Interjections">
          <p className="panelNote">{interjections.note || "No interjection events available."}</p>
          {(interjections.events || []).length === 0 ? (
            <KeyValues values={{ "Estimated count": 0 }} />
          ) : (
            <div className="eventList">
              {interjections.events.map((event, index) => (
                <div className="event" key={`${event.time}-${index}`}>
                  <strong>{event.speaker}</strong> at {event.time}s
                  <span>{event.type}: "{event.text}"</span>
                </div>
              ))}
            </div>
          )}
        </Panel>
      </section>

      <Panel title="Transcript">
        <div className="transcript">
          {transcript.length === 0 ? (
            <p className="panelNote">No transcript turns available for this recording.</p>
          ) : transcript.map((turn, index) => (
            <article className="turn" key={`${turn.start}-${index}`}>
              <div className="turnMeta">
                <strong>{turn.speaker}</strong>
                <span>{turn.start}s - {turn.end}s</span>
                <span>{turn.duration}s · sentiment {turn.sentiment}</span>
              </div>
              <p>{turn.text}</p>
            </article>
          ))}
        </div>
      </Panel>
    </div>
  );
}

function PipelineExplorer({ recording, insights, interpretation, onRefresh, setStatus }) {
  const [isInterpreting, setIsInterpreting] = useState(false);
  const [labels, setLabels] = useState([]);
  const [isLoadingLabels, setIsLoadingLabels] = useState(false);
  const [labelDraft, setLabelDraft] = useState({
    scope: "conversation",
    target: "warmth",
    value: "",
    confidence: "0.8",
    rationale: "",
  });

  useEffect(() => {
    loadLabels({ quiet: true });
  }, [recording.id]);

  async function runInterpretation() {
    setIsInterpreting(true);
    setStatus("Rerunning context interpretation and refreshing context-aware priorities.");
    try {
      await fetchJson(`/api/recordings/${recording.id}/interpret`, { method: "POST" });
      await onRefresh();
      await loadLabels({ quiet: true });
      setStatus("Interpretation refreshed. Context-aware priorities are updated.");
    } catch (error) {
      setStatus(apiErrorMessage(error));
    } finally {
      setIsInterpreting(false);
    }
  }

  async function loadLabels(options = {}) {
    if (!options.quiet) setIsLoadingLabels(true);
    try {
      const payload = await fetchJson(`/api/recordings/${recording.id}/labels`);
      setLabels(payload);
    } catch (error) {
      if (!options.quiet) setStatus(apiErrorMessage(error));
    } finally {
      if (!options.quiet) setIsLoadingLabels(false);
    }
  }

  async function saveLabel(event) {
    event.preventDefault();
    const value = parseLabelValue(labelDraft.value);
    if (value === "") return;
    try {
      await fetchJson(`/api/recordings/${recording.id}/labels`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          scope: labelDraft.scope,
          target: labelDraft.target,
          value,
          source: "human",
          confidence: Number(labelDraft.confidence),
          rationale: labelDraft.rationale || "Manual UI label.",
        }),
      });
      setLabelDraft((draft) => ({ ...draft, value: "", rationale: "" }));
      await loadLabels({ quiet: true });
      setStatus("Label saved. Training export now includes this curated row.");
    } catch (error) {
      setStatus(apiErrorMessage(error));
    }
  }

  const hasInsights = Object.keys(insights?.scores || {}).length > 0;

  return (
    <section className="pipeline">
      <div className="pipelineHeader">
        <div>
          <p className="eyebrow">ML pipeline</p>
          <h2>From raw signals to coaching</h2>
        </div>
        <button type="button" className="primaryAction" onClick={runInterpretation} disabled={isInterpreting || !hasInsights}>
          {isInterpreting ? <LoaderCircle size={18} className="spin" /> : <WandSparkles size={18} />}
          Reinterpret
        </button>
      </div>

      <PipelineFlow hasInsights={hasInsights} hasInterpretation={Boolean(interpretation)} labelCount={labels.length} />

      {!hasInsights ? (
        <Panel title="Insight Layer Missing">
          <p className="panelNote">This recording was analyzed before the new insight layer existed. Re-run analysis, then interpret it.</p>
        </Panel>
      ) : (
        <>
          <section className="metricGrid">
            <ContextFocusPanel insights={insights} interpretation={interpretation} />
            <InsightScorePanel scores={insights.contextualized_scores || insights.scores || {}} />
          </section>

          <section className="metricGrid">
            <InterpretationPanel interpretation={interpretation} runInterpretation={runInterpretation} isInterpreting={isInterpreting} />
            <MiddleLayerPanel middle={insights.middle_layer || {}} />
          </section>

          <section className="metricGrid">
            <RawFeaturePanel features={insights.raw_feature_snapshot || {}} />
            <LabelPanel
              labels={labels}
              isLoadingLabels={isLoadingLabels}
              labelDraft={labelDraft}
              setLabelDraft={setLabelDraft}
              saveLabel={saveLabel}
              loadLabels={loadLabels}
              interpretation={interpretation}
            />
            <TrainingExportPanel />
          </section>
        </>
      )}
    </section>
  );
}

function PipelineFlow({ hasInsights, hasInterpretation, labelCount }) {
  const steps = [
    ["Raw metrics", "Transcript, timing, prosody, language counts", true, Activity],
    ["Middle layer", "Balance, listening, reactivity, clarity", hasInsights, Layers3],
    ["Top scores", "Warmth, curiosity, regulation, generosity", hasInsights, SlidersHorizontal],
    ["LLM context", "Auto-generated context and weighted priorities", hasInterpretation, Workflow],
    ["Labels", `${labelCount} curated labels saved`, labelCount > 0, Database],
  ];
  return (
    <div className="pipelineFlow">
      {steps.map(([title, detail, active, Icon]) => (
        <div className={active ? "pipelineStep active" : "pipelineStep"} key={title}>
          <Icon size={18} />
          <strong>{title}</strong>
          <span>{detail}</span>
        </div>
      ))}
    </div>
  );
}

function ContextFocusPanel({ insights, interpretation }) {
  const context = insights.context || interpretation?.context || {};
  const brief = context.brief || interpretation?.discussion_brief || interpretation?.summary;
  const focus = insights.primary_focus || [];
  const strengths = insights.contextual_strengths || [];
  return (
    <Panel title={<span className="titleWithIcon"><Workflow size={18} />Context-Aware Focus</span>}>
      <div className="contextBox">
        <div>
          <span>Context</span>
          <strong>{humanize(context.type || "pending")}</strong>
        </div>
        <div>
          <span>Confidence</span>
          <strong>{format(context.confidence)}</strong>
        </div>
        <div>
          <span>Source</span>
          <strong>{interpretation?.provider || "pending"}</strong>
        </div>
      </div>
      {brief && (
        <div className="briefBox">
          <span>Discussion brief</span>
          <strong>{brief}</strong>
        </div>
      )}
      <p className="panelNote">{context.why_it_matters || "Context-aware priorities appear after the analysis interpretation step completes."}</p>
      <div className="miniList">
        <strong>Highest-priority growth areas</strong>
        {focus.length === 0 ? (
          <span>No contextual priorities yet.</span>
        ) : focus.map((item) => (
          <div className="priorityItem" key={item.variable}>
            <span>{humanize(item.variable)} · {item.importance}</span>
            <b>{format(item.priority)}</b>
          </div>
        ))}
      </div>
      <div className="miniList">
        <strong>Contextual strengths</strong>
        {strengths.length === 0 ? (
          <span>No contextual strengths yet.</span>
        ) : strengths.map((item) => (
          <div className="priorityItem" key={item.variable}>
            <span>{humanize(item.variable)} · {item.importance}</span>
            <b>{format(item.score)}</b>
          </div>
        ))}
      </div>
    </Panel>
  );
}

function InsightScorePanel({ scores }) {
  return (
    <Panel title={<span className="titleWithIcon"><SlidersHorizontal size={18} />Contextualized Scores</span>}>
      <div className="scoreList">
        {Object.entries(scores).map(([name, item]) => (
          <ScoreRow key={name} name={name} item={item} />
        ))}
      </div>
    </Panel>
  );
}

function MiddleLayerPanel({ middle }) {
  return (
    <Panel title={<span className="titleWithIcon"><Layers3 size={18} />Middle-Layer Behaviors</span>}>
      <div className="scoreList compact">
        {Object.entries(middle).map(([name, item]) => (
          <ScoreRow key={name} name={name} item={item} />
        ))}
      </div>
    </Panel>
  );
}

function ScoreRow({ name, item }) {
  const score = item?.score;
  const numericScore = Number(score || 0);
  const details = [];
  if (item?.confidence !== undefined) details.push(`confidence ${format(item.confidence)}`);
  if (item?.context_weight !== undefined) details.push(`weight ${format(item.context_weight)}`);
  if (item?.priority !== undefined) details.push(`priority ${format(item.priority)}`);
  if (item?.importance) details.push(item.importance);
  return (
    <div className="scoreRow">
      <div>
        <strong>{humanize(name)}</strong>
        <span>{details.join(" · ")}</span>
      </div>
      <div className="scoreMeter" aria-label={`${humanize(name)} score ${numericScore}`}>
        <span style={{ width: `${Math.max(0, Math.min(100, numericScore))}%` }} />
      </div>
      <b>{format(score)}</b>
    </div>
  );
}

function InterpretationPanel({ interpretation, runInterpretation, isInterpreting }) {
  if (!interpretation) {
    return (
      <Panel title={<span className="titleWithIcon"><WandSparkles size={18} />Context Interpretation</span>}>
        <p className="panelNote">New analyses run interpretation automatically. Use Reinterpret after changing provider settings or prompts.</p>
        <button type="button" className="secondaryAction" onClick={runInterpretation} disabled={isInterpreting}>
          {isInterpreting ? <LoaderCircle size={16} className="spin" /> : <WandSparkles size={16} />}
          Reinterpret
        </button>
      </Panel>
    );
  }
  const context = interpretation.context || {};
  const brief = context.brief || interpretation.discussion_brief;
  return (
    <Panel title={<span className="titleWithIcon"><WandSparkles size={18} />Context Interpretation</span>}>
      <div className="contextBox">
        <div>
          <span>Context</span>
          <strong>{humanize(context.type || "unknown")}</strong>
        </div>
        <div>
          <span>Confidence</span>
          <strong>{format(context.confidence)}</strong>
        </div>
        <div>
          <span>Provider</span>
          <strong>{interpretation.provider || "local"}</strong>
        </div>
      </div>
      {brief && (
        <div className="briefBox">
          <span>Discussion brief</span>
          <strong>{brief}</strong>
        </div>
      )}
      <p className="analysisText">{interpretation.summary}</p>
      <p className="panelNote">{context.why_it_matters}</p>
      <ListBlock title="Action plan" items={interpretation.action_plan || []} />
      <PriorityList priorities={interpretation.context_weighted_priorities || []} />
    </Panel>
  );
}

function PriorityList({ priorities }) {
  if (!priorities.length) return null;
  return (
    <div className="miniList">
      <strong>Context-weighted priorities</strong>
      {priorities.slice(0, 5).map((item) => (
        <div className="priorityItem" key={item.variable}>
          <span>{humanize(item.variable)}</span>
          <b>{format(item.priority)}</b>
        </div>
      ))}
    </div>
  );
}

function RawFeaturePanel({ features }) {
  return (
    <Panel title={<span className="titleWithIcon"><FileJson size={18} />Raw Feature Snapshot</span>}>
      <div className="featureGrid">
        {Object.entries(features).map(([key, value]) => (
          <div className="featureCell" key={key}>
            <span>{humanize(key)}</span>
            <strong>{format(value)}</strong>
          </div>
        ))}
      </div>
    </Panel>
  );
}

function LabelPanel({ labels, isLoadingLabels, labelDraft, setLabelDraft, saveLabel, loadLabels, interpretation }) {
  const suggestions = interpretation?.label_suggestions || [];
  return (
    <Panel title={<span className="titleWithIcon"><Tags size={18} />Curated Labels</span>}>
      <form className="labelForm" onSubmit={saveLabel}>
        <select value={labelDraft.scope} onChange={(event) => setLabelDraft((draft) => ({ ...draft, scope: event.target.value }))}>
          <option value="conversation">Conversation</option>
          <option value="segment">Segment</option>
          <option value="turn_pair">Turn pair</option>
          <option value="turn">Turn</option>
        </select>
        <select value={labelDraft.target} onChange={(event) => setLabelDraft((draft) => ({ ...draft, target: event.target.value }))}>
          <option value="warmth">Warmth</option>
          <option value="curiosity">Curiosity</option>
          <option value="conversational_balance">Conversational balance</option>
          <option value="respectful_disagreeability">Respectful disagreeability</option>
          <option value="emotional_regulation">Emotional regulation</option>
          <option value="clarity">Clarity</option>
          <option value="context_type">Context type</option>
        </select>
        <input
          value={labelDraft.value}
          placeholder="Value"
          onChange={(event) => setLabelDraft((draft) => ({ ...draft, value: event.target.value }))}
        />
        <input
          type="number"
          min="0"
          max="1"
          step="0.05"
          value={labelDraft.confidence}
          aria-label="Label confidence"
          onChange={(event) => setLabelDraft((draft) => ({ ...draft, confidence: event.target.value }))}
        />
        <textarea
          value={labelDraft.rationale}
          placeholder="Rationale"
          onChange={(event) => setLabelDraft((draft) => ({ ...draft, rationale: event.target.value }))}
        />
        <button type="submit" className="secondaryAction">
          <Save size={16} />
          Save label
        </button>
      </form>

      <div className="labelHeader">
        <strong>Saved labels</strong>
        <button type="button" onClick={() => loadLabels()} disabled={isLoadingLabels}>
          <RefreshCw size={14} />
        </button>
      </div>
      {labels.length === 0 ? (
        <p className="panelNote">No curated labels saved yet.</p>
      ) : (
        <div className="labelList">
          {labels.map((label) => (
            <div className="labelItem" key={label.id}>
              <strong>{humanize(label.target)}: {format(label.value)}</strong>
              <span>{label.scope} · {label.source} · confidence {format(label.confidence)}</span>
              <p>{label.rationale}</p>
            </div>
          ))}
        </div>
      )}

      {suggestions.length > 0 && (
        <div className="miniList">
          <strong>LLM label suggestions</strong>
          {suggestions.slice(0, 6).map((item, index) => (
            <div className="suggestionItem" key={`${item.target}-${index}`}>
              <span>{humanize(item.target)}: {format(item.value)}</span>
              <small>{item.rationale}</small>
            </div>
          ))}
        </div>
      )}
    </Panel>
  );
}

function TrainingExportPanel() {
  return (
    <Panel title={<span className="titleWithIcon"><Database size={18} />Training Dataset Export</span>}>
      <p className="panelNote">
        Export rows combine raw feature snapshots, deterministic scores, interpretation context, and curated labels.
      </p>
      <div className="exportActions">
        <a className="secondaryLink" href={apiUrl("/api/training/labels")} target="_blank" rel="noreferrer">
          <FileJson size={16} />
          View JSON
        </a>
        <a className="secondaryLink" href={apiUrl("/api/training/labels.jsonl")} target="_blank" rel="noreferrer">
          <Database size={16} />
          Download JSONL
        </a>
      </div>
      <div className="pipelineNote">
        <strong>Training loop</strong>
        <span>Upload conversations, run interpretation, add human labels, export JSONL, then train Ridge/ElasticNet/tree models against real labels.</span>
      </div>
    </Panel>
  );
}

function ListBlock({ title, items }) {
  if (!items.length) return null;
  return (
    <div className="miniList">
      <strong>{title}</strong>
      {items.map((item, index) => <span key={`${item}-${index}`}>{item}</span>)}
    </div>
  );
}

function Panel({ title, children }) {
  return (
    <section className="panel">
      <h3>{title}</h3>
      {children}
    </section>
  );
}

function MetricPanel({ icon: Icon, title, values }) {
  return (
    <Panel title={<span className="titleWithIcon"><Icon size={18} />{title}</span>}>
      <KeyValues values={values} />
    </Panel>
  );
}

function KeyValues({ values }) {
  return (
    <div className="kvList">
      {Object.entries(values).map(([key, value]) => (
        <div className="kv" key={key}>
          <span>{key}</span>
          <strong>{format(value)}</strong>
        </div>
      ))}
    </div>
  );
}

function SpeakerTable({ speakers }) {
  return (
    <div className="tableWrap">
      <table>
        <thead>
          <tr>
            <th>Speaker</th>
            <th>Turns</th>
            <th>Talk time</th>
            <th>Share</th>
            <th>Words</th>
            <th>WPM</th>
            <th>Volume</th>
            <th>Pitch</th>
            <th>Sentiment</th>
          </tr>
        </thead>
        <tbody>
          {Object.entries(speakers).map(([speaker, stats]) => (
            <tr key={speaker}>
              <td>{speaker}</td>
              <td>{stats.turns}</td>
              <td>{sec(stats.talk_time_seconds)}</td>
              <td>{pct(stats.talk_time_percent)}</td>
              <td>{stats.word_count}</td>
              <td>{stats.words_per_minute}</td>
              <td>{db(stats.average_volume_db)}</td>
              <td>{hz(stats.average_pitch_hz)}</td>
              <td>{stats.sentiment_average}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function diarizationLabel(status) {
  if (!status?.enabled) return `Diarization fallback: ${status?.status || "unavailable"}`;
  const backend = status.backend || "diarization";
  if (backend === "resemblyzer" && status.fallback_reason) {
    return `resemblyzer: ${status.speaker_count || "?"} speakers · pyannote ${status.fallback_reason.status}`;
  }
  return `${backend}: ${status.speaker_count || "?"} speakers`;
}

function parseLabelValue(value) {
  const trimmed = String(value).trim();
  if (!trimmed) return "";
  if (trimmed === "true") return true;
  if (trimmed === "false") return false;
  const numeric = Number(trimmed);
  return Number.isNaN(numeric) ? trimmed : numeric;
}

function humanize(value) {
  return String(value || "")
    .replaceAll("_", " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function format(value, suffix = "") {
  if (value === null || value === undefined || Number.isNaN(value)) return "n/a";
  return `${value}${suffix}`;
}

function statusLabel(status) {
  const labels = {
    uploaded: "Uploaded",
    processing: "Processing",
    complete: "Complete",
    failed: "Failed",
  };
  return labels[status] || status;
}

function sourceIcon(source) {
  return source === "device" ? "Wearable" : "Browser";
}

function formatDate(value) {
  if (!value) return "n/a";
  return new Date(value).toLocaleString();
}

function apiErrorMessage(error) {
  if (!API_BASE_URL && window.location.hostname.includes("vercel.app")) {
    return "Frontend is deployed, but no backend API is connected yet. Set VITE_API_BASE_URL in Vercel after deploying the backend.";
  }
  return error.message;
}

const sec = (value) => format(value, "s");
const pct = (value) => format(value, "%");
const db = (value) => format(value, " dB");
const hz = (value) => format(value, " Hz");

createRoot(document.getElementById("root")).render(<App />);
