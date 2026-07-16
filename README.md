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

## What gets installed

- CLIProxyAPI binary (`cliproxyapi` Homebrew formula if available, otherwise upstream release binary)
- `~/.cli-proxy-api/config.yaml`
- wrapper commands in `~/.claudex/bin`:
  - `claudex`
  - `claudex-auth`
  - `claudex-proxy`
- shell PATH snippet in `~/.zshrc` or `~/.bashrc`

## Defaults

`claudex` sets:

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:8317
ANTHROPIC_AUTH_TOKEN=<local proxy api key>
ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-5-codex(high)
ANTHROPIC_DEFAULT_SONNET_MODEL=gpt-5-codex(medium)
ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5-codex(low)
```

Override per invocation:

```bash
CLAUDEX_SONNET_MODEL='gpt-5(high)' claudex
CLAUDEX_HAIKU_MODEL='gemini-2.5-flash-lite' claudex
```

## Notes

- The proxy listens locally only by default.
- Your OAuth tokens stay in `~/.cli-proxy-api/` and are **not** part of this repo.
- If Claude Code is v1.x, the wrapper also sets `ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` for backwards compatibility.
