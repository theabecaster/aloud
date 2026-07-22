# Release pipeline

Fully automatic: merge to `main` → version computed from Conventional Commits → build, sign, notarize, staple → GitHub Release with a `.dmg`. Users update in-app.

## Branching

- `dev` — integration branch. Day-to-day work lands here (direct or via PR). CI (`build` job) must be green.
- `main` — release branch. Advancing it (PR merge from `dev`, or direct push) triggers `release.yml`.
- Both protected: PR + green `build` check required; repo-admin bypass enabled so the maintainer can push directly. `scripts/setup-branch-protection.sh` applies the rules.

## Versioning — `scripts/next-version.sh`

Semver derived from Conventional Commits since the last `v*` tag:

- `feat!:` / `BREAKING CHANGE` → major
- `feat:` → minor
- `fix:` / `perf:` → patch
- anything else only (docs/chore/ci/refactor/test) → **no release**
- `[skip release]` in the tip commit → no release

Manual escape hatches: `gh workflow run release.yml -f version=X.Y.Z`, or push a `vX.Y.Z` tag.

## Signing & notarization

Local + CI both go through `scripts/make-app.sh` (stage bundle, embed Info.plist + entitlements, codesign) and `scripts/make-dmg.sh` (create the drag-to-Applications DMG). Hardened runtime + secure timestamp always on for Developer ID signing; ad-hoc fallback when no identity is available (PRs, forks) so CI still validates packaging.

Notarization uses an **App Store Connect API key** via `xcrun notarytool` (`--key/--key-id/--issuer`), then `stapler staple` on both the .app and the .dmg, then `spctl -a` as a hard gate.

GitHub secrets:

| Secret | Content |
|---|---|
| `MACOS_CERTIFICATE` | base64 `.p12` of the Developer ID Application cert |
| `MACOS_CERTIFICATE_PWD` | its export password |
| `KEYCHAIN_PWD` | throwaway CI keychain password |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | issuer ID |
| `ASC_KEY_P8` | contents of the `.p8` key |

Locally, the same scripts pick up `CODESIGN_IDENTITY` from the keychain and notarize with `xcrun notarytool ... --key ~/.appstoreconnect/private_keys/...` (or a stored `--keychain-profile aloud`).

## Artifacts

Each release publishes:

- `Aloud.dmg` — the installer users download (drag to Applications)
- `Aloud-macos.zip` — the bare notarized `.app`, consumed by the in-app updater

## In-app updates — `Support/Updater.swift`

No Sparkle; pure Foundation (same design as claude-pet's updater):

1. Silent check at launch, throttled to once/24 h, against `api.github.com/repos/theabecaster/aloud/releases/latest`. Also a manual "Check for Updates…" menu item.
2. Newer tag → download `Aloud-macos.zip`, extract with `ditto`, **verify code signature + Developer ID team** before touching anything.
3. Stage a detached shell helper that waits for the app to exit, then atomically swaps the bundle (copy → mv old aside → mv new in → rollback on any failure), strips quarantine, relaunches.
4. If in-place swap can't be trusted (translocated/quarantined run, unwritable parent), fall back to opening the Releases page.
5. UX: never interrupts. A subtle "Update available" item appears in the menu; clicking shows release notes + one button ("Update and Relaunch"). No nags, no modal on launch.

## Clean-account acceptance checklist (before calling a release done)

- [ ] Fresh user account: DMG opens with no Gatekeeper warning; drag-install works
- [ ] First launch: onboarding explains mic + accessibility, deep-links on denial, app never crashes while unprivileged
- [ ] Model downloads with visible progress; kill network afterwards → everything still works
- [ ] Hold-speak-release inserts accurate text in Terminal, TextEdit, and a browser field
- [ ] Settings (hotkey, launch-at-login, mic) persist across relaunch
- [ ] No network traffic at runtime beyond update check (verify with `nettop`/Little Snitch)
