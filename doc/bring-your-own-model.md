# Bring your own model

The iOS app never holds a model API key and never talks to a model
provider directly. It talks to the Proper Dave server
(`src/proper_dave/server.py`, FastAPI, port 3283), and the server
talks to the model. Which model is entirely the server's environment;
the app neither knows nor cares, and `GET /v1/health` reports what is
live. That insulation is deliberate (TRD-003 CLD-04): keys stay on a
machine you control, and swapping models is a restart, not a release.

The server speaks the OpenAI chat-completions dialect: it POSTs to
`{base_url}/chat/completions` with a Bearer key, sends frames as
images, and requires a JSON-object response. Any provider — hosted or
local — that offers a vision model behind that dialect will work.

## The reference wiring: Muse Spark (how the field tests ran)

```sh
cd ~/src/proper-dave        # your clone
uv sync --group dev

export PROPER_DAVE_MODEL_BACKEND=frontier
export PROPER_DAVE_FRONTIER_BASE_URL=https://api.meta.ai/v1
export PROPER_DAVE_FRONTIER_MODEL=muse-spark-1.3
export PROPER_DAVE_FRONTIER_API_KEY=<your key>   # shell env only
export PROPER_DAVE_MIN_INTERVAL_S=3              # see "expect" below

uv run proper-dave-server
```

Verify before touching the phone:

```sh
curl localhost:3283/v1/health
# {"status":"ok","model":"frontier:muse-spark-1.3"}
```

If health names `fake` instead, the backend variable did not reach
the server process — that was the single most common setup failure
during development, and health exists to catch it in one command.
Keep keys in your shell environment or an ignored `.envrc`; the repo
git-ignores `.envrc` and the app's `Secrets.xcconfig` for exactly
this reason. Never commit either.

Optional split tiers: `PROPER_DAVE_FRONTIER_PARSE_MODEL` and
`PROPER_DAVE_FRONTIER_EVALUATE_MODEL` override `..._MODEL` for goal
parsing and scene evaluation separately, so a cheap model can parse
and a strong one can look. Unset, both use `..._MODEL`.

## Zero-key and local alternatives

- **No key at all:** start the server bare. The default backend is
  `fake` — deterministic canned answers that exercise the full
  client/server loop, the classifier gate, and speech with zero
  credentials. Combined with the app's offline tiers below, this is
  the fastest way to see the system move.
- **Workstation-local model** (e.g. Ollama serving Qwen2.5-VL):

  ```sh
  ollama pull qwen2.5vl:7b
  PROPER_DAVE_MODEL_BACKEND=local uv run proper-dave-server
  # defaults: http://localhost:11434/v1, model qwen2.5vl:7b
  ```

  Any other OpenAI-compatible local server works the same way via
  `PROPER_DAVE_LOCAL_BASE_URL` / `..._MODEL` / `..._API_KEY`.
- **Fully offline, no server:** in the app, Settings offers on-device
  tiers — Apple's built-in Foundation model, or downloadable Qwen
  packs. These also take over automatically mid-goal if the server
  becomes unreachable, and hand back when it returns.

## Pointing the phone at your server

In the app: **Settings → Server**.

- **Host:** the server machine's LAN IP (e.g. `192.168.1.163`), port
  3283. Not `localhost` — on the phone, that is the phone. A bare
  MagicDNS hostname failed from iOS during field testing while the
  Tailscale IP worked; prefer the IP.
- **API key:** must match the server's `PROPER_DAVE_API_KEY`. For
  trusted-LAN development, leave both sides blank. (The in-app note
  is accurate: plain HTTP on a home network is a courtesy lock, not
  security.)
- Then start any goal on the Home tab. The Log tab (Developer Mode)
  shows each escalation and its latency; `model=server` confirms the
  phone is reaching this server and not a fallback tier.

## What to expect

- **Latency is the model's, not the gate's.** Frontier calls during
  field testing ran 5–25 s; the on-device gate judges scenes in
  milliseconds and coalesces (drops) digests that went stale while a
  call was in flight, so speech stays about the present rather than
  narrating the past. `PROPER_DAVE_MIN_INTERVAL_S` (default 10) is
  the server's anti-storm backstop; 3 worked better for walking.
- **Errors surface as tiers swapping, not crashes.** An unreachable
  or rate-limited model produces a `model_unavailable` answer; the
  app offers/hands off to an on-device tier and returns when the
  server recovers. A building's elevator, it turns out, is a network
  dead zone; the logs in `doc/demo.md` show what that looks like.
- **Silence is the default state.** Most frames will be judged not
  worth a model call at all. That is the product working as designed
  (TRD-000 §1b), not a wiring fault — check health and the Log tab
  before suspecting your key.
