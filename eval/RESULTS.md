# Action-router eval: which local model should route a sentence to a typed shell action?

Due diligence for the "quick actions" idea: a registry of twelve typed actions
(switch kubectl context, set AWS profile, start/stop/restart a brew service,
open the branch's PR, open a file at a line, kill or show the process on a
port, checkout a branch by fragment, run tests, changes since a time, tail a
service log, disk usage) and the question of which model maps a sentence to
one of them, with arguments, fast enough for a shell.

Machine: Apple Silicon laptop, ollama 0.35.1, 2026-10-08. 97 labelled
sentences in `sentences.jsonl`: 81 across the twelve actions and 16 negatives
(ordinary commands, typos, and sentences no action covers). Harness:
`router_eval.py` (stdlib Python). Latency is the wall time of the HTTP call,
warm model, median and 95th percentile. "Full" means action and every
required argument correct. "False positives" are negatives routed to an
action, the metric that decides whether this feels helpful or annoying.

## Results

| candidate | model, mode | action acc | full acc | false positives | p50 ms | p95 ms |
| --- | --- | --- | --- | --- | --- | --- |
| fg-tools | functiongemma 270M, native tool calling | 40.2% | 29.9% | 1/16 | 311 | 719 |
| fg-schema | functiongemma 270M, JSON schema | 50.5% | 34.0% | 11/16 | 283 | 429 |
| q3b-schema | qwen2.5-coder:3b, JSON schema (the plugin's model) | 90.7% | 79.4% | 6/16 | 673 | 1026 |
| **q3b-strict** | **same, stricter "none" instruction with negative examples** | **94.8%** | **83.5%** | **2/16** | **512** | **703** |
| q06-schema | qwen3:0.6b, no thinking, JSON schema | 64.9% | 52.6% | 0/16 | 201 | 366 |
| tev1-dec | tev1:0.8b, decision lane, routing + enum args in one call | 61.9% | 42.3% | 0/16 | 710 | 1039 |
| tev1-route | tev1:0.8b, decision lane, routing question only | 47.4% | 29.9% | 0/16 | 162 | 261 |

Offline what-ifs over the per-sentence predictions (`hybrids.py`), on the
plain 3B prompt:

| variant | action acc | full acc | false positives | p50 ms |
| --- | --- | --- | --- | --- |
| 3B alone | 90.7% | 79.4% | 6/16 | 673 |
| 3B + the plugin's input gate (commands and typos are never routed) | 90.7% | 79.4% | 4/16 | 659 |
| 3B + qwen3:0.6b veto (route only if both route) | 70.1% | 60.8% | 0/16 | 865 |
| 3B + tev1 veto | 72.2% | 61.9% | 0/16 | 1416 |

The two remaining false positives of the strict prompt are `gti pus` (a typo,
which the plugin's gate never sends to a router) and `undo my last commit but
keep the changes` (routed to "changes since", a near miss the existing
translation path would then handle on a "none").

## Findings

1. **functiongemma is not usable through ollama 0.35.1.** Its chat template
   is a bare `{{ .Prompt }}` with a native renderer and parser; the model
   page's own weather example returns empty content and no tool call, a
   single tool yields a malformed call (`model:kill_port{}`, name empty),
   and operational sentences are refused outright ("I cannot assist with
   restarting services", "I cannot assist with managing Git statuses").
   Sending Google's raw declaration format through `/api/generate` is no
   better: the control tokens are not honoured. This matches a cluster of
   open ollama issues about dropped and malformed Gemma tool calls. On top of
   that it is not faster than a 0.6B general model here (311 vs 201 ms).
2. **The decision lane does not fit this shape.** tev1:0.8b with the routing
   question plus every enum argument as further questions costs 710 ms, more
   than the 3B, because each question lengthens the prompt; routing alone is
   162 ms but only 47% accurate. It cannot produce a port, a path or a branch
   fragment at all. Its one virtue, zero false positives, comes from saying
   "none" too readily.
3. **Vetoes are a bad trade.** Gating the 3B on a tiny model's agreement
   removes every false positive but costs twenty points of accuracy and
   200 to 700 ms, because the small models decline too much.
4. **The model already running wins, with a better prompt.** Four sentences of
   explicit "this is none" guidance moved the 3B from 90.7% to 94.8% action
   accuracy, 79.4% to 83.5% fully correct, and 6 to 2 false positives, at no
   cost in in-registry sentences and with a lower median (512 ms, since a
   decisive "none" is shorter to produce). The remaining argument errors are
   normalisation (`' prod eu cluster'` for `prod-eu`), which enum-constrained
   schemas per action would remove.

## Recommendation

Build the action registry on the plugin's existing qwen2.5-coder:3b with the
strict routing prompt and the existing input gate, as a step before the
translation path. Expected DevEx: roughly five in six sentences that name a
registered action get a fully correct, concrete command line to confirm with
→ in about half a second; one in eight out-of-registry sentences gets a
near-miss action instead of a free-form translation, which the → confirmation
makes a mild annoyance rather than a wrong action. No new model, no new
runtime, nothing added to the installer.

Revisit functiongemma when ollama's Gemma tool-call parser is fixed; the
harness runs against it unchanged. Revisit the decision lane only for a pure
yes/no gate (is this destructive?), where one question costs 160 ms.

## Reproduce

```sh
ollama pull functiongemma tev1:0.8b qwen3:0.6b     # the 3B is already there
cd eval
python3 router_eval.py --markdown                   # all candidates, ~5 min
python3 router_eval.py -c q3b-strict -v             # one candidate, with failures
python3 router_eval.py -c q3b-schema -c q06-schema -c tev1-dec --dump predictions.jsonl
python3 hybrids.py                                  # gate and veto what-ifs
```

Generation is capped at 96 tokens per call: without the cap, functiongemma's
degenerate outputs ran for sixteen seconds each and one stuck request blocked
ollama's single slot for everything else.
