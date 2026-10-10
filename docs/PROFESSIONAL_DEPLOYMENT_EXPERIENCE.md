# Professional Deployment and Maintenance Experience

**Status:** Initial CLI implementation complete; advanced discovery, safe
restore/rollback, release manifests, full profile-based service pruning, and a
local web interface remain planned.
**Purpose:** Implementation specification for a guided, adaptive, and maintainable media-stack experience  
**Primary audience:** Maintainers implementing the feature and operators reviewing its behavior

## Implementation status

| Capability | Status | Current behavior |
|---|---|---|
| Cross-platform CLI foundation | Implemented | `cmd/media-stack` builds for Windows and Linux and delegates mutations to the existing wrappers. |
| Strict desired state and profiles | Implemented | Versioned YAML, unknown-field rejection, validation, examples, and five guided profiles. |
| Discovery and deterministic planning | Initial implementation | Detects platform, Docker/Compose, target, state directories, and occupied service ports; GPU, filesystem, hardlink, and service API inspection remain deferred. |
| Plan-before-apply safety | Implemented | Versioned plans, desired/actual hashes, blockers, explicit approval, and stale-plan rejection. |
| Resumable workflows | Implemented | Redacted mode-`600` journals, dependency ordering, postcondition verification, and resume. |
| Existing deployment adoption | Implemented | Read-only `.env` inference, secret references, backup helper, reviewable plan, and migration guide. |
| Status, doctor, logs, and repair | Initial implementation | Bounded Compose status probes, operation status, guarded component restart, and wrapper logs; the full integration/version/backup health model remains deferred. |
| Backup and update | Implemented with wrapper semantics | Explicit approval is required; update runs backup before image pull/reconcile/prune. |
| Restore and rollback | Safety-blocked | Commands fail explicitly until archive validation and application downgrade compatibility are implemented. |
| Profile-driven service pruning | Deferred | Profiles record desired intent but do not yet remove services from the Compose topology. |
| TUI/local web interface | Deferred | The initial release is a command-line interface. |

## 1. Summary

The repository currently exposes capable but separate Compose, environment,
secret, bootstrap, diagnostic, verification, and backup workflows. A new
operator must understand how those pieces relate before they can safely deploy
the stack. This feature will add one cross-platform command that discovers the
host, asks only relevant questions, records desired state, previews changes,
executes the existing automation as a resumable workflow, and verifies the
result.

The intended experience is:

```text
media-stack install
media-stack status
media-stack configure
media-stack doctor
media-stack update
media-stack backup
media-stack restore
media-stack resume
```

The first implementation should be a CLI with an interactive terminal user
interface (TUI). A future local web interface may call the same application
engine, but it must not contain separate deployment logic.

## 2. Problem statement

The current deployment process requires operators to coordinate several
concepts:

- selecting Linux or Windows and generating `.env`;
- understanding Compose overlays and profiles;
- preserving the single-filesystem `/data` hardlink contract;
- sourcing session secrets through
  [`scripts/set-env.sh`](../scripts/set-env.sh) or running the PowerShell
  equivalent;
- creating file-based VPN credentials separately;
- starting containers before running API bootstrap;
- distinguishing configuration, health, and integration failures;
- knowing which steps are safe to rerun after partial failure; and
- maintaining images, application state, integrations, and backups afterward.

The shell and PowerShell entry points already provide commands such as `use`,
`init-vpn`, `up`, `bootstrap`, `doctor`, `verify`, and `backup`
([`stack.sh`](../stack.sh), [`stack.ps1`](../stack.ps1)). The issue is not an
absence of automation. It is the absence of a single desired-state model and a
workflow coordinator that translates user intent into those operations.

## 3. Goals

1. Provide one discoverable cross-platform entry point.
2. Reduce initial setup to a short series of high-level, conditional decisions.
3. Detect host capabilities and deployment hazards automatically.
4. Generate a durable, reviewable desired-state document.
5. Show a complete plan before changing the machine.
6. Make installation and maintenance operations idempotent and resumable.
7. Explain failures in operator language and provide exact remediation.
8. Support both new installations and adoption of existing deployments.
9. Preserve advanced access to Compose and the existing scripts.
10. Keep secrets out of desired state, logs, plans, and workflow journals.
11. Create a safe foundation for updates, backup, restore, repair, and rollback.

## 4. Non-goals

The initial feature will not:

- replace Docker Compose as the runtime orchestrator;
- rewrite every existing Bash and PowerShell bootstrap operation;
- expose a remotely accessible management service;
- automatically open router ports or make services public;
- silently modify an existing deployment without a reviewed plan;
- guarantee compatibility with every NAS distribution;
- store plaintext credentials in the desired-state file; or
- make irreversible data migrations without a separate confirmation and
  rollback plan.

## 5. Users and primary journeys

### 5.1 First-time home operator

The operator wants a recommended deployment without understanding every
application. The installer detects the host, proposes a profile, validates
storage and networking, gathers the minimum required secrets, previews the
deployment, executes it, and proves the core pipeline is healthy.

### 5.2 Advanced operator

The operator wants explicit control over enabled services, networking, hardware
acceleration, versions, paths, and secret providers. The same desired-state
model supports non-interactive planning and application.

### 5.3 Existing-deployment operator

The tool detects `.env`, Compose state, configuration directories, and running
containers. It offers:

- **Adopt:** infer desired state without changing services;
- **Repair:** reconcile failed or missing resources;
- **Reconfigure:** preview intentional changes; or
- **Inspect only:** run status and diagnostics without adoption.

Adoption must never overwrite `.env`, application configuration, or secrets
until the operator approves a plan.

### 5.4 Maintenance operator

The operator uses status, doctor, update, backup, restore, and repair commands.
The tool explains drift and health in terms of the desired deployment rather
than exposing raw container output as the primary interface.

## 6. Product principles

### 6.1 Ask for intent, detect implementation details

Ask whether the user wants remote access, torrents, Usenet, subtitles, live TV,
and hardware transcoding. Detect operating system, paths, GPUs, Docker state,
ports, and existing services.

### 6.2 Progressive disclosure

Recommended profiles should require few decisions. Advanced settings remain
available but should not appear unless selected or required by a prior answer.

### 6.3 Plan before apply

Every mutating command must produce an inspectable plan. The plan identifies
resources created, changed, restarted, retained, or removed. Destructive or
security-sensitive changes require separate confirmation.

### 6.4 Verify outcomes, not command completion

A successful command exit is not enough. Each workflow step defines a
postcondition, such as:

- hardlinks work across download and media paths;
- Gluetun is healthy before qBittorrent is considered ready;
- service APIs authenticate;
- Moonbase responds to `/Moonfin/Ping`;
- Seerr references the expected Sonarr and Radarr servers; and
- expected containers match the desired profile.

### 6.5 Safe reruns

Operations must query actual state and reconcile it to desired state. A failed
deployment should resume from verified state rather than replaying every action
blindly.

### 6.6 Escape hatches remain available

The generated Compose model, environment file, and commands must stay
inspectable. Expert users may continue using the current wrappers directly.

## 7. Proposed command surface

| Command | Purpose | Mutating |
|---|---|---:|
| `media-stack install` | Discover, design, plan, deploy, and verify a new stack | Yes |
| `media-stack adopt` | Import an existing deployment into desired state | No by default |
| `media-stack plan` | Compare desired and actual state | No |
| `media-stack apply` | Apply an already reviewed plan | Yes |
| `media-stack resume` | Continue an interrupted operation from verified state | Yes |
| `media-stack configure` | Edit desired state and preview the resulting changes | Yes |
| `media-stack status` | Summarize health, drift, versions, disk, and integrations | No |
| `media-stack doctor` | Run diagnostics and recommend or perform scoped repairs | Repair is opt-in |
| `media-stack repair [component]` | Reconcile one failed component or integration | Yes |
| `media-stack update` | Plan, back up, apply, verify, and possibly roll back updates | Yes |
| `media-stack backup` | Create and verify a state backup | Yes |
| `media-stack restore` | Preview and restore a selected backup | Yes |
| `media-stack rollback` | Return to the previous deployment manifest and compatible state | Yes |
| `media-stack logs [component]` | Show redacted, scoped diagnostics | No |

All mutating commands require a non-interactive equivalent suitable for
automation:

```bash
media-stack plan --state media-stack.yaml --output json
media-stack apply --state media-stack.yaml --plan plan.json --non-interactive
```

The apply command must reject a stale plan if host facts, actual state, or the
desired-state file changed after the plan was generated.

## 8. Desired-state model

Store non-secret intent in a versioned file named `media-stack.yaml`. Keep `.env`
as a generated compatibility artifact while existing Compose and scripts depend
on it.

Example:

```yaml
apiVersion: media-stack.dev/v1alpha1
kind: MediaStack

metadata:
  name: home-media

spec:
  platform: linux
  releaseChannel: stable

  storage:
    root: /data
    requireHardlinks: true

  features:
    movies: true
    television: true
    subtitles: true
    liveTv: true
    torrents: true
    usenet: true

  networking:
    bindMode: lan
    remoteAccess: tailscale
    lanSubnet: 192.168.1.0/24

  acceleration:
    mode: intel-quick-sync

  jellyfin:
    serverName: Media Stack
    moonbase:
      enabled: true
      version: 2.4.0.0
      settingsSync: true
      seerrIntegration: true

  secrets:
    provider: interactive-session
    references:
      jellyfinAdminPassword: jellyfin-admin-password
      vpnUsername: nordvpn-service-username
      vpnPassword: nordvpn-service-password
```

### 8.1 Schema requirements

- Include `apiVersion` and `kind` for future migrations.
- Reject unknown fields by default to catch misspellings.
- Supply documented defaults through the planner, not implicit behavior spread
  across UI code.
- Validate conditional requirements. For example, VPN credentials are required
  only when torrents through Gluetun are enabled.
- Distinguish user intent from detected facts. GPU model, free space, and
  running container IDs do not belong in desired state.
- Store secret references only. Never serialize secret values.
- Preserve comments and stable field ordering when the interactive configurator
  updates the file.

### 8.2 Generated artifacts

The initial implementation may generate:

- `.env` from the target template;
- Compose overlay selection and profiles;
- file-based VPN secrets;
- runtime secret injection instructions;
- an immutable deployment manifest containing resolved versions; and
- an operation plan.

The desired-state file is authoritative for intent. The deployment manifest is
authoritative for what was last successfully applied.

## 9. Adaptive discovery and questioning

### 9.1 Automatically detected facts

The discovery engine should report:

- operating system, architecture, and WSL status;
- Docker Engine and Compose availability and versions;
- current repository and tool version;
- CPU and supported Intel, NVIDIA, or AMD acceleration;
- candidate data roots, filesystem type, writability, ownership, and capacity;
- whether download and media directories can hardlink;
- active ports used by the stack;
- existing `.env`, configuration, secrets, backups, containers, and project
  names;
- LAN subnet candidates and bind-address safety;
- whether Jellyfin is initialized;
- service API and container health; and
- current image and plugin versions where available.

Discovery must be read-only. A check requiring a temporary file must create it
inside the selected data root and remove it immediately.

### 9.2 Deployment profiles

Initial profiles:

1. **Recommended home server:** movies, television, subtitles, Usenet,
   torrent fallback through VPN, Jellyfin, Moonbase, Seerr, and Tailscale.
2. **Usenet only:** no torrent client or VPN requirement.
3. **Torrent only:** no Usenet provider prompts.
4. **Local network only:** no Tailscale.
5. **Advanced/custom:** expose the complete feature selection.

Profiles are defaults, not separate code paths. Each resolves into the same
desired-state schema.

### 9.3 Conditional questions

- Ask for VPN setup only if torrents are enabled.
- Ask for Usenet providers only if Usenet is enabled.
- Offer only acceleration modes supported by detected hardware.
- Ask for Tailscale only if remote access is requested.
- Ask for Moonbase TMDB or MDBList keys only if the corresponding optional
  integration is selected.
- Do not request first-run Jellyfin credentials if adopting an initialized
  server until authentication is needed.
- Ask whether existing resources should be adopted before proposing changes.

Every question must explain why the information is needed and where it will be
stored.

## 10. Plan format and review experience

A plan must be available as both human-readable text and versioned JSON. The
human view should include:

```text
Deployment plan: home-media

Host
  Linux x86_64
  Docker and Compose supported
  Intel Quick Sync detected

Storage
  /data is writable
  Hardlinks verified
  1.8 TB available

Services
  11 enabled
  2 disabled by profile

Security
  qBittorrent isolated behind Gluetun
  Management interfaces bound to LAN
  Remote access through Tailscale
  3 secrets required; no values will be written to media-stack.yaml

Changes
  CREATE  14 directories
  CREATE  .env
  RETAIN  existing VPN secret files
  START   11 containers
  UPDATE  Jellyfin Moonbase configuration
  VERIFY  8 service integrations
```

Every planned operation needs:

- stable operation ID;
- component and action;
- current and desired summaries;
- mutability and restart impact;
- destructive/security-sensitive flags;
- prerequisites;
- verification method; and
- rollback behavior.

## 11. Workflow engine and journal

### 11.1 Step lifecycle

Each step implements:

```text
Inspect -> Plan -> Apply -> Verify -> Record
```

The workflow engine must not infer success from a previous journal entry alone.
On resume, it reinspects the postcondition. If actual state drifted, it replans
or marks the step blocked.

### 11.2 Journal requirements

Store journals under an ignored local state directory, for example:

```text
.media-stack/
  state.json
  manifests/
  operations/
    2026-10-09T141500Z-install.json
```

The journal may contain:

- operation and step IDs;
- timestamps and durations;
- desired-state and plan hashes;
- component versions;
- redacted request metadata;
- success, failure, skipped, blocked, and rollback states;
- verification evidence; and
- operator-approved decisions.

It must not contain passwords, API keys, cookies, access tokens, raw
authorization headers, or secret file contents.

### 11.3 Failure behavior

A failed step should produce:

```text
Jellyfin authentication is not ready after restart.

Expected:
  An authenticated API session within 90 seconds.

Observed:
  Public status responded, but authenticated requests were reset.

Automatic action:
  Retried authentication for 90 seconds.

Next actions:
  1. Show Jellyfin startup logs
  2. Retry this step
  3. Leave deployment paused
```

Broad error suppression and success-shaped fallbacks are prohibited. Retriable
transport failures must be distinguished from authentication rejection and
invalid configuration.

## 12. Secrets architecture

The initial release should support:

1. **Interactive session:** parity with the current
   [`scripts/set-env.sh`](../scripts/set-env.sh) and
   [`scripts/set-env.ps1`](../scripts/set-env.ps1) behavior.
2. **Docker secret files:** initially for the existing VPN credential flow
   described in [`VPN_CREDENTIALS_MIGRATION.md`](./VPN_CREDENTIALS_MIGRATION.md).
3. **Environment injection:** for CI and advanced operators.
4. **Local encrypted store:** optional after a threat model and key-management
   decision are approved.

Future providers may include systemd credentials, 1Password, or Bitwarden. A
provider interface should expose `Exists`, `Set`, `GetForExecution`, `Rotate`,
and `DeleteReference`, while preventing callers from logging returned values.

Security requirements:

- redact secrets structurally rather than by ad hoc string replacement;
- never place secret values in command arguments when a safer input channel is
  available;
- show which secret references are missing without showing values;
- support secret rotation as a planned maintenance operation;
- retain current restrictive permissions for VPN files; and
- treat backups containing application configuration as sensitive.

## 13. Component architecture

The recommended implementation is a small Go application distributed as one
binary for supported Windows and Linux targets.

```text
CLI / TUI / future local Web UI
                |
        Application services
                |
  Discovery | Planner | Workflow engine
                |
   Desired state | Journal | Secrets
                |
  Compose adapter | Script adapter | API adapters
                |
       Docker and media services
```

### 13.1 Packages

Suggested boundaries:

```text
cmd/media-stack/       command entry point
internal/config/       desired-state schema, defaults, migrations
internal/discovery/    read-only host and deployment facts
internal/planner/      desired/actual comparison and operation graph
internal/workflow/     apply, verify, resume, rollback, journal
internal/secrets/      provider interfaces and redaction
internal/compose/      Compose rendering and lifecycle adapter
internal/services/     typed Jellyfin, Seerr, arr, and downloader clients
internal/scripts/      transitional existing-script adapter
internal/status/       health and drift aggregation
internal/ui/           CLI output and TUI presentation
```

UI packages may depend on application services, but discovery, planner,
workflow, and service packages must not depend on UI code.

### 13.2 Transition strategy

Do not rewrite working automation at once.

1. The first CLI wraps existing target selection, setup, bootstrap, doctor,
   verify, and backup commands.
2. Add structured step boundaries and verification around those calls.
3. Move logic into typed modules only when a script boundary prevents accurate
   planning, retry, or diagnostics.
4. Keep script behavior available until the replacement has parity tests.
5. Remove a legacy path only after both Windows and Linux behavior are covered.

## 14. New deployment workflow

### Phase A: Discover

- Inspect the host and any existing deployment.
- Display blockers separately from recommendations.
- Make no persistent changes.

### Phase B: Design

- Select a profile.
- Ask conditional questions.
- Select a secret provider.
- Write or update `media-stack.yaml` only after confirmation.

### Phase C: Preview

- Resolve defaults and tested component versions.
- Render Compose in memory or a temporary location.
- Validate storage, network, secret references, and compatibility.
- Show the complete plan and restart/destructive impact.

### Phase D: Deploy

- Create directories and generated artifacts.
- Materialize required secrets.
- Start infrastructure in dependency order.
- Run idempotent application configuration.
- Persist step results without secret material.

### Phase E: Verify

- Check container and API health.
- Verify VPN isolation before accepting torrent readiness.
- Verify application authentication and integrations.
- Verify Moonbase and Seerr behavior when enabled.
- Present service URLs and next manual actions.
- Write the successful deployment manifest.

## 15. Maintenance behavior

### 15.1 Status

`media-stack status` should aggregate:

- desired versus actual services;
- container and service API health;
- image and plugin version drift;
- VPN egress status;
- disk capacity and hardlink health;
- integration health;
- pending or interrupted operations; and
- age and verification status of the latest backup.

### 15.2 Doctor and repair

Doctor is read-only by default. Repair actions require an explicit plan and
approval. Diagnostics should map technical evidence to likely causes without
hiding raw evidence from advanced users.

### 15.3 Configure

The configurator reloads existing desired state, reruns discovery, asks only
questions related to requested changes, and previews the delta. Unrelated
services must not restart.

### 15.4 Updates

The stable channel should use a tested release manifest rather than floating
image tags. An update operation:

1. checks compatibility and release notes;
2. creates and verifies a backup;
3. records the current deployment manifest;
4. pulls resolved versions;
5. applies changes in dependency order;
6. runs component and integration verification; and
7. automatically rolls back stateless changes on critical failure.

Stateful application downgrades are not assumed safe. The update plan must say
whether rollback restores configuration data, restores only Compose versions,
or requires manual intervention. Existing image policy context is documented in
[`IMAGE_TAG_POLICY.md`](./IMAGE_TAG_POLICY.md).

### 15.5 Backup and restore

Backups should include:

- desired state;
- applied deployment manifest;
- generated non-secret configuration;
- application state;
- version and compatibility metadata; and
- restore instructions.

Secret values should be excluded or stored only through a separately encrypted,
explicitly selected mechanism. Restore must support preview and must validate
the archive before stopping services.

## 16. Observability and supportability

- Use structured logs internally and concise operator output by default.
- Assign a correlation ID to every operation.
- Redact typed secret fields before serialization.
- Allow `--verbose` and `--output json` without exposing secrets.
- Capture command exit codes, bounded stderr, HTTP status, and component names.
- Do not log complete API responses that may contain credentials or tokens.
- Provide an explicit support bundle command in a later phase. It must show the
  operator exactly what will be included before writing the archive.

## 17. Phased implementation plan

### Phase 1: Foundation and unified CLI

**Goal:** Provide one binary that safely wraps the current command surface.

Tasks:

- create the Go module and cross-platform CLI;
- implement version, help, platform detection, and repository-root discovery;
- add adapters for existing Bash and PowerShell commands;
- add structured command results and redaction;
- implement `status`, `doctor`, and `logs` as read-only commands first;
- add unit tests for argument construction, redaction, and platform selection;
- package development binaries for Windows and Linux.

Exit criteria:

- existing wrapper commands remain unchanged and usable;
- no secret appears in command output or test snapshots;
- read-only commands work against both target layouts;
- the binary reports missing prerequisites with actionable messages.

### Phase 2: Desired state, discovery, and planning

**Goal:** Produce a validated desired-state file and a non-mutating plan.

Tasks:

- define and version the YAML/JSON schema;
- implement schema migrations and strict validation;
- build host, storage, Docker, GPU, port, and existing-install discovery;
- implement profiles and conditional requirements;
- translate desired state to `.env`, Compose overlays, profiles, and required
  secret references;
- implement stable plan IDs and human/JSON plan formats;
- reject stale plans.

Exit criteria:

- `media-stack plan` makes no persistent changes;
- equivalent inputs produce deterministic plans;
- Linux and Windows Compose render successfully from generated artifacts;
- hardlink and bind-address hazards block apply;
- plan snapshots cover all initial profiles.

### Phase 3: Guided install and resumable apply

**Goal:** Deliver the end-to-end new-deployment experience.

Tasks:

- add the TUI questionnaire and non-interactive input path;
- implement the workflow graph and operation journal;
- add step verification and resume semantics;
- integrate interactive, environment, and VPN-file secret providers;
- wrap setup, start, bootstrap, and verify operations;
- produce final service URLs and manual next steps.

Exit criteria:

- an interrupted deployment resumes without duplicating verified resources;
- a failed verification leaves the workflow paused, not successful;
- the journal contains no secret values;
- a clean Linux deployment completes from one entry point;
- a clean Windows deployment completes from one entry point;
- rerunning install produces an empty or explicitly explained plan.

### Phase 4: Adoption, configure, doctor, and repair

**Goal:** Support existing deployments and routine remediation.

Tasks:

- infer desired state from `.env`, Compose, and running services;
- show confidence and unresolved fields during adoption;
- implement desired/actual drift reporting;
- implement configuration deltas and minimal restart selection;
- model repair actions as normal reviewed plans;
- add component-scoped diagnostics.

Exit criteria:

- adoption is read-only until confirmed;
- unknown or ambiguous existing values are surfaced, not guessed;
- changing one feature does not restart unrelated services;
- repairs are idempotent and verified.

### Phase 5: Safe maintenance lifecycle

**Goal:** Add professional updates, backup, restore, and rollback.

Tasks:

- define signed or checksummed tested release manifests;
- add update compatibility and release-note metadata;
- implement verified backups and previewable restores;
- record pre-update manifests;
- implement rollback classifications for stateless and stateful components;
- add backup age and update drift to status.

Exit criteria:

- update cannot begin without a valid backup unless the operator uses a clearly
  labeled break-glass override;
- failed critical verification triggers the documented rollback path;
- restore validates archive integrity before stopping services;
- current and previous deployment manifests remain available.

### Phase 6: Optional local web interface

**Goal:** Provide a browser experience without duplicating application logic.

Prerequisites:

- CLI/TUI workflow and state model are stable;
- authentication and local exposure threat models are approved;
- all mutations already flow through the application service layer.

The web interface is deferred, not required for the professional CLI/TUI
experience.

## 18. Testing strategy

### Unit tests

- desired-state validation and migrations;
- profile expansion and conditional questions;
- plan determinism and stale-plan detection;
- secret redaction;
- operation dependency ordering;
- retry classification and journal transitions;
- platform-specific path and command generation.

### Integration tests

- Compose rendering for every profile and platform;
- fake HTTP servers for Jellyfin, Seerr, arr applications, and download clients;
- restart readiness and transient connection-reset behavior;
- interrupted apply and resume;
- existing-deployment adoption;
- backup manifest creation and restore validation.

### End-to-end tests

Use disposable Linux and Windows-capable environments where practical:

1. clean install;
2. idempotent second apply;
3. forced mid-bootstrap interruption and resume;
4. component configuration drift and repair;
5. update success;
6. update verification failure and rollback; and
7. backup and restore.

Tests must assert outcome state and integrations, not only command exit codes.

## 19. Security and privacy requirements

- Default to local execution and local-only management interfaces.
- Never transmit repository code, configuration, or credentials to third-party
  services without an explicit feature and consent.
- Treat Docker access as privileged host access and state that clearly.
- Do not put secrets in YAML desired state, plans, manifests, journals, process
  arguments, or support bundles.
- Validate generated paths before writing or deleting.
- Require additional confirmation for data deletion, restore, downgrade, public
  binding, or disabling VPN isolation.
- Record approval of security-sensitive plan operations.
- Pin tool release artifacts and publish checksums.

## 20. Acceptance criteria for the feature

The feature is ready for general use when:

1. A new Linux operator can complete a recommended deployment from one command
   without manually editing `.env`.
2. A new Windows operator receives correct WSL/ext4 guidance and completes the
   supported development deployment from the same command surface.
3. The installer asks only questions relevant to enabled features.
4. Every mutation appears in a plan before apply.
5. Apply can resume after process termination or host restart.
6. A second apply is idempotent.
7. Existing deployments can be adopted without mutation.
8. Status identifies container, API, integration, storage, VPN, version, and
   backup health.
9. Doctor distinguishes transient startup failures from invalid credentials and
   invalid configuration.
10. Secrets are absent from desired state, plans, logs, journals, process
    arguments, and automated test artifacts.
11. Update creates a verified backup and has an explicit rollback classification
    for every changed component.
12. Existing `stack.sh` and `stack.ps1` workflows remain available during the
    transition.

## 21. Suggested issue breakdown

Create separate implementation issues rather than one long-running branch:

1. Define CLI skeleton, package boundaries, and release artifacts.
2. Define `media-stack.yaml` v1alpha1 schema and validation.
3. Implement read-only host and existing-deployment discovery.
4. Implement deployment profiles and conditional requirement engine.
5. Implement deterministic plan model and text/JSON renderers.
6. Implement secret provider interface and structural redaction.
7. Implement workflow journal, resume, and verification contracts.
8. Wrap Linux setup and bootstrap.
9. Wrap Windows setup and bootstrap.
10. Build guided TUI install flow.
11. Implement adoption and drift reporting.
12. Implement configure and minimal restart planning.
13. Implement component diagnostics and repair plans.
14. Implement tested release manifests and update workflow.
15. Implement verified backup, restore, and rollback.
16. Add disposable integration and end-to-end environments.

Each issue should include tests, documentation updates, and compatibility with
the existing scripts. Issues that replace script logic must identify the exact
legacy path retained or removed.

## 22. Decisions required before implementation

The following choices should be resolved before their corresponding phase:

1. **CLI name and distribution:** confirm `media-stack` and decide whether
   releases are GitHub binaries, packages, or both.
2. **Go support policy:** choose the minimum Go version and supported target
   matrix.
3. **Desired-state location:** repository root versus a platform configuration
   directory.
4. **Local state location:** repository-local `.media-stack/` versus platform
   state directories.
5. **Stable release manifest ownership:** determine who tests and publishes
   compatible version sets.
6. **Encrypted secret store:** decide whether it is required for the first
   install release or deferred.
7. **Automatic rollback scope:** define which application data formats are
   proven downgrade-safe.
8. **Adoption authority:** decide whether imported values become authoritative
   immediately or only after a separate confirmation.
9. **Telemetry:** default recommendation is no telemetry. Any future telemetry
   must be opt-in and documented before implementation.
10. **Web UI:** keep deferred until the CLI/TUI engine reaches stable behavior.

## 23. Definition of done for each implementation PR

Every PR contributing to this feature must:

- preserve or explicitly migrate existing Linux and Windows behavior;
- include focused automated tests;
- keep planning separate from mutation;
- prove redaction for new secret-bearing structures;
- document new desired-state fields and commands;
- validate generated Compose for affected profiles;
- include an objective verification step;
- avoid unrelated script rewrites; and
- update this document when a listed decision or phase changes materially.
