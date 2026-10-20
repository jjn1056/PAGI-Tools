# Webhook Receiver

A whip-it-up application: GitHub-style webhook deliveries, verified by HMAC
over the raw body, appended to a JSONL log, with a status page and a JSON
view of the log. The kind of thing you write in one sitting because a
service needs somewhere to post to this afternoon.

It was written in one sitting with a clock running, as part of the
whipupitude gap analysis, by someone who had just spent most of an hour
reading the Tools docs (`PAGI::Tools`, the gut-check, `PAGI::Request`),
and kept as written apart from the house brace style (one bug fixed:
`use v5.40` turns on the `bitwise` feature, so string xor is `^.`). The
same program in Flask and in Go's `net/http` is at the end of this README,
driven with the same curl sequence.

## Run

```bash
WEBHOOK_SECRET=s3cret pagi-server --app examples/webhook-receiver/app.pl --port 5000
```

The log defaults to `/tmp/deliveries.jsonl`; set `WEBHOOK_LOG` to move it.

## What it shows

- **The raw body is still there after parsing.** `$request->body` caches the
  bytes, and `$request->json` reads through it, so the signature is checked
  on exactly what was sent and the payload is parsed from the same bytes.
- **Bad input answers itself.** A body that is not JSON is a
  `PAGI::Exception::RequestBody`, which Compose's error handler turns into a
  plain-text 400 with `Cache-Control: no-store`; the handler has no
  try/catch. `GET /hooks/github` is the router's 405 with `Allow: POST`.
- **No ceremony for the page.** The status page is an HTML heredoc in a
  `response('HTML', ...)`; the JSON view is `response('JSON', \@rows)`.
- **In-process tests need no server.** `t/example-webhook-receiver.t` posts
  signed and unsigned deliveries through `PAGI::Test::Client`, whose calls
  return the response directly.

Measured with the gut-check line counter (code lines, imports in
parentheses): PAGI-Tools 53 (5), Flask 47 (2), Go 93 (2). All three answer
the curl sequence below with the same statuses.

## Try

```bash
body='{"action":"opened","number":7}'
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac s3cret | sed 's/^.* //')
curl -i -X POST localhost:5000/hooks/github -H 'X-GitHub-Event: pull_request' \
     -H "X-Hub-Signature-256: sha256=$sig" -H 'Content-Type: application/json' -d "$body"   # 202
curl -i -X POST localhost:5000/hooks/github -d "$body"                                        # 401
curl -i localhost:5000/hooks/github                                                           # 405
curl localhost:5000/                                                                          # the page
curl 'localhost:5000/deliveries.json?n=5'
```

## The Flask and Go versions

The same program, as measured and driven with the curl sequence above.

### Flask

```python
# The same webhook receiver in Flask, for comparison with app.pl.
#
# Run:  pip install flask
#       WEBHOOK_SECRET=s3cret flask --app flask_app run --port 8000

import hmac, hashlib, json, os, time
from flask import Flask, request, jsonify, abort

SECRET = os.environ.get("WEBHOOK_SECRET", "s3cret").encode()
LOG = os.environ.get("WEBHOOK_LOG", "/tmp/deliveries.jsonl")
app = Flask(__name__)


def signature_ok(raw):
    given = request.headers.get("X-Hub-Signature-256")
    if given is None:
        return False
    want = "sha256=" + hmac.new(SECRET, raw, hashlib.sha256).hexdigest()
    return hmac.compare_digest(given, want)


def deliveries():
    try:
        with open(LOG) as fh:
            return [json.loads(line) for line in fh]
    except FileNotFoundError:
        return []


@app.post("/hooks/github")
def receive():
    raw = request.get_data()
    if not signature_ok(raw):
        return jsonify(error="bad signature"), 401
    payload = request.get_json(force=True)  # a 400 if it is not JSON
    delivery = {
        "id": request.headers.get("X-GitHub-Delivery", str(int(time.time()))),
        "event": request.headers.get("X-GitHub-Event", "unknown"),
        "received": int(time.time()),
        "payload": payload,
    }
    with open(LOG, "a") as fh:
        fh.write(json.dumps(delivery, sort_keys=True) + "\n")
    return jsonify(ok=1, id=delivery["id"]), 202


@app.get("/")
def status_page():
    recent = list(reversed(deliveries()[-10:]))
    rows = "".join(
        f"<li><code>{d['event']}</code> {d['id']} <small>{time.ctime(d['received'])}</small></li>"
        for d in recent
    )
    return f"""<h1>Webhook receiver</h1>
<p>{len(deliveries())} deliveries logged to <code>{LOG}</code>.</p>
<ul>{rows}</ul>
<p><a href="/deliveries.json">JSON</a></p>
"""


@app.get("/deliveries.json")
def deliveries_json():
    n = request.args.get("n", 50, type=int)
    return jsonify(deliveries()[-n:])
```

### Go

```go
// The same webhook receiver in Go's standard library, for comparison with
// app.pl. No framework: net/http with Go 1.22's method-aware patterns.
//
// Run:  WEBHOOK_SECRET=s3cret go run main.go
package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"
)

var secret = []byte(env("WEBHOOK_SECRET", "s3cret"))
var logPath = env("WEBHOOK_LOG", "/tmp/deliveries.jsonl")

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

type delivery struct {
	ID       string          `json:"id"`
	Event    string          `json:"event"`
	Received int64           `json:"received"`
	Payload  json.RawMessage `json:"payload"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func signatureOK(r *http.Request, raw []byte) bool {
	given := r.Header.Get("X-Hub-Signature-256")
	if given == "" {
		return false
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write(raw)
	want := "sha256=" + hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(given), []byte(want))
}

func deliveries() []delivery {
	f, err := os.Open(logPath)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []delivery
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var d delivery
		if json.Unmarshal(sc.Bytes(), &d) == nil {
			out = append(out, d)
		}
	}
	return out
}

func receive(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	if !signatureOK(r, raw) {
		writeJSON(w, 401, map[string]string{"error": "bad signature"})
		return
	}
	if !json.Valid(raw) {
		http.Error(w, "The request body is not valid JSON.", 400)
		return
	}
	id := r.Header.Get("X-GitHub-Delivery")
	if id == "" {
		id = strconv.FormatInt(time.Now().Unix(), 10)
	}
	event := r.Header.Get("X-GitHub-Event")
	if event == "" {
		event = "unknown"
	}
	d := delivery{ID: id, Event: event, Received: time.Now().Unix(), Payload: raw}
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer f.Close()
	json.NewEncoder(f).Encode(d)
	writeJSON(w, 202, map[string]any{"ok": 1, "id": id})
}

func statusPage(w http.ResponseWriter, r *http.Request) {
	all := deliveries()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, "<h1>Webhook receiver</h1>\n<p>%d deliveries logged to <code>%s</code>.</p>\n<ul>", len(all), logPath)
	for i := len(all) - 1; i >= 0 && i >= len(all)-10; i-- {
		d := all[i]
		fmt.Fprintf(w, "<li><code>%s</code> %s <small>%s</small></li>", d.Event, d.ID, time.Unix(d.Received, 0).Format(time.ANSIC))
	}
	fmt.Fprint(w, "</ul>\n<p><a href=\"/deliveries.json\">JSON</a></p>\n")
}

func deliveriesJSON(w http.ResponseWriter, r *http.Request) {
	all := deliveries()
	n, err := strconv.Atoi(r.URL.Query().Get("n"))
	if err != nil || n <= 0 || n > len(all) {
		n = min(50, len(all))
	}
	if all == nil {
		all = []delivery{}
	}
	writeJSON(w, 200, all[len(all)-n:])
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /hooks/github", receive)
	mux.HandleFunc("GET /{$}", statusPage)
	mux.HandleFunc("GET /deliveries.json", deliveriesJSON)
	http.ListenAndServe(":8000", mux)
}
```

## See also

- `PAGI::Request`, `body` and `json`
- `PAGI::Middleware::ErrorHandler`, for what a thrown `PAGI::Exception::RequestBody` becomes
- `examples/background-tasks`, for a receiver that does its work after the 202
