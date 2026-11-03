# Local planner measurements — 3 November 2026

Development machine: Intel MacBookPro15,1, six CPU cores, 32 GB RAM. Ollama 0.40.13 reported CPU inference and no GPU VRAM. These are single sequential runs on an in-use Mac, not controlled microbenchmarks; concurrent machine load and warm caches affect latency.

| Model | Prompt | Thinking | Exact passes | Median wall time | Observed range |
|---|---|---|---|---|---|
| Qwen3 0.6B | Examples included | Off | 2 / 6 | 1.45 s | 1.20–7.61 s |
| Qwen3.5 0.8B Q8_0 | Examples included | Off | 3 / 6 | 6.62 s | 4.21–10.74 s |
| Qwen3 0.6B | Examples included | On | 5 / 6 | 9.87 s | 5.11–69.93 s |

The initial short prompt, with thinking disabled and a 2,048-token context, scored 0/6 for both models. The current example-based prompt uses an 8,192-token context. Structured final output is limited to 160 generated tokens without thinking; the thinking run has a 768-token budget including reasoning. Current reports include the exact prompt. Baseline reports retain raw responses but predate embedded prompt/config metadata.

Passing requires exact agreement on action, target and text. Failure modes included inventing completion before acting, selecting the wrong control, truncating a requested name, proposing a redundant edit, and responding to instructions inside an untrusted button label. In the thinking run the untrusted-label case failed to produce a parseable final action; the app treats such responses as errors and executes nothing. The already-completed case passed but took 69.93 seconds.

**Decision:** Qwen3 0.6B can be used as an experimental, reviewed action proposer with thinking enabled. It is not sufficiently established as an unattended desktop operator. Fast mode saves time at a substantial accuracy cost on this test. Five successes on six synthetic tasks do not establish general reliability, and the benchmark does not measure vision, long workflows, or native Accessibility execution.

No cloud model was benchmarked, so these results do not establish that local inference is faster than a hosted model. The original extension does no inference at all; its deterministic motion remains the appropriate way to animate cursors. Keep one shared model for occasional planning and run animation independently.

The app default is Qwen3 0.6B with reasoning enabled and explicit approval for each proposed action. Both tested models remain installed locally. Reports contain only synthetic test data.

## Existing Loupe workflow

The user's existing Loupe CLI uses Qwen3.5 0.8B, span narrowing and structured refinement. A separate `fix` smoke test on `def avg(xs): return sum(xs) / len(xs)` completed in 76.45 seconds and returned the input unchanged, leaving the empty-list division error unresolved. Exit status zero therefore did not establish a successful repair. The bridge now escalates unchanged fix/refactor results to GPT and marks every proposal as behavior-unverified; no generated code is applied automatically.

The Codex bridge gives local workers narrower responsibilities than the standalone planner benchmark: GPT supplies the operation and replacement text, exact unique labels resolve without inference, and Qwen may select only among a small set of observed target IDs. The table above does not measure this newer target-resolution workflow or prove that Loupe speeds up a complete task.
