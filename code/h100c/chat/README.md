# H100 Chat — single-user web UI over the vLLM endpoint

A tiny self-contained chat app that wraps whatever model is live on `:8000`
(Qwen/Gemma/…) with persistent, threaded conversation history. Single user, no
auth — meant to sit local to the box or on the trusted LAN (same pattern as the
vLLM and Jupyter planes).

Runs with `--network host`, so it reaches vLLM on `localhost:8000` and binds the
chat port directly on the box.

---

## Files (all under `chat/`)

| File | Purpose |
|---|---|
| `app.py` | FastAPI backend — SQLite threads/messages + streaming proxy to vLLM |
| `index.html` | Single-page UI: thread sidebar, new/rename/delete, streamed replies |
| `requirements.txt` | fastapi, uvicorn, httpx |
| `Dockerfile` | Slim `python:3.12` image; port/host from env |
| `../scripts/h100-chat.sh` | H100 launcher: `up` / `down` / `rebuild` / `logs` / `status` / `url` |
| `../scripts/spark-chat.sh` | Spark launcher: same commands, `SPARK_*` env/defaults |

## Features

- **Wraps the live endpoint** — the model dropdown is populated from
  `GET /v1/models`, so whatever is up (Qwen now, Gemma after a swap) is what it
  talks to. Qwen's `<think>` output is suppressed via the "hide thinking" toggle.
- **Threaded history** — each conversation is a thread; full message history
  persists in SQLite.
- **Create / delete / rename** — "+ New chat", trash icon per thread (with
  confirm), double-click a title to rename. The first message auto-titles the
  thread.
- **Export** — just ask in the chat ("make this a PDF", "turn it into a slide
  deck", "export our conversation as markdown") and a **⬇ Download** button
  appears inline under the reply — same feel as Claude/ChatGPT/Gemini artifacts.
  Supported: **Markdown**, **PDF**, **PowerPoint (.pptx)**. A manual **Export ▾**
  dropdown in the topbar is also there as a fallback ("answers only" exports just
  the assistant replies). All generated server-side with pure-Python libs — no
  outbound calls, nothing to secure.
- **Single user, local** — no auth, streamed token-by-token.

## Prereq

vLLM is serving a model (`bash h100-serve.sh status` shows `h100-vllm` up and
`test` lists the model).

## Run it

First `up` builds the image (one-time). After editing `app.py`/`index.html`,
run `rebuild`.

```bash
# default — LAN-reachable at :8080
./chat.sh up

# custom port
H100_CHAT_PORT=9000 ./chat.sh up

# keep it strictly on the box (then tunnel from a client)
H100_CHAT_HOST=127.0.0.1 ./chat.sh up

# optional system prompt prepended to every conversation
H100_CHAT_SYSTEM="You are a terse QC assistant." ./chat.sh up

./chat.sh status      # container + URLs
./chat.sh logs        # follow logs
./chat.sh rebuild     # rebuild image + recreate after code edits
./chat.sh down        # stop & remove
```

## Port — configurable, piped like the other scripts

Default is **8080** (clear of 8000 vLLM / 8888 Jupyter / 11434 ollama). Pipe env
vars in exactly like `H100_GPUS`:

| env | default | meaning |
|---|---|---|
| `H100_CHAT_PORT` | `8080` | host port the UI binds |
| `H100_CHAT_HOST` | `0.0.0.0` | bind interface (`127.0.0.1` = box-local only) |
| `H100_CHAT_VLLM` | `http://localhost:8000/v1` | endpoint the app calls |
| `H100_CHAT_API_KEY` | `h100` | only needed if vLLM started with `--api-key` |
| `H100_CHAT_SYSTEM` | *(none)* | system prompt prepended to every conversation |
| `H100_ROOT` | `$HOME/h100c` | SQLite DB lives under `chat/` |
| `CHAT_IMAGE` | `h100-chat:latest` | built image tag |

## Access

With `H100_CHAT_HOST=0.0.0.0` (default), reachable across the LAN — same model as
Jupyter/vLLM:

- Local : `http://localhost:8080/`
- LAN   : `http://xxx.xxx.xxx.xxx:8080/`

To keep it box-local, set `H100_CHAT_HOST=127.0.0.1` and tunnel from a client:

```bash
ssh -N -L 8080:localhost:8080 test@xxx.xxx.xxx.xxx
# then open http://localhost:8080/
```

## On the Spark (same app, Spark launcher)

The app is box-agnostic — `spark-chat.sh` runs the identical `chat/` folder with
Spark-flavoured labels/defaults (container `spark-chat`, image
`spark-chat:latest`, `SPARK_*` env, `SPARK_ROOT=$HOME/pai/spark`, API key
default `spark`). Same commands:

```bash
./spark-chat.sh up          # build (once) + start on :8080, --network host
./spark-chat.sh status      # container + URLs
./spark-chat.sh rebuild     # after editing app.py/index.html
./spark-chat.sh down        # stop & remove
```

Env knobs mirror the H100 ones with a `SPARK_` prefix:

| env | default | meaning |
|---|---|---|
| `SPARK_CHAT_PORT` | `8080` | host port the UI binds |
| `SPARK_CHAT_HOST` | `0.0.0.0` | bind interface (`127.0.0.1` = box-local only) |
| `SPARK_CHAT_VLLM` | `http://localhost:8000/v1` | endpoint the app calls |
| `SPARK_CHAT_API_KEY` | `spark` | only needed if vLLM started with `--api-key` |
| `SPARK_CHAT_SYSTEM` | *(none)* | system prompt prepended to every conversation |
| `SPARK_ROOT` | `$HOME/pai/spark` | SQLite DB lives under `chat/` |
| `CHAT_IMAGE` | `spark-chat:latest` | built image tag |

Access is the same pattern (LAN at `http://xxx.xxx.xxx.xxx:8080/`, or
`127.0.0.1` + tunnel to keep it box-local). Both launchers point at this one
`chat/` folder, so a change to the app applies to both boxes after a `rebuild`.

## Storage

SQLite DB at `$H100_ROOT/chat/chat.db` (mounted to `/data` in the container),
persists across restarts. Threads cascade-delete their messages. To wipe
everything, stop the app and remove that file.

## Notes

- **Unauthenticated**, like the other services — fine on a trusted LAN; use the
  `127.0.0.1` + tunnel option otherwise.
- Only the model **currently served** on `:8000` will respond; the dropdown
  reflects `GET /v1/models`. After `h100-serve.sh swap <model>`, reload the page
  to pick up the new model.
