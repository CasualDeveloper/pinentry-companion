<p align="center">
  <img src="assets/logo.svg" width="260" alt="pinentry-companion logo">
</p>

# pinentry-companion

Native macOS GPG pinentry with Apple Watch/companion unlock, Touch ID, macOS password fallback, and Keychain-backed passphrase storage.

`pinentry-companion` is a Swift command-line pinentry program. It speaks the GnuPG pinentry/Assuan protocol over stdin/stdout, stores GPG passphrases in the macOS Keychain, and uses LocalAuthentication to require local device-owner authentication before reading them.

## Features

- Native Swift implementation
- Keychain unlock with Apple Watch/companion support on macOS 15+, plus Touch ID and the macOS account password on supported Macs
- `pinentry-mac` fallback for first-time passphrase entry and unsupported flows, with `pinentry-curses`/`pinentry-tty` fallback if needed
- Stale Keychain entry repair when GPG reports a bad passphrase retry
- Interactive `doctor auth` check for Touch ID/Apple Watch/account-password verification
- No background daemon, telemetry, network calls, or automatic signing tests

## Security Model

This tool optimizes local convenience for macOS GPG users. It stores the GPG key passphrase in the macOS login Keychain as a `ThisDeviceOnly` item and requires macOS local authentication before reading it.

On macOS 15 and later, unlock attempts use LocalAuthentication companion/biometry policy where available, allowing supported companion devices such as Apple Watch or Touch ID, with device-owner authentication fallback for the macOS account password. Older macOS versions use device-owner authentication.

Keychain-enforced companion ACL storage requires a signed build with the required Keychain entitlement. `pinentry-companion doctor` reports this as informational when ACL storage is unavailable for unsigned/Homebrew builds. When ACL storage is available, new cached entries are stored under an ACL-protected Keychain service and macOS enforces authentication on read. Source/Homebrew builds fall back to the app-level LocalAuthentication gate described above.

That means your GPG passphrase becomes unlockable by macOS local authentication rather than a separately typed GPG passphrase. If you require your GPG passphrase to remain independent from your macOS account credentials, do not use this tool.

`pinentry-companion` never runs a real signing/decryption test by itself. Any live GPG operation must be initiated explicitly by the user.

## Requirements

- macOS 10.13 or newer
- GnuPG
- `pinentry-mac`
- Swift 5.10 or newer for source builds

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

## How It Works

On `GETPIN`, GnuPG sends prompt metadata including a stable cache identity via `SETKEYINFO`. `pinentry-companion` uses that cache identity as the Keychain account.

- If no Keychain entry exists, `pinentry-companion` delegates to `pinentry-mac` so the user can enter the passphrase in a native macOS dialog. It then stores the passphrase in the login Keychain.
- If a signed build can create Keychain ACL items, cached reads are authenticated by the Keychain ACL itself.
- If ACL storage is unavailable, cached reads are gated by `LocalAuthentication` before reading the stored `ThisDeviceOnly` item.
- If authorization succeeds, the stored passphrase is returned to `gpg-agent` over the pinentry protocol.
- If GPG retries with a bad-passphrase error, the stale Keychain entry is deleted and the user is prompted again through `pinentry-mac`.

In protocol mode, stdout is reserved for Assuan protocol output. Diagnostics are written to stderr or logs so the Assuan stream is not contaminated.

## Commands

```sh
pinentry-companion               # run pinentry protocol server on stdin/stdout
pinentry-companion doctor        # check the local GPG/pinentry setup
pinentry-companion doctor auth   # run an interactive local-authentication check
pinentry-companion doctor report # print safe Markdown diagnostics for bug reports
pinentry-companion setup         # configure GPG to use pinentry-companion
pinentry-companion help          # show top-level help
```

## Protocol Smoke Tests

These checks validate the binary and pinentry protocol loop without requiring a GPG key:

```sh
swift build -c release --product pinentry-companion
swift run PinentryCompanionUnitTests
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
