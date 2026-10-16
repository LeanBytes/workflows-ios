#!/usr/bin/env python3
"""
products.py — the prepare "brain" for the per-product, independent iOS workflows.

A repo describes each product it ships as a self-contained JSON file at
`Config/products/<id>.json` (build identity + a mandatory inline `changelog`).
This script discovers those files and computes what each orchestrator needs,
emitting `key=value` lines meant to be appended to `$GITHUB_OUTPUT`.

Subcommands:
  discover       Identity of every product (for the PR compile fan-out).
  plan           What builds on a push to main — a product builds ONLY when its
                 version is unreleased AND its own product file (or one of its
                 `source-paths`) changed since its last build. Each product is
                 fully independent: own version line, own tags. Every build is
                 tagged `<id>-v<version>-<build number>`, the pair App Store
                 Connect shows as "<version> (<build number>)". There are no
                 betas: the build tested in TestFlight is the build that ships.
                 "Released" = a bare `<id>-v<version>` / `v<version>` tag exists:
                 a marker pushed by hand once the version shipped. Nothing builds
                 on it.

Both iOS channels (App Store Connect, Ad Hoc) build the same way — only the
export method and publish leg differ — so unlike the macOS sibling there are no
per-channel subsets: a single `has-any` boolean gates the build job (an empty
matrix throws rather than skipping).

Everything is pure stdlib. Git access is isolated so the logic unit-tests
offline: set `GIT_TAGS` (space-separated) and `ASSUME_CHANGED` (space-separated
ids treated as "changed since last build", or `*` for every product) to stub git,
and `BUILD_NUMBER` to pin the timestamp.

Env inputs:
  PRODUCTS_DIR                 product dir (default "Config/products")
  DEF_DISTRIBUTE               default a product inherits when it omits
                               "distribute" (mirrors the orchestrator input)
  GIT_TAGS / BUILD_NUMBER      test-injection overrides
  ASSUME_CHANGED               ids to treat as changed since their last build,
                               or `*` for all. Stubs git for tests AND backs the
                               orchestrator's force input. Empty == unset.
"""
import glob
import json
import os
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
    between last_tag and HEAD, OR if ASSUME_CHANGED stipulates it.

    Without `source-paths`, only the product file counts, so a commit that changes
    nothing but Swift still builds nothing and the run goes green with the fix
    sitting unshipped on main. Declaring the paths a product actually builds from
    makes a code-only change build on its own.
    """
    # Empty counts as UNSET, deliberately. The obvious workflow wiring for an
    # off switch renders to "", and under an `is not None` test that would mean
    # "nothing changed" — silently stopping every build on every normal push.
    inj = os.environ.get("ASSUME_CHANGED", "").strip()
    if inj:
        return inj == "*" or key in inj.split()
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
        channel = str(p.get("channel") or "app-store").strip()
        if channel not in ("app-store", "ad-hoc"):
            errors.append(f"product '{pid}': channel must be 'app-store' or 'ad-hoc', got {channel!r}")

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
            # Vertriebskanal des Produkts. "app-store" lädt per altool nach App
            # Store Connect; "ad-hoc" exportiert release-testing-signiert und legt
            # IPA + manifest.plist auf S3, von wo ein registriertes Gerät sie per
            # itms-services ohne Apple ID installiert. Kanalabhängig sind Export-
            # Methode und Publish-Leg — Archive und Signatur sind identisch.
            "channel": channel,
            "profile-secret": str(p.get("profile-secret") or ""),
            "cert-secret": str(p.get("cert-secret") or ""),
            "cert-password-secret": str(p.get("cert-password-secret") or ""),
            "_version": version,
            "_bare": bare,
            "_file": os.path.basename(f),
            # Git pathspecs this product builds from, e.g. ["Sources/**",
            # "Project.swift"]. Optional; when set, a change to any of them
            # builds on its own, so a code-only fix ships without needing a
            # cosmetic edit to the product file. Internal: plan only.
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


def cmd_plan(products_dir, defaults):
    records = resolve(products_dir, defaults)
    tags = set(git_tags())
    forced = bool(os.environ.get("ASSUME_CHANGED", "").strip())
    build = build_number()
    cutting = []
    for r in records:
        pid, v = r["id"], r["_version"]
        pfx = tag_prefix(r)                             # 'v' (primary) or '<id>-v'
        if f"{pfx}{v}" in tags:                          # released → idle → skip
            # Forcing overrides "nothing changed", never "already released" — App
            # Store Connect rejects any further build of an approved version. But
            # a run that was asked to force and then quietly does nothing looks
            # broken exactly when it is behaving correctly, so say so loudly and
            # name the way out.
            if forced:
                warn(f"{pid}: force was set, but {pfx}{v} is already released — no build "
                     f"cut. Forcing overrides 'nothing changed', not 'already shipped'. Bump "
                     f"changelog.versions[0].version to start the next version.")
            else:
                note(f"{pid}: {pfx}{v} already released — idle (bump its changelog to build again)")
            continue
        # A build tag is <pfx><v>-<build number>. The build number is a fixed-width
        # timestamp, so the newest build is the largest. Anything else after the
        # prefix — a pre-v0.4.0 `-beta.N` tag — is not a build: the first push
        # after an app upgrades builds once, deliberately (#15).
        builds = [t[len(f"{pfx}{v}-"):] for t in tags if t.startswith(f"{pfx}{v}-")]
        builds = [b for b in builds if b.isdecimal()]
        if builds:                                      # rebuild ONLY if this product changed
            last_tag = f"{pfx}{v}-{max(builds, key=int)}"
            if not product_changed_since(pid, r["_file"], last_tag, products_dir, r["_source_paths"]):
                # A warning, not a notice: this is the case where a push that DID
                # change code still ships nothing, and the run is otherwise green.
                # Without `source-paths` the check cannot see code at all, so say
                # what to do about it rather than letting the silence pass.
                if r["_source_paths"]:
                    warn(f"{pid}: neither {products_dir}/{r['_file']} nor its source-paths "
                         f"changed since {last_tag} — no build cut")
                else:
                    warn(f"{pid}: {products_dir}/{r['_file']} unchanged since {last_tag} — no build "
                         f"cut. Code-only changes do NOT trigger a build; add \"source-paths\" to "
                         f"the product file (e.g. [\"Sources/**\", \"Project.swift\"]) so they do.")
                continue
        # else: first build of v — the bump IS the change
        rec = strip_internal(r)
        # TestFlight takes the bare marketing version always — Apple's iTMS rejects
        # a non-N.N.N CFBundleShortVersionString. The build number disambiguates.
        rec.update({
            "version": v,
            "marketing": v,
            "release-tag": f"{pfx}{v}-{build}",
        })
        cutting.append(rec)

    emit("products", compact(cutting))
    emit("has-any", "true" if cutting else "false")
    emit("build-number", build)
    # Test scheme/app-name default to the FIRST discovered product (always
    # present, even when the cutting set is empty) so the opt-in test gate has a
    # scheme regardless of what changed this push.
    emit("test-scheme", records[0]["scheme"])
    emit("test-app-name", records[0]["product-name"])


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    products_dir = os.environ.get("PRODUCTS_DIR") or "Config/products"
    defaults = read_defaults()
    if cmd == "discover":
        cmd_discover(products_dir, defaults)
    elif cmd == "plan":
        cmd_plan(products_dir, defaults)
    else:
        die(f"unknown subcommand '{cmd}' (expected discover | plan)")


if __name__ == "__main__":
    main()
