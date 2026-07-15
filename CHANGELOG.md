# Changelog

Release notes list only what changed since the previous release.

## v1.5.1

- Re-release of v1.5.0, which was published without its zip/sha256 assets (GitHub immutable releases reject asset uploads after publishing, which broke the publish-triggered release workflow)
- Release workflow now runs on tag push and publishes via draft → attach assets → publish, compatible with immutable releases

## v1.5.0

Published without release assets — superseded by v1.5.1.

- Auto-updater now pins the update's code signature to the Developer ID Team ID, and a SECURITY.md was added
- CHANGELOG catch-up, README badges, and a social preview image

## v1.4.0

- Homebrew support: `brew install --cask hatoya/tap/ccglance` — the tap cask is updated automatically on every release
- New sessions show a placeholder label until their title resolves, instead of a temporary random name
- Removed non-functional keyboard shortcut hints from the right-click menu
- Documentation updated for Developer ID signed and notarized releases

## v1.3.0

- Releases are now Developer ID signed and notarized, so Gatekeeper opens them without warnings
- Updates install automatically when a newer release is found
- PR status is polled every 60 seconds while sessions are idle
- Fixed subagent status not being reflected in the panel
- Refreshed README demo GIF with subagent rows and the PR badge
- Fixed a release workflow condition that prevented signing secrets from being detected

## v1.2.0

- Show awaiting-input status while Claude is waiting on a question or plan approval
- Show running subagent status in the panel
- Show PR status on the idle row icon
- The yellow attention dot is no longer shown while a session is awaiting confirmation
- Fixed the polling interval documented in the README to match the implementation (0.5s)
- Added release-drafter for automated draft release notes

## v1.1.1

- Release assets (`ccglance.zip` + `.sha256`) are now built and attached automatically by GitHub Actions when a release is published
- Higher-quality demo GIF and a larger download button in the README
- Added "Built with Claude / not affiliated" section to the README

## v1.1.0

- Release zip is now unversioned (`ccglance.zip`), so the stable link `releases/latest/download/ccglance.zip` always points to the latest version
- Right-click menu: version / update block moved to the top
- README rewritten in English, with a demo GIF, a one-click download button, and manual-update instructions
- Added CHANGELOG

## v1.0.0

Initial release.
