# Security Policy

## Supported versions

Security fixes are made on `main` and released from the latest `v*` tag. Older
tags are not patched; upgrade to the latest release.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| `main` | Yes |
| Older releases | No |

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability
reporting: open the repository's **Security** tab and choose **Report a
vulnerability**. If that is unavailable, open an issue asking for a private
contact channel and leave out the details until one is arranged.

Do not open a public issue for a vulnerability.

Please include:

- the affected version or commit;
- the operating system and Neovim version;
- a description of the impact and, when possible, a minimal reproduction.

You can expect an acknowledgement within a few days. A confirmed report is
fixed on `main`, released, and credited in the release notes unless you ask
otherwise.

## Scope

In scope:

- the `md-render` engine (`engine/`) and the vendored crates under `crates/`;
- the Neovim plugin under `lua/`, `plugin/` and `doc/`;
- the release workflow and the published binaries.

Out of scope:

- vulnerabilities in Neovim itself, or in a package manager;
- documents whose source the reader already chose to open: a markdown file can
  reference images and links, and the plugin only opens what the reader asks
  it to open;
- reports that require an already-compromised machine or editor configuration.
