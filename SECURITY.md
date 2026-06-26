# Security Policy

## Supported versions

MacCam is under active development. Security fixes are applied to the latest
release and `main`.

## Reporting a vulnerability

**Please do not open public issues for security vulnerabilities.**

Instead, report privately via one of:

- GitHub's [private vulnerability reporting](https://github.com/polyackiy/MacCam/security/advisories/new)
  (Security → Report a vulnerability), or
- Email **polyackiy@gmail.com** with subject `MacCam security`.

Include:

- A description of the issue and its impact.
- Steps to reproduce (a proof of concept if possible).
- Affected version / commit.

We aim to acknowledge reports within a few days and to ship a fix or mitigation
as quickly as is practical, crediting you unless you prefer to remain anonymous.

## Scope and threat model

MacCam is a fully offline, App-Sandboxed macOS app with no network code. Its
trust boundaries are narrow:

- It records the local camera/microphone to a user-selected local folder.
- Settings live in the app's sandboxed `UserDefaults`.
- It receives standard screen-lock distributed notifications (for guard mode).

Reports most relevant to this model include: sandbox escapes, arbitrary file
read/write/delete outside the chosen folder, privilege escalation, or any path
by which data could leave the machine. General Gatekeeper friction from ad-hoc
signing is expected and documented, not a vulnerability.
