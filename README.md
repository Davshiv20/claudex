# claudex

Guided setup for running GPT/Codex (or Gemini) models inside [Claude Code](https://docs.anthropic.com/en/docs/claude-code) via [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI).

claudex installs and configures a **local** CLIProxyAPI server, helps you authenticate Codex/Claude, and adds a `claudex` command that launches `claude` pointed at the proxy through Anthropic-compatible environment variables. You keep the Claude Code UX; the models behind it are yours to choose.

> [!NOTE]
> This is a **guided, minimal setup** — not a single command. You'll install prerequisites, run the installer, authenticate once via OAuth, start the proxy, and pick your models. Each step is one command and is explained below.

## Prerequisites

- **macOS or Linux** (arm64 or x86_64). Windows is not supported by these wrappers.
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** installed (the `claude` command). claudex wraps it; it does not install it.
- **`bash`, `curl`, `python3`** (present on macOS and most Linux distros).
- A **Codex/ChatGPT account** (and/or Claude, Gemini) to authenticate the proxy against.
- Optional: **[`fzf`](https://github.com/junegunn/fzf)** for fuzzy model selection, **Homebrew** on macOS (used to install CLIProxyAPI when available).

Verify your setup at any time with `claudex-doctor`.

## Quick start

```bash
git clone https://github.com/Davshiv20/claudex.git
cd claudex
./install.sh
```

Open a new shell (or `source ~/.zshrc`) so the `claudex` commands are on your `PATH`, then:

```bash
claudex-auth codex          # browser OAuth for OpenAI/Codex
# optional: also expose Claude OAuth behind the proxy
claudex-auth claude

claudex-proxy start         # start the local proxy
claudex-models set          # pick your models (guided)
claudex                     # launch Claude Code backed by your chosen models
```

Run `claudex-doctor` if anything looks off.

## Choosing your models

Claude Code has only three model slots: **Opus**, **Sonnet**, and **Haiku**.
claudex lets you decide which real model powers each slot.

The easiest way is the **guided picker** — it lists the models your account can
actually use and lets you choose by number (or fuzzy-search, if `fzf` is
installed). No IDs to memorize:

```bash
claudex-models set          # walks through Opus, then Sonnet, then Haiku
claudex-models set opus      # just re-pick one slot
```

Each step shows which slot you're configuring, your current choice, the list of
available (chat-capable) models, and a reasoning-effort menu (high/medium/low/none).

Prefer to type it directly? Pass the model and skip the prompts:

```bash
claudex-models set haiku gpt-5.4-mini(low)
```

Quickly dial effort up or down across all slots with a **profile**:

```bash
claudex-models profile cheap      # every slot -> low effort
claudex-models profile balanced   # high / medium / low
claudex-models profile max        # high / high / medium
```

Other commands:

```bash
claudex-models list   # every model your account can use (proxy must be running)
claudex-models show   # the current map
claudex-models edit   # open ~/.claudex/models.conf in your editor
```

The `(high|medium|low)` suffix is optional and sets reasoning effort.
Everything is stored in a plain, commented file at `~/.claudex/models.conf`.

When you run `claudex`, it prints the active map so it's never a mystery:

```
[claudex] Opus:gpt-5.5(high)  Sonnet:gpt-5.5(medium)  Haiku:gpt-5.4-mini(low)
```

### Model resolution precedence

1. `CLAUDEX_OPUS_MODEL` / `CLAUDEX_SONNET_MODEL` / `CLAUDEX_HAIKU_MODEL` env vars
2. `~/.claudex/models.conf`
3. built-in fallback (`gpt-5-codex(...)`)

So you can override a single run without touching your config:

```bash
CLAUDEX_SONNET_MODEL='gpt-5.5(high)' claudex
```

## How it works / data flow

Everything runs on your machine. Claude Code talks to `127.0.0.1`, and the proxy
forwards requests to the upstream provider using your OAuth credentials.

```mermaid
flowchart LR
    CC[Claude Code<br/>claude CLI] -->|Anthropic API<br/>127.0.0.1:8317| P[CLIProxyAPI<br/>local proxy]
    P -->|OAuth token| U[Upstream provider<br/>OpenAI / Anthropic / Google]
    K[~/.claudex/api-key] -.local auth.-> CC
    T[~/.cli-proxy-api/*.json<br/>OAuth tokens] -.-> P
```

- **Local-only by default.** The proxy binds to `127.0.0.1:8317`; nothing is exposed to your network.
- **Local auth token.** A random `sk-claudex-…` key in `~/.claudex/api-key` authenticates Claude Code to the proxy. It is not an provider key and never leaves your machine.
- **Provider OAuth.** `claudex-auth` performs a normal browser OAuth login. Tokens are stored by CLIProxyAPI under `~/.cli-proxy-api/` (mode `0600`) and are **never** part of this repo.
- **Your prompts and code** flow from Claude Code → local proxy → your chosen provider, exactly as they would if you used that provider directly. claudex adds no telemetry of its own.

## Billing & cost

- claudex is free and does not bill you. **Your usage is billed by the upstream provider** (OpenAI/Anthropic/Google) according to your account/plan.
- Model choice and reasoning effort directly affect cost and latency. `high` effort is slower and more expensive; use `claudex-models profile cheap` to dial everything down.
- Costs shown inside Claude Code's model picker come from Claude Code, not from claudex, and may not reflect your actual provider pricing.

## Telemetry

- CLIProxyAPI's usage statistics are **disabled by default** in the config claudex writes (`usage-statistics-enabled: false`). Set it to `true` in `~/.cli-proxy-api/config.yaml` to opt in.
- claudex itself sends no telemetry.

## Security & supply chain

- **Pinned + verified binary.** The installer downloads a specific, reviewed CLIProxyAPI version and verifies its **SHA256** against the release `checksums.txt`. A mismatch aborts the install.
- **Minimum release age.** Any version other than the vouched pin (including `CLAUDEX_CLIPROXY_VERSION=latest`) must be at least **7 days old**, so brand-new releases are given time to be caught before they're installed. Tune with `CLAUDEX_MIN_RELEASE_AGE_DAYS` (set `0` to disable).
- **Private secrets.** The installer runs with `umask 077` and writes `api-key` and `config.yaml` atomically at mode `0600` — they are never briefly world-readable.
- **Non-destructive config.** An existing `~/.cli-proxy-api/config.yaml` is **preserved**; pass `--reset` to overwrite (a timestamped backup is kept either way).
- **Safe process control.** `claudex-proxy stop` only kills a PID that is actually a `cli-proxy-api` process, and clears stale PID files, so it won't kill an unrelated process.

Install options:

```bash
./install.sh --reset                              # overwrite existing CLIProxy config
CLAUDEX_CLIPROXY_VERSION=v7.2.93 ./install.sh      # pin a specific version
CLAUDEX_CLIPROXY_VERSION=latest ./install.sh       # newest release >= min age
CLAUDEX_MIN_RELEASE_AGE_DAYS=14 ./install.sh       # stricter soak period
```

## Maintenance

```bash
claudex-doctor       # health check: deps, perms, auth, proxy, model map
claudex-update       # pull latest repo + refresh CLIProxyAPI and wrappers
claudex-uninstall    # remove wrappers, config, PATH/alias (keeps OAuth tokens)
claudex-uninstall --purge   # also delete ~/.cli-proxy-api (OAuth tokens included)
```

## What gets installed

- CLIProxyAPI binary (Homebrew formula if available, otherwise a pinned, checksum-verified release binary)
- `~/.cli-proxy-api/config.yaml` and `~/.cli-proxy-api/` for OAuth tokens/logs
- `~/.claudex/api-key` (local proxy auth token, mode `0600`)
- `~/.claudex/models.conf` (your Opus/Sonnet/Haiku model map)
- wrapper commands in `~/.claudex/bin`:
  - `claudex` — launch Claude Code with your model map
  - `claudex-auth` — OAuth login (codex/claude)
  - `claudex-proxy` — start/stop/status/logs/models
  - `claudex-models` — pick/list/show/profile models
  - `claudex-doctor` — health check
  - `claudex-update` — update in place
  - `claudex-uninstall` — clean removal
- a PATH + alias snippet in `~/.zshrc`, `~/.bashrc`, or `~/.profile`

## Troubleshooting

| Symptom | Try |
| --- | --- |
| `claudex` says Claude Code not found | Install Claude Code so `claude` is on your `PATH`. |
| Commands not found after install | Open a new shell or `source ~/.zshrc`. |
| `proxy not reachable` | `claudex-proxy start`, then `claudex-proxy status`. Check `claudex-proxy logs`. |
| `claudex-models list` fails | The proxy must be running and you must be authenticated (`claudex-auth codex`). |
| Model picker shows nothing | No chat models for your account, or the proxy is down. Run `claudex-doctor`. |
| Checksum mismatch on install | Re-run; if it persists, the release may have changed. Do **not** use `CLAUDEX_SKIP_CHECKSUM=1` unless you trust the source. |
| Auth expired | Re-run `claudex-auth codex` (or `claude`). |

Start with `claudex-doctor` — it points at the most likely fix.

## Compatibility

| Component | Supported |
| --- | --- |
| OS | macOS (arm64/x86_64), Linux (arm64/x86_64) |
| Shell | zsh, bash (profile fallback otherwise) |
| Claude Code | v1.x and v2.x (v1.x also gets `ANTHROPIC_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL`) |
| CLIProxyAPI | pinned `v7.2.93` (override with `CLAUDEX_CLIPROXY_VERSION`) |

## Development

```bash
bash tests/run.sh    # static checks + hermetic unit/integration tests (no network)
```

CI runs the same suite on macOS and Linux via GitHub Actions (`.github/workflows/ci.yml`).

## License

[MIT](./LICENSE) © 2026 Shivam
