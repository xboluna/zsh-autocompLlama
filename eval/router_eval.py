#!/usr/bin/env python3
"""Action-router eval: which local model best maps a sentence to one of a dozen
typed shell actions, and how fast. Python stdlib only; talks to ollama.

  python3 router_eval.py                 # all candidates, all sentences
  python3 router_eval.py -c fg-tools     # one candidate
  python3 router_eval.py --repeat 3      # repeat each sentence (latency)
  python3 router_eval.py --markdown      # results table for RESULTS.md

Candidates (name: model, mode):
  fg-tools    functiongemma, native tool calling (/api/chat with tools)
  fg-schema   functiongemma, JSON schema output (/api/chat with format)
  q3b-schema  qwen2.5-coder:3b, JSON schema output (the plugin's current model)
  q3b-strict  the same with a stricter 'none' instruction and negative examples
  q06-schema  qwen3:0.6b (no thinking), JSON schema output
  tev1-dec    tev1:0.8b, decision lane (/v1/systemone): routing plus enum
              arguments in one call; it cannot produce free-text arguments
  tev1-route  tev1:0.8b, decision lane, the routing question only (latency
              floor; arguments would need a second call)

Metrics per candidate: action accuracy (including 'none'), full accuracy
(action and every required argument), false positives (an action where
'none' was expected), latency p50/p95 of the HTTP call, and ollama's own
total_duration where it reports one.
"""
import argparse, json, statistics, sys, time, urllib.request, urllib.error

OLLAMA = "http://localhost:11434"
ACTIONS = json.load(open("actions.json"))
SENTENCES = [json.loads(l) for l in open("sentences.jsonl") if l.strip()]

SYSTEM = ("You route what a shell user typed to one of the actions below, with its "
          "arguments, or to none when no action fits. Only route when the user clearly "
          "means that action.")

def post(path, body, timeout=120):
    req = urllib.request.Request(OLLAMA + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read())
    return data, (time.perf_counter() - t0) * 1000

# ---------------- tool and schema builders ----------------
def tools_spec():
    out = []
    for name, a in ACTIONS.items():
        props = {}
        for p, spec in a["params"].items():
            props[p] = {k: v for k, v in spec.items()}
        out.append({"type": "function", "function": {
            "name": name, "description": a["description"],
            "parameters": {"type": "object", "properties": props, "required": a["required"]}}})
    return out

def schema_spec():
    props = {}
    for a in ACTIONS.values():
        for p, spec in a["params"].items():
            props.setdefault(p, {k: v for k, v in spec.items() if k != "description"})
    return {"type": "object",
            "properties": {"name": {"type": "string", "enum": list(ACTIONS) + ["none"]},
                           "args": {"type": "object", "properties": props}},
            "required": ["name", "args"]}

def actions_text():
    lines = []
    for name, a in ACTIONS.items():
        ps = ", ".join(f"{p}: {s.get('type')}" + (f" one of {s['enum']}" if 'enum' in s else "")
                       for p, s in a["params"].items()) or "no arguments"
        lines.append(f"- {name}: {a['description']} ({ps})")
    lines.append("- none: nothing above fits")
    return "\n".join(lines)

# ---------------- candidates ----------------
def run_tools(model, text):
    body = {"model": model, "stream": False, "options": {"temperature": 0, "num_predict": 96},
            "messages": [{"role": "system", "content": SYSTEM + "\nCall no tool if none fits."},
                         {"role": "user", "content": text}],
            "tools": tools_spec()}
    data, ms = post("/api/chat", body)
    calls = data.get("message", {}).get("tool_calls") or []
    if not calls:
        return "none", {}, ms, data.get("total_duration")
    fn = calls[0]["function"]
    return fn.get("name", "none"), fn.get("arguments") or {}, ms, data.get("total_duration")

STRICT = ("\n\nAnswer none unless the request is exactly what one action does. Similar is not enough: "
          "a request about git history, commits, pulling or pushing is none unless it asks what changed since a time; "
          "a question about a file or its contents is none unless it asks to open the file; "
          "a request about a port is none unless it asks to kill or show the process on a numbered port. "
          "Examples that are none: 'show the last 5 commits', 'undo my last commit', 'pull from this repo', "
          "'how many lines are in this file', 'compress the logs folder'.")

def schema_spec_combined():
    sc = schema_spec()
    # Enums are the union over actions sharing a parameter name; the eval's
    # first version kept only the first action's enum, which made some
    # arguments impossible to produce.
    props = {}
    for a in ACTIONS.values():
        for p, spec in a["params"].items():
            cur = props.setdefault(p, {"type": spec["type"]})
            if "enum" in spec:
                cur.setdefault("enum", []); cur["enum"] = sorted(set(cur["enum"]) | set(spec["enum"]))
    sc["properties"]["args"]["properties"] = props
    sc["properties"]["cmd"] = {"type": "string"}
    sc["required"] = ["name", "args", "cmd"]
    return sc

def run_schema(model, text, think=None, strict=False, combined=False):
    task = SYSTEM + "\n\nActions:\n" + actions_text() + (STRICT if strict else "")
    if combined:
        task += ("\n\nWhen no action fits but the text describes something a single shell command "
                 "does, put that command in \"cmd\" with name none; otherwise cmd is an empty string.")
    body = {"model": model, "stream": False, "options": {"temperature": 0, "num_predict": 96},
            "messages": [{"role": "system", "content": task +
                          "\n\nAnswer as JSON: {\"name\": <action or none>, \"args\": {...}" + (", \"cmd\": ..." if combined else "") + "}."},
                         {"role": "user", "content": "Typed: " + text}],
            "format": schema_spec_combined() if combined else schema_spec()}
    if think is not None:
        body["think"] = think
    data, ms = post("/api/chat", body)
    try:
        obj = json.loads(data["message"]["content"])
    except Exception:
        return "none", {}, ms, data.get("total_duration")
    return obj.get("name", "none"), obj.get("args") or {}, ms, data.get("total_duration")

def run_decision(model, text, route_only=False):
    questions = {"action": {"type": "choice", "instructions": SYSTEM + " Which action, if any?",
                            "criteria": {n: a["description"] for n, a in ACTIONS.items()} | {"none": "No action fits."}}}
    for name, a in ({} if route_only else ACTIONS).items():
        for p, spec in a["params"].items():
            if "enum" in spec:
                questions[f"{name}.{p}"] = {"type": "choice",
                    "instructions": f"For the action '{name}': {spec['description']}",
                    "criteria": {v: v for v in spec["enum"]}}
    data, ms = post("/v1/systemone", {"model": model, "state": text, "questions": questions})
    answers = data.get("answers", {})
    action = answers.get("action", {}).get("choice", "none")
    args = {}
    if action in ACTIONS:
        for p in ACTIONS[action]["params"]:
            q = answers.get(f"{action}.{p}")
            if q: args[p] = q.get("choice")
    return action, args, ms, None

def run_schema_enum(text):
    body = {"model": "qwen2.5-coder:3b", "stream": False, "options": {"temperature": 0, "num_predict": 96},
            "messages": [{"role": "system", "content": SYSTEM + "\n\nActions:\n" + actions_text() + STRICT +
                          "\n\nAnswer as JSON: {\"name\": <action or none>, \"args\": {...}}."},
                         {"role": "user", "content": "Typed: " + text}],
            "format": {**schema_spec_combined(), "required": ["name", "args"]}}
    body["format"]["properties"].pop("cmd")
    data, ms = post("/api/chat", body)
    try: obj = json.loads(data["message"]["content"])
    except Exception: return "none", {}, ms, data.get("total_duration")
    return obj.get("name", "none"), obj.get("args") or {}, ms, data.get("total_duration")

CANDIDATES = {
    "fg-tools":   lambda t: run_tools("functiongemma", t),
    "fg-schema":  lambda t: run_schema("functiongemma", t),
    "q3b-schema": lambda t: run_schema("qwen2.5-coder:3b", t),
    "q3b-strict": lambda t: run_schema("qwen2.5-coder:3b", t, strict=True),
    "q3b-strict-enum": lambda t: run_schema("qwen2.5-coder:3b", t, strict=True, combined=False) if False else run_schema_enum(t),
    "q3b-combined": lambda t: run_schema("qwen2.5-coder:3b", t, strict=True, combined=True),
    "q06-schema": lambda t: run_schema("qwen3:0.6b", t, think=False),
    "tev1-dec":   lambda t: run_decision("tev1:0.8b", t),
    "tev1-route": lambda t: run_decision("tev1:0.8b", t, route_only=True),
}

# ---------------- scoring ----------------
def norm(v):
    if isinstance(v, str):
        v = v.strip().strip("'\"")
        try: return int(v)
        except ValueError: return v.lower().rstrip("/").removeprefix("./")
    return v

def args_match(action, expected, got):
    if action not in ACTIONS: return True
    for p in ACTIONS[action]["required"]:
        if norm(expected.get(p)) != norm(got.get(p)): return False
    for p, v in expected.items():
        if p not in ACTIONS[action]["required"] and p in got and norm(v) != norm(got[p]): return False
    return True

def evaluate(name, fn, repeat, verbose, dump=None):
    rows, lat, dur = [], [], []
    for s in SENTENCES:
        for _ in range(repeat):
            try:
                action, args, ms, total = fn(s["text"])
            except Exception as e:
                action, args, ms, total = "error", {}, float("nan"), None
                if verbose: print(f"    error on {s['text']!r}: {e}", file=sys.stderr)
            lat.append(ms)
            if total: dur.append(total / 1e6)
        ok_action = action == s["action"]
        ok_full = ok_action and args_match(s["action"], s["args"], args)
        rows.append((s, action, args, ok_action, ok_full))
        if dump:
            dump.write(json.dumps({"candidate": name, "text": s["text"], "expected": s["action"],
                                   "expected_args": s["args"], "got": action, "got_args": args, "ms": ms}) + "\n")
        if verbose and not ok_full:
            print(f"    {'ACTION' if not ok_action else 'ARGS  '} {s['text']!r}: expected {s['action']} {s['args']}, got {action} {args}")
    n = len(rows)
    acc_a = sum(r[3] for r in rows) / n
    acc_f = sum(r[4] for r in rows) / n
    negatives = [r for r in rows if r[0]["action"] == "none"]
    fp = sum(1 for r in negatives if r[1] not in ("none", "error"))
    lat_ok = [x for x in lat if x == x]
    p50 = statistics.median(lat_ok) if lat_ok else float("nan")
    p95 = sorted(lat_ok)[int(len(lat_ok) * 0.95) - 1] if len(lat_ok) >= 20 else max(lat_ok, default=float("nan"))
    d50 = statistics.median(dur) if dur else None
    return {"candidate": name, "action_acc": acc_a, "full_acc": acc_f, "false_pos": fp,
            "negatives": len(negatives), "p50_ms": p50, "p95_ms": p95, "ollama_p50_ms": d50, "n": n,
            "rows": rows}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--candidate", action="append")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--dump", help="append per-sentence predictions as JSONL to this file")
    a = ap.parse_args()
    dump = open(a.dump, "a") if a.dump else None
    names = a.candidate or list(CANDIDATES)
    results = []
    for name in names:
        print(f"== {name}", file=sys.stderr)
        # warm the model once so the first sentence does not pay the load
        try: CANDIDATES[name]("warm up")
        except Exception as e: print(f"   warm-up failed: {e}", file=sys.stderr)
        results.append(evaluate(name, CANDIDATES[name], a.repeat, a.verbose, dump))
    if a.markdown:
        print("| candidate | action acc | full acc | false positives | p50 ms | p95 ms |")
        print("| --- | --- | --- | --- | --- | --- |")
    for r in results:
        if a.markdown:
            print(f"| {r['candidate']} | {r['action_acc']:.1%} | {r['full_acc']:.1%} | {r['false_pos']}/{r['negatives']} | {r['p50_ms']:.0f} | {r['p95_ms']:.0f} |")
        else:
            print(f"{r['candidate']:<11} action {r['action_acc']:.1%}  full {r['full_acc']:.1%}  "
                  f"false-pos {r['false_pos']}/{r['negatives']}  p50 {r['p50_ms']:.0f} ms  p95 {r['p95_ms']:.0f} ms"
                  + (f"  (ollama p50 {r['ollama_p50_ms']:.0f} ms)" if r['ollama_p50_ms'] else ""))

if __name__ == "__main__":
    main()
