param(
  [ValidateSet('qwen3vl4b','vlthink','qwen38distill','qwen3vl2b','lfm16','lfm3b','stop','status','logs')]
  [string]$Action,
  [string]$Name,  # optional: for 'stop' and 'logs', targets a named instance
  [int]$Tail = 40 # for 'logs': history lines to show before following live
)

# ---------------------------------------------------------------------------
# Paths. Adjust these two to match your machine; nothing else below is
# installation-specific.
# ---------------------------------------------------------------------------
$RootDir   = if ($env:LLM_ROOT_DIR) { $env:LLM_ROOT_DIR } else { 'D:\LLM-Setup' }
$ModelsDir = if ($env:LLM_MODELS_DIR) { $env:LLM_MODELS_DIR } else { 'D:\models' }

# ---------------------------------------------------------------------------
# One llama.cpp build here, Vulkan backend, and that is not a default: it is
# the only backend that drives this card. The Radeon RX 5700 XT is RDNA1
# (gfx1010), an architecture ROCm dropped support for, so the HIP backend is
# not an option on this box. Vulkan is.
# ---------------------------------------------------------------------------
$exe     = "$RootDir\llama-cpp-vulkan\llama-server.exe"
$workDir = $RootDir

$instDir = "$RootDir\instances"
New-Item -ItemType Directory -Force -Path $instDir | Out-Null

# Every model sits on port 8080 and they are mutually exclusive on the GPU:
# starting one unloads the others. With 8 GB of video memory there is no room
# to hold two at once, so this is a constraint, not a policy.
$ports = @{ qwen3vl4b = 8080; vlthink = 8080; qwen38distill = 8080; qwen3vl2b = 8080; lfm16 = 8080; lfm3b = 8080 }

# Shared by every model block below. Without it, any web page open on any
# machine of the LAN can query this server through the user's browser: a
# firewall does not protect against that case, because the request originates
# from inside the network. This closes the browser path.
$CorsOrigins = ''

function Quote($s) {
  # An EMPTY argument must be quoted too. Left bare it vanishes from the joined
  # command line instead of being passed through, which silently hands the
  # PRECEDING flag whatever token comes next as its value.
  if ($s -eq '' -or $s -match '[\s"]') { return '"' + ($s -replace '"','\"') + '"' }
  return $s
}

function Read-Instances {
  Get-ChildItem $instDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
    $o = Get-Content $_.FullName -Raw | ConvertFrom-Json
    [pscustomobject]@{ Name = $_.BaseName; Pid = $o.Pid; Port = $o.Port }
  }
}

function Kill-Pid($procId) {
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if ($p) { $p | Stop-Process -Force }
}

# Wait for the graphics card to actually hand its memory back.
#
# Stop-Process returns as soon as the process is marked dead, but Windows frees
# device memory ASYNCHRONOUSLY. An instance relaunched before that hand-back
# completes sees a card that is still occupied. A FIXED delay cannot cover this
# properly: it is either too short or wasted time. So we wait for the processes
# to actually disappear, then for the card's usage to settle, with a 30 s guard
# rail.
#
# The reading comes from the Windows performance counters, not from a vendor
# tool. There is no AMD equivalent of nvidia-smi on Windows, and rocm-smi does
# not cover this card. The counter set is provided by the WDDM driver model
# itself, so it works for any graphics card. Verified on this box 2026-09-02:
# the counter names stay ENGLISH on a fr-FR Windows, this set is not localised,
# so no culture-dependent lookup is needed.
#
# Instances are summed because the machine exposes several adapters and only
# one of them is the discrete card; the idle ones report zero.
function Get-VramUsedMb {
  try {
    $samples = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
  } catch {
    return -1
  }
  if (-not $samples) { return -1 }
  $sum = ($samples | Measure-Object -Property CookedValue -Sum).Sum
  return [int][math]::Round($sum / 1MB)
}

function Wait-VramReleased($timeoutSec = 30) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)

  while ((Get-Date) -lt $deadline -and (Get-Process -Name llama-server -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 250
  }

  Start-Sleep -Milliseconds 500
  $previous = -1
  $stable   = 0
  while ((Get-Date) -lt $deadline) {
    $used = Get-VramUsedMb
    # Counters unavailable: fall back to a fixed delay rather than burning the
    # whole timeout. Control must not depend on that one source.
    if ($used -lt 0) { Start-Sleep -Seconds 2; return }
    if ($used -eq $previous) { $stable++ } else { $stable = 0 }
    if ($stable -ge 2) { return }
    $previous = $used
    Start-Sleep -Milliseconds 500
  }
}

function Stop-One($name) {
  $f = Join-Path $instDir "$name.json"
  if (Test-Path $f) {
    $o = Get-Content $f -Raw | ConvertFrom-Json
    Kill-Pid $o.Pid
    Remove-Item $f -Force
    Write-Output "STOPPED $name"
  } else {
    Write-Output "NOT_RUNNING $name"
  }
}

function Stop-All {
  $procs = Get-Process -Name llama-server -ErrorAction SilentlyContinue
  if ($procs) { $procs | Stop-Process -Force; Wait-VramReleased; Write-Output "STOPPED all" }
  else { Write-Output "NOT_RUNNING" }
  Get-ChildItem $instDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
}

# Live log tailing.
#
# llama-server writes ALL of its output to stderr, including progress lines and
# served requests: llm-out-<name>.log stays empty forever and is NOT the file to
# read. llm-err-<name>.log carries everything. This action exists so nobody has
# to remember that: it picks the log of the running instance and follows it.
# Ctrl+C to exit; the server is unaffected.
function Show-Logs($name, $tail) {
  if (-not $name) {
    $running = @(Read-Instances | Where-Object { Get-Process -Id $_.Pid -ErrorAction SilentlyContinue })
    if ($running.Count -eq 0) {
      Write-Output "NO_INSTANCE no tracked instance is running. Pass -Name ($($ports.Keys -join '/'))."
      return
    }
    $name = $running[0].Name
  }
  $errLog = "$RootDir\llm-err-$name.log"
  if (-not (Test-Path $errLog)) { Write-Output "NO_LOG $errLog not found"; return }
  Write-Output "TAILING name=$name file=$errLog (Ctrl+C to exit)"
  Get-Content $errLog -Tail $tail -Wait
}

function Start-LLM($name, $modelArgs) {
  $port = $ports[$name]
  # Free the port: kill any tracked instance on the same port.
  $killed = @()
  foreach ($i in Read-Instances) {
    if ($i.Port -eq $port) { Kill-Pid $i.Pid; $killed += $i.Pid; Remove-Item (Join-Path $instDir "$($i.Name).json") -Force -ErrorAction SilentlyContinue }
  }
  # Then any ORPHAN instance still listening on that port. A llama-server
  # started by hand, or one that survived a loss of tracking, used to block the
  # bind silently while this script reported STARTED and the health check went
  # green by querying the old process.
  Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    Where-Object { $killed -notcontains $_ -and (Get-Process -Id $_ -ErrorAction SilentlyContinue).ProcessName -eq 'llama-server' } |
    ForEach-Object { Write-Output "KILLED_ORPHAN pid=$_ port=$port"; Kill-Pid $_ }
  Wait-VramReleased

  $outLog = "$RootDir\llm-out-$name.log"
  $errLog = "$RootDir\llm-err-$name.log"
  Clear-Content $outLog -ErrorAction SilentlyContinue
  Clear-Content $errLog -ErrorAction SilentlyContinue

  # The error log is written via llama-server's own --log-file flag, NOT via a
  # shell "2>" redirection. Sent through cmd.exe to a file, the process's C
  # runtime fully buffers its stderr and the file stays at 0 bytes until the
  # process exits, which defeats both the FAILED diagnostic below and the
  # 'logs' action. --log-file is flushed by the process itself and stays
  # readable while it runs.
  $fullArgs = $modelArgs + @('--log-file', $errLog)
  $quoted = ($fullArgs | ForEach-Object { Quote $_ }) -join ' '

  # No `set` inside the cmd line, and this is not a style choice. cmd /c strips
  # the outer quotes of the whole line, after which `set VAR=<value> && <rest>`
  # swallows ` && <rest>` INTO the value: nothing after it ever runs, no log
  # file is even created, and Win32_Process.Create still returns 0. Measured on
  # the CUDA box 2026-09-01, on every quoting variant tried, including /s and an
  # extra wrapping pair. `cd /d` is still required, dropping it makes the launch
  # fail.
  $inner = "cd /d `"$workDir`" && `"$exe`" $quoted > `"$outLog`""
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd.exe /c $inner"; CurrentDirectory = $workDir }
  if ($r.ReturnValue -ne 0) { Write-Output "ERROR Win32_Process.Create rc=$($r.ReturnValue)"; return }

  # Resolve the real llama-server PID (child of the cmd.exe we launched).
  $llamaPid = $null
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($r.ProcessId) AND Name='llama-server.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($child) { $llamaPid = $child.ProcessId; break }
  }
  if (-not $llamaPid) {
    # No STARTED here: without a PID the instance is untracked and the process
    # almost certainly failed at startup. Reporting success hid the failure.
    Write-Output "FAILED name=$name port=$port (no llama-server started, see llm-err-$name.log)"
    Get-Content $errLog -Tail 20 -ErrorAction SilentlyContinue
    return
  }

  # A live PID is not a usable server. Loading the weights and warming the card
  # takes time here, and answering before /health is green means the caller's
  # first request hits a closed socket.
  $ready = $false
  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    try {
      $h = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 3
      if ($h.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
    Start-Sleep -Seconds 1
  }
  if (-not $ready) {
    Write-Output "FAILED name=$name pid=$llamaPid port=$port (health check timeout)"
    Get-Content $errLog -Tail 30 -ErrorAction SilentlyContinue
    return
  }

  @{ Pid = $llamaPid; Port = $port } | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $instDir "$name.json")
  Write-Output "STARTED name=$name pid=$llamaPid port=$port"
}

function Get-Status {
  $any = $false
  foreach ($i in Read-Instances) {
    $any = $true
    $alive = [bool](Get-Process -Id $i.Pid -ErrorAction SilentlyContinue)
    $health = 'no answer'
    try {
      $resp = Invoke-WebRequest -Uri "http://localhost:$($i.Port)/health" -TimeoutSec 3 -UseBasicParsing
      if ($resp.StatusCode -eq 200) { $health = 'ok' }
    } catch { $health = 'no answer' }
    Write-Output "RUNNING name=$($i.Name) pid=$($i.Pid) port=$($i.Port) alive=$alive health=$health"
  }
  if (-not $any) { Write-Output "NOT_RUNNING" }
}

switch ($Action) {
  'stop'   { if ($Name) { Stop-One $Name } else { Stop-All }; break }
  'status' { Get-Status; break }
  'logs'   { Show-Logs $Name $Tail; break }

  'qwen3vl4b' {
    # The default served on this box. Qwen3-VL 4B Instruct, vision included.
    Start-LLM 'qwen3vl4b' @(
      '-m',"$ModelsDir\qwen3-vl-4b\Qwen3VL-4B-Instruct-Q4_K_M.gguf",
      '--mmproj',"$ModelsDir\qwen3-vl-4b\mmproj-Qwen3VL-4B-Instruct-F16.gguf",
      '-ngl','99',
      '-c','81920',
      '-b','2048',
      '-ub','512',
      '--cache-type-k','q4_0',
      '--cache-type-v','q4_0',
      # --no-mmap plus --mlock: hold the weights in resident memory instead of
      # letting Windows page them back from disk under pressure.
      '--no-mmap',
      '--mlock',
      # Patched chat template. The native one drops a system message that does
      # not come first, which is exactly what a client sending its instructions
      # mid-conversation does. Every Qwen model on this box needs this.
      '--chat-template-file',"$ModelsDir\qwen3-vl-4b\chat-template-system-anywhere.jinja",
      '--host','0.0.0.0',
      '--port','8080',
      '--log-colors','off',
      '--cors-origins',$CorsOrigins
    )
    break
  }

  'vlthink' {
    # Qwen3-VL-4B, THINKING edition, for API-driven work: reading mail, deciding
    # whether it deserves an answer, routing it, calling a tool when it needs a
    # fact it does not have. Not a dialogue model: here the thinking phase is
    # what is wanted, not a latency to work around.
    #
    # Same family, same quantiser and same footprint as 'qwen3vl4b' above, which
    # is deliberate: a bench between the two isolates the Instruct/Thinking
    # variable and nothing else.
    Start-LLM 'vlthink' @(
      '-m',"$ModelsDir\qwen3-vl-4b-thinking\Qwen3VL-4B-Thinking-Q4_K_M.gguf",
      '--mmproj',"$ModelsDir\qwen3-vl-4b-thinking\mmproj-Qwen3VL-4B-Thinking-F16.gguf",
      '-ngl','99',
      # 65536, and --parallel 1 with it. WITHOUT that flag llama.cpp opens FOUR
      # slots and SPLITS -c between them: -c 32768 gave 8192 tokens per request,
      # not 32768, and nothing says so. Found 2026-09-02 by reading total_slots
      # in /props, not by reading the script.
      #
      # 65536 leaves 1201 MB of video memory free, above the 1077 MB that the
      # 2026-08-25 campaign set as the safe floor after a full-screen image.
      # Higher paliers do load, up to 196608, but the cache is not fully
      # pre-allocated so loading proves nothing: they were not tested under load.
      '-c','65536',
      '--parallel','1',
      '-b','2048',
      '-ub','512',
      '--cache-type-k','q4_0',
      '--cache-type-v','q4_0',
      '--no-mmap',
      '--mlock',
      # Host-side prompt cache, 8 GiB, in MiB. This is NOT the context: it keeps
      # already-processed prompts in host RAM so that a repeated system prompt is
      # not recomputed. Worth far more than any sampling setting on this box,
      # where a cache hit turned 25.9 s into 0.26 s.
      '-cram','8192',
      # --jinja is what makes this profile work at all, and the other five do not
      # have it. Without it llama.cpp ignores the model's own template, so tool
      # calls are never parsed and the thinking tags are never recognised.
      '--jinja',
      # Thoughts go to message.reasoning_content, the answer stays alone in
      # message.content. A caller reading mail wants the verdict, not the
      # deliberation, and should not have to strip <think> blocks by hand.
      '--reasoning-format','deepseek',
      # Sampling as published by Qwen in generation_config.json for this exact
      # model. --min-p 0 is not redundant: llama.cpp forces 0.05 by default,
      # which silently clips the tail on top of the top_p and top_k already
      # calibrated here.
      '--temp','1.0',
      '--top-p','0.95',
      '--top-k','20',
      '--min-p','0',
      '--host','0.0.0.0',
      '--port','8080',
      '--log-colors','off',
      '--cors-origins',$CorsOrigins
    )
    break
  }

  # Candidate evaluated on 2026-08-25, not retained as the default.
  # Reasoning model: add "chat_template_kwargs": {"enable_thinking": false} to
  # the /v1/messages request to get usable short-dialogue latency, otherwise it
  # spends its whole budget thinking before answering.
  'qwen38distill' {
    Start-LLM 'qwen38distill' @(
      '-m',"$ModelsDir\qwen38-4b-distill\Qwen3.8-4B-Distill.i1-Q4_K_M.gguf",
      '--mmproj',"$ModelsDir\qwen38-4b-distill\Qwen3.8-4B-Distill.mmproj-f16.gguf",
      '-ngl','99',
      '-c','262144',
      '-b','2048',
      '-ub','512',
      '--cache-type-k','q4_0',
      '--cache-type-v','q4_0',
      '--no-mmap',
      '--mlock',
      '--chat-template-file',"$ModelsDir\qwen38-4b-distill\chat-template-system-anywhere.jinja",
      '--host','0.0.0.0',
      '--port','8080',
      '--log-colors','off',
      '--cors-origins',$CorsOrigins
    )
    break
  }

  # Candidate evaluated on 2026-08-25, not retained as the default.
  # Exact little brother of qwen3vl4b: same family, same patched chat template.
  'qwen3vl2b' {
    Start-LLM 'qwen3vl2b' @(
      '-m',"$ModelsDir\qwen3-vl-2b\Qwen3-VL-2B-Instruct-Q4_K_M.gguf",
      '--mmproj',"$ModelsDir\qwen3-vl-2b\mmproj-F16.gguf",
      '-ngl','99',
      '-c','114688',
      '-b','2048',
      '-ub','512',
      '--cache-type-k','q4_0',
      '--cache-type-v','q4_0',
      '--no-mmap',
      '--mlock',
      '--chat-template-file',"$ModelsDir\qwen3-vl-2b\chat-template-system-anywhere.jinja",
      '--host','0.0.0.0',
      '--port','8080',
      '--log-colors','off',
      '--cors-origins',$CorsOrigins
    )
    break
  }

  # Candidate evaluated on 2026-08-25, not retained as the default.
  # Its native chat template is already correct: a late system message is
  # rendered as an ordinary turn by construction, so no --chat-template-file is
  # needed here, unlike every Qwen model on this box.
  'lfm16' {
    Start-LLM 'lfm16' @(
      '-m',"$ModelsDir\lfm2.5-vl-1.6b\LFM2.5-VL-1.6B-F16.gguf",
      '--mmproj',"$ModelsDir\lfm2.5-vl-1.6b\mmproj-LFM2.5-VL-1.6b-F16.gguf",
      '-ngl','99',
      '-c','128000',
      '-b','2048',
      '-ub','512',
      '--cache-type-k','q4_0',
      '--cache-type-v','q4_0',
      '--no-mmap',
      '--mlock',
      '--host','0.0.0.0',
      '--port','8080',
      '--log-colors','off',
      '--cors-origins',$CorsOrigins
    )
    break
  }

  # Candidate evaluated on 2026-08-25, not retained as the default.
  # Unquantised F16 weights: here the context ceiling is set by the size of the
  # weights themselves, not by the marginal cost of the KV cache.
  'lfm3b' {
    Start-LLM 'lfm3b' @(
      '-m',"$ModelsDir\lfm2.5-vl-3b\LFM2.5-VL-3B-F16.gguf",
      '--mmproj',"$ModelsDir\lfm2.5-vl-3b\mmproj-LFM2.5-VL-3B-F16.gguf",
      '-ngl','99',
      '-c','49152',
      '-b','2048',
      '-ub','512',
      '--cache-type-k','q4_0',
      '--cache-type-v','q4_0',
      '--no-mmap',
      '--mlock',
      '--host','0.0.0.0',
      '--port','8080',
      '--log-colors','off',
      '--cors-origins',$CorsOrigins
    )
    break
  }

  # ValidateSet already rejects an unknown value with a usable error. The only
  # case left is no argument at all, which would otherwise fall through the
  # whole switch and exit silently as if it had worked.
  default  { Write-Output "USAGE: llm-ctl.ps1 -Action <$($ports.Keys -join '|')|stop|status|logs> [-Name <instance>] [-Tail <n>]"; break }
}
