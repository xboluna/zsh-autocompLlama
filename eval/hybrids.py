#!/usr/bin/env python3
"""Offline what-ifs over predictions.jsonl: how the 3B router behaves with a
prose-only gate (the plugin only routes sentences, never commands or typos)
and with a tiny-model veto (route only when the small model also routes)."""
import json, collections, statistics
from router_eval import ACTIONS, args_match
P = collections.defaultdict(dict)
for l in open("predictions.jsonl"):
    r = json.loads(l); P[r["candidate"]][r["text"]] = r
FUNCTION_WORDS = {"the","a","an","my","me","i","this","that","these","those","please","how","what","which",
                  "where","who","whom","whose","to","of","from","with","into","onto","all","any","some","every"}
def looks_like_prose(t):
    w = t.split()
    return len(w) >= 3 and sum(x.lower() in FUNCTION_WORDS for x in w) >= 2
def first_word_is_command(t):
    return t.split()[0] in {"git","ls","docker","gti","cd","ssh","kill"}  # stand-in for whence
def score(name, decide):
    rows = list(P["q3b-schema"].values()); n = len(rows)
    ok_a = ok_f = fp = neg = 0; lat = []
    for r in rows:
        got, args, ms = decide(r)
        lat.append(ms)
        if r["expected"] == "none": neg += 1; fp += got not in ("none", "error")
        a = got == r["expected"]; ok_a += a
        ok_f += a and args_match(r["expected"], r["expected_args"], args)
    print(f"| {name} | {ok_a/n:.1%} | {ok_f/n:.1%} | {fp}/{neg} | {statistics.median(lat):.0f} |")
def base(r): return r["got"], r["got_args"], r["ms"]
def gated(r):
    t = r["text"]
    if first_word_is_command(t) and not looks_like_prose(t): return "none", {}, 0
    return base(r)
def veto(other):
    def f(r):
        o = P[other].get(r["text"])
        if o and o["got"] == "none": return "none", {}, r["ms"] + o["ms"]
        return r["got"], r["got_args"], r["ms"] + (o["ms"] if o else 0)
    return f
def gated_veto(other):
    v = veto(other)
    def f(r):
        t = r["text"]
        if first_word_is_command(t) and not looks_like_prose(t): return "none", {}, 0
        return v(r)
    return f
print("| variant | action acc | full acc | false positives | p50 ms |")
print("| --- | --- | --- | --- | --- |")
score("q3b-schema alone", base)
score("q3b + input gate (commands and typos never routed)", gated)
score("q3b + qwen3:0.6b veto", veto("q06-schema"))
score("q3b + tev1 veto", veto("tev1-dec"))
score("q3b + gate + qwen3:0.6b veto", gated_veto("q06-schema"))
print()
print("3B false positives in detail:")
for r in P["q3b-schema"].values():
    if r["expected"] == "none" and r["got"] not in ("none", "error"):
        print(f"  {r['text']!r:<45} -> {r['got']} {r['got_args']}  (prose={looks_like_prose(r['text'])}, cmd-first={first_word_is_command(r['text'])})")
