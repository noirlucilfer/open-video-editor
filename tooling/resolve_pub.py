#!/usr/bin/env python3
"""Resolve a Dart package's transitive hosted deps via pub.dev API (curl),
download tarballs, and print the resolved {name: version} map as JSON.
Usage: resolve_pub.py <pubspec.yaml> [--dev]
Only handles hosted deps with common constraints (^, exact, ranges).
SDK deps (sdk: flutter) are skipped — caller maps them to the local SDK.
"""
import json, re, subprocess, sys, urllib.request

PUB = "https://pub.dev"
DART_SDK = "3.13.5"  # running Dart version; filter incompatible package versions

def curl_json(url):
    out = subprocess.run(["curl", "-s", "--max-time", "30", url],
                         capture_output=True, text=True)
    return json.loads(out.stdout)

def parse_version(v):
    # strip build metadata, split numeric parts
    v = v.split("+")[0]
    parts = []
    for p in v.split("."):
        m = re.match(r"(\d+)", p)
        parts.append(int(m.group(1)) if m else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)

def satisfies(version, constraint):
    c = constraint.strip()
    if c == "any" or c == "":
        return True
    v = parse_version(version)
    # caret
    m = re.match(r"\^(\S+)", c)
    if m:
        lo = parse_version(m.group(1))
        if lo[0] == 0:
            hi = (0, lo[1] + 1, 0)
        else:
            hi = (lo[0] + 1, 0, 0)
        return lo <= v < hi
    # exact
    if re.match(r"^[\d.]+$", c):
        return v == parse_version(c)
    # ranges like ">=1.0.0 <2.0.0"
    ok = True
    for part in c.split():
        m = re.match(r"(>=|>|<=|<|=)?([\d.]+)", part)
        if not m:
            continue
        op, ver = m.group(1) or "=", parse_version(m.group(2))
        if op == ">=": ok &= v >= ver
        elif op == ">": ok &= v > ver
        elif op == "<=": ok &= v <= ver
        elif op == "<": ok &= v < ver
        else: ok &= v == ver
    return ok

_ver_cache = {}
def versions(name):
    if name not in _ver_cache:
        d = curl_json(f"{PUB}/api/packages/{name}")
        _ver_cache[name] = d["versions"]
    return _ver_cache[name]

def pick(name, constraint):
    cands = []
    for v in versions(name):
        ver = v["version"]
        if v.get("pubspec", {}).get("environment", {}).get("sdk"):
            if not satisfies(DART_SDK, v["pubspec"]["environment"]["sdk"]):
                continue
        if satisfies(ver, constraint):
            cands.append(ver)
    if not cands:
        raise SystemExit(f"No version of {name} satisfies '{constraint}'")
    cands.sort(key=parse_version, reverse=True)
    return cands[0]

def deps_of(name, version):
    for v in versions(name):
        if v["version"] == version:
            ps = v.get("pubspec", {})
            out = {}
            # NB: real pub only follows `dependencies` transitively;
            # dev_dependencies apply to the root package only (already queued).
            for section in ("dependencies",):
                for dn, spec in (ps.get(section) or {}).items():
                    if isinstance(spec, dict) and "sdk" in spec:
                        continue  # SDK dep, handled by caller
                    if isinstance(spec, dict):
                        continue  # git/path deps unsupported
                    out[dn] = spec if isinstance(spec, str) else "any"
            return out, ps.get("environment", {}).get("sdk")
    raise SystemExit(f"Version {version} of {name} not found")

def main():
    pubspec_path = sys.argv[1]
    with open(pubspec_path) as f:
        text = f.read()
    # minimal pubspec parse: dependencies: / dev_dependencies: sections
    resolved = {}
    queue = []
    in_deps = in_dev = False
    for line in text.splitlines():
        if re.match(r"^dependencies:\s*$", line):
            in_deps, in_dev = True, False
            continue
        if re.match(r"^dev_dependencies:\s*$", line):
            in_deps, in_dev = False, True
            continue
        if re.match(r"^[a-z_]+:", line):
            in_deps = in_dev = False
            continue
        m = re.match(r"^\s{2}(\S+):\s*(.*)$", line)
        if m and (in_deps or in_dev):
            name, spec = m.group(1), m.group(2).strip()
            if "sdk:" in spec or spec == "":
                # could be sdk dep on next line or empty; check next lines simply
                pass
            if "sdk" in spec:
                continue
            constraint = spec.strip("'\"") if spec else "any"
            queue.append((name, constraint))
    # handle multiline sdk specs: drop names whose block contains 'sdk:'
    # (simple approach: re-scan blocks)
    blocks = re.findall(r"^  (\S+):\s*\n((?:    .*\n)+)", text, re.M)
    sdk_names = {n for n, b in blocks if "sdk:" in b}
    queue = [(n, c) for n, c in queue if n not in sdk_names]

    while queue:
        name, constraint = queue.pop(0)
        if name in resolved:
            continue
        ver = pick(name, constraint)
        resolved[name] = ver
        sub, _ = deps_of(name, ver)
        for sn, sc in sub.items():
            if sn not in resolved:
                queue.append((sn, sc))
    print(json.dumps(resolved, indent=1))

main()
