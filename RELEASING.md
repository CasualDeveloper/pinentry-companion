# Releasing pinentry-companion

## Release policy

GitHub release archives contain architecture-specific macOS command-line binaries, documentation, versioned machine-contract schemas and fixtures, per-binary SHA-256 digests, an aggregate `SHA256SUMS` file, and GitHub build-provenance attestations. The release workflow refuses a tag that does not exactly match `ComponentVersion.current`.

The project does not currently have an Apple Developer Program membership. Release binaries therefore use an ad hoc code signature with the hardened runtime and are not Apple-notarized. An ad hoc signature lets the workflow detect post-signing changes and verify the hardened-runtime flag, but it does not establish the developer's identity or satisfy Gatekeeper as a Developer ID signature would. Release integrity instead depends on the Homebrew formula's pinned SHA-256 digest, the checked-in and release-level digests, GitHub's artifact attestation, and testing the exact archives before publication.

The release binary intentionally has no restricted Keychain entitlement and uses the app-level LocalAuthentication gate. Full Xcode and signing secrets are not required: the Swift toolchain and macOS Command Line Tools provide the compiler and `codesign` used by the release workflow.

## Prepare

1. Update `ComponentVersion.current` and add the matching changelog entry.
2. Run the full SwiftPM tests, contract validation, native release build, both architecture builds, and protocol smoke test.
3. Confirm `git diff --check` is clean and review the complete release diff.
4. Merge the reviewed release commit to `main`.
5. Run the Release workflow manually for `main`. Download the seven-day, non-publishing release-candidate artifact and complete the archive verification below. A Homebrew preflight is useful here, but the final gate must use the later draft-release assets.

## Draft and publish

After the preflight candidate passes, create and push the matching annotated tag, for example `v0.2.0`. The tag-triggered workflow tests the tagged source, verifies intrinsic version equality, packages arm64 and x86_64 archives, generates checksums and provenance attestations, and creates a **draft** GitHub release. It does not make the release public.

Download the draft-release assets and run the verification and both disposable-machine Homebrew passes below against those exact archives. Once they pass and publication is explicitly approved, publish the existing draft without rebuilding it:

```sh
gh release edit v0.2.0 --draft=false --repo CasualDeveloper/pinentry-companion
```

Manual workflow runs accept a branch, commit, or tag but only upload an expiring candidate artifact. They never create a tag or release. The tag workflow creates a draft release only; publication is always a separate approval-controlled action.

## Verify

Download both archives and `SHA256SUMS`, then verify:

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify pinentry-companion-v0.2.0-arm64.tar.gz --repo CasualDeveloper/pinentry-companion
gh attestation verify pinentry-companion-v0.2.0-x86_64.tar.gz --repo CasualDeveloper/pinentry-companion
```

Extract each archive, verify the inner binary digest, ad hoc signature, hardened-runtime flag, intrinsic version, and non-interactive protocol before updating downstream package metadata. Do not use `spctl` as a success gate: these binaries do not have a Developer ID signature or notarization ticket.

```sh
tar -xzf pinentry-companion-v0.2.0-arm64.tar.gz
cd pinentry-companion-v0.2.0-arm64
shasum -a 256 -c pinentry-companion.sha256
codesign --verify --strict ./pinentry-companion
codesign --display --verbose=4 ./pinentry-companion
./pinentry-companion --version
printf 'GETINFO flavor\nGETINFO version\nBYE\n' | ./pinentry-companion
```

## Disposable-machine Homebrew gate

Use a disposable macOS account or VM with a passphrase-protected test GPG key. For the final gate, download the draft-release assets and verify `SHA256SUMS` and both attestations. Copy the published tap formula somewhere outside the tap. In the tap's working copy, change `version`, the two architecture URLs and SHA-256 digests, and replace the unversioned macOS requirement with `depends_on macos: :sonoma`. Candidate URLs may be absolute `file://` URLs to the downloaded archives. Keep Homebrew on that local formula while testing:

Do not substitute a changed `HOME`, `CFFIXED_USER_HOME`, `GNUPGHOME`, or an isolated Homebrew prefix for the separate account or VM. `CFPreferences` can still communicate with the logged-in user's `cfprefsd`, and the Keychain and LocalAuthentication checks remain account-scoped. Those environment changes are useful for non-mutating package checks only, not for lifecycle or authentication tests.

```sh
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 \
  brew install CasualDeveloper/tap/pinentry-companion
brew test CasualDeveloper/tap/pinentry-companion
```

Run two separate passes from clean snapshots:

1. **Fresh install:** capture whether `gpg-agent.conf` exists, its exact bytes and mode when present, and the presence/value of `org.gpgtools.common DisableKeychain`. Install the candidate formula, run `setup`, passive `doctor`, explicit `doctor auth`, and `setup` again to prove idempotence. Sign once through the fallback pinentry, kill `gpg-agent`, then sign again and authenticate with Touch ID or Apple Watch. Run `restore` and compare the captured file and preference state exactly. Run `setup` once more, then `uninstall --prepare`, compare the baseline again, and remove the formula.
2. **Published upgrade:** restore the unmodified published formula, install the current release, run its `setup`, replace the formula with the candidate copy, and run `brew upgrade CasualDeveloper/tap/pinentry-companion`. Confirm the candidate version, passive `doctor`, explicit `doctor auth`, idempotent `setup`, and both signing paths still work.

Releases before 0.2.0 did not create a lifecycle record covering both `gpg-agent.conf` and `DisableKeychain`. They could leave a timestamped configuration backup, but did not retain the prior preference state. The upgrade pass therefore verifies a safe functional migration, not reconstruction of state that the old release never saved. If a pre-0.2.0 configuration already points at `pinentry-companion`, the new lifecycle record adopts that configuration as its baseline; `uninstall --prepare` will correctly refuse to remove the binary until the user configures a retained fallback pinentry. Exact restore and one-command uninstall preparation are required in the fresh-install pass, where 0.2.0 owns the complete lifecycle.

Do not publish the draft release or update the public tap formula until both passes succeed using those exact ad hoc-signed draft assets. After publication, replace the candidate `file://` URLs with the matching GitHub release URLs, retain `depends_on macos: :sonoma`, and update the formula test to assert both `pinentry-companion --version` and the `GETINFO version` response in addition to the flavor response. Rerun the strict formula audit and test before committing the tap update.
