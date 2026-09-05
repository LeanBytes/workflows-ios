# workflows-ios

Reusable GitHub Actions workflows for iOS / iPadOS app distribution — build, sign, and ship to
App Store Connect (TestFlight + App Store). The iOS sibling of
[`workflows-macos`](https://github.com/LeanBytes/workflows-macos).

> **Heads up — strongly opinionated.** These workflows are tailored to how **LeanBytes** ships iOS
> apps. The choices baked in — one channel (App Store Connect), timestamp-based build numbers, one
> self-contained `Config/products/<id>.json` per product (build identity + inline changelog) as the
> source of truth, self-hosted macOS runners by default — reflect that specific use case.

**Two channels, one build callee.** Most apps ship through App Store Connect (TestFlight + App Store).
A product that cannot — an app for under-13 family members, whom TestFlight's terms exclude — sets
`"channel": "ad-hoc"` and is instead signed for **release-testing** and published to S3 as
`app.ipa` + `manifest.plist`, which a device with a registered UDID installs over the air via an
`itms-services://` link **without any Apple ID**. Archive and signing are identical either way; only
the ExportOptions `method` and the publish leg differ.

There is still no Developer ID equivalent: no notarization, no stapling, no Gatekeeper assessment, no
DMG or ZIP, no Sparkle appcast.

Adding a new app means: dropping one `Config/products/<id>.json` per product, setting 7 secrets, and
copying three **trigger-only** shell workflows into `.github/workflows/` (they *discover* your
products — there is no `products` input). No build/sign/upload code lives in the consumer repo.

---

## Architecture

```
Per-app shell (trigger-only)          Shared orchestrator                       Shared callee
distribute-pr.yml           ──→   distribute-pr.yml
  on: pull_request                   discover → verify (compile each product)
distribute-beta.yml         ──→   distribute-beta.yml
  on: push branches:[main]           prepare (plan-beta: changelog-driven   ───┐
                                     cutting set) → build (matrix) →           │  _build-ios.yml
                                     publish (per product: TestFlight upload,  ├──→  (ios-build-<id>)
                                     <id>-v<ver>-beta.N tag + pre-release)     │
distribute-release.yml      ──→   distribute-release.yml                    ───┘
  on: push tags 'v*' / '<id>-v*'     prepare (plan-release: parse tag →
       (excl. -beta / -alpha)        scoped product) → build → publish-release
```

`_test.yml` is a reusable test runner (iOS Simulator destination) called by `distribute-pr.yml` as a
red PR check, by `distribute-beta.yml` as a gate, or directly by a per-app nightly shell.

## Setup

### 1. Repository access (this repo is private)

`workflows-ios` → Settings → Actions → General → **Access** →
*"Accessible from repositories in the LeanBytes organization"*. Without it, `uses:` fails with
"workflow was not found" even inside the org.

Then add **`SHARED_WORKFLOWS_TOKEN`** as a **LeanBytes organization secret** — a fine-grained PAT with
`Contents: read` on `workflows-ios`, or a GitHub App token via `actions/create-github-app-token`.
Every job that runs a shared script checks this repo out into `.shared-ci/`, and `github.token`
cannot read another private repo.

> The workflows use `token: ${{ secrets.SHARED_WORKFLOWS_TOKEN || github.token }}` throughout, so if
> this repo ever goes public the `github.token` fallback takes over and the PAT becomes optional —
> no YAML change, no new tag.

### 2. Copy the shells

Copy the three files from [`examples/per-app/`](examples/per-app/) into your app's
`.github/workflows/`. They declare triggers and secrets and nothing else.

### 3. Describe each product

One `Config/products/<id>.json` per shippable product — see the schema below and
[`examples/per-app/Config/products/app.json`](examples/per-app/Config/products/app.json).

### 4. Set the secrets

| Secret | Purpose |
|---|---|
| `APPLE_DISTR_P12_BASE64` | Apple Distribution cert + private key (base64), signs the `.app` |
| `APPLE_DISTR_PASSWORD` | Password for the Apple Distribution p12 |
| `KEYCHAIN_PASSWORD` | Ephemeral build keychain password |
| `PROV_PROF_STORE_BASE64` | App Store provisioning profile (`.mobileprovision`, base64) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64` | App Store Connect API key (for `altool`) |
| `SHARED_WORKFLOWS_TOKEN` | Read access to this repo (see above) |
| `JIRA_API_TOKEN` | Only when `run-tests` + `file-jira-on-failure` |

Per-product overrides (a multi-product repo, or a product signing under a different team) name their
own secrets in the product file — e.g. `PROV_PROF_STORE_PRO_BASE64`, `APPLE_DISTR_P12_ALT_BASE64`.

No repo **Variables** are needed. (The macOS sibling needs `S3_DISTRIBUTION_PATH` /
`S3_DOWNLOAD_URL` for direct-download hosting; iOS has no binaries to host.)

### Ad Hoc channel (`"channel": "ad-hoc"`)

Swap two secrets and add three settings:

| What | Value |
|---|---|
| `profile-secret` in the product file | name of the secret holding the **Ad Hoc** profile, e.g. `PROV_PROF_ADHOC_BASE64` |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_BASE64` | not needed — nothing is uploaded to App Store Connect |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | secrets, for the S3 upload |
| `S3_DISTRIBUTION_PATH`, `S3_DOWNLOAD_URL` | repo **variables**, same meaning as in `workflows-macos` |

The upload lands at a **stable** path so the install link never changes across versions:

```
<S3_DISTRIBUTION_PATH>/<bundle-id>/app.ipa
<S3_DISTRIBUTION_PATH>/<bundle-id>/manifest.plist
```

and the install link is

```
itms-services://?action=download-manifest&url=<S3_DOWNLOAD_URL>/<bundle-id>/manifest.plist
```

Three things bite here, all of them silently:

- **Both URLs must be HTTPS with a valid certificate.** iOS gives no useful error otherwise.
- **The manifest must be served as `text/xml`.** With S3's default `application/octet-stream` iOS downloads it and refuses to read it. The workflow sets the content type explicitly.
- **The link must be tapped in Safari.** Chrome and in-app browsers do not hand `itms-services://` to the installer.

No App Store Connect app record is required for this channel — only a registered App ID, the device
UDIDs, and the Ad Hoc profile. **The profile expires after one year, and the installed app then stops
launching**, so an annual rebuild plus a re-tap on every device is not optional.

Encode the p12 and profile like this:

```bash
base64 -i Distribution.p12       | pbcopy   # → APPLE_DISTR_P12_BASE64
base64 -i AppStore.mobileprovision | pbcopy # → PROV_PROF_STORE_BASE64
base64 -i AuthKey_XXXXXXXXXX.p8  | pbcopy   # → ASC_KEY_BASE64
```

## Product schema — `Config/products/<id>.json`

| Key | Required | Meaning |
|---|---|---|
| `id` | — | Omit (or `""`) → the **primary** product, which uses bare `vX.Y.Z` tags. At most one per repo. A non-empty id must match the filename. |
| `scheme` | **yes** | Xcode scheme to archive. |
| `bundle-id` | **yes** | Main app bundle id — the key in the ExportOptions `provisioningProfiles` dict. |
| `product-name` | no | Display name for summaries and release notes. Defaults to `scheme`. |
| `distribute` | no | Upload the `.ipa` to App Store Connect. Default `true`; set `false` for a build-and-sign dry run. |
| `profile-secret` | no | Name of the secret holding this product's profile. Defaults to `PROV_PROF_STORE_BASE64`. |
| `cert-secret` / `cert-password-secret` | no | Names of the secrets holding this product's Apple Distribution p12 + password. Default to `APPLE_DISTR_P12_BASE64` / `APPLE_DISTR_PASSWORD`. |
| `source-paths` | no | Git pathspecs this product builds from, e.g. `["Sources/**", "Project.swift"]`. **Set this** — without it a code-only push cuts no beta. |
| `channel` | no | `app-store` (default) → TestFlight via `altool`. `ad-hoc` → `release-testing` export, IPA + manifest to S3. |
| `changelog` | **yes** | Inline changelog. `versions[0].version` is the version this product is building toward. |

```json
{
  "scheme": "MyApp",
  "product-name": "My App",
  "bundle-id": "io.leanbytes.myapp",
  "source-paths": ["Sources/**", "Resources/**", "Project.swift"],
  "changelog": { "versions": [
    { "version": "1.0.0", "items": [
      { "type": "feat", "title": { "en": "Initial release" }, "issues": ["#1"] }
    ] }
  ] }
}
```

Changelog item `type` buckets into the rendered notes as `feat → New Features`, `fix → Bug Fixes`,
`core → Improvements`; `chore` and unknown types are dropped. `issues` is pure provenance — nothing
in the pipeline reads it.

## Versioning

- **Build number** is `date -u +%y%m%d%H%M%S` — a UTC timestamp, strictly monotonic, used as
  `CFBundleVersion` / `CURRENT_PROJECT_VERSION`. Every build path uses this.
- **Marketing version** is always the bare `X.Y.Z` from `changelog.versions[0].version`. App Store
  Connect rejects a non-`N.N.N` `CFBundleShortVersionString`, so betas do **not** carry a `-beta.N`
  suffix in the binary — the build number disambiguates them, and the git tag records which beta it was.
- Git tag `<id>-vX.Y.Z` (or bare `vX.Y.Z` for the primary) marks a release. Pushing it triggers the
  release flow; CI validates it matches that product's `changelog.versions[0].version`.
- Git tag `<id>-vX.Y.Z-beta.N` marks the Nth beta. Auto-pushed per product by `distribute-beta.yml`.

**Beta is changelog-driven (the gate).** On every push to `main`, a product cuts its next beta **only
when** (a) its `changelog.versions[0]` version isn't released (no `<id>-vX.Y.Z` tag) AND (b) its own
`Config/products/<id>.json` — or one of its `source-paths` — changed since its last beta. So editing
one product's changelog betas only that product, and a released (idle) product is skipped, not blocked.

## Publish ordering

Fail-safe: the git tag and the GitHub Release come **last**, so nothing ever claims a build shipped
when the upload failed.

```
1. Render release notes from the product's inline .changelog
2. (gate) xcrun altool --upload-app --type ios   →  App Store Connect
3. beta only: git push <id>-v<ver>-beta.N
4. gh release create        ← only if every prior step succeeded
```

There is no asset upload on the GitHub Release — an App-Store-only product has no downloadable
artifact. The `.ipa` is available as a workflow artifact for the retention window.

**Release is upload-only.** Creating the App Store version and hitting *Submit for Review* stays
manual in App Store Connect.

**TestFlight is upload-only too.** Groups, tester assignment, auto-distribution and "What to Test"
are configured in App Store Connect.

## App-side requirements

The workflows do not manage your Xcode project. Your app must:

- Reference `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` in its `Info.plist` — the archive
  step injects both via `xcodebuild`.
- Set `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` (or the real value) so App Store Connect
  skips the manual export-compliance question on every TestFlight upload.
- Have a registered bundle id and an **app record in App Store Connect** before anything can upload.

### Embedded targets (widgets, extensions, Watch apps)

`_build-ios.yml` currently signs the **main app bundle only**. Things that need nothing extra:

- **CarPlay** — an entitlement (`com.apple.developer.carplay-*`) on the main app's profile, granted by
  Apple on request. One target, one profile.
- **App Intents compiled into the main app target** — Shortcuts, Siri and the Action button all work
  from intents in the app binary.

Things that would need a second provisioning profile, and therefore support that isn't built yet:
a **widget** (WidgetKit is always a separate `.appex`, and Control Center / Lock Screen controls live
inside it), a separate **App Intents Extension**, a **share extension**, a **notification service
extension**, or a **Watch app**. Adding it touches only `_build-ios.yml`, one product-JSON key and
one secret — open an issue when an app needs it.

## Runners

Every job defaults to `runs-on: [self-hosted, macOS]`. Each runner is a **JSON-encoded**
`runs-on` / `runs-on-build` / `runs-on-publish` / `runs-on-prepare` input consumed via `fromJSON()`:

```yaml
runs-on-build: '"macos-26"'                   # a GitHub-hosted runner
runs-on-build: '["self-hosted","agent-alex"]' # a specific self-hosted runner
```

A bare `macos-26` is **not** valid. An app with no self-hosted macOS runner **must** override these,
or its jobs queue forever.

`runs-on-prepare` covers the cheap coordination jobs — `discover` on PRs, `prepare` on beta/release,
and (passed through automatically) `_test.yml`'s `gate`. They run `actions/checkout` plus `python3`
and never touch Xcode, so a hosted `'"ubuntu-latest"'` is the cheapest correct value there. An app on
hosted runners overrides all three:

```yaml
with:
  runs-on-prepare: '"ubuntu-latest"'
  runs-on-build:   '"macos-26"'
  runs-on-publish: '"macos-26"'   # altool — must be macOS
```

## Development

```bash
bash tests/run.sh   # offline products.py + classify_upload suite; no git repo, no network
actionlint -ignore 'property "job_workflow_sha" is not defined' \
           -ignore 'shellcheck reported issue' .github/workflows/*.yml
```

`selftest.yml` runs both on every PR and push to `main` that touches `.github/**` or `tests/**`.

**Tag discipline:** every workflow change ships under a new patch tag, and the `@vX.Y.Z` callouts
*inside* the shared workflows **and** in `examples/per-app/` are bumped in the same commit.

## License

MIT — see [LICENSE](LICENSE).
