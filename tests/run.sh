#!/usr/bin/env bash
# Offline unit tests for .github/scripts/products.py — no git repo, no network.
# Git is stubbed via GIT_TAGS / ASSUME_CHANGED; the timestamp via BUILD_NUMBER.
# Run from anywhere:  bash tests/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/.github/scripts/products.py"
MULTI="$ROOT/tests/fixtures/multi/Config/products"
SINGLE="$ROOT/tests/fixtures/single/Config/products"
MIXED="$ROOT/tests/fixtures/mixed/Config/products"
DUAL="$ROOT/tests/fixtures/dual-bare/Config/products"
FAIL=0

CAP()  { OUT=$(env "$@" 2>/tmp/pd.err); RC=$?; }
pass() { echo "  ok  : $*"; }
bad()  { echo "  FAIL: $*"; echo "    rc=$RC"; echo "    stdout: $OUT"; echo "    stderr: $(cat /tmp/pd.err)"; FAIL=1; }
line() { grep -qxF "$2" <<<"$OUT" && pass "$1" || bad "$1 — missing line: $2"; }
jok()  { python3 - "$OUT" "$2" <<'PY' && pass "$1" || bad "$1"
import json, sys
o = dict(l.split("=", 1) for l in sys.argv[1].splitlines() if "=" in l)
exec(sys.argv[2])
PY
}

echo "== discover (multi) =="
CAP PRODUCTS_DIR="$MULTI" python3 "$PY" discover
[ $RC -eq 0 ] && pass "exit 0" || bad "discover exit"
line "has-any=true" "has-any=true"
line "ids sorted glob" "ids=companion main"
jok "products=2, identity carried" \
  'p={x["id"]:x for x in json.loads(o["products"])}; assert len(p)==2; assert p["main"]["scheme"]=="Main"; assert p["main"]["bundle-id"]=="io.leanbytes.main"'
jok "product-name defaults to the scheme when omitted" \
  'p={x["id"]:x for x in json.loads(o["products"])}; assert p["companion"]["product-name"]=="Companion"; assert p["main"]["product-name"]=="Main App"'
jok "distribute defaults true, product file overrides to false" \
  'p={x["id"]:x for x in json.loads(o["products"])}; assert p["main"]["distribute"] is True; assert p["companion"]["distribute"] is False'
jok "per-product profile secret carried" \
  'p={x["id"]:x for x in json.loads(o["products"])}; assert p["companion"]["profile-secret"]=="PROV_PROF_STORE_COMPANION_BASE64"; assert p["main"]["profile-secret"]==""'
jok "channel defaults to app-store, product file overrides to ad-hoc" \
  'p={x["id"]:x for x in json.loads(o["products"])}; assert p["main"]["channel"]=="app-store"; assert p["companion"]["channel"]=="ad-hoc"'

echo "== discover: an unknown channel fails loudly rather than defaulting =="
BAD=$(mktemp -d)/products; mkdir -p "$BAD"
cat > "$BAD/app.json" <<'JSON'
{ "scheme": "X", "bundle-id": "com.a.b", "channel": "typo",
  "changelog": { "versions": [ { "version": "1.0.0", "items": [] } ] } }
JSON
CAP PRODUCTS_DIR="$BAD" python3 "$PY" discover
[ $RC -ne 0 ] && pass "exit non-zero" || bad "unknown channel should fail"
grep -q "channel must be" /tmp/pd.err && pass "names the offending key" || bad "error text" 

echo "== discover: DEF_DISTRIBUTE=false flips the default, not the override =="
CAP PRODUCTS_DIR="$MULTI" DEF_DISTRIBUTE=false python3 "$PY" discover
jok "main inherits false; companion stays false" \
  'p={x["id"]:x for x in json.loads(o["products"])}; assert p["main"]["distribute"] is False; assert p["companion"]["distribute"] is False'

echo "== plan-beta: companion released (idle), main mid-dev, no betas yet =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="companion-v1.3.0" BUILD_NUMBER="260704000000" python3 "$PY" plan-beta
[ $RC -eq 0 ] && pass "exit 0" || bad "plan-beta exit"
jok "only main → beta.1 (idle companion skipped)" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["main"], b; assert b[0]["release-tag"]=="main-v2.14.0-beta.1"; assert o["build-number"]=="260704000000"'
jok "TestFlight marketing version stays bare N.N.N (ASC rejects suffixes)" \
  'b=json.loads(o["beta-products"]); assert b[0]["marketing"]=="2.14.0", b[0]["marketing"]; assert b[0]["artifact-label"]=="v2.14.0-beta.1"'
line "test scheme falls back to the first product" "test-scheme=Companion"
line "test app-name falls back to the first product" "test-app-name=Companion"

echo "== plan-beta: both mid-dev, nothing released → both first beta =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "both → beta.1" \
  'b=json.loads(o["beta-products"]); assert sorted(x["id"] for x in b)==["companion","main"]; assert o["has-any"]=="true"'

echo "== plan-beta: push 2 — only main changed =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1 companion-v1.3.0-beta.1" ASSUME_CHANGED="main" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "only main → beta.2; companion unchanged → skipped" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["main"], b; assert b[0]["release-tag"]=="main-v2.14.0-beta.2"'

echo "== plan-beta: everything released → empty cutting set =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0 companion-v1.3.0" BUILD_NUMBER="x" python3 "$PY" plan-beta
line "nothing cuts → has-any=false gates the build job" "has-any=false"
jok "beta-products is an empty array, not absent" 'assert json.loads(o["beta-products"])==[]'

echo "== force-beta: ASSUME_CHANGED overrides \"nothing changed\", not \"already shipped\" =="
# Backs the orchestrator's force-beta checkbox. `*` = every product; a list
# names them. Empty MUST count as unset, or the off position of the switch
# would silently stop every beta on every normal push (#13). `*` itself is
# asserted in the real-git source-paths section below: with stub tags, a
# failing `git diff` reads as "changed" too, so no stubbed case can show it.

# Empty must behave EXACTLY like unset, whatever git then says — that is the
# invariant, and it holds without depending on this repo's tag state.
E=$(PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1" ASSUME_CHANGED="" BUILD_NUMBER="x" python3 "$PY" plan-beta 2>/dev/null)
U=$(PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1"                     BUILD_NUMBER="x" python3 "$PY" plan-beta 2>/dev/null)
[ "$E" = "$U" ] && pass "empty ASSUME_CHANGED behaves exactly like unset" \
  || { echo "  FAIL: ASSUME_CHANGED='' differs from unset — the off position of force-beta"; FAIL=1; }

CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0 companion-v1.3.0" ASSUME_CHANGED="*" BUILD_NUMBER="x" python3 "$PY" plan-beta
line "a released version is NOT forced — it stays idle" "has-any=false"
grep -q "::warning::.*force-beta was set, but" /tmp/pd.err \
  && pass "forcing a released version warns loudly instead of going quietly green" \
  || { echo "  FAIL: forcing an already-released version must ::warning::, not ::notice::"; FAIL=1; }

# The wiring: `*` when the box is ticked, "" when it is not — never a value that
# products.py would read as "nothing changed".
BWF="$ROOT/.github/workflows/distribute-beta.yml"
grep -q "^      force-beta:" "$BWF" && pass "distribute-beta.yml declares force-beta" \
  || { echo "  FAIL: distribute-beta.yml has no force-beta input"; FAIL=1; }
grep -qF "ASSUME_CHANGED: \${{ inputs.force-beta && '*' || '' }}" "$BWF" \
  && pass "force-beta wires to ASSUME_CHANGED ('*' on, '' off)" \
  || { echo "  FAIL: distribute-beta.yml must set ASSUME_CHANGED from force-beta"; FAIL=1; }
grep -rq "CHANGED_PRODUCTS" "$ROOT/.github" "$ROOT/CLAUDE.md" "$ROOT/README.md" \
  && { echo "  FAIL: CHANGED_PRODUCTS still referenced — it was renamed to ASSUME_CHANGED"; FAIL=1; } \
  || pass "no stale CHANGED_PRODUCTS references"

echo "== single-product fixture =="
CAP PRODUCTS_DIR="$SINGLE" python3 "$PY" discover
line "single ids" "ids=app"
CAP PRODUCTS_DIR="$SINGLE" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "app → beta.1" 'b=json.loads(o["beta-products"]); assert b[0]["release-tag"]=="app-v1.0.0-beta.1"'

echo "== mixed: primary (empty id → bare v*) + prefixed pro =="
CAP PRODUCTS_DIR="$MIXED" python3 "$PY" discover
line "mixed ids (keys from filenames)" "ids=base pro"
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "base → bare v1.0.0-beta.1; pro → pro-v2.0.0-beta.1" \
  'b={x["id"]:x for x in json.loads(o["beta-products"])}; assert b["base"]["release-tag"]=="v1.0.0-beta.1", b["base"]["release-tag"]; assert b["pro"]["release-tag"]=="pro-v2.0.0-beta.1", b["pro"]["release-tag"]'
jok "per-product cert secret carried (base overrides, pro defaults)" \
  'b={x["id"]:x for x in json.loads(o["beta-products"])}; assert b["base"]["cert-secret"]=="APPLE_DISTR_P12_ALT_BASE64"; assert b["base"]["cert-password-secret"]=="APPLE_DISTR_PASSWORD_ALT"; assert b["pro"]["cert-secret"]==""'
# A shipped version's marker tag (pushed by hand — nothing builds on it, #14)
# idles exactly that product, never its sibling.
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "base released (bare v1.0.0) → idle; only pro cuts" \
  'b=[x["id"] for x in json.loads(o["beta-products"])]; assert b==["pro"], b'
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="pro-v2.0.0" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "pro released (pro-v2.0.0) → idle; only base cuts" \
  'b=[x["id"] for x in json.loads(o["beta-products"])]; assert b==["base"], b'

echo "== validation: two empty-id products → hard error =="
CAP PRODUCTS_DIR="$DUAL" python3 "$PY" discover
{ [ $RC -ne 0 ] && grep -q "at most one product may omit" /tmp/pd.err; } && pass "dual-bare rejected" || bad "dual-bare should fail with the one-primary error (rc=$RC)"

echo "== validation: missing required identity → hard error =="
BADDIR=$(mktemp -d); mkdir -p "$BADDIR/Config/products"
cat > "$BADDIR/Config/products/x.json" <<'JSON'
{ "id": "x", "changelog": { "versions": [ { "version": "1.0.0", "items": [] } ] } }
JSON
CAP PRODUCTS_DIR="$BADDIR/Config/products" python3 "$PY" discover
{ [ $RC -ne 0 ] && grep -q "'scheme' is required" /tmp/pd.err && grep -q "'bundle-id' is required" /tmp/pd.err; } \
  && pass "missing scheme + bundle-id both reported" || bad "expected both identity errors (rc=$RC)"
cat > "$BADDIR/Config/products/x.json" <<'JSON'
{ "id": "x", "scheme": "X", "bundle-id": "io.leanbytes.x" }
JSON
CAP PRODUCTS_DIR="$BADDIR/Config/products" python3 "$PY" discover
{ [ $RC -ne 0 ] && grep -q "mandatory 'changelog'" /tmp/pd.err; } \
  && pass "missing changelog rejected" || bad "expected the mandatory-changelog error (rc=$RC)"
cat > "$BADDIR/Config/products/x.json" <<'JSON'
{ "id": "wrong", "scheme": "X", "bundle-id": "io.leanbytes.x",
  "changelog": { "versions": [ { "version": "1.0.0", "items": [] } ] } }
JSON
CAP PRODUCTS_DIR="$BADDIR/Config/products" python3 "$PY" discover
{ [ $RC -ne 0 ] && grep -q "must match the filename" /tmp/pd.err; } \
  && pass "id/filename mismatch rejected" || bad "expected the filename-mismatch error (rc=$RC)"
rm -rf "$BADDIR"

echo "== source-paths: a code-only change cuts a beta =="
# Real git repos, real `git diff` — ASSUME_CHANGED is deliberately NOT set, so
# these exercise the actual diff path rather than the test stub.
# $1 = dir, $2 = the "source-paths" JSON line (empty to omit it).
mkrepo() {
  mkdir -p "$1/Config/products" "$1/Sources"
  cat > "$1/Config/products/app.json" <<JSON
{ "id": "app", "scheme": "App", "bundle-id": "io.leanbytes.app",
  $2
  "changelog": { "versions": [ { "version": "1.0.0",
    "items": [ { "type": "feat", "title": { "en": "x" } } ] } ] } }
JSON
  (
    set -e; cd "$1"
    git init -q . && git config user.email t@t && git config user.name t
    echo 'let a = 1' > Sources/App.swift
    git add -A && git commit -qm init && git tag app-v1.0.0-beta.1
    echo 'let a = 2' > Sources/App.swift   # code-only: product file untouched
    git add -A && git commit -qm "code only"
  ) >/dev/null 2>&1
}
planbeta() { CAP bash -c "cd '$1' && PRODUCTS_DIR='$1/Config/products' GIT_TAGS='app-v1.0.0-beta.1' BUILD_NUMBER=x python3 '$PY' plan-beta"; }

WITH=$(mktemp -d); mkrepo "$WITH" '"source-paths": ["Sources/**"],'
planbeta "$WITH"
jok "code-only change WITH source-paths → cuts beta.2" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["app"], b; assert b[0]["release-tag"]=="app-v1.0.0-beta.2", b[0]["release-tag"]'
jok "source-paths stays internal — not emitted to the workflow matrix" \
  'assert all("source-paths" not in x and "_source_paths" not in x for x in json.loads(o["beta-products"]))'

WITHOUT=$(mktemp -d); mkrepo "$WITHOUT" ''
planbeta "$WITHOUT"
line "code-only change WITHOUT source-paths → nothing cuts" "has-any=false"
{ grep -q '::warning::' /tmp/pd.err && grep -q 'source-paths' /tmp/pd.err; } \
  && pass "the silent skip is now a warning naming the fix" \
  || bad "expected a ::warning:: mentioning source-paths; got: $(cat /tmp/pd.err)"
# The same repo, forced: real git says "nothing changed", and force-beta
# overrides exactly that (#13). The stubbed cases above cannot show this —
# outside a repo a failing `git diff` also reads as "changed".
CAP ASSUME_CHANGED='*' bash -c "cd '$WITHOUT' && PRODUCTS_DIR='$WITHOUT/Config/products' GIT_TAGS='app-v1.0.0-beta.1' BUILD_NUMBER=x python3 '$PY' plan-beta"
jok "force-beta cuts beta.2 where real git saw no change" \
  'b=json.loads(o["beta-products"]); assert [x["release-tag"] for x in b]==["app-v1.0.0-beta.2"], b'
rm -rf "$WITH" "$WITHOUT"

echo "== classify_upload: altool outcome classification =="
# Sourced from the shipped script rather than re-implemented, so this test cannot
# drift from what the publish steps actually run.
source "$ROOT/.github/scripts/classify-upload.sh"
cls() { GOT=$(classify_upload "$2" "$3"); [ "$GOT" = "$4" ] && pass "$1" || { echo "  FAIL: $1 — got '$GOT', want '$4'"; FAIL=1; }; }

cls "clean success → accepted" 0 \
  "UPLOAD SUCCEEDED with no errors
No errors uploading archive at './App.ipa'." accepted
cls "exit 0, quiet output → accepted" 0 "Uploading... done" accepted
cls "build-number collision (-19232) → failed" 31 \
  "ERROR: [ContentDelivery.Uploader.7814C25280] The provided entity includes an attribute with a value that has already been used (-19232) The bundle version must be higher than the previously uploaded version: '1'.
ERROR: [altool.main] ExitFailure (31)" failed
cls "true redundant upload (ITMS-90189) → already-present" 31 \
  "ERROR: [altool] Redundant Binary Upload. There already exists a binary upload with build version '42' (ITMS-90189)" already-present
cls "opaque altool error → failed" 1 "ERROR: [altool.main] network unreachable" failed

echo "== changelog: every type the apps render reaches the notes =="
# The apps' What's New views know feat/fix/core/lang/release. CI knew three, so
# six MacPacker releases shipped without their lang items (workflows-macos#17,
# here #11). chore stays a silent drop; anything else must be dropped LOUDLY,
# never silently, and never onto stdout — stdout IS the release notes.
CL="$ROOT/.github/scripts/changelog-from-json.sh"
cat > /tmp/cl-types.json <<'JSON'
{"versions":[{"version":"1.0.0","items":[
  {"type":"feat","title":{"en":"F"}},   {"type":"fix","title":{"en":"B"}},
  {"type":"core","title":{"en":"C"}},   {"type":"lang","title":{"en":"L"}},
  {"type":"release","title":{"en":"A"}},{"type":"chore","title":{"en":"Internal"}},
  {"type":"l10n","title":{"en":"Typo"}}
]}]}
JSON
SUM=/tmp/cl-summary.md; : > "$SUM"
OUT="$(CHANGELOG_PATH=/tmp/cl-types.json VERSION=1.0.0 GITHUB_STEP_SUMMARY="$SUM" bash "$CL" 2>/tmp/cl.err)"
for sec in "New Features" "Bug Fixes" "Improvements" "Localization" "Announcements"; do
  grep -qxF "### $sec" <<<"$OUT" && pass "renders ### $sec" \
    || { echo "  FAIL: '### $sec' missing from the notes"; FAIL=1; }
done
grep -q "Internal" <<<"$OUT" && { echo "  FAIL: chore leaked into customer-facing notes"; FAIL=1; } \
  || pass "chore dropped from the notes"
grep -q "chore" /tmp/cl.err && { echo "  FAIL: chore warned about; it is a deliberate silent drop"; FAIL=1; } \
  || pass "chore dropped silently (no warning)"
grep -q "Typo" <<<"$OUT" && { echo "  FAIL: unknown type 'l10n' rendered; it must be dropped"; FAIL=1; } \
  || pass "unknown type dropped from the notes"
grep -q "::warning::.*l10n" /tmp/cl.err && pass "unknown type warned on stderr" \
  || { echo "  FAIL: unknown type 'l10n' dropped silently — the #11 bug"; FAIL=1; }
grep -q "l10n" "$SUM" && pass "unknown type reaches \$GITHUB_STEP_SUMMARY" \
  || { echo "  FAIL: unknown type missing from the step summary"; FAIL=1; }
grep -q "::warning::" <<<"$OUT" && { echo "  FAIL: a warning reached stdout — stdout is the release notes"; FAIL=1; } \
  || pass "warnings never touch stdout"
rm -f /tmp/cl-types.json "$SUM" /tmp/cl.err

echo "== signing: the ephemeral keychain disarms its auto-lock =="
# A keychain straight out of `security create-keychain` inherits lock-on-sleep +
# a 300s idle-lock, which fires mid-archive and hangs codesign on an unlock
# prompt no headless runner answers (#9). The create must be followed by
# `set-keychain-settings` (no -t/-l ⇒ no timeout) and an explicit unlock, and
# preceded by a tolerant delete of a keychain a cancelled run left behind.
KCWF="$ROOT/.github/workflows/_build-ios.yml"
KCBODY="$(grep -A 15 'security create-keychain' "$KCWF")"
grep -q 'security set-keychain-settings' <<<"$KCBODY" && grep -q 'security unlock-keychain' <<<"$KCBODY" \
  && pass "create-keychain is followed by set-keychain-settings + unlock-keychain" \
  || { echo "  FAIL: create-keychain is not followed by set-keychain-settings + unlock-keychain"; FAIL=1; }
grep -qE 'set-keychain-settings.*(-[a-z]*[tl])' <<<"$KCBODY" \
  && { echo "  FAIL: set-keychain-settings must carry no -t/-l, or the fuse is only lengthened"; FAIL=1; } \
  || pass "no -t/-l, so no timeout at all"
grep -B 4 'security create-keychain' "$KCWF" | grep -q 'security delete-keychain build.keychain 2>/dev/null || true' \
  && pass "a stale keychain from a cancelled run is deleted before the create" \
  || { echo "  FAIL: no tolerant delete-keychain before create-keychain"; FAIL=1; }

echo "== distribute-pr: every product compiles, whether or not tests run =="
# The tests never stand in for this compile — the swift runner never opens the
# Xcode project, and the xcodebuild runner builds for the Simulator in Debug,
# while the beta archives for a device in Release (#10).
PRWF="$ROOT/.github/workflows/distribute-pr.yml"
VERIFY="$(awk '$0=="  verify:"{f=1;next} f&&/^  [a-z][a-z0-9_-]*:[ ]*$/{f=0} f' "$PRWF")"
COMPILE="$(awk 'index($0,"- name: Compile (no signing)"){f=1;next} f&&/^      - name: /{f=0} f' <<<"$VERIFY")"
[ -n "$COMPILE" ] && pass "verify has a Compile (no signing) step" \
  || { echo "  FAIL: distribute-pr.yml verify has no 'Compile (no signing)' step"; FAIL=1; }
grep -q "run-tests" <<<"$VERIFY" \
  && { echo "  FAIL: verify mentions run-tests — compiling must not depend on testing (#10)"; FAIL=1; } \
  || pass "verify has no run-tests gate"
grep -q "^ *if:" <<<"$COMPILE" \
  && { echo "  FAIL: the Compile step is conditional — a build that can skip itself is how #10 hid"; FAIL=1; } \
  || pass "the Compile step is unconditional"
grep -q "CODE_SIGNING_ALLOWED=NO" <<<"$COMPILE" && grep -q 'generic/platform=iOS' <<<"$COMPILE" && ! grep -q "xcodebuild archive" <<<"$COMPILE" \
  && pass "compiles unsigned for a device, without archiving" \
  || { echo "  FAIL: the PR compile must build unsigned (fork PRs get no secrets) for generic/platform=iOS, and must not archive"; FAIL=1; }

echo "== actions: nothing left on the deprecated Node 20 runtime =="
# GitHub is forcing Node 20 actions onto Node 24 and will stop doing so. The
# cache SUB-actions lagged at v4 (node20) while actions/cache itself was already
# v5 (node24) in the same file (#12). A minimum per action, not an exact pin, so
# this does not go stale on every upstream release; an UNKNOWN action fails too,
# forcing a deliberate choice.
python3 - "$ROOT" <<'PYCHK' || FAIL=1
import glob, os, re, sys
MIN = {            # first major running on node24
    "actions/checkout": 6,
    "actions/cache": 5,
    "actions/cache/restore": 5,
    "actions/cache/save": 5,
    "actions/upload-artifact": 7,
    "actions/download-artifact": 8,
}
bad = []
seen = set()
for f in sorted(glob.glob(os.path.join(sys.argv[1], ".github/workflows/*.yml"))):
    for n, line in enumerate(open(f), 1):
        m = re.search(r"uses:\s*(actions/[\w./-]+)@v(\d+)", line)
        if not m:
            continue
        name, major = m.group(1), int(m.group(2))
        seen.add(name)
        where = f"{os.path.basename(f)}:{n}"
        if name not in MIN:
            bad.append(f"{where}  {name}@v{major} is not in the known-good table — "
                       f"check its runtime and add a minimum")
        elif major < MIN[name]:
            bad.append(f"{where}  {name}@v{major} runs on node20; needs >= v{MIN[name]}")
for b in bad:
    print(f"  FAIL: {b}")
if not bad:
    print(f"  ok  : all {len(seen)} distinct actions are on a node24 major")
sys.exit(1 if bad else 0)
PYCHK

echo
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED ✅" || { echo "SOME TESTS FAILED ❌"; exit 1; }
