#!/usr/bin/env bash
# Offline unit tests for .github/scripts/products.py — no git repo, no network.
# Git is stubbed via GIT_TAGS / CHANGED_PRODUCTS; the timestamp via BUILD_NUMBER.
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
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0-beta.1 companion-v1.3.0-beta.1" CHANGED_PRODUCTS="main" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "only main → beta.2; companion unchanged → skipped" \
  'b=json.loads(o["beta-products"]); assert [x["id"] for x in b]==["main"], b; assert b[0]["release-tag"]=="main-v2.14.0-beta.2"'

echo "== plan-beta: everything released → empty cutting set =="
CAP PRODUCTS_DIR="$MULTI" GIT_TAGS="main-v2.14.0 companion-v1.3.0" BUILD_NUMBER="x" python3 "$PY" plan-beta
line "nothing cuts → has-any=false gates the build job" "has-any=false"
jok "beta-products is an empty array, not absent" 'assert json.loads(o["beta-products"])==[]'

echo "== plan-release =="
CAP PRODUCTS_DIR="$MULTI" TAG="main-v2.14.0" BUILD_NUMBER="x" python3 "$PY" plan-release
[ $RC -eq 0 ] && pass "main release exit 0" || bad "main release exit"
line "target-id=main" "target-id=main"
line "version=2.14.0" "version=2.14.0"
line "artifact-label=v2.14.0" "artifact-label=v2.14.0"
line "has-any=true" "has-any=true"
jok "products is the single scoped target" \
  'p=json.loads(o["products"]); assert len(p)==1 and p[0]["id"]=="main"; assert p[0]["marketing"]=="2.14.0"'

CAP PRODUCTS_DIR="$MULTI" TAG="companion-v1.3.0" BUILD_NUMBER="x" python3 "$PY" plan-release
[ $RC -eq 0 ] && pass "companion release exit 0" || bad "companion release exit"
line "target-id=companion" "target-id=companion"

for T in "main-v9.9.9" "v2.14.0" "bogus-v1.0.0" "main-v2.14.0-beta.1"; do
  CAP PRODUCTS_DIR="$MULTI" TAG="$T" python3 "$PY" plan-release
  [ $RC -ne 0 ] && pass "reject '$T'" || bad "'$T' should fail (rc=$RC)"
done

echo "== single-product fixture =="
CAP PRODUCTS_DIR="$SINGLE" python3 "$PY" discover
line "single ids" "ids=app"
CAP PRODUCTS_DIR="$SINGLE" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "app → beta.1" 'b=json.loads(o["beta-products"]); assert b[0]["release-tag"]=="app-v1.0.0-beta.1"'
CAP PRODUCTS_DIR="$SINGLE" TAG="app-v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "app release target" "target-id=app"

echo "== mixed: primary (empty id → bare v*) + prefixed pro =="
CAP PRODUCTS_DIR="$MIXED" python3 "$PY" discover
line "mixed ids (keys from filenames)" "ids=base pro"
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "base → bare v1.0.0-beta.1; pro → pro-v2.0.0-beta.1" \
  'b={x["id"]:x for x in json.loads(o["beta-products"])}; assert b["base"]["release-tag"]=="v1.0.0-beta.1", b["base"]["release-tag"]; assert b["pro"]["release-tag"]=="pro-v2.0.0-beta.1", b["pro"]["release-tag"]'
jok "per-product cert secret carried (base overrides, pro defaults)" \
  'b={x["id"]:x for x in json.loads(o["beta-products"])}; assert b["base"]["cert-secret"]=="APPLE_DISTR_P12_ALT_BASE64"; assert b["base"]["cert-password-secret"]=="APPLE_DISTR_PASSWORD_ALT"; assert b["pro"]["cert-secret"]==""'
CAP PRODUCTS_DIR="$MIXED" TAG="v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "bare tag → primary" "target-id=base"
CAP PRODUCTS_DIR="$MIXED" TAG="pro-v2.0.0" BUILD_NUMBER="x" python3 "$PY" plan-release
line "prefixed tag → pro (longest prefix wins over bare 'v')" "target-id=pro"
CAP PRODUCTS_DIR="$MIXED" GIT_TAGS="v1.0.0" BUILD_NUMBER="x" python3 "$PY" plan-beta
jok "base released (bare v1.0.0) → idle; only pro cuts" \
  'b=[x["id"] for x in json.loads(o["beta-products"])]; assert b==["pro"], b'

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
# Real git repos, real `git diff` — CHANGED_PRODUCTS is deliberately NOT set, so
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

echo
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED ✅" || { echo "SOME TESTS FAILED ❌"; exit 1; }
