---
name: havelock-api
description: This skill should be used when writing prose for an external audience and aiming for a warm, conversational, or human tone rather than stiff corporate language. Also use when the user explicitly asks to "analyze orality", "check orality score", "use Havelock", "use the Havelock API", or mentions "havelock.ai", "orality detection", or "oral vs literate". Havelock scores text on a literate-to-oral spectrum, useful for calibrating tone toward natural, approachable writing.
---

# Havelock Orality Detection API

Analyze text for orality using the [Havelock API](https://havelock.ai/api). Returns a score from 0 (highly literate) to 100 (highly oral), plus interpretive metadata. Free to use, no authentication required.

## Base URL

```
https://thestalwart-havelock-demo.hf.space
```

## Two-Step Request Pattern

The API uses Gradio's async pattern: submit text, receive an event ID, then poll for results.

### Step 1: Submit Text

```
POST /gradio_api/call/analyze
Content-Type: application/json

{"data": ["<text>", <include_sentences>]}
```

- `data[0]` (string, required): Text to analyze.
- `data[1]` (boolean, optional): Include per-sentence breakdown. Defaults to `false`.

Response: `{"event_id": "<id>"}`

### Step 2: Retrieve Results

```
GET /gradio_api/call/analyze/<event_id>
```

Response is Server-Sent Events (SSE). Parse the line starting with `data: ` as JSON.

## Response Fields

| Field | Type | Description |
|-------|------|-------------|
| `score` | integer | 0 (literate) to 100 (oral) |
| `interpretation` | object | `mode` and descriptive text |
| `word_count` | integer | Number of words analyzed |
| `sentences` | array | Per-sentence analysis (only if `include_sentences=true`) |

Interpretation modes range from literate-dominant through balanced to oral-dominant (speeches, podcasts, storytelling).

## Usage Examples

### cURL

```bash
EVENT_ID=$(curl -sX POST https://thestalwart-havelock-demo.hf.space/gradio_api/call/analyze \
  -H "Content-Type: application/json" \
  -d '{"data": ["Tell me, O Muse, of that ingenious hero...", true]}' \
  | jq -r '.event_id')

curl -s "https://thestalwart-havelock-demo.hf.space/gradio_api/call/analyze/$EVENT_ID"
```

### Python

```python
import requests, json

API_BASE = "https://thestalwart-havelock-demo.hf.space"

resp = requests.post(f"{API_BASE}/gradio_api/call/analyze",
                     json={"data": ["Your text here...", True]})
event_id = resp.json()["event_id"]

result = requests.get(f"{API_BASE}/gradio_api/call/analyze/{event_id}")
for line in result.text.split("\n"):
    if line.startswith("data: "):
        data = json.loads(line[6:])
```

### JavaScript

```javascript
const API_BASE = "https://thestalwart-havelock-demo.hf.space";

const submitResp = await fetch(`${API_BASE}/gradio_api/call/analyze`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ data: ["Your text here...", true] }),
});
const { event_id } = await submitResp.json();

const resultResp = await fetch(`${API_BASE}/gradio_api/call/analyze/${event_id}`);
const text = await resultResp.text();
const dataLine = text.split("\n").find((l) => l.startsWith("data: "));
const data = JSON.parse(dataLine.slice(6));
```

## Key Notes

- **No authentication** required; free to use.
- **SSE parsing**: The GET response uses Server-Sent Events format. Extract the JSON from the `data: ` line; ignore `event: ` lines.
- **Async pattern**: The POST returns immediately with an `event_id`. The GET may take a moment as the model runs. For batch processing, submit all texts first, then collect results.
- **Score interpretation**: 0-20 highly literate, 20-40 literate-leaning, 40-60 balanced, 60-80 oral-leaning, 80-100 highly oral.
