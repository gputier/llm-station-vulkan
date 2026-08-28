# Running Claude Code against this server

The mechanism is identical to the CUDA box, and
[its page](../../llm-station-cuda/docs/claude-code-integration.md) covers it in
full: `llama.cpp` exposes `/v1/messages` natively in the Anthropic format, so
only the base URL is redirected and no translation proxy is involved.

This page covers only what differs here.

## The API key is mandatory

This server runs with `--api-key`, so the client must present it:

```bash
export ANTHROPIC_AUTH_TOKEN="$LLM_API_KEY"
```

Still `ANTHROPIC_AUTH_TOKEN` and **not** `ANTHROPIC_API_KEY`: the latter triggers
Claude Code's custom-key approval prompt. `AUTH_TOKEN` is sent as
`Authorization: Bearer`, which llama.cpp accepts alongside `x-api-key`. Both were
verified working against this server.

Consequence for the launcher: `/props` is **not** reachable without the key,
while `/health` is. Every probe that reads `model_path` has to carry the
authorisation header, which is the one place the CUDA launchers and this one
genuinely differ.

## A smaller window changes what matters

At 81,920 tokens the client's context ceiling has to be set accordingly. The rule
from the CUDA box applies unchanged and matters more here: the authoritative
value is `default_generation_settings.n_ctx` from `/props`, never what was passed
to `-c`. Promise the client more than the server serves and a long session is
truncated server-side with no warning.

Dropping MCP servers with `--strict-mcp-config` also matters more at this size.
Measured on the CUDA box, the full client prompt is 109,738 tokens with MCP
servers loaded and roughly 44,000 without. The first figure does not fit in this
server's window at all.

## Prompt ordering is a performance setting here

See the prefix-cache measurement in the [main README](../README.md): one changed
character at the top of a prompt cost 25.9 s instead of 0.26 s. On this card,
where prompt processing is slower to begin with, keeping volatile content out of
the top of the prompt is worth more than any sampling parameter.
