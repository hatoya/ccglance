# Security Policy

## Supported versions

Only the [latest release](https://github.com/hatoya/ccglance/releases/latest) is supported. The app updates itself automatically, so most users are on the latest version.

## Reporting a vulnerability

Please **do not open a public issue** for security vulnerabilities.

Report them privately via GitHub's private vulnerability reporting: go to the [Security tab](https://github.com/hatoya/ccglance/security) → **Report a vulnerability**.

Please include:

- A description of the vulnerability and its impact
- Steps to reproduce (a proof of concept if possible)
- The version of ccglance affected

You should receive an initial response within a week. Once a fix is released, the report will be disclosed through a GitHub Security Advisory.

## Scope notes

- ccglance runs entirely locally: session state is written to `~/.claude/ccglance/` and never leaves the machine. The only network access is to GitHub (`api.github.com` / release assets) for the auto-updater, plus `gh pr view` runs against the repos of your own sessions.
- The auto-updater verifies the release zip's SHA-256 against the published `.sha256` asset and requires the new bundle to carry a valid Developer ID signature from the project's team before installing.
