# Launcher

`aziz` starts Qwen3-VL-4B on the server if needed, waits for it to answer, then
hands over to Claude Code pointed at it.

```bash
export LLM_HOST=your-server-hostname-or-ip
export LLM_SSH_USER=your-ssh-user
export LLM_API_KEY=the-key-the-server-runs-with

./aziz
```

`LLM_API_KEY` has no default: the script fails immediately if it is unset, rather
than sending unauthenticated requests that would be refused with a confusing
error.

## What it does

Same five steps as the [CUDA launchers](../../llm-station-cuda/clients/):

1. `GET /health` to see if a server is up. This endpoint stays open without a key.
2. `GET /props` and read `model_path` to see **which** model is loaded. Unlike
   the CUDA box, **this call needs the key**, since the server authenticates
   everything except health.
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
