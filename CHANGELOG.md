# Changelog

Release notes list only what changed since the previous release.

## v1.7.0

- Session renames made in Claude Desktop are now detected via an FSEvents watch on the Desktop store, so the panel picks up new titles without waiting for the next hook event
- Equalized horizontal padding in the social preview image
- Added a release skill codifying the end-to-end release flow

## v1.6.0

- Panel now draws a hairline border and a reliable drop shadow
- Edge resize cursors now show up over the panel borders, and the actual resize zones match the cursor zones
- Fixed the stale Release build badge in the README
- Re-recorded the README demo GIF (smaller file) and added a record-demo-gif skill to regenerate it

## v1.5.4

- Replace release-drafter with GitHub's auto-generated release notes (categorized by PR label via `.github/release.yml`), removing the standing notes draft that could be hand-published into a broken immutable release

## v1.5.3

- Regenerate the social preview image with the new Retina demo frame and the icon wordmark as its title
- Proper release of the accidentally hand-published v1.5.3 notes draft, which went out asset-less on the drafter's placeholder tag (now deleted); publishing releases must always go through a `v*` tag push

## v1.5.2

- Re-release of v1.5.1: pushing the tag auto-published release-drafter's draft (which named the same tag) before the workflow could attach assets, leaving an immutable asset-less release
- The drafter's placeholder tag name no longer matches real release tags, so tag pushes can't publish the notes draft

## v1.5.1

Published without release assets — superseded by v1.5.2.

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
