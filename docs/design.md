# pinentry-companion design for agent operation

Status: implementation in progress. Commits `0f14db7`, `cda1662`, and `6ba75f2`
now protect setup from intervening edits, preserve equivalent configured paths,
and distinguish ownership/recovery writes from true no-ops. The remaining
machine-contract extensions below are proposed. The
[system design](https://github.com/CasualDeveloper/AuthCompanion/blob/main/docs/design.md)
and [machine contract](https://github.com/CasualDeveloper/AuthCompanion/blob/main/docs/agent-contract.md)
define shared semantics. Delivery is stage 1 of the
[sequential plan](https://github.com/CasualDeveloper/AuthCompanion/blob/main/docs/plans/2026-09-16-agent-operability.md).
This component must remain useful when AuthCompanion is absent.

## Existing foundation

The no-argument executable is an Assuan server. Management commands are a
separate surface. Do not inject agent metadata into protocol stdout.

`CommandLineEntry` routes passive status/plan and `LifecycleMachineCommand`
routes the four strict mutation forms. `PassiveSnapshot`,
`PassiveManagement`, and `PassivePlan` inspect and describe the current
configuration. `LifecycleManager`, `LifecycleRecord`, `LifecycleStateStore`,
and `LifecycleLockProvider` own durable changes and recovery.
[Contracts](../Contracts/Schemas/) contain the existing strict v1 schemas.

The selected GPG home is user configuration. DisableKeychain is shared across
that login account's managed GPG homes. Keychain and LocalAuthentication also
belong to the account, not GNUPGHOME. Existing global lifecycle serialization
and final-home preference restoration must survive the proposed changes.

## Proposed component boundary

Add a static `describe --format json` and explicitly selected next-major
machine schemas while preserving current v1 output. Description works offline
with missing dependencies and does not construct secret/authentication adapters.

Status preserves configuration alignment, ownership, drift, recovery evidence,
and not-probed authentication/cache facts separately. A missing recovery record
does not mean configuration is absent. A readable record alone does not prove
an arbitrary reverse transition is safe.

Plans for setup, restore, and uninstall preparation name the selected home and
any account-shared preference effects. Their summaries never include GPG config
contents, key identities, passphrases, or Keychain inventory. Derive preview and
apply from the same transition logic.

New machine mutations bind their intention/options, binary/contract identity,
target, current state, lifecycle generation, and effects through the shared
expected-state design. Recheck at each write while preserving current lock,
safe-path, metadata, and compare-and-swap checks. Report none, committed,
reverted, partial, or unknown effects accurately.

A result supplies its verified postcondition and next action. Pinentry owns
the explanation of its failure; the coordinator must not infer it from stderr
or run a signing test merely to understand lifecycle completion.

## Restore is not undo-last

`LifecycleRecord.originalConfig` and related original state describe the
enrollment baseline. Transaction-base fields describe the state before a
particular operation. Keep that distinction visible in recovery results.

A conditional compensation must prove attempt identity, generation, current
state, and the correct immediate before-state. Initially support only new
enrollments where ordinary restoration demonstrably returns to that before-state.
An upgrade, adoption, or pre-existing managed home must not be removed because
PAM failed later. Missing output means attribution is unknown unless the
existing durable record can resolve it.

Do not introduce a second journal or an arbitrary snapshot history.
`uninstall --prepare` continues to reject a baseline that invokes the binary
being removed. Restoration and package removal preserve cached passphrases;
purge remains an explicit separate secret-deletion operation.

## Authentication boundaries remain unchanged

The complete external-cache gate remains mandatory: explicit opt-in, stable
SETKEYINFO identity, and no repeat-entry request. Unsupported flows use the
fallback pinentry without component cache reads, stores, or retry deletion.
The protocol's explicit CLEARPASSPHRASE remains an independent deletion request.

Management observation never touches Keychain or triggers authentication.
Interactive doctor auth remains explicitly requested and distinct from passive
doctor/report. GPG signing or decryption uses a deliberately selected key and
requires separate task authority. A successful operation without a prompt
cannot prove fresh device-owner authentication.

Preserve the unentitled release's documented app-level LocalAuthentication
boundary. Agent ergonomics does not justify claiming Keychain-enforced ACLs,
notarization, or a signing entitlement that the shipped build lacks.

## Local implementation and acceptance

Work in this order: interface description and fixtures; next-major state/effect
models; shared preview/apply preconditions; bounded durable attempt evidence;
release packaging and consumer fixtures. Full path and test ownership is in
stage 1 of the shared plan.

Extend existing passive, lifecycle-machine, lifecycle-manager/state/lock, and
PinentryServer tests with recording fakes and temporary filesystem targets.
The required cases are stale target/options/binary/preference, managed-state
drift, interrupted writes, lost receipts, existing enrollment preservation,
multiple GPG homes, and strict no-side-effect observation. Existing v1 fixtures
and protocol behavior must continue to pass.

Each newly understood failure becomes a synthetic fixture plus the smallest
owner-level regression and diagnostic entry. The versioned fixture is the
reusable lesson; a private user transcript or copied personal configuration
is not a test asset.

Run the current tests and `python3 Scripts/validate-contracts.py` before
candidate packaging. Follow [RELEASING.md](../RELEASING.md) for actual artifact
and live gates. Keep new releases as drafts until the tap/coordinator
compatibility gate in the shared plan is ready; the current coordinator
accepts only pinentry 0.2.0.
