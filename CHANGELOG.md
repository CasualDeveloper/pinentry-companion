# Changelog

## 0.2.1 - Unreleased

### Fixed

- Reject configuration or preference changes detected after setup preparation,
  preserving the external edit and restoring the previous lifecycle record.
- Preserve an equivalent configured path when the plan reports no change.
- Distinguish ownership-recording and interrupted-restore recovery from a true
  no-op in lifecycle results.
- Stop suggesting an uninstall retry that cannot alter an adopted baseline.

The JSON schema remains v1. Keep this candidate unpublished until the compatible
AuthCompanion bridge and tap guard are promoted.

## 0.2.0 - 2026-07-19

### Added

- Transactional setup with private ownership records, globally serialized locking, postcondition verification, rollback, and interrupted-operation recovery.
- Preserve existing `GNUPGHOME` directory permissions; newly created homes use mode `0700`.
- Exact `restore` and `uninstall --prepare` operations with compare-and-swap drift protection.
- Shared-preference ownership across multiple `GNUPGHOME` values, with globally serialized lifecycle operations and last-owner restoration.
- Explicit `cache purge` scoped to pinentry-companion's two Keychain services.
- Versioned `status`, `plan`, `setup`, `restore`, and `uninstall` JSON contracts with checked-in schemas and fixtures.
- Strict non-interactive lifecycle mutation commands for automation, requiring canonical argument order and explicit `--yes` confirmation.
- Uninstall preparation blocks package removal when the exact restored configuration would still invoke the binary being removed.
- Lifecycle ownership, drift, recovery, and reversibility reporting for installers and other automation.
- Standard SwiftPM XCTest coverage and arm64/x86_64 release validation.
- Ad hoc signatures with the hardened runtime, SHA-256 manifests, build-provenance attestations, and strict integrity verification for both release architectures.

### Security

- Require the complete Assuan external-cache opt-in before any `GETPIN`-driven Keychain read, write, or retry deletion, report cache hits to `gpg-agent`, and try the external cache only once per prompt session.
- Reject symlinked, special, out-of-scope, root-owned, or other-user lifecycle targets.
- Use descriptor-relative atomic configuration writes and private, digest-checked lifecycle records.
- Enforce byte-bounded Assuan data lines, return upstream-compatible `GETINFO ttyinfo` metadata, and forward timeout, prompt-control, display, grab, default-label, Emacs-prompt, and terminal context to fallback pinentries.
- Accept the current pinentry metadata command surface, including explicit cache clearing and repeat-prompt controls, while suppressing quality/generator controls that require unsupported inquiry relay.
- Preserve agent-level options and timeout across protocol `RESET` while clearing per-prompt metadata and cache-attempt state.
- Verify that setup records the binary actually running before changing GPG configuration.

### Changed

- The production deployment floor is macOS 14, matching the tested CI matrix.
- Apple Watch/companion and Touch ID authentication use the same stable policy values across every supported macOS SDK and runtime.
- Release tags must exactly match the component's intrinsic version.
