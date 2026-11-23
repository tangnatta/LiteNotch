# Security policy

LiteNotch reads Claude Code approvals, other apps' notifications and the
clipboard, and can keep a Mac awake with the lid closed, so we take reports
seriously.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private reporting:
<https://github.com/tangnatta/LiteNotch/security/advisories/new>

Include the version, macOS version, and steps to reproduce. This is a
prototype maintained by volunteers: expect an acknowledgement within about a
week, not a bounty.

## Scope

The invariants we hold ourselves to are listed under "Security invariants" in
[CLAUDE.md](CLAUDE.md): for example, nothing arriving on the socket can answer
an approval, and an approval that cannot be reviewed in full cannot be allowed
from the notch. A way around one of them is a vulnerability.

Only the latest release is supported.
