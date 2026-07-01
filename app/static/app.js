const form = document.querySelector("#uploadForm");
const fileInput = document.querySelector("#audioFile");
const statusEl = document.querySelector("#status");
const emptyState = document.querySelector("#emptyState");
const resultsEl = document.querySelector("#results");

const formatValue = (value, suffix = "") => {
  if (value === null || value === undefined || Number.isNaN(value)) return "n/a";
  if (typeof value === "number") return `${value}${suffix}`;
  return String(value);
};

const seconds = (value) => `${formatValue(value)}s`;
const percent = (value) => `${formatValue(value)}%`;

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const file = fileInput.files[0];
  if (!file) return;

  const button = form.querySelector("button");
  button.disabled = true;
  statusEl.textContent = "Uploading and analyzing. First run can take a few minutes while Whisper initializes.";

  try {
    const body = new FormData();
    body.append("file", file);
    const response = await fetch("/api/analyze", { method: "POST", body });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.detail || "Analysis failed.");
    }
    renderResults(payload);
    statusEl.textContent = "Analysis complete.";
  } catch (error) {
    statusEl.textContent = error.message;
  } finally {
    button.disabled = false;
  }
});

function renderResults(data) {
  emptyState.classList.add("hidden");
  resultsEl.classList.remove("hidden");

  document.querySelector("#fileName").textContent = data.metadata.file_name;
  document.querySelector("#headline").textContent = `${Math.round(data.summary.duration_seconds)} second conversation`;
  document.querySelector("#diarizationStatus").textContent = diarizationText(data.metadata.diarization);

  renderCards(data);
  renderSpeakerTable(data.speakers);
  renderKeyValues("#turnTaking", {
    "Total turns": data.turn_taking.turn_count,
    "Average turn": seconds(data.turn_taking.average_turn_seconds),
    "Median turn": seconds(data.turn_taking.median_turn_seconds),
    "Longest turn": seconds(data.turn_taking.longest_turn_seconds),
    "Very short responses": data.turn_taking.very_short_responses,
    "Monologues over 45s": data.turn_taking.monologues_over_45s,
    "Avg response latency": seconds(data.turn_taking.average_response_latency_seconds),
    "Fast responses under 300ms": data.turn_taking.fast_responses_under_300ms,
    "Slow responses over 2s": data.turn_taking.slow_responses_over_2s,
  });
  renderKeyValues("#language", {
    "Filler words": data.language.filler_words_total,
    "Fillers per minute": data.language.fillers_per_minute,
    "Questions": data.language.question_count,
    "Follow-up question estimate": data.language.follow_up_question_estimate,
    "Backchannels": data.language.backchannel_count,
    "Validation phrases": data.language.validation_phrase_count,
    "Advice phrases": data.language.advice_phrase_count,
    "Type-token ratio": data.language.lexical_diversity_type_token_ratio,
    "Avg sentence words": data.language.average_sentence_words,
  });
  renderKeyValues("#pauses", {
    "Total silence": seconds(data.silence_and_pauses.total_silence_seconds),
    "Silence share": percent(data.summary.silence_percent),
    "Avg between-turn pause": seconds(data.silence_and_pauses.average_between_turn_pause_seconds),
    "Long pauses over 2s": data.silence_and_pauses.long_pauses_over_2s,
    "Intra-speech pauses over 500ms": data.silence_and_pauses.intra_speech_pauses_over_500ms,
    "Intra-speech pauses over 1s": data.silence_and_pauses.intra_speech_pauses_over_1s,
  });
  renderKeyValues("#sentiment", {
    "Average": data.sentiment.average,
    "Most negative": data.sentiment.minimum,
    "Most positive": data.sentiment.maximum,
    "Ending average": data.sentiment.ending_average_last_3_turns,
    "Largest shift": data.sentiment.largest_shift,
  });
  renderInterjections(data.interjections);
  renderKeyValues("#audioQuality", {
    "Average volume": formatValue(data.audio_quality.average_volume_db, " dB"),
    "Dynamic range": formatValue(data.audio_quality.dynamic_range_db, " dB"),
    "Pitch range": formatValue(data.audio_quality.pitch_range_hz, " Hz"),
    "Pitch variability": formatValue(data.audio_quality.pitch_variability_hz, " Hz"),
    "Confidence": data.audio_quality.audio_quality_confidence,
  });
  renderTranscript(data.transcript);
}

function diarizationText(diarization) {
  if (!diarization?.enabled) {
    return `Diarization off: ${diarization?.status || "unavailable"}`;
  }
  return `Diarization: ${diarization.speaker_count} speaker estimate`;
}

function renderCards(data) {
  const cards = [
    ["Speakers", data.summary.speaker_count],
    ["Words", data.summary.total_words],
    ["Turns", data.summary.total_turns],
    ["Conversation WPM", data.summary.conversation_wpm],
    ["Silence", percent(data.summary.silence_percent)],
    ["Interjections", data.interjections.estimated_count],
    ["Fillers / min", data.language.fillers_per_minute],
    ["Questions", data.language.question_count],
  ];
  document.querySelector("#summaryCards").innerHTML = cards
    .map(
      ([label, value]) => `
        <article class="stat-card">
          <div class="label">${escapeHtml(label)}</div>
          <div class="value">${escapeHtml(value)}</div>
        </article>
      `,
    )
    .join("");
}

function renderSpeakerTable(speakers) {
  const rows = Object.entries(speakers)
    .map(
      ([speaker, stats]) => `
        <tr>
          <td>${escapeHtml(speaker)}</td>
          <td>${stats.turns}</td>
          <td>${seconds(stats.talk_time_seconds)}</td>
          <td>${percent(stats.talk_time_percent)}</td>
          <td>${stats.word_count}</td>
          <td>${stats.words_per_minute}</td>
          <td>${formatValue(stats.average_volume_db, " dB")}</td>
          <td>${formatValue(stats.average_pitch_hz, " Hz")}</td>
          <td>${stats.sentiment_average}</td>
        </tr>
      `,
    )
    .join("");
  document.querySelector("#speakerTable").innerHTML = `
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
      <tbody>${rows}</tbody>
    </table>
  `;
}

function renderKeyValues(selector, values) {
  document.querySelector(selector).innerHTML = Object.entries(values)
    .map(
      ([key, value]) => `
        <div class="kv">
          <div class="key">${escapeHtml(key)}</div>
          <div class="val">${escapeHtml(value)}</div>
        </div>
      `,
    )
    .join("");
}

function renderInterjections(interjections) {
  const note = `<p class="muted">${escapeHtml(interjections.note)}</p>`;
  if (!interjections.events.length) {
    document.querySelector("#interjections").innerHTML = `${note}<div class="kv"><div class="key">Estimated count</div><div class="val">0</div></div>`;
    return;
  }
  const events = interjections.events
    .map(
      (event) => `
        <div class="event">
          <strong>${escapeHtml(event.speaker)}</strong> at ${event.time}s
          <br />
          <span>${escapeHtml(event.type)}: “${escapeHtml(event.text)}”</span>
        </div>
      `,
    )
    .join("");
  document.querySelector("#interjections").innerHTML = `${note}${events}`;
}

function renderTranscript(turns) {
  document.querySelector("#transcript").innerHTML = turns
    .map(
      (turn) => `
        <article class="turn">
          <div class="turn-meta">
            <div class="turn-speaker">${escapeHtml(turn.speaker)}</div>
            <div>${turn.start}s - ${turn.end}s</div>
            <div>${turn.duration}s · sentiment ${turn.sentiment}</div>
          </div>
          <div>${escapeHtml(turn.text)}</div>
        </article>
      `,
    )
    .join("");
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

