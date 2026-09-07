# Launcher

`vlthink` starts Qwen3-VL-4B Thinking on the server if needed, waits for it to
answer, then hands over to Claude Code pointed at it. Loading a cold server and
proving it answers takes about ten seconds.

**Opening the session itself does not.** Claude Code sends ~35000 tokens of
instructions at every start, and an RDNA1 card ingests them on a collapsing
curve, so budget around half an hour before the first word. The launcher prints
that warning with its figures every time rather than letting you discover it
after ten silent minutes. The cost is paid once per session; later turns are
fast. See the main README for why no setting fixes this.

```bash
export LLM_HOST=your-server-hostname-or-ip
export LLM_SSH_USER=your-ssh-user

./vlthink
```

No credential is needed: the server runs without `--api-key`. The launcher still
exports a placeholder `ANTHROPIC_AUTH_TOKEN`, whose value is never checked, so
that the client has something to send.

## What it does

Same five steps as the [CUDA launchers](../../llm-station-cuda/clients/):

1. `GET /health` to see if a server is up. This endpoint stays open without a key.
2. `GET /props` and read `model_path` to see **which** model is loaded. Open,
   like `/health`, and like its CUDA counterpart.
3. If the wrong model is loaded, ask before swapping.
4. Load over SSH, poll until it actually answers, up to 180 s.
5. `export` the environment and `exec claude`.

The exported variables live in this process only. A plain `claude` in another
shell still talks to Anthropic.

## Why the model check matters here too

Five model configurations share port 8080 on this box and are mutually exclusive
on the GPU. The server answers every request with whatever model is loaded,
regardless of the model id asked for, so checking `/health` alone tells you
nothing about what you are about to talk to.
