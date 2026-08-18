# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

The canonical shared **iOS / iPadOS** CI/CD workflows for LeanBytes apps — the sibling of
`LeanBytes/workflows-macos`. Each app repo carries tiny per-app shell workflows that call into the
orchestrators here via `uses: LeanBytes/workflows-ios/.github/workflows/<orchestrator>.yml@<tag>`.

**The defining constraint: iOS has no external distribution.** Everything ships through App Store
Connect. The macOS repo's entire Developer ID / Direct channel has no analogue here and is
deliberately absent — no notarization, no `stapler`, no `spctl`, no DMG/`hdiutil`, no `ditto` ZIP, no
Sparkle appcast or `generate_appcast`, no `SPARKLE_ED_PRIVATE_KEY`, no S3 hosting, no
`Mac Installer Distribution`/`productbuild`/`.pkg`, no unlisted alpha hand-out. One channel: archive
→ export `.ipa` → `xcrun altool --upload-app --type ios`.

Because there is one channel there is **one build callee and one `has-any` gate**, where macOS has
two of each (`direct` + `store`). Don't reintroduce the split.

Layout: `.github/workflows/_build-ios.yml` is the internal callee;
`.github/workflows/distribute-{pr,beta,release}.yml` are the orchestrators; `_test.yml` is a reusable
test runner; `.github/scripts/` holds `products.py` (the discovery/beta/release brain) plus helpers;
each app repo carries one `Config/products/<id>.json` per product (identity + inline changelog);
`examples/per-app/` has the trigger-only shell templates; `tests/` holds the offline suite.

## Relationship to workflows-macos

`products.py` is a **fork and reduction** of the macOS one (~313 lines vs 374), not a shared copy.
`changelog-from-json.sh`, `classify-upload.sh`, `jira_client.py` and `create_test_ticket.py` are
byte-identical copies. `run-tests.sh` differs by exactly one thing: a `TEST_DESTINATION` env var
defaulting to an iOS Simulator instead of a hardcoded `platform=macOS`.

When fixing a bug in a copied file, check whether `workflows-macos` has the same bug.

**Two known drifts worth an issue on `workflows-macos`:**
- Its App Store export omits `manageAppVersionAndBuildNumber`, which defaults to `true` and lets Xcode
  rewrite `CFBundleVersion` at export. This repo sets it `false`.
- Its `distribute-alpha.yml` downloads the artifact by the hardcoded name `direct-build` while
  `_build-direct.yml`'s callers override it per product.

## Repository visibility

**Private for now** — because there's no need for it to be public yet, not because anything depends
on it. Nothing in the design assumes private:

- Every `.shared-ci` checkout uses `token: ${{ secrets.SHARED_WORKFLOWS_TOKEN || github.token }}` and
  declares the secret `required: false`. Private ⇒ the PAT is required in practice; going public makes
  the `github.token` fallback take over, with **no YAML change and no new tag**.
- The per-app shells ship with the **explicit `secrets:` block**, which works in every configuration.
  `secrets: inherit` is a same-org shortcut only — it silently passes nothing once the call chain
  crosses an account boundary.

Never bake a private-only assumption into the workflows.

Consequence to remember: `workflows-ios` → Settings → Actions → Access must be
*"Accessible from repositories in the LeanBytes organization"*, and `SHARED_WORKFLOWS_TOKEN` must
exist as a LeanBytes org secret. Every job except `_build-ios.yml` checks this repo out for its
scripts.

## Versioning model

Each product's `Config/products/<id>.json` carries its own inline `changelog` — the single source of
truth for that product's next-to-ship version and release notes. Git tags mark ship moments. The
**primary** product (the one that omits `id`) uses bare `vX.Y.Z`; every other product is
`<id>-vX.Y.Z`. At most one product per repo may omit `id`.

**Marketing version is always the bare `X.Y.Z`** — App Store Connect rejects a non-`N.N.N`
`CFBundleShortVersionString`, so unlike macOS's Sparkle channel there is no `-beta.N` in the binary.
The timestamp build number disambiguates betas; the git tag records which beta it was. (macOS splits
this per channel; here the two collapse, and `products.py` emits a single `marketing` key.)

**Gate (changelog-driven, per product):** on push→main a product cuts a beta only when its version is
unreleased AND its own file (or one of its `source-paths`) changed since its last beta. No
cross-product coupling — editing one product's changelog never cuts another's beta, and a released
(idle) product is skipped, not blocked.

## Scope decisions (deliberate omissions)

- **`distribute-alpha.yml` — skipped permanently, not deferred.** A TestFlight *internal* group is
  already an invite-only, review-free private channel. Building a 400-line orchestrator to duplicate
  something Apple gives away is over-building. If you want an off-main build, add a
  `workflow_dispatch` trigger to the beta shell.
- **`memory-watch.yml` — skipped.** `simctl` RSS sampling measures something different from the macOS
  version (simulator process ≠ device memory, no jetsam), so the thresholds don't transfer and you'd
  tune a new heuristic from scratch. Revisit only if an iOS app actually leaks.
- **S3 `Changelog.json` publishing — skipped.** No consuming app has a marketing page that reads it.
- **ASC review submission / TestFlight "What to Test" via the ASC REST API — skipped.** Both would
  need a JWT ES256 signer, which stdlib Python can't do (no ECDSA) — meaning an `openssl` shell-out or
  a pip dependency on the runner. Release and TestFlight are both **upload-only**; the human finishes
  in the ASC UI.
- **Embedded-target provisioning profiles — not built yet.** See below.

Each of these has a default-off shape if it ever gets built. Don't add one speculatively.

## Embedded targets

`_build-ios.yml` signs the **main app bundle only**. Know the difference before agreeing something
"needs extension support":

- **CarPlay** needs nothing — it's an entitlement on the main app's profile.
- **App Intents in the main app target** need nothing — Shortcuts, Siri and the Action button all work
  from intents in the app binary.
- A **widget**, a separate **App Intents Extension**, a **share extension**, a **notification service
  extension** or a **Watch app** each need their own provisioning profile, and that is unbuilt.

When it's needed: add ONE generic list (`extensions: [{bundle-id, profile-secret}]`) with a single
install loop, not macOS's three near-identical hardcoded steps. Note the GHA constraint —
`${{ secrets[expr] }}` is evaluated before bash runs, so a bash loop cannot index `secrets` by a name
read from JSON. The workable shape is one secret per product holding base64 of a JSON map
`{bundle-id: base64(profile)}`, selected with the existing `secrets[matrix.product.<key>]` idiom.

## Load-bearing details

These are all bugs someone already paid for. Don't "clean them up".

- **`\x1f` (Unit Separator), never tab**, in the publish product tables. Tab is IFS-whitespace, so
  `read` collapses runs of it and an empty column shifts every later field. `tr '\037' '\t'` only for
  the human-readable echo.
- **`rm -rf /tmp/build` before every archive** (LB-459). `/tmp` persists across jobs on a self-hosted
  runner; a killed job's export otherwise rides along in the `*.ipa` upload glob.
- **`set +e` around the `altool` capture.** Under errexit a non-zero exit aborts the step before the
  classifier runs. This was a real macOS bug (v0.3.46).
- **`classify-upload.sh` must stay the single definition** of "did the upload land?", sourced by both
  publish jobs *and* `tests/run.sh`. `ITMS-90189` → `already-present` (benign); `-19232` →
  **`failed`**. Never widen the pattern to "already been used" — that swallowed a failed upload as
  green once already.
- **`manageAppVersionAndBuildNumber` must be `false`** in ExportOptions. It defaults to `true` for
  `app-store-connect` exports and rewrites `CFBundleVersion`, destroying the monotonic build number.
- **Never pass `PROVISIONING_PROFILE_SPECIFIER` to `xcodebuild archive`.** It's project-wide, so it
  silently mis-signs every embedded target. Signing is pinned at *export* via `provisioningProfiles`.
- **iOS profiles are `.mobileprovision`** (macOS: `.provisionprofile`) but live in the same directory.
  Clean them up in `if: always()` or they accumulate on the self-hosted runner and shadow each other.
- **A job `if:` cannot read `matrix`, and an empty matrix throws** rather than skipping — hence
  `prepare` emits `has-any` and the build job gates on that boolean. `matrix.*` is likewise illegal in
  `uses:`.
- **`download-artifact` flattens a lone matched artifact** into the base path with no subdir; two or
  more do get subdirs. The re-nest loop is why a single-product beta doesn't report "No .ipa" — and
  a release always builds exactly one product, so that path is the norm there.
- **`.shared-ci` is checked out at `github.job_workflow_sha`**, never `@main`, so the scripts can't
  drift from the workflow YAML calling them mid-run.
- **`runs-on*` inputs are JSON-encoded** and consumed with `fromJSON()`. A bare `macos-26` is invalid.
- **Repo-wide `concurrency`, `cancel-in-progress: false`** on beta — racing pushes would otherwise
  produce duplicate `-beta.N` tags.

## Editing patterns

- **All workflow logic lives here; per-app shells only declare triggers and secrets.** When iterating
  on logic, edit the workflows in this repo and bump the tag. Don't fork logic into per-app shells.
- **`products.py` is offline-testable** via injected `GIT_TAGS` / `CHANGED_PRODUCTS` / `BUILD_NUMBER`
  / `PRODUCTS_DIR` / `TAG`. Add a case to `tests/run.sh` for any behaviour change — it runs in about a
  second and needs no git repo or network.
- **When bumping the tag, also bump the `@vX.Y.Z` callouts inside the shared workflows AND in
  `examples/per-app/`.** Both `distribute-*.yml` (which call `_build-ios.yml` / `_test.yml`) and every
  example shell carry the pin.
- **Prove changes end-to-end on one app first**, then port. TestFlight is a free smoke test — an
  `altool` upload triggers no App Store review, and internal-tester distribution is unlimited. For an
  even cheaper dry run, set `distribute: false` in the product file: it builds, signs and produces the
  `.ipa` artifact without ever contacting ASC.
