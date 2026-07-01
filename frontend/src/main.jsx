import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Activity,
  AudioLines,
  Brain,
  CheckCircle2,
  Clock3,
  HardDriveUpload,
  LoaderCircle,
  MessageSquareQuote,
  Mic2,
  Pause,
  Radio,
  RefreshCw,
  Sparkles,
  Upload,
  Users,
  Volume2,
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
      const response = await fetch(apiUrl("/api/recordings"));
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail || "Could not load recordings.");
      setRecordings(payload);
      if (!selectedId && payload.length > 0) setSelectedId(payload[0].id);
    } catch (error) {
      if (!options.quiet) setStatus(error.message);
    } finally {
      if (!options.quiet) setIsRefreshing(false);
    }
  }

  async function refreshRecording(id, options = {}) {
    try {
      const response = await fetch(apiUrl(`/api/recordings/${id}`));
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail || "Could not load recording.");
      setSelectedRecording(payload);
    } catch (error) {
      if (!options.quiet) setStatus(error.message);
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
      const response = await fetch(apiUrl("/api/recordings"), { method: "POST", body });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail || "Upload failed.");
      setSelectedId(payload.id);
      setSelectedRecording(payload);
      setFile(null);
      await refreshRecordings({ quiet: true });
      setStatus("Recording uploaded. Analysis is running in the background.");
    } catch (error) {
      setStatus(error.message);
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
          <Results data={selectedRecording.result} />
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

function Results({ data }) {
  const summaryValues = {
    ...data.summary,
    interjections: data.interjections.estimated_count,
    fillers_per_minute: data.language.fillers_per_minute,
    question_count: data.language.question_count,
  };

  return (
    <div className="results">
      <header className="resultHeader">
        <div>
          <p className="eyebrow">{data.metadata.file_name}</p>
          <h2>{Math.round(data.summary.duration_seconds)} second conversation</h2>
        </div>
        <div className="badge">{diarizationLabel(data.metadata.diarization)}</div>
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

      <Panel title="Speaker Breakdown">
        <SpeakerTable speakers={data.speakers} />
      </Panel>

      <section className="metricGrid">
        <MetricPanel icon={Clock3} title="Turn Taking" values={{
          "Total turns": data.turn_taking.turn_count,
          "Average turn": sec(data.turn_taking.average_turn_seconds),
          "Median turn": sec(data.turn_taking.median_turn_seconds),
          "Longest turn": sec(data.turn_taking.longest_turn_seconds),
          "Very short responses": data.turn_taking.very_short_responses,
          "Monologues over 45s": data.turn_taking.monologues_over_45s,
          "Avg response latency": sec(data.turn_taking.average_response_latency_seconds),
          "Fast responses under 300ms": data.turn_taking.fast_responses_under_300ms,
        }} />
        <MetricPanel icon={MessageSquareQuote} title="Language" values={{
          "Filler words": data.language.filler_words_total,
          "Fillers per minute": data.language.fillers_per_minute,
          "Questions": data.language.question_count,
          "Follow-up estimate": data.language.follow_up_question_estimate,
          "Backchannels": data.language.backchannel_count,
          "Validation phrases": data.language.validation_phrase_count,
          "Advice phrases": data.language.advice_phrase_count,
          "Type-token ratio": data.language.lexical_diversity_type_token_ratio,
        }} />
        <MetricPanel icon={Pause} title="Pauses" values={{
          "Total silence": sec(data.silence_and_pauses.total_silence_seconds),
          "Silence share": pct(data.summary.silence_percent),
          "Avg between-turn pause": sec(data.silence_and_pauses.average_between_turn_pause_seconds),
          "Long pauses over 2s": data.silence_and_pauses.long_pauses_over_2s,
          "Intra-speech pauses >500ms": data.silence_and_pauses.intra_speech_pauses_over_500ms,
        }} />
        <MetricPanel icon={Volume2} title="Audio Quality" values={{
          "Average volume": db(data.audio_quality.average_volume_db),
          "Dynamic range": db(data.audio_quality.dynamic_range_db),
          "Pitch range": hz(data.audio_quality.pitch_range_hz),
          "Pitch variability": hz(data.audio_quality.pitch_variability_hz),
          "Confidence": data.audio_quality.audio_quality_confidence,
        }} />
      </section>

      <section className="metricGrid">
        <Panel title="Sentiment">
          <KeyValues values={{
            "Average": data.sentiment.average,
            "Most negative": data.sentiment.minimum,
            "Most positive": data.sentiment.maximum,
            "Ending average": data.sentiment.ending_average_last_3_turns,
            "Largest shift": data.sentiment.largest_shift,
          }} />
        </Panel>
        <Panel title="Interjections">
          <p className="panelNote">{data.interjections.note}</p>
          {data.interjections.events.length === 0 ? (
            <KeyValues values={{ "Estimated count": 0 }} />
          ) : (
            <div className="eventList">
              {data.interjections.events.map((event, index) => (
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
          {data.transcript.map((turn, index) => (
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

const sec = (value) => format(value, "s");
const pct = (value) => format(value, "%");
const db = (value) => format(value, " dB");
const hz = (value) => format(value, " Hz");

createRoot(document.getElementById("root")).render(<App />);
