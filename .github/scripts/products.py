#!/usr/bin/env python3
"""
products.py — the prepare "brain" for the per-product, independent iOS workflows.

A repo describes each product it ships as a self-contained JSON file at
`Config/products/<id>.json` (build identity + a mandatory inline `changelog`).
This script discovers those files and computes what each orchestrator needs,
emitting `key=value` lines meant to be appended to `$GITHUB_OUTPUT`.

Subcommands:
  discover       Identity of every product (for the PR compile fan-out).
  plan-beta      The beta cutting set on a push to main — a product is cut ONLY
                 when its version is unreleased AND its own product file (or one
                 of its `source-paths`) changed since its last beta. Each product
                 is fully independent: own version line, own `-beta.N` counter.
  plan-release   Parse a pushed `<id>-v<version>` tag → the single target product,
                 validated against that product's changelog.versions[0].

iOS ships through exactly ONE channel (App Store Connect), so unlike the macOS
sibling there are no per-channel subsets — a single `has-any` boolean gates the
build job (an empty matrix throws rather than skipping).

Everything is pure stdlib. Git access is isolated so the logic unit-tests
offline: set `GIT_TAGS` (space-separated) and `CHANGED_PRODUCTS` (space-separated
ids treated as "changed since last beta") to stub git, and `BUILD_NUMBER` to
pin the timestamp.

Env inputs:
  PRODUCTS_DIR                 product dir (default "Config/products")
  DEF_DISTRIBUTE               default a product inherits when it omits
                               "distribute" (mirrors the orchestrator input)
  TAG                          (plan-release) the pushed github.ref_name
  GIT_TAGS / CHANGED_PRODUCTS / BUILD_NUMBER   test-injection overrides
"""
import glob
import json
import os
import re
import subprocess
import sys


def die(msg):
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def note(msg):
    print(f"::notice::{msg}", file=sys.stderr)


def warn(msg):
    print(f"::warning::{msg}", file=sys.stderr)


def as_bool(v, default):
    if v is None or v == "":
        return default
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() == "true"


def emit(key, value):
    print(f"{key}={value}")


def compact(x):
    return json.dumps(x, separators=(",", ":"))


def strip_internal(rec):
    return {k: v for k, v in rec.items() if not k.startswith("_")}


def tag_prefix(rec):
    """Bare 'v' for the primary (empty-id) product, '<id>-v' otherwise. The
    prefix is a git-tag/workflow identifier only — never the app's version."""
    return "v" if rec.get("_bare") else f'{rec["id"]}-v'


# ── git (isolated + injectable) ──────────────────────────────────────────────
def git_tags():
    inj = os.environ.get("GIT_TAGS")
    if inj is not None:
        return [t for t in inj.split() if t]
    out = subprocess.run(["git", "tag", "--list"], capture_output=True, text=True)
    return [t for t in out.stdout.splitlines() if t]


def product_changed_since(key, filename, last_tag, products_dir, source_paths=()):
    """True if the product's file — or any of its declared source paths — differs
    between last_tag and HEAD.

    Without `source-paths`, only the product file counts, so a commit that changes
    nothing but Swift still cuts no beta and the run goes green with the fix
    sitting unshipped on main. Declaring the paths a product actually builds from
    makes a code-only change cut a beta on its own.
    """
    inj = os.environ.get("CHANGED_PRODUCTS")
    if inj is not None:
        return key in inj.split()
    paths = [os.path.join(products_dir, filename), *source_paths]
    rc = subprocess.run(["git", "diff", "--quiet", last_tag, "HEAD", "--", *paths]).returncode
    return rc != 0


def build_number():
    inj = os.environ.get("BUILD_NUMBER")
    if inj:
        return inj
    return subprocess.run(["date", "-u", "+%y%m%d%H%M%S"], capture_output=True, text=True).stdout.strip()


# ── discovery + validation + defaulting ──────────────────────────────────────
def read_defaults():
    return {"distribute": as_bool(os.environ.get("DEF_DISTRIBUTE"), True)}


def resolve(products_dir, defaults):
    """Glob → validate → normalize. Returns records with identity + internal _version.

    Every product must carry a mandatory inline `changelog` with a
    versions[0].version, plus the build identity every iOS archive needs.
    Fails loudly (exit 1) listing every problem.
    """
    files = sorted(glob.glob(os.path.join(products_dir, "*.json")))
    if not files:
        die(f"no product files in {products_dir}/ (expected Config/products/<id>.json)")

    errors, resolved, seen = [], [], set()
    for f in files:
        try:
            p = json.load(open(f, encoding="utf-8"))
        except Exception as e:  # noqa: BLE001 — surface any parse error verbatim
            errors.append(f"{f}: invalid JSON: {e}")
            continue
        if not isinstance(p, dict):
            errors.append(f"{f}: top-level value is not a JSON object")
            continue

        stem = os.path.splitext(os.path.basename(f))[0]
        file_id = str(p.get("id") or "").strip()   # empty/omitted → primary, bare v* tags
        bare = file_id == ""
        pid = file_id or stem                        # internal key (artifacts/matrix) — always set
        if file_id and file_id != stem:
            errors.append(f"{f}: id '{file_id}' must match the filename ('{stem}.json') — rename to '{file_id}.json', or drop 'id' for the primary product")
        if pid in seen:
            errors.append(f"duplicate product id/key '{pid}'")
        seen.add(pid)

        scheme = str(p.get("scheme") or "").strip()
        bundle_id = str(p.get("bundle-id") or "").strip()
        # product-name is cosmetic (summary table + notes) — default it to the
        # scheme rather than making every product file repeat itself.
        product_name = str(p.get("product-name") or "").strip() or scheme

        if not scheme:
            errors.append(f"product '{pid}': 'scheme' is required")
        if not bundle_id:
            errors.append(f"product '{pid}': 'bundle-id' is required")

        # Mandatory inline changelog → the product's version source.
        version = ""
        cl = p.get("changelog")
        if not isinstance(cl, dict) or not (cl.get("versions") or []):
            errors.append(f"product '{pid}': mandatory 'changelog' with versions[0].version is missing")
        else:
            version = str((cl["versions"][0] or {}).get("version") or "").strip()
            if not version:
                errors.append(f"product '{pid}': changelog.versions[0].version is empty")

        resolved.append({
            "id": pid,
            "distribute": as_bool(p.get("distribute"), defaults["distribute"]),
            "scheme": scheme,
            "product-name": product_name,
            "bundle-id": bundle_id,
            "profile-secret": str(p.get("profile-secret") or ""),
            "cert-secret": str(p.get("cert-secret") or ""),
            "cert-password-secret": str(p.get("cert-password-secret") or ""),
            "_version": version,
            "_bare": bare,
            "_file": os.path.basename(f),
            # Git pathspecs this product builds from, e.g. ["Sources/**",
            # "Project.swift"]. Optional; when set, a change to any of them cuts a
            # beta on its own, so a code-only fix ships without needing a
            # cosmetic edit to the product file. Internal: plan-beta only.
            "_source_paths": [str(x) for x in (p.get("source-paths") or []) if str(x).strip()],
        })

    if sum(1 for r in resolved if r["_bare"]) > 1:
        errors.append("at most one product may omit 'id' — the primary uses bare 'v*' tags; give the others a unique id")

    if errors:
        for e in errors:
            print(f"::error::products: {e}", file=sys.stderr)
        sys.exit(1)
    return resolved


# ── subcommands ──────────────────────────────────────────────────────────────
def cmd_discover(products_dir, defaults):
    records = [strip_internal(r) for r in resolve(products_dir, defaults)]
    emit("products", compact(records))
    emit("has-any", "true" if records else "false")
    emit("ids", " ".join(r["id"] for r in records))


def cmd_plan_beta(products_dir, defaults):
    records = resolve(products_dir, defaults)
    tags = set(git_tags())
    cutting = []
    for r in records:
        pid, v = r["id"], r["_version"]
        pfx = tag_prefix(r)                             # 'v' (primary) or '<id>-v'
        if f"{pfx}{v}" in tags:                          # released → idle → skip
            note(f"{pid}: {pfx}{v} already released — idle (bump its changelog to cut betas)")
            continue
        betas = [t for t in tags if t.startswith(f"{pfx}{v}-beta.")]
        if betas:                                       # re-beta ONLY if this product changed
            nums = [int(t.rsplit(".", 1)[1]) for t in betas if t.rsplit(".", 1)[1].isdigit()]
            last_n = max(nums) if nums else 0
            last_tag = f"{pfx}{v}-beta.{last_n}"
            if not product_changed_since(pid, r["_file"], last_tag, products_dir, r["_source_paths"]):
                # A warning, not a notice: this is the case where a push that DID
                # change code still ships nothing, and the run is otherwise green.
                # Without `source-paths` the check cannot see code at all, so say
                # what to do about it rather than letting the silence pass.
                if r["_source_paths"]:
                    warn(f"{pid}: neither {products_dir}/{r['_file']} nor its source-paths "
                         f"changed since {last_tag} — no beta cut")
                else:
                    warn(f"{pid}: {products_dir}/{r['_file']} unchanged since {last_tag} — no beta "
                         f"cut. Code-only changes do NOT trigger a beta; add \"source-paths\" to "
                         f"the product file (e.g. [\"Sources/**\", \"Project.swift\"]) so they do.")
                continue
            n = last_n + 1
        else:
            n = 1                                       # first beta of v — the bump IS the change
        rec = strip_internal(r)
        # TestFlight takes the bare marketing version always — Apple's iTMS rejects
        # a non-N.N.N CFBundleShortVersionString. The build number disambiguates.
        rec.update({
            "version": v,
            "marketing": v,
            "artifact-label": f"v{v}-beta.{n}",
            "release-tag": f"{pfx}{v}-beta.{n}",
        })
        cutting.append(rec)

    emit("beta-products", compact(cutting))
    emit("has-any", "true" if cutting else "false")
    emit("build-number", build_number())
    # Test scheme/app-name default to the FIRST discovered product (always
    # present, even when the cutting set is empty) so the opt-in test gate has a
    # scheme regardless of what changed this push.
    emit("test-scheme", records[0]["scheme"])
    emit("test-app-name", records[0]["product-name"])


def cmd_plan_release(products_dir, defaults):
    records = resolve(products_dir, defaults)
    tag = (os.environ.get("TAG") or "").strip()
    if not tag:
        die("TAG (github.ref_name) is required for plan-release")
    if re.search(r"-(?:beta|alpha)\.", tag):
        die(f"'{tag}' is a beta/alpha tag and must not reach the release flow — fix the shell tag filter")

    # Each product's tag prefix: 'v' for the primary (empty id), '<id>-v' otherwise.
    # Match the longest prefix first, so 'pro-v…' binds to 'pro' before the bare 'v…'.
    candidates = sorted(((tag_prefix(r), r) for r in records), key=lambda c: len(c[0]), reverse=True)
    hit = None
    for prefix, r in candidates:
        if tag.startswith(prefix):
            ver = tag[len(prefix):]
            if re.match(r"^\d+\.\d+(\.\d+)?$", ver):
                hit = (r, ver)
                break
    if not hit:
        die(f"'{tag}' matches no product's release tag — the primary product releases via 'vX.Y.Z', others via '<id>-vX.Y.Z'")

    r, ver = hit
    pid = r["id"]
    if ver != r["_version"]:
        die(f"tag '{tag}' (={ver}) != Config/products/{r['_file']} changelog.versions[0].version (={r['_version']}). Bump the changelog or fix the tag.")

    rec = strip_internal(r)
    rec.update({"version": ver, "marketing": ver, "artifact-label": f"v{ver}"})
    emit("target-id", pid)
    emit("version", ver)
    emit("artifact-label", f"v{ver}")
    emit("build-number", build_number())
    emit("products", compact([rec]))
    emit("has-any", "true")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    products_dir = os.environ.get("PRODUCTS_DIR") or "Config/products"
    defaults = read_defaults()
    if cmd == "discover":
        cmd_discover(products_dir, defaults)
    elif cmd == "plan-beta":
        cmd_plan_beta(products_dir, defaults)
    elif cmd == "plan-release":
        cmd_plan_release(products_dir, defaults)
    else:
        die(f"unknown subcommand '{cmd}' (expected discover | plan-beta | plan-release)")


if __name__ == "__main__":
    main()
