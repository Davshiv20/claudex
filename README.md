# claudex

One-command setup for running GPT/Codex models inside Claude Code via [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI).

It installs/configures a local CLIProxyAPI server, authenticates Claude and/or Codex, and adds a `claudex` command that launches `claude` with the right Anthropic-compatible proxy environment.

## Quick start

```bash
git clone <your-repo-url> claudex
cd claudex
./install.sh
```

Then authenticate at least Codex:

```bash
claudex-auth codex
# optional, if you also want Claude OAuth available behind the proxy
claudex-auth claude
```

Start the proxy:

```bash
claudex-proxy start
```

Run Claude Code backed by GPT/Codex:

```bash
claudex
```

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
available models, and a reasoning-effort menu (high/medium/low/none).

Prefer to type it directly? Pass the model and skip the prompts:

```bash
claudex-models set haiku gpt-5.4-mini(low)
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

## What gets installed

- CLIProxyAPI binary (`cliproxyapi` Homebrew formula if available, otherwise upstream release binary)
- `~/.cli-proxy-api/config.yaml`
- `~/.claudex/models.conf` (your Opus/Sonnet/Haiku model map)
- wrapper commands in `~/.claudex/bin`:
  - `claudex`
  - `claudex-auth`
  - `claudex-proxy`
  - `claudex-models`
- shell PATH snippet in `~/.zshrc` or `~/.bashrc`

## Defaults & precedence

Out of the box `claudex-models show` maps all three slots to `gpt-5-codex`
(high/medium/low). Change them any time with `claudex-models set` or by editing
`~/.claudex/models.conf`.

Model resolution follows this precedence (highest wins):

1. `CLAUDEX_OPUS_MODEL` / `CLAUDEX_SONNET_MODEL` / `CLAUDEX_HAIKU_MODEL` env vars
2. `~/.claudex/models.conf`
3. built-in fallback (`gpt-5-codex(...)`)

So you can still override a single run without touching your config:

```bash
CLAUDEX_SONNET_MODEL='gpt-5.5(high)' claudex
CLAUDEX_HAIKU_MODEL='gpt-5.4-mini(low)' claudex
```

## Notes

- The proxy listens locally only by default.
- Your OAuth tokens stay in `~/.cli-proxy-api/` and are **not** part of this repo.
- If Claude Code is v1.x, the wrapper also sets `ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` for backwards compatibility.
