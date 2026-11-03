# Swarm Desktop

An experimental native macOS desktop assistant with a **Codex ↔ Loupe ↔ desktop** bridge. Your existing Codex session coordinates tasks, the existing Loupe CLI handles bounded local code jobs, and the native app owns checked Accessibility actions. Each real background job gets a visible cursor and status. No separate OpenAI API key is required for this Codex MCP route.

The panel also has a standalone local-Qwen mode: select an app, request one action, review its target/text, and approve it. This is useful for testing the execution layer independently.

This is an initial desktop agent, not a general autonomous computer-use system. It supports accessible buttons (`AXPress`) and editable text fields (`AXValue`). Codex can queue jobs and alternate steps across apps; the bridge serializes actual inputs. It does not yet support screenshots, visual grounding, keyboard shortcuts, scrolling, drag and drop, or an independent persistent GPT loop. GPT only coordinates while the connected Codex session is active. A model's `done` response is not verified completion.

## Connect your existing Codex session

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r desktop/requirements.lock
python3 desktop/install_codex.py          # review the exact configuration
python3 desktop/install_codex.py --install
```

The installer appends only a `swarm_desktop` MCP entry to `~/.codex/config.toml` and refuses to overwrite an existing entry. Pass `--loupe /absolute/path/to/loupe` if your Loupe executable is elsewhere. Keep this checkout and `.venv` in place. Open Swarm Desktop before using its tools. Restart Codex if the new tools are not discovered in the current session; registration does not retroactively prove that a running chat has loaded them. [Official Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

The bridge exposes nine tools:

| Tool | Purpose |
|---|---|
| `swarm_status` | Connection health, app names/PIDs, permission state |
| `swarm_observe_app` | Fresh controls from one specified window |
| `swarm_resolve_target` | Ground a GPT-chosen operation and exact text to a small candidate set |
| `swarm_stage_action` | Prepare an exact action, without executing it |
| `swarm_execute_action` | Execute one staged action authorized by the user in chat |
| `swarm_submit_loupe` | Start a bounded explain/fix/refactor/tests job in the real Loupe CLI |
| `swarm_get_job` | Collect result or escalation reason |
| `swarm_list_jobs` | Compact progress across jobs |
| `swarm_cancel_job` | Cancel pending local work or staged actions |

For example, ask Codex: “Use Swarm to set Name to Ada in Swarm Practice; meanwhile ask Loupe to explain this small function.” Codex can submit the local job, observe and operate the practice app, then collect the local result. A unique exact label is grounded deterministically without inference. Ambiguous target selection shows Qwen at most six candidates; it chooses only an ID. GPT supplies the operation and complete replacement text. No worker invents executable code for desktop control.

Use `swarm_get_job` for a pending job rather than resubmitting it. An execution timeout has an unknown outcome: observe before considering another action. The native app rejects expired snapshots and changed controls. A successful action returns resulting state with `goal_verified: false`, leaving semantic verification to GPT. Stop in the app pauses bridge commands and cancels local workers; Resume does not replay cancelled tasks.

Local inference has one shared lane across bridge sessions to avoid CPU contention. GPT can continue other work while local jobs run; native UI actions serialize separately. Completed job results stay in the MCP process until shutdown. Task cursors in the side rail indicate job state, not simultaneous physical mouse positions. An action cursor highlights the actual control during execution.

The bridge uses private local filesystem IPC under `dist/bridge` (directory mode 0700, payload files 0600). Requests and responses are normally removed after collection; a crash can leave transient payloads. MCP returns requested UI/code results to your Codex chat and its normal data-handling context. Qwen calls go to local Ollama. The native app exposes no HTTP listener.

## Build and start

Requires macOS 13+, Apple's Swift toolchain, and Ollama. No npm packages or third-party Swift libraries are needed.

```sh
bash desktop/build.sh
ollama pull qwen3:0.6b
# If Ollama is not already running:
OLLAMA_NO_CLOUD=1 OLLAMA_HOST=127.0.0.1:11434 ollama serve
```

Open `dist/desktop/Swarm Desktop.app`. Keep `Swarm Practice.app` next to it. The build script accepts an alternate output directory as its first argument. App bundles are ad-hoc signed for local use and are not notarized distribution builds.

1. Click **Enable Accessibility…**, and enable **Swarm Desktop** under System Settings → Privacy & Security → Accessibility. macOS controls this permission; the app cannot grant it to itself. Moving or rebuilding an ad-hoc signed app can require reauthorization.
2. Click **Open practice app**, then **Refresh apps** and select **Swarm Practice**.
3. Enter a goal such as `Set the Name field to Ada Lovelace`.
4. Click **Plan next action**. This observes the current window and sends its displayed text and available controls to local Ollama.
5. Check the proposed target and complete replacement value. Click **Approve & run this action** only when correct. The colored overlay points at the proposed control and does not intercept mouse input.
6. Review the observed result. Use a separate `Click Save` goal to test a button press.

**Stop** cancels an in-flight model request, invalidates pending actions, pauses the Codex bridge and hides overlays. It cannot undo an action already accepted by another app. Closing the app stops its planner and overlay, but does not shut down a separately running Ollama server.

If Ollama isn't available, the app reports the connection error. If a model is missing, run `ollama pull MODEL` in Terminal and enter that installed model tag. Use a local Ollama server with `OLLAMA_NO_CLOUD=1` for fully local inference. The client sends requests only to `127.0.0.1:11434` and rejects HTTP redirects.

## Design

- **Observe:** Traverse only the selected app's focused window, with time, depth and element limits. Secure text fields are excluded. Panel observations go to local Ollama when you plan; explicitly requested MCP observations return to Codex through private local IPC.
- **Plan:** One shared model proposes structured JSON. There is never a separate model for every animated cursor. UI text is marked as untrusted, but the small-model benchmarks show this is not sufficient for unattended use.
- **Act:** Validate the schema, target ID, available action and replacement size. Reject redundant edits. Immediately before execution, re-observe and compare the window, element identity, displayed state and complete editable values to the approved snapshot. Each button click authorizes one action only.
- **Verify:** Refresh the Accessibility tree and report whether it changed. API success alone is not presented as proof of the user's goal.
- **Animate:** Native click-through action cursors run at a requested 30 Hz independently of inference. The task rail shows up to eight actual bridge jobs. Actual inputs serialize through Accessibility; there is one macOS focus context.

No shell execution tool, raw coordinate clicks, or model-generated desktop code is provided. The bridge invokes only the configured Loupe binary with a fixed operation vocabulary and source on stdin. Some apps do not expose useful Accessibility controls. In that case the app reports a missing control or partial view; this version has no vision fallback.

## Validation and benchmarks

`build.sh` compiles both apps, runs 12 action-validation checks, and verifies their code signatures.

Bridge validation: `.venv/bin/python -m unittest discover -s desktop/tests -p 'test_*.py' -v` runs 14 checks covering serialization, cancellation, stale health, private files, grounding, RPC cleanup and Loupe result review. `.venv/bin/python desktop/tests/protocol_smoke.py` checks a real SDK handshake, nine tool definitions and offline handling without touching desktop apps.

```sh
python3 desktop/benchmark.py --model qwen3:0.6b --output benchmark.json
# Compare the latency/quality tradeoff with thinking enabled:
python3 desktop/benchmark.py --model qwen3:0.6b --think --output thinking-benchmark.json
```

The benchmark performs six synthetic action-selection tasks and never operates desktop apps. Cases cover text replacement, button choice, the next step of a task, a missing control, an already completed task and an instruction embedded in a button label. Exact action, target and text must all match. Prompt and runtime settings are saved with current reports. This small test is a smoke test, not a representative reliability evaluation. See `benchmarks/RESULTS.md` for measurements on the development Mac.

Ollama's [generate API](https://docs.ollama.com/api/generate) supplies structured output and token timings. Wall time here includes prompt evaluation, generation and any model load. **Reason before acting** is enabled by default in the app. Disabling it is faster but performed poorly in testing. Use a model that supports the selected thinking setting.

The upstream Chrome project already runs its cursor movement and scheduler entirely locally without model inference. Adding Qwen does not accelerate those animations; it adds desktop action selection, which is a different capability.

## Attribution

The original Swarm Rebuild extension by Dhvanil Patel and its acknowledgment of Joel Califa's Swarm remain in the repository. This desktop implementation uses native AppKit controls, Accessibility and independently drawn cursor indicators. No new license is assigned to upstream material; see the root README's license note.
