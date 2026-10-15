# Contributing

Thanks for helping. Bug reports, fixes and ideas are welcome.

## Before you start

- For anything bigger than a fix, open an issue first so we can agree on the approach.
- Keep the project dependency-free: one Swift package, AppKit and the system frameworks only.
- Match the surrounding code: short functions, comments that explain *why*, messages written for the agent that reads them.

## Build and test

```sh
swift build
swift test              # needs Xcode (XCTest)
scripts/smoke-test.sh   # the real binary, driven as an MCP client would
```

Automated tests can't grant macOS permissions, so anything that touches apps also needs a manual check:

1. `./scripts/install.sh`, then `mac-computer-use-mcp permissions` and `doctor`.
2. Connect a client, and with **TextEdit** (a throwaway document): `get_app_state`, click a toolbar button, `type_text`, `press_key super+a`, `paste` with `md`, `scroll`.
3. Keep working in another window meanwhile: your pointer and typing must stay yours.
4. Mention the macOS version and the apps you tried in the pull request.

Never test on real conversations, e-mails or documents you care about.

## Pull requests

- One topic per pull request, with a short description of the behaviour change.
- Add a line to `CHANGELOG.md` under an "Unreleased" heading.
- CI must pass (build, unit tests, smoke test).
