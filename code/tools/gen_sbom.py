#!/usr/bin/env python3
"""
Regenerate sbom.json (SPDX 2.3) by descending into a directory tree.

Sources scanned (mixed shell + python project):
  * requirements*.txt / constraints*.txt          -> PyPI packages
  * pyproject.toml (project + optional deps)      -> PyPI packages
  * *.sh / *.bash / Dockerfile* / Makefile        -> `pip install ...`, `apt-get install ...`
  * *.py imports (3rd party, resolved through     -> PyPI packages
    the *installed* distributions)

The existing sbom.json is used as a baseline:
  * document name / dataLicense / SPDXID / display names are preserved
  * package entries that are still found are reused as-is (no network needed)
  * package entries that are no longer found are dropped
  * new packages are looked up on PyPI (checksum, wheel URL, license, author)

Usage:
  python3 gen_sbom.py                       # scan cwd, update ./sbom.json
  python3 gen_sbom.py -r . -o sbom.json
  python3 gen_sbom.py --dry-run             # just print what would change
  python3 gen_sbom.py --offline             # never hit PyPI
  python3 gen_sbom.py --no-imports --no-apt # restrict sources
"""
import argparse
import ast
import json
import os
import re
import shutil
import sys
import urllib.request
from datetime import datetime, timezone
from importlib import metadata

try:
    import tomllib  # py3.11+
except ImportError:  # pragma: no cover
    tomllib = None

SKIP_DIRS = {".git", ".hg", ".svn", "venv", ".venv", "env", "node_modules",
             "__pycache__", ".tox", ".mypy_cache", ".pytest_cache", "build",
             "dist", "vendor", "site-packages", ".eggs"}
TOOL = "custom-python-sbom-generator-2.0"
DEFAULT_NAME = "ocp-windtunnel-sbom"


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def spdx_id(prefix, name):
    return "SPDXRef-" + prefix + "-" + re.sub(r"[^A-Za-z0-9.\-]", "-", name)


# --------------------------------------------------------------------------
# discovery
# --------------------------------------------------------------------------
class Found:
    """key=(ecosystem, normalized-name) -> {name, version, sources:set}"""
    def __init__(self):
        self.pk = {}

    def add(self, eco, name, version, source):
        k = (eco, norm(name) if eco == "pypi" else name)
        e = self.pk.setdefault(k, {"name": name, "version": None, "sources": set()})
        if version and not e["version"]:
            e["version"] = version
        e["sources"].add(source)


REQ_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*(.*)$")


def parse_req(spec):
    """'requests[socks]==2.32.5 ; python_version>"3"' -> ('requests', '2.32.5')"""
    spec = spec.split(";")[0].split(" #")[0].strip().strip("\"'")
    if not spec or spec[0] in "-#." or "://" in spec or "/" in spec or "$" in spec:
        return None
    m = REQ_RE.match(spec)
    if not m:
        return None
    ver = re.search(r"===?\s*([A-Za-z0-9.!+_-]+)", m.group(3))
    return m.group(1), (ver.group(1) if ver else None)


def scan_requirements(path, found, rel):
    with open(path, errors="replace") as f:
        for line in f:
            r = parse_req(line.strip())
            if r:
                found.add("pypi", r[0], r[1], rel)


def scan_pyproject(path, found, rel):
    if not tomllib:
        return
    with open(path, "rb") as f:
        try:
            d = tomllib.load(f)
        except Exception:
            return
    specs = list(d.get("project", {}).get("dependencies", []))
    for lst in d.get("project", {}).get("optional-dependencies", {}).values():
        specs += lst
    for lst in d.get("dependency-groups", {}).values():
        specs += [s for s in lst if isinstance(s, str)]
    for s in specs:
        r = parse_req(s)
        if r:
            found.add("pypi", r[0], r[1], rel)
    for n, v in d.get("tool", {}).get("poetry", {}).get("dependencies", {}).items():
        if n.lower() != "python":
            ver = v if isinstance(v, str) and re.match(r"^\d", v) else None
            found.add("pypi", n, ver, rel)


PIP_ARG_OPTS = {"-r", "--requirement", "-c", "--constraint", "-e", "--editable",
                "-i", "--index-url", "--extra-index-url", "-f", "--find-links",
                "-t", "--target", "--prefix", "--root", "--platform",
                "--python-version", "--implementation", "--abi", "--proxy"}
DEB_RE = re.compile(r"^[a-z0-9][a-z0-9+.\-]+(=[A-Za-z0-9.+:~\-]+)?$")


def logical_lines(path):
    buf = ""
    with open(path, errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.rstrip().endswith("\\"):
                buf += line.rstrip()[:-1] + " "
                continue
            yield buf + line
            buf = ""
    if buf:
        yield buf


LEAD_WORDS = {"then", "do", "else", "elif", "if", "!", "time", "exec", "command"}
SKIP_CMDS = {"echo", "printf", "print", "read", "log", "info", "warn", "error", "die", "cat"}


def command_tokens(seg):
    """Strip prefixes (RUN, sudo, env, VAR=x, then/do/...) so toks[0] is the real command."""
    toks = seg.split()
    while toks:
        t = toks[0]
        if t in LEAD_WORDS or t in ("RUN", "sudo", "env", "-E") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=\S*$", t):
            toks = toks[1:]
        else:
            break
    return toks


def scan_shell(path, found, rel, want_apt):
    for line in logical_lines(path):
        line = line.split("#")[0]
        for seg in re.split(r"&&|\|\||[;|]", line):
            toks = command_tokens(seg)
            if len(toks) < 3 or toks[0] in SKIP_CMDS:
                continue
            cmd = os.path.basename(toks[0])
            is_pip = (re.match(r"^pip3?(\.\d+)?$", cmd) and toks[1] == "install" and 2) or \
                     (re.match(r"^python3?(\.\d+)?$", cmd) and toks[1:3] == ["-m", "pip"] and len(toks) > 3
                      and toks[3] == "install" and 4)
            if is_pip:
                skip = False
                for a in toks[is_pip:]:
                    if skip:
                        skip = False
                        continue
                    if a in PIP_ARG_OPTS:
                        skip = True
                        continue
                    if a.startswith("-") or a.startswith(">") or a.startswith("2>"):
                        continue
                    r = parse_req(a)
                    if r:
                        found.add("pypi", r[0], r[1], rel)
            elif want_apt and cmd in ("apt", "apt-get") and "install" in toks[1:4]:
                for a in toks[toks.index("install") + 1:]:
                    if a.startswith("-") or a.startswith(">") or a.startswith("2>"):
                        continue
                    if DEB_RE.match(a):
                        n, _, v = a.partition("=")
                        found.add("deb", n, v or None, rel)


def packages_distributions():
    """importlib.metadata.packages_distributions() with a fallback for Python < 3.10."""
    fn = getattr(metadata, "packages_distributions", None)
    if fn:
        return fn()
    out = {}
    for dist in metadata.distributions():
        name = dist.metadata["Name"]
        if not name:
            continue
        mods = set()
        top = dist.read_text("top_level.txt")
        if top:
            mods.update(top.split())
        else:
            for f in dist.files or []:
                parts = f.parts
                if not parts or parts[0].endswith((".dist-info", ".egg-info")) or parts[0] == "..":
                    continue
                m = parts[0][:-3] if parts[0].endswith(".py") else parts[0]
                if m.isidentifier():
                    mods.add(m)
        for m in mods:
            out.setdefault(m, []).append(name)
    return out


def scan_imports(root, found):
    local = set()
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        local.update(dns)
        local.update(os.path.splitext(f)[0] for f in fns if f.endswith(".py"))
    stdlib = set(getattr(sys, "stdlib_module_names", ())) | set(sys.builtin_module_names)
    if not hasattr(sys, "stdlib_module_names"):  # Python < 3.10: approximate from stdlib dir
        import sysconfig
        sl = sysconfig.get_paths()["stdlib"]
        for f in os.listdir(sl):
            if f.endswith(".py"):
                stdlib.add(f[:-3])
            elif os.path.isdir(os.path.join(sl, f)) and f != "site-packages":
                stdlib.add(f)
            elif f.endswith(".so"):
                stdlib.add(f.split(".")[0])
        ld = os.path.join(sl, "lib-dynload")
        if os.path.isdir(ld):
            stdlib.update(f.split(".")[0] for f in os.listdir(ld))
    mod2dist = packages_distributions()
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for fn in fns:
            if not fn.endswith(".py"):
                continue
            p = os.path.join(dp, fn)
            try:
                tree = ast.parse(open(p, errors="replace").read())
            except SyntaxError:
                continue
            for n in ast.walk(tree):
                mods = []
                if isinstance(n, ast.Import):
                    mods = [a.name.split(".")[0] for a in n.names]
                elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module:
                    mods = [n.module.split(".")[0]]
                for m in mods:
                    if m in stdlib or m in local:
                        continue
                    for dist in mod2dist.get(m, []):
                        found.add("pypi", dist, None, os.path.relpath(p, root))


def discover(root, args):
    found = Found()
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(d for d in dns if d not in SKIP_DIRS)
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root)
            low = fn.lower()
            if re.match(r"(requirements|constraints).*\.(txt|in)$", low):
                scan_requirements(p, found, rel)
            elif low == "pyproject.toml":
                scan_pyproject(p, found, rel)
            elif low.endswith((".sh", ".bash")) or low.startswith("dockerfile") or low in ("makefile",):
                scan_shell(p, found, rel, not args.no_apt)
    if not args.no_imports:
        scan_imports(root, found)
    return found


# --------------------------------------------------------------------------
# metadata resolution
# --------------------------------------------------------------------------
def pypi_json(name, version=None):
    url = f"https://pypi.org/pypi/{name}/{version}/json" if version else f"https://pypi.org/pypi/{name}/json"
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)


def license_from(info):
    for c in reversed(info.get("classifiers") or []):
        if c.startswith("License ::"):
            return c.split("::")[-1].strip()
    lic = (info.get("license_expression") or info.get("license") or "").strip()
    return lic if lic and len(lic) < 100 and "\n" not in lic else "NOASSERTION"


def build_pypi(entry, offline):
    name, ver = entry["name"], entry["version"]
    if not ver:
        try:
            ver = metadata.version(name)
        except metadata.PackageNotFoundError:
            pass
    pkg = {"name": name, "versionInfo": ver or "NOASSERTION",
           "downloadLocation": "NOASSERTION", "licenseDeclared": "NOASSERTION",
           "licenseConcluded": "NOASSERTION", "supplier": "NOASSERTION"}
    if not offline:
        try:
            d = pypi_json(name, ver)
            info = d["info"]
            pkg["name"] = info.get("name") or name
            pkg["versionInfo"] = info["version"]
            ver = info["version"]
            urls = d.get("urls", [])
            pick = next((u for u in urls if u["filename"].endswith("py3-none-any.whl")), None) \
                or next((u for u in urls if u["packagetype"] == "sdist"), None) \
                or (urls[0] if urls else None)
            if pick:
                pkg["downloadLocation"] = pick["url"]
                pkg["checksums"] = [{"algorithm": "SHA256", "checksumValue": pick["digests"]["sha256"]}]
            lic = license_from(info)
            pkg["licenseDeclared"] = pkg["licenseConcluded"] = lic
            who = info.get("author") or info.get("maintainer")
            if who:
                pkg["supplier"] = "Person: " + who
        except Exception as e:  # noqa
            print(f"  ! PyPI lookup failed for {name} {ver or ''}: {e}", file=sys.stderr)
    if ver:
        pkg["externalRefs"] = [{"referenceCategory": "PACKAGE-MANAGER",
                                "referenceType": "purl",
                                "referenceLocator": f"pkg:pypi/{norm(name)}@{ver}"}]
    return pkg


def build_other(eco, entry):
    n, v = entry["name"], entry["version"]
    pkg = {"name": n, "versionInfo": v or "NOASSERTION",
           "downloadLocation": "NOASSERTION", "licenseDeclared": "NOASSERTION",
           "licenseConcluded": "NOASSERTION", "supplier": "NOASSERTION"}
    if eco == "deb":
        purl = f"pkg:deb/ubuntu/{n}" + (f"@{v}" if v else "")
    else:
        purl = None
    if purl:
        pkg["externalRefs"] = [{"referenceCategory": "PACKAGE-MANAGER",
                                "referenceType": "purl", "referenceLocator": purl}]
    return pkg


def eco_of(pkg):
    for r in pkg.get("externalRefs", []):
        m = re.match(r"pkg:([a-z]+)/", r.get("referenceLocator", ""))
        if m:
            return m.group(1).replace("pypi", "pypi")
    return "pypi"  # legacy entries (e.g. Requests) had no purl


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-r", "--root", default=".")
    ap.add_argument("-o", "--output", default="sbom.json")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--no-imports", action="store_true")
    ap.add_argument("--no-apt", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-backup", action="store_true")
    ap.add_argument("-b", "--baseline", help="old SBOM to use as baseline if it is not the output file "
                    "(e.g. one restored with: git show HEAD:path/sbom.json > /tmp/old.json)")
    args = ap.parse_args()

    old = {}
    base = args.baseline or args.output
    if os.path.exists(base):
        old = json.load(open(base))
        print(f"Baseline: {base} ({len(old.get('packages', []))} packages)")
    else:
        print(f"Baseline: none found at {base} (name defaults to {DEFAULT_NAME})")
    old_pk = {}
    for p in old.get("packages", []):
        e = eco_of(p)
        old_pk[(e, norm(p["name"]) if e == "pypi" else p["name"])] = p

    found = discover(args.root, args)
    print(f"Discovered {len(found.pk)} packages under {os.path.abspath(args.root)}")

    packages, kept, added = [], [], []
    for key in sorted(found.pk, key=lambda k: (k[0], k[1])):
        eco, _ = key
        ent = found.pk[key]
        prev = old_pk.get(key)
        # reuse old entry if still present and version not contradicted
        if prev and (not ent["version"] or prev.get("versionInfo") == ent["version"]):
            pkg = dict(prev)
            kept.append(pkg["name"])
        else:
            pkg = build_pypi(ent, args.offline) if eco == "pypi" else build_other(eco, ent)
            if prev:
                pkg["name"] = prev["name"]   # keep the established display name
            added.append(f"{pkg['name']} {pkg['versionInfo']}")
        pkg["SPDXID"] = spdx_id("Package", f"{pkg['name']}-{eco}" if eco != "pypi" else pkg["name"])
        pkg["sourceInfo"] = "Found in: " + ", ".join(sorted(ent["sources"])[:8]) + \
                            (" ..." if len(ent["sources"]) > 8 else "")
        packages.append(pkg)

    removed = [p["name"] for k, p in old_pk.items() if k not in found.pk]

    now = datetime.now(timezone.utc)
    name = old.get("name", DEFAULT_NAME)
    doc = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": old.get("dataLicense", "CC0-1.0"),
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": name,
        "documentNamespace": f"http://spdx.org/spdxdocs/{name}-{now:%Y%m%d%H%M%S}",
        "creationInfo": {"created": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "creators": [f"Tool: {TOOL}"]},
        "packages": packages,
        "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT",
                           "relationshipType": "DESCRIBES",
                           "relatedSpdxElement": p["SPDXID"]} for p in packages],
    }

    print(f"  kept    : {len(kept)}")
    print(f"  added   : {len(added)}  {added}")
    print(f"  removed : {len(removed)}  {removed}")
    if args.dry_run:
        return
    if os.path.exists(args.output) and not args.no_backup:
        shutil.copy2(args.output, args.output + ".bak")
    with open(args.output, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
