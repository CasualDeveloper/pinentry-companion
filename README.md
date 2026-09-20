<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/logo.svg">
    <img src="assets/logo.svg" width="260" alt="pinentry-companion logo">
  </picture>
</p>

# pinentry-companion

Native macOS GPG pinentry with Apple Watch/companion unlock, Touch ID, macOS password fallback, and Keychain-backed passphrase storage.

`pinentry-companion` is a Swift command-line pinentry program. It speaks the GnuPG pinentry/Assuan protocol over stdin/stdout, stores GPG passphrases in the macOS Keychain, and uses LocalAuthentication to require local device-owner authentication before reading them.

## Features

- Native Swift implementation
- Keychain unlock with Apple Watch/companion support, plus Touch ID and the macOS account password on supported Macs
- `pinentry-mac` fallback for first-time passphrase entry and unsupported flows, with `pinentry-curses`/`pinentry-tty` fallback if needed
- Stale Keychain entry repair when GPG reports a bad passphrase retry
- Transactional, reversible setup with exact compare-and-swap drift checks
- Versioned JSON status, change-plan, and transactional lifecycle commands for automation
- Explicit, component-scoped cache purge and uninstall preparation commands
- Interactive `doctor auth` check for Touch ID/Apple Watch/account-password verification
- No background daemon, telemetry, network calls, or automatic signing tests

## Security Model

This tool optimizes local convenience for macOS GPG users. It stores the GPG key passphrase in the macOS login Keychain as a `ThisDeviceOnly` item and requires macOS local authentication before reading it.

On every supported macOS release, unlock attempts use the LocalAuthentication Watch/companion and biometry policy where available, allowing Apple Watch or Touch ID, with device-owner authentication fallback for the macOS account password. Apple renamed the Watch APIs to Companion in the macOS 15 SDK without changing their underlying policy values.

Keychain-enforced companion ACL storage requires a build with the required Keychain entitlement; an ad hoc signature is not sufficient. The explicit `pinentry-companion doctor auth` check reports this as informational when ACL storage is unavailable for unentitled builds, including ordinary source/Homebrew builds. When ACL storage is available, new cached entries are stored under an ACL-protected Keychain service and macOS enforces authentication on read. Unentitled builds fall back to the app-level LocalAuthentication gate described above. Ordinary `doctor` and `doctor report` remain passive; only `doctor auth` creates temporary diagnostic Keychain items.

That means your GPG passphrase becomes unlockable by macOS local authentication rather than a separately typed GPG passphrase. If you require your GPG passphrase to remain independent from your macOS account credentials, do not use this tool.

`pinentry-companion` never runs a real signing/decryption test by itself. Any live GPG operation must be initiated explicitly by the user.

Setup records the exact original GPG configuration bytes, file and directory modes, and `DisableKeychain` preference in a private `0600` lifecycle record under `~/Library/Application Support/pinentry-companion/state-v1`. Lifecycle operations are globally serialized because `DisableKeychain` is shared across GPG homes. Additional managed homes inherit the first active home's preference baseline, and that preference is restored only after the final managed home is released. Configuration writes use atomic replacement, verify postconditions, and roll back on failure. Restore refuses to overwrite configuration that no longer matches a recorded transaction state.

## Requirements

- macOS 14 or newer
- GnuPG
- A supported fallback pinentry: `pinentry-mac` (recommended), `pinentry-curses`, or `pinentry-tty`
- Swift 5.10 or newer for source builds

Building the release binary works with the Swift toolchain and macOS Command Line Tools; full Xcode is not a product dependency. The XCTest suite requires Xcode, or another developer toolchain that actually bundles the XCTest module.

Starting with 0.2.0, release binaries are ad hoc signed with the hardened runtime and are not Apple-notarized because the project does not currently have an Apple Developer Program membership. Homebrew verifies the archive's pinned SHA-256 digest, and GitHub releases include checksums and build-provenance attestations, but macOS cannot present these builds as originating from an Apple-verified developer.

## Install With Homebrew

```sh
brew tap CasualDeveloper/tap
brew install pinentry-companion
pinentry-companion setup
pinentry-companion doctor
```

## Build From Source

Install runtime dependencies:

```sh
brew install gnupg pinentry pinentry-mac
```

Build:

```sh
swift build -c release --product pinentry-companion
```

The binary is written to:

```text
.build/release/pinentry-companion
```

## Install Manually

```sh
install -m 755 .build/release/pinentry-companion "$(brew --prefix)/bin/pinentry-companion"
```

If you are not using Homebrew, install the binary anywhere on your `PATH`.

Configure GPG:

```sh
pinentry-companion setup
```

Check the installation:

```sh
pinentry-companion doctor
```

Run an explicit interactive authentication check:

```sh
pinentry-companion doctor auth
```

For unattended setup, for example in a bootstrap script:

```sh
pinentry-companion setup --yes
```

Replacing an existing foreign `pinentry-program` is intentionally separate:

```sh
pinentry-companion setup --dry-run --take-over
pinentry-companion setup --take-over
```

`--take-over` preserves the previous configuration as the restore point; it does not discard it.

## Restore and Uninstall

Preview and restore the exact state recorded before setup:

```sh
pinentry-companion restore --dry-run
pinentry-companion restore
```

Before removing the installed binary, the explicit uninstall-preparation alias performs the same restoration:

```sh
pinentry-companion uninstall --prepare
brew uninstall pinentry-companion
```

Uninstall preparation verifies that the restored configuration will not still invoke the binary being removed. If pinentry-companion was already configured before lifecycle ownership was first recorded, the recorded baseline still invokes that binary. Version 0.2.0 therefore refuses automatic uninstall preparation for the adopted installation. Retrying after editing only the current configuration cannot change the recorded baseline; keep the formula installed until a supported release workflow is available.

This includes upgrades from releases before 0.2.0: those releases did not create a lifecycle record covering both the prior GPG configuration and `DisableKeychain` preference, so 0.2.0 cannot invent an exact pre-install restore point. The upgrade remains functional and future managed changes are transactional, but 0.2.0 cannot automatically prepare that adopted installation for removal.

Cached passphrases deliberately survive configuration restore and package removal. If the user also wants those secrets deleted, purge them explicitly before uninstalling the binary:

```sh
pinentry-companion cache purge --dry-run
pinentry-companion cache purge
```

The purge targets generic-password items in the `pinentry-companion` and `pinentry-companion.acl` Keychain services only. It does not target GPG keys or unrelated Keychain items.

## How It Works

On `GETPIN`, GnuPG sends prompt metadata including a stable cache identity via `SETKEYINFO`. `pinentry-companion` uses that cache identity as the Keychain account.

- If GnuPG explicitly sends `OPTION allow-external-password-cache`, supplies `SETKEYINFO`, and does not request repeat-entry mode, a missing cache entry is collected through the first available supported fallback pinentry and stored in the login Keychain.
- Without that complete opt-in, `GETPIN` performs no component Keychain read, retry deletion, or store; the request stays on the fallback pinentry path. The protocol's explicit `CLEARPASSPHRASE` command remains an independent cache-deletion request.
- If an entitled build can create Keychain ACL items, cached reads are authenticated by the Keychain ACL itself.
- If ACL storage is unavailable, cached reads are gated by `LocalAuthentication` before reading the stored `ThisDeviceOnly` item.
- If authorization succeeds, the stored passphrase is returned to `gpg-agent` over the pinentry protocol.
- If GPG retries with a bad-passphrase error, the stale Keychain entry is deleted and the user is prompted again through the selected fallback pinentry.

In protocol mode, stdout is reserved for Assuan protocol output. Diagnostics are written to stderr or logs so the Assuan stream is not contaminated.

Quality-bar and generated-passphrase labels are accepted for compatibility but are not forwarded to the nested fallback pinentry. Those controls require relaying Assuan inquiries back to `gpg-agent`, which this release does not implement; ordinary passphrase entry, repeat confirmation, and confirmation/message flows remain supported.

## Commands

```sh
pinentry-companion               # run pinentry protocol server on stdin/stdout
pinentry-companion doctor        # check the local GPG/pinentry setup
pinentry-companion doctor auth   # run an interactive local-authentication check
pinentry-companion doctor report # print safe Markdown diagnostics for bug reports
pinentry-companion setup         # configure GPG to use pinentry-companion
pinentry-companion restore       # restore exact state recorded by setup
pinentry-companion uninstall --prepare # restore before removing the binary
pinentry-companion cache purge   # explicitly delete component-owned cached passphrases
pinentry-companion status --format json # passive versioned machine status
pinentry-companion plan --format json   # passive versioned change preview
pinentry-companion setup --yes --format json
pinentry-companion setup --take-over --yes --format json
pinentry-companion restore --yes --format json
pinentry-companion uninstall --prepare --yes --format json
pinentry-companion --version     # print the intrinsic component version
pinentry-companion help          # show top-level help
```

`status` and `plan` emit one JSON document and never write configuration, preferences, lifecycle state, or Keychain data; prompt for authentication; launch a fallback pinentry; or reload `gpg-agent`. They report lifecycle ownership, drift, recovery availability, dependency blockers, and whether a proposed change has or will create an exact restore record. Their Draft 2020-12 schemas and golden fixtures are checked in under `Contracts/`.

The four lifecycle invocations shown above are the complete machine mutation surface. Their argument order is part of the contract: machine mode requires the literal `--yes`, never prompts, writes exactly one JSON document to stdout, and reports invocation errors without calling lifecycle adapters. Exit status `0` means the requested lifecycle operation completed, `1` means an operational error or state conflict, and `2` means invalid invocation. `setup` uses the same ownership-recorded transaction and rollback engine as the interactive command. `restore` and `uninstall --prepare` use the same compare-and-swap restoration engine; uninstall preparation does not remove the binary or delete cached passphrases. Review `plan` before requesting a mutation, and use `--take-over` only after explicitly accepting replacement of a foreign `pinentry-program` directive.

## Agent integration and design

The versioned commands above are the current automation interface. Inspect
configuration alignment, lifecycle ownership, drift, and recovery together;
`notProbed` authentication/cache fields are intentional. A successful signing
operation alone does not prove fresh authentication because a key or agent
cache may require no prompt.

[Component design](docs/design.md) explains the proposed next contract and links
to the shared system design and sequential implementation plan. Those extensions
are not available in 0.2.0. AuthCompanion is an optional coordinator, not a
dependency of this tool.

## Protocol Smoke Tests

These checks validate the binary and pinentry protocol loop without requiring a GPG key:

```sh
swift build -c release --product pinentry-companion
swift test
python3 Scripts/validate-contracts.py
.build/release/pinentry-companion setup --dry-run
printf 'NOP\nHELP\nBYE\n' | .build/release/pinentry-companion
```

After installing the binary you plan to use, run:

```sh
pinentry-companion doctor
```

For an explicit local-authentication check without a GPG key, run:

```sh
pinentry-companion doctor auth
```

End-to-end GPG signing or decryption tests are still manual because they require choosing a specific local key.

## Acknowledgements

This project builds on the documented GnuPG pinentry/Assuan protocol and Apple's LocalAuthentication and Security frameworks.

## License

Apache License 2.0. See [LICENSE](LICENSE).
