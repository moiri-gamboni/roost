#!/usr/bin/env python3
"""sym — whole definitions and their callers by name, over Bash, Python and TypeScript/JavaScript.

    sym body NAME [PATH...]               every definition of NAME, whole, with file:first-last
    sym callers NAME [PATH...] [--bodies] every call of NAME: file:line, the enclosing definition, the call line
                                          (--bodies: the enclosing definitions in full instead)

NAME is a bare name (every function, method or class called that) or Class.method. PATH defaults to the current
directory. Built on ast-grep: definitions are cut by the syntax tree, never by a guessed line count. Callers are
matched by name, not resolved, so same-named functions elsewhere are counted too.

Searches gitignored directories (the apart-research parent repo ignores every nested repo) but skips hidden
directories and the generated or mirrored trees in SKIP_GLOBS. Exit 0 on a result, 1 when nothing matched,
2 on a usage or ast-grep error.
"""
import json
import os
import re
import subprocess
import sys

# HTML and minified bundles: ast-grep parses the scripts inside every .html file, and a few multi-megabyte
# generated pages (inline plotting libraries) made a TypeScript/JavaScript scan of apart-research take ~7 s
# and ~1 GB; excluding them brings it under 0.2 s.
SKIP_GLOBS = ["!**/node_modules/**", "!**/dist/**", "!**/build/**", "!**/__pycache__/**",
              "!**/venv/**", "!**/site-packages/**", "!**/*.html", "!**/*.min.js",
              "!notion/**", "!data/**", "!drive/**"]

# Per ast-grep language: the definition kinds (each with a `name` field), the kinds that qualify a method's name,
# and the call rule, whose NAME placeholder becomes an anchored regex.
LANGS = {
    "Bash": {
        "defs": ["function_definition"],
        "containers": [],
        "call": {"kind": "command", "has": {"field": "name", "regex": "NAME"}},
    },
    "Python": {
        "defs": ["function_definition", "class_definition"],
        "containers": ["class_definition"],
        "call": {"kind": "call", "has": {"field": "function", "any": [
            {"kind": "identifier", "regex": "NAME"},
            {"kind": "attribute", "has": {"field": "attribute", "regex": "NAME"}}]}},
    },
}
_JS = {
    "defs": ["function_declaration", "generator_function_declaration", "method_definition", "class_declaration",
             "abstract_class_declaration", "interface_declaration", "type_alias_declaration", "variable_declarator"],
    "containers": ["class_declaration", "abstract_class_declaration", "class"],
    "call": {"kind": "call_expression", "has": {"field": "function", "any": [
        {"kind": "identifier", "regex": "NAME"},
        {"kind": "member_expression", "has": {"field": "property", "regex": "NAME"}}]}},
}
# JavaScript's grammar has no type-only declarations; ast-grep rejects kinds a grammar lacks.
LANGS["TypeScript"] = LANGS["Tsx"] = _JS
LANGS["JavaScript"] = dict(_JS, defs=[k for k in _JS["defs"] if k not in (
    "abstract_class_declaration", "interface_declaration", "type_alias_declaration")],
    containers=["class_declaration", "class"])


def fill(rule, regex):
    """Copy of `rule` with every "NAME" placeholder replaced by `regex`."""
    if isinstance(rule, dict):
        return {k: fill(v, regex) for k, v in rule.items()}
    if isinstance(rule, list):
        return [fill(v, regex) for v in rule]
    return regex if rule == "NAME" else rule


def def_rule(kinds, name_rule):
    return {"any": [{"kind": k, "has": {"field": "name", **name_rule}} for k in kinds]}


def rules_for(mode, name, cls):
    """ast-grep inline rules: ids are "<kind of match>:<language>"."""
    exact = {"regex": f"^{re.escape(name)}$"}
    capture = {"pattern": "$NAME"}
    docs = []
    for lang, spec in LANGS.items():
        call = fill(spec["call"], exact["regex"])
        if mode == "body":
            docs.append({"id": f"def:{lang}", "language": lang, "rule": def_rule(spec["defs"], exact)})
        else:
            docs.append({"id": f"call:{lang}", "language": lang, "rule": call})
            docs.append({"id": f"def:{lang}", "language": lang,
                         "rule": {**def_rule(spec["defs"], capture), "has": {**call, "stopBy": "end"}}})
        if spec["containers"]:
            inner = def_rule(spec["defs"], exact) if mode == "body" else call
            name_rule = {"regex": f"^{re.escape(cls)}$"} if cls else capture
            docs.append({"id": f"container:{lang}", "language": lang,
                         "rule": {**def_rule(spec["containers"], name_rule), "has": {**inner, "stopBy": "end"}}})
    return "\n---\n".join(json.dumps(d) for d in docs)


def scan(rules, paths):
    cmd = ["ast-grep", "scan", "--inline-rules", rules, "--json=stream", "--no-ignore", "vcs"]
    for g in SKIP_GLOBS:
        cmd += ["--globs", g]
    try:
        proc = subprocess.run(cmd + paths, capture_output=True, text=True)
    except FileNotFoundError:
        sys.exit("sym: ast-grep is not on PATH")
    if proc.returncode not in (0, 1):
        sys.stderr.write(proc.stderr)
        sys.exit(2)
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


def node(m):
    kind = m["ruleId"].split(":", 1)[0]
    single = m.get("metaVariables", {}).get("single", {})
    name = single["NAME"]["text"] if "NAME" in single else None
    r = m["range"]
    return {"kind": kind, "file": m["file"], "start": r["start"]["line"] + 1, "end": r["end"]["line"] + 1,
            "text": m["text"], "lines": m["lines"], "name": name}


def contains(outer, inner):
    return outer["file"] == inner["file"] and outer["start"] <= inner["start"] and inner["end"] <= outer["end"] \
        and (outer["start"], outer["end"]) != (inner["start"], inner["end"])


def qualified(defn, containers, name=None):
    """Name of a definition prefixed by the innermost class that holds it."""
    own = name or defn["name"] or "?"
    holders = [c for c in containers if contains(c, defn)]
    if not holders:
        return own
    holder = min(holders, key=lambda c: c["end"] - c["start"])
    return f"{holder['name'] or '?'}.{own}"


def body(name, cls, paths):
    found = [node(m) for m in scan(rules_for("body", name, cls), paths)]
    defs = [n for n in found if n["kind"] == "def"]
    containers = [n for n in found if n["kind"] == "container"]
    if cls:
        defs = [d for d in defs if any(contains(c, d) for c in containers)]
    for c in containers:
        c["name"] = cls or c["name"]
    # A class holding NAME is also returned as a container; never print it as a definition of NAME.
    defs = [d for d in defs if not any(d is c for c in containers)]
    for d in sorted(defs, key=lambda d: (d["file"], d["start"])):
        print(f"== {d['file']}:{d['start']}-{d['end']}  {qualified(d, containers, name)}")
        print(d["lines"])
        print()
    return bool(defs)


def callers(name, paths, bodies):
    found = [node(m) for m in scan(rules_for("callers", name, None), paths)]
    calls = [n for n in found if n["kind"] == "call"]
    defs = [n for n in found if n["kind"] == "def"]
    containers = [n for n in found if n["kind"] == "container"]
    shown = set()
    for call in sorted(calls, key=lambda c: (c["file"], c["start"])):
        holders = [d for d in defs if contains(d, call) or (d["file"] == call["file"]
                   and d["start"] <= call["start"] <= d["end"] and d["text"] != call["text"])]
        holder = min(holders, key=lambda d: d["end"] - d["start"]) if holders else None
        where = f"in {qualified(holder, containers)}" if holder else "(top level)"
        if not bodies:
            first = call["lines"].splitlines()[0].strip() if call["lines"] else call["text"]
            print(f"{call['file']}:{call['start']}  {where}  {first}")
        elif holder and id(holder) not in shown:
            shown.add(id(holder))
            print(f"== {holder['file']}:{holder['start']}-{holder['end']}  {qualified(holder, containers)}")
            print(holder["lines"])
            print()
        elif not holder:
            print(f"== {call['file']}:{call['start']}  (top level)")
            print(call["lines"])
            print()
    return bool(calls)


def main(argv):
    args = [a for a in argv if a != "--bodies"]
    if len(args) < 2 or args[0] not in ("body", "callers") or args[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 2
    mode, target, paths = args[0], args[1], args[2:] or ["."]
    cls, _, name = target.rpartition(".") if "." in target else ("", "", target)
    if mode == "body":
        ok = body(name, cls or None, paths)
    else:
        ok = callers(target if not cls else name, paths, "--bodies" in argv)
    if not ok:
        what = "definition" if mode == "body" else "call"
        print(f"sym: no {what} of {target} under {' '.join(paths)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
