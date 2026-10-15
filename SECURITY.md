# Security

This tool lets AI agents act on a real Mac, so security reports are taken seriously.

## Reporting

Please report vulnerabilities privately through GitHub: **Security › Report a vulnerability** on this repository. Do not open a public issue.

You can expect an answer within a week. Fixes are released as soon as they are ready, and you are credited unless you prefer otherwise.

## In scope

- Reaching a blocked app (password managers) or bypassing the approval dialog or a saved refusal.
- Acting while the screen is locked.
- Revealing secure text field contents.
- Anything that lets the permissions granted to Mac Computer Use MCP be used by another program.
- Writing screenshots or window content to disk.

## Out of scope

- Prompt injection that convinces a model to misuse apps the user approved. The server warns the model about it, but it can't fully prevent it (see the README). Ideas to reduce it are welcome as regular issues.
- Issues that need an already compromised user account.
