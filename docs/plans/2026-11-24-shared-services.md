# Shared services: implementation plan

> **For agentic workers:** run through `/sdd-execute` (subagent-driven by default, `superpowers:subagent-driven-development`), task by task. Steps use checkboxes (`- [ ]`).

**Goal:** One services stack (database server, Elasticsearch, Kibana, Redis) serves several platform stacks over a shared Docker network. Each platform has one URL, `https://<name>.dev.internal:<PLATFORM_PORT>`, for every caller.

**Architecture:**
- `STACK_ROLE` (empty, `services`, `platform`) gates the `COMPOSE_FILE` catalog. Each catalog entry names the roles it may appear in.
- A platform stack's `COMPOSE_FILE` starts with the services folder's `docker-compose.yml`, so Compose reads the services `.env` in place (P1).
- The platform stack itself lists marker files (which servers it uses) and `platform-shared-*` link files (the wiring). Each platform stack registers in the services folder under `stacks/`.

**Tech stack:** PowerShell 7.4, Pester 5, Docker Compose ≥ 2.18.0, Elasticsearch REST, `dotnet dev-certs`.

**Spec:** [docs/specs/2026-11-24-shared-services-design.md](../specs/2026-11-24-shared-services-design.md) (DESIGN). Decisions S1–S19 are cited by ID, and the executor reads DESIGN alongside this plan. There's no research note and no Jira issue for this slug.

## Global Constraints

- Everything in the env-first plan's *Global Constraints* still holds ([2026-11-10-env-first-redesign.md](2026-11-10-env-first-redesign.md#global-constraints)). In particular: PowerShell 7.4 (`#Requires -Version 7.4`), loading only through `scripts/_init.ps1`, `Push-Location` before `docker compose`, list-form `environment:`, `${KEY:?KEY is empty in .env}` for secrets, `${BIND_ADDRESS:-127.0.0.1}` on every published port.
- Standalone folders (`STACK_ROLE` empty) behave as today. The one exception is S7: the platform's container port becomes `PLATFORM_PORT`.
- Nothing listens beyond `BIND_ADDRESS`, except the S8 docker0 listener (S16).
- No Docker `depends_on` crosses projects (S4).
- Typed exceptions for unexpected errors; `$null`, `bool` or empty collections for expected failures. Full variable names in scriptblocks.
- Out of scope: the `Get-DockerBridgeBindAddress` comment and the cloud routine's `ca.yml` (DESIGN §12).

## Review Focus

Each item gets a pinning test in the task named in parentheses.

1. **A platform `.env` missing a key that isn't services-owned**, for example a user deleted `VOLUME_PREFIX=`. Compose would take the services value: verified, the volumes would get the services prefix. Start puts the key back from `.env.example` (Task 2).
2. **Re-running start on an already registered platform stack.** The S9 check must not flag the stack's own registration (Task 6).
3. **Removing scope `tenant` while a stack with scope `tenant-2` exists.** Only `tenant`'s own indexes are deleted (Task 9).
4. **A stale registry entry** (its folder was deleted). It is reported and ignored by S9, S12 stop and S12 remove (Task 6, Task 9).
5. **stop or remove on a platform `.env` without `COMPOSE_PROJECT_NAME`.** `down` would target the services project, so both refuse with a message (Task 8, Task 9).

## Executor notes

- **Tests:** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit|Compose|All`. One file: `pwsh -NoProfile -c "Invoke-Pester -Path <file> -Output Detailed"`. Compose on 2.18.0: download `docker-compose-linux-x86_64` v2.18.0 into `$TMPDIR` and set `$env:SL_COMPOSE_BINARY` (see `.github/workflows/ci.yml` job `compose-min`).
- **Live checks** run in scratch folders under `$TMPDIR` (`New-ScratchSolution`). Never run `remove.ps1` in the repo root.
- **"Stop and report"** marks a step that checks an unverified fact (DESIGN §15). On failure, stop the task loop and report. The fact goes back to `/sdd-design`; don't redesign in place.
- `docker compose` in a platform stack outside start's normal flow (any `-f` call): pass `Get-ComposeProjectArguments` (Task 7), never `--project-directory .` (P3).

## Decisions (`P#`)

- **P1. The anchor is the services folder's `docker-compose.yml`.** A platform stack's first `COMPOSE_FILE` entry is the relative path from the platform folder to `<services>/docker-compose.yml`. The external network goes in `docker-compose/shared-network.yml` instead. Verified on Compose 5.7.1 (2026-11-24): a first entry in the services folder's root loads its `.env`; one in `<services>/docker-compose/` loads none. Later relative entries resolve against the platform folder. This amends S5's "the one declaring the external shared network" (DESIGN *Amendments*).
- **P2. Precedence across the two `.env` files** (verified 5.7.1): a key present but empty in the platform `.env` wins over the services value; an absent key takes the services value. So a platform `.env` removes every services-owned key and keeps every other key from `.env.example`. `Get-StackEnvTable` merges the same way: the services table first, then every key present in the platform file on top.
- **P3. `-f` calls in a platform stack** use `-p <project> --project-directory <services> --env-file <services>/.env --env-file <platform>/.env`. With both `--env-file`s the platform values win (verified 5.7.1). `--project-directory .` loads no services `.env`.
- **P4. Markers and links.** A platform stack with a source platform has no `vc-platform-web` service. So `shared-<provider|elasticsearch|redis>.yml` carry only `x-start-local: {}` and drive feature inference (C3), and the wiring sits in `platform-shared-*.yml`, which require `platform.yml`. This mirrors `postgres.yml` / `platform-postgres.yml`.
- **P5. Keys the services stack writes:** `SERVICES_NETWORK_NAME` (`<project>-shared`, S3) and `SERVICES_CERTS_VOLUME` (`Get-CertsVolumeName` of the services folder). Services start writes them; neither is in `.env.example`.
- **P6. Certificates.** In a platform stack, `certs` is the services certificates volume (`shared-certs.yml`, `external: true`). Platform start syncs the dev certificate into it with `-ProjectName <services project>`, so `Copy-DevCertificateToVolume`'s labels match the volume's owner.
- **P7. `ASPNETCORE_URLS` stays container-only** (`Get-ContainerOnlyKeys`). The Host topology already listens on `Kestrel:Endpoints:Main:Url` with `PLATFORM_PORT`. §6a's "alike" is met by both following `PLATFORM_PORT`.
- **P8. Index removal (S12) uses a strict pattern** (the user's choice, 2026-11-24), with S9 unchanged:
  - Own aliases match `^<scope>-[^-]+-(active|backup)$`. Delete the indexes they point to.
  - Orphans are deleted only when they match `^<scope>-(<own doc types>)(-[a-z0-9]{10})?$`.
  - Names come from `ElasticSearch8Provider`/`ElasticSearch9Provider` (`GetIndexName`, `GetIndexAlias`, `SuffixLength = 10`, lowercase). The public modules' document types contain no `-`: `Product`, `Category`, `Member`, `CustomerOrder`, `ContentFile`, `Pages`, `PickupLocation`.
  - Delete by exact name only, never with a wildcard.
- **P9. A platform stack's full remove refuses** while the services folder exists but its servers aren't running. Nothing is removed, and there is no override. When the services folder is gone, or is no longer a services stack, remove proceeds with a warning that the database and indexes went with it. A `-keepData` remove needs no servers.
- **P10. S12 override switch:** `-ignoreStacks` on `stop.ps1` and `remove.ps1`.
- **P11. Isolation defaults for a platform stack** (S9), derived from the project name `p`:
  - `DB_NAME=VirtoCommerce_<p with - → _>`;
  - `SEARCH_SCOPE=<p>`;
  - `REDIS_CHANNEL=VirtoCommerceChannel-<p>`;
  - `PLATFORM_HOSTNAME=<p with _ → ->.dev.internal`.

  Standalone compose defaults are `${DB_NAME:-VirtoCommerce3}`, `${SEARCH_SCOPE:-default}` (vc-platform `appsettings.json` `Search:Scope`) and `${REDIS_CHANNEL:-VirtoCommerceChannel}`.
- **P12. A platform stack with no Compose service** (a source platform and no storefront): start skips `up`. On 5.7.1 such a project passes `config`, `ps` and `down` (exit 0), and only `up` fails ("no service selected"), as verified 2026-11-24.
- **P13. A services stack has platform mode `none`.** It needs no `RELEASE_CHANNEL`, builds no image, and runs no platform steps.
- **P14. The installer skips the vc-build question for a services stack.** `build.ps1` in that role goes straight to "Start now?".
- **P15. Each platform stack has its own Redis database** (§15.9, the user's choice, 2026-11-24; DESIGN *Amendments*).
  - Why: vc-platform keeps the DataProtection key ring under the fixed key `VirtoCommerce-Keys` and takes locks as `redlock:[KeyPrefix:]<resource>`, and `InternalDistributedLockService` ignores `KeyPrefix`. Two platforms on one database would share both.
  - New key `REDIS_DATABASE`. Standalone uses `0`, as today. A platform stack takes the lowest index 0–15 that no non-stale registration uses.
  - The Redis connection string gains `,defaultDatabase=${REDIS_DATABASE:-0}`. S9's uniqueness check covers `REDIS_DATABASE`.
  - The backplane channels stay separate through `REDIS_CHANNEL`, because Redis pub/sub ignores the database index.
- **P16. Who fills a platform stack's `COMPOSE_FILE`.** install, build and start each call `Update-EnvForRole` before `Update-EnvFromOptions`.
  - An empty list becomes `Get-DefaultPlatformComposeFiles`: base, `shared-network.yml`, the services provider's marker, `https.yml` when the services stack has it, the Elasticsearch and Redis markers when the services stack runs them, `platform.yml` when the platform mode is `docker`, and `frontend.yml`.
  - The switches then apply to that list. A platform stack never gets the provider prompt.
- **P17. The S18 signal for a services stack** is `SERVICES_NETWORK_NAME` empty in `.env` *as start reads it*. Start writes the P5 keys only after preflight passes, and the installer never writes them.
  - So `services-network.yml` names the network `${SERVICES_NETWORK_NAME:-${COMPOSE_PROJECT_NAME}-shared}`, which loads before the key exists.
  - `shared-network.yml` keeps `:?`.

## User steps (`F#`)

- **F1.** After Task 11: on Docker Desktop (your machine) and on a native Engine, call a platform run from source from a Docker platform listed in `PEER_PLATFORMS_FROM_SOURCE` (DESIGN §15.2). The executor has only one of the two.
- **F2.** After Task 12: push the branch to your fork and run `ci.yml` (Windows `;`, macOS, Compose 2.18.0: DESIGN §15.3, §15.7, §15.8) and `smoke.yml`. The executor doesn't push.
- **F3.** After Task 12: run the RND-167 pair from DESIGN §6. The tenant's AI module calls `https://mgmt.dev.internal:<port>`, and Management calls back, with `EXTRA_CA_CERTS` naming your local CA (DESIGN §15.1, a .NET client).

## Where DESIGN §15 gets verified

| §15 fact | Verified in |
|---|---|
| 1. .NET client with `EXTRA_CA_CERTS` | Task 12 step 4 (openssl in the container), F3 (.NET) |
| 2. `host-gateway` to a source platform | Task 11 step 5 (this machine), F1 |
| 3. External network, `name:`, alias on 2.18.0 | Task 1 step 4, F2 |
| 4. Services `down` with an attached container | Task 8 step 6 |
| 5. `DB_NAME` database created on first start | Task 8 step 6 (postgres), Task 12 step 4 (smoke matrix) |
| 6. Deleting indexes by name on ES 9.5 | Task 9 step 5 |
| 7. `use_service_name_alias` | Task 1 step 4, F2 |
| 8. Second `.env` via the first entry | Task 1 step 4 (Linux), F2 (Windows, macOS) |
| 9. Other Redis keys shared across platforms | Answered while planning: shared (P15). Task 2 step 1 confirms `defaultDatabase` reaches RedLock and DataProtection; Task 8 step 6 checks it live |

---

## Phase A — Compose layer and configuration core

### Task 1: Shared and services compose files

**Reads:** DESIGN §3, S2–S6, S13, S15, S16, §15.3, §15.7, §15.8; this plan P1, P2, P4–P6.

**Files:**
- Create in `docker-compose/`: `services-network.yml`, `services-database.yml`, `services-elasticsearch.yml`, `services-redis.yml`, `shared-network.yml`, `shared-postgres.yml`, `shared-mysql.yml`, `shared-sqlserver.yml`, `shared-elasticsearch.yml`, `shared-redis.yml`, `shared-certs.yml`, `platform-shared.yml`, `platform-shared.https.yml`, `platform-shared-postgres.yml`, `platform-shared-mysql.yml`, `platform-shared-sqlserver.yml`, `platform-shared-elasticsearch.yml`, `platform-shared-elasticsearch.https.yml`, `platform-shared-redis.yml`
- Create: `tests/compose/SharedStacks.Tests.ps1`
- Modify: `tests/support/TestHelpers.ps1`, `tests/compose/ComposeConfig.Tests.ps1` (the test "every compose file in the repo is in the catalog": mark the new files pending until Task 3)

**Interfaces — Produces** (file contents; every variable a file reads is listed):

| File | Content |
|---|---|
| `services-network.yml` | `networks.shared: { name: ${SERVICES_NETWORK_NAME:-${COMPOSE_PROJECT_NAME}-shared} }` (P17) |
| `services-database.yml` / `-elasticsearch` / `-redis` | `vc-db` / `es` / `redis`: `networks: [virto, shared]`. Kibana and es-setup stay off it (S15). |
| `shared-network.yml` | `networks.shared: { external: true, name: ${SERVICES_NETWORK_NAME:?…} }` |
| `shared-<postgres\|mysql\|sqlserver\|elasticsearch\|redis>.yml` | Only `x-start-local: {}` (P4) |
| `shared-certs.yml` | `volumes.certs: { external: true, name: ${SERVICES_CERTS_VOLUME:?…} }`. It overrides the `certs` of `https.yml` by merge. |
| `platform-shared.yml` | `vc-platform-web`: `networks: { virto: {}, shared: { aliases: [${PLATFORM_HOSTNAME:?…}], use_service_name_alias: false } }` (S15). The key belongs per network: 5.7.1 rejects it at service level ("services.web.use_service_name_alias … schema") and accepts it under `networks.<name>` (checked 2026-11-24). Also `Assets__FileSystem__PublicUrl=http://${PLATFORM_HOSTNAME}:${PLATFORM_PORT}/assets/` and `Content__…=/cms-content/` (S19) |
| `platform-shared.https.yml` | The same two URLs with `https`. |
| `platform-shared-<provider>.yml` | The `platform-<provider>.yml` content with `Database=${DB_NAME:?…}` and no `depends_on`. |
| `platform-shared-elasticsearch.yml` | The `platform-elasticsearch.yml` content plus `Search__Scope=${SEARCH_SCOPE:?…}`, and no `depends_on`. |
| `platform-shared-elasticsearch.https.yml` | The same as `platform-elasticsearch.https.yml`. |
| `platform-shared-redis.yml` | The `platform-redis.yml` connection string with `,defaultDatabase=${REDIS_DATABASE:?…}` (P15), plus `Caching__Redis__ChannelName` and `PushNotifications__RedisBackplane__ChannelName` = `${REDIS_CHANNEL:?…}`, and no `depends_on`. |

```powershell
# tests/support/TestHelpers.ps1
New-SharedStackFixture [-ServicesFiles] <string[]> [-PlatformFiles] <string[]> [[-PlatformEnv] <hashtable>] [[-ServicesEnv] <hashtable>]
  -> [pscustomobject]@{ Root; ServicesFolder; PlatformFolder }
# Siblings services/ and platform/ under one scratch parent. Platform COMPOSE_FILE = '../services/docker-compose.yml' + PlatformFiles.
# The platform .env is .env.example minus the services-owned keys (Task 2's list, spelled out here), plus COMPOSE_PROJECT_NAME=platform and the S9 keys.
```

- [ ] **Step 1: Write the failing tests** in `tests/compose/SharedStacks.Tests.ps1` (tag `Compose`, skip without docker). Each runs `Invoke-ComposeConfigJson` in the fixture's folder.
  - `services stack: vc-db, es and redis join <project>-shared; kibana and es-setup do not` (postgres, HTTPS, Elasticsearch, Kibana, Redis).
  - `platform stack reads the services .env in place`: `DB_PASSWORD` only in services `.env` → the connection string of `vc-platform-web` contains it; `COMPOSE_PROJECT_NAME` → config `name` is `platform`.
  - `an empty platform key shadows the services value` (P2): `DB_PASSWORD=` present but empty in the platform `.env` → `docker compose config` fails with "DB_PASSWORD is empty in .env". This pins why Task 2 removes the keys.
  - `the platform joins the external network with its alias`: `networks.shared.external` is true, its `name` is the services `SERVICES_NETWORK_NAME`, and `aliases` holds `PLATFORM_HOSTNAME`.
  - `the platform has no depends_on` in a platform stack.
  - `HTTPS: certs is the external services volume` (`external: true`, `name` = `SERVICES_CERTS_VOLUME`), and the platform and storefront mount it.
  - `every published port follows a non-default BIND_ADDRESS in both roles` (S16): `BIND_ADDRESS=127.0.0.2`, each `ports[].host_ip` is `127.0.0.2`.
  - `PublicUrl uses PLATFORM_HOSTNAME`: `https://mgmt.dev.internal:8091/assets/`.
  - `a services stack names its network before SERVICES_NETWORK_NAME exists`: key absent, folder `svc` → network `name` is `svc-shared` (P17).
  - `a platform stack with no service loads` (P12): anchor, `docker-compose.yml`, `shared-network.yml`, `shared-postgres.yml` → `config` succeeds with `services: {}`.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/compose/SharedStacks.Tests.ps1 -Output Detailed"`. Expected: FAIL (files missing).
- [ ] **Step 3: Implement** the files from the table and `New-SharedStackFixture`. No file uses a relative path (S5(c)).
- [ ] **Step 4: Run** the same on the machine's Compose, then with `$env:SL_COMPOSE_BINARY` set to Compose 2.18.0. Expected: PASS on both. **Stop and report** (§15.3, §15.7, §15.8) if:
  - the external network, its `name:` or the alias fails on 2.18.0;
  - `use_service_name_alias` is rejected on 2.18.0, or, after `up` on 5.7+, `docker inspect` still lists `vc-platform-web` among the container's aliases on `<project>-shared`;
  - the services `.env` is not read;
  - the zero-service project fails `config` on 2.18.0.
- [ ] **Step 5: Commit:** `git add docker-compose/ tests/compose/ tests/support/TestHelpers.ps1 && git commit -m "Add the compose files of services and platform stacks"`

### Task 2: Role keys, the merged settings table and the platform `.env`

**Reads:** DESIGN S1, S4, S5(a)(b)(d), S6, S9, S18, §6a, §9, §15.9, *Amendments*; this plan P2, P5, P11, P13, P15, P17.

**Files:**
- Create: `scripts/stack-role.ps1`, `tests/unit/StackRole.Tests.ps1`
- Modify: `scripts/_init.ps1` (after `settings-file.ps1`), `.env.example`, `scripts/env-file.ps1` (`Add-MissingEnvKeys`), `scripts/migrate.ps1` (`Get-EnvLayout`), `scripts/source-mode.ps1` (`Get-PlatformMode`), `tests/unit/EnvFile.Tests.ps1`, `tests/unit/Migrate.Tests.ps1`, `tests/unit/SourceMode.Tests.ps1`

**Interfaces — Produces:**
```powershell
Get-StackRole [-EnvValues] <IDictionary> -> [string]           # '', 'services', 'platform'; throws [InvalidOperationException] naming STACK_ROLE otherwise
Get-ServicesOwnedKeys -> [string[]]   # $script:SecretKeys + PGSQL_VERSION, PGSQL_PORT, MYSQL_VERSION, MYSQL_PORT, MSSQL_VERSION, MSSQL_PORT,
                                      # STACK_VERSION, ES_PORT, KIBANA_PORT, ES_MEM_LIMIT, REDIS_PORT, SERVICES_NETWORK_NAME, SERVICES_CERTS_VOLUME
Resolve-ServicesFolder [-Value] <string> [-SolutionFolder] <string> -> [string]   # absolute; relative to SolutionFolder
Get-ServicesStackInfo [-ServicesFolder] <string> -> [pscustomobject]   # $null when the folder has no .env or STACK_ROLE is not 'services'
  # @{ Folder; ProjectName; Features (Get-ComposeFeatures of its list); NetworkName; CertsVolume; EnvTable }
Get-StackEnvTable [-Document] <psobject> [-SolutionFolder] <string> -> [OrderedDictionary]   # P2; non-platform roles: Get-EnvTable
Get-IsolationDefaults [-ProjectName] <string> -> [hashtable]   # P11: DB_NAME, SEARCH_SCOPE, REDIS_CHANNEL, PLATFORM_HOSTNAME
Update-EnvForRole [-Document] <psobject> [-SolutionFolder] <string> [-Template] <psobject> -> [string[]]   # the keys changed
  # platform: Add-MissingEnvKeys -ExcludeKeys (Get-ServicesOwnedKeys); Remove-EnvKey each services-owned key;
  #   COMPOSE_PROJECT_NAME = Get-SolutionProjectName when empty; fill empty P11 keys (Task 3 adds the COMPOSE_FILE fill, P16)
  # services: COMPOSE_PROJECT_NAME when empty — never the P5 keys (P17)
  # standalone: nothing
Set-ServicesStackKeys [-Document] <psobject> [-SolutionFolder] <string> -> [string[]]   # services start, after preflight (P17):
  # SERVICES_NETWORK_NAME = '<project>-shared'; SERVICES_CERTS_VOLUME = Get-CertsVolumeName
Add-MissingEnvKeys [-Document] <psobject> [-Template] <psobject> [-ExcludeKeys <string[]> = @()] -> [string[]]
Get-PlatformMode -> adds 'none' when STACK_ROLE=services
```

- [ ] **Step 1: P15's premise, stop and report.** Read two sources:
  - RedLock.net's `RedLockMultiplexer` (the database it uses when none is given);
  - `Microsoft.AspNetCore.DataProtection.StackExchangeRedis` `PersistKeysToStackExchangeRedis(IConnectionMultiplexer, RedisKey)` (which database it writes).

  Expected: both use the multiplexer's default database, which `defaultDatabase=` in the connection string sets. If either pins database 0, **stop and report**: P15 doesn't isolate it.
- [ ] **Step 2: Write the failing tests** in `tests/unit/StackRole.Tests.ps1`:
  - `Get-StackRole` returns `''`, `'services'` or `'platform'`, and throws naming `STACK_ROLE` for `Platform` (case matters, like `SKIP_PLATFORM`).
  - `Get-StackEnvTable` (P2): services `REDIS_PORT=6380`, platform without it → `6380`; platform `PLATFORM_PORT=8091` over services `8090` → `8091`; platform `VOLUME_PREFIX=` present → `''`.
  - `Update-EnvForRole` on a platform `.env` made from `.env.example`:
    - every services-owned key is gone;
    - `COMPOSE_PROJECT_NAME=tenant-2` is written;
    - `DB_NAME=VirtoCommerce_tenant_2`, `SEARCH_SCOPE=tenant-2`, `REDIS_CHANNEL=VirtoCommerceChannel-tenant-2`, `PLATFORM_HOSTNAME=tenant-2.dev.internal`;
    - a second call changes nothing;
    - user values are kept.
  - **Review Focus 1:** a platform `.env` without `VOLUME_PREFIX` gets `VOLUME_PREFIX=` back.
  - `Update-EnvForRole` on a services `.env` writes `COMPOSE_PROJECT_NAME=svc` and leaves `SERVICES_NETWORK_NAME` empty (P17). `Set-ServicesStackKeys` then writes `SERVICES_NETWORK_NAME=svc-shared` and `SERVICES_CERTS_VOLUME=svc_certs`.
  - `Resolve-ServicesFolder '../svc' <platform folder>` is the sibling's absolute path.
  - `Get-EnvLayout` is 2 for an unmarked `.env` with `STACK_ROLE=platform` and no `DB_PROVIDER`.
  - `Get-PlatformMode` is `none` for `STACK_ROLE=services`, even with `PLATFORM_SOURCE_PATH` set.
- [ ] **Step 3: Run** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit`. Expected: FAIL.
- [ ] **Step 4: Implement.** Add to `.env.example`:
  - a `# --- Shared services ---` group after `--- Stack ---` with `STACK_ROLE=`, `SERVICES_FOLDER=`, `PLATFORM_HOSTNAME=`, `PEER_PLATFORMS_FROM_SOURCE=`, `DB_NAME=`, `SEARCH_SCOPE=`, `REDIS_CHANNEL=`, `REDIS_DATABASE=`;
  - `EXTRA_CA_CERTS=`.

  Each gets a one-line comment on its own line; there are no inline comments (pinned by `EnvFile.Tests`).
- [ ] **Step 5: Run** the Unit tier. Expected: PASS.
- [ ] **Step 6: Commit:** `git add .env.example scripts/ tests/unit/ && git commit -m "Add stack roles and the platform stack's .env rules"`

### Task 3: Role-aware `COMPOSE_FILE` catalog and switches

**Reads:** DESIGN S2, S4, S5, S15, S17, §10; env-first plan P1, P8, P16; this plan P1, P4, P13.

**Files:**
- Modify: `scripts/compose-files.ps1`, `scripts/options.ps1`
- Modify: `tests/unit/ComposeFiles.Tests.ps1`, `tests/unit/ComposeCatalog.Tests.ps1`, `tests/unit/Options.Tests.ps1`, `tests/compose/ComposeConfig.Tests.ps1` (lift Task 1's pending mark)

**Interfaces — Produces:**
```powershell
# Catalog entry gains Roles [string[]] (the roles it may be emitted in; '' is standalone) and kinds 'role' and 'shared'.
#   ''+services: provider files, elasticsearch(.https), es-limited, kibana(.https), redis, kibana-elasticsearch(.https)
#   ''+platform: platform(.https), frontend(.https), platform-frontend, platform-modules, frontend-hostplatform
#   '' only:     platform-<provider>, platform-elasticsearch(.https), platform-redis
#   services:    services-network (kind role), services-database/-elasticsearch/-redis (link; Requires services-network + their server file;
#                services-database requires only services-network)
#   platform:    shared-network (kind role); shared-<provider|elasticsearch|redis> (kind shared, Feature = provider|elasticsearch|redis,
#                Requires shared-network); shared-certs (link: https.yml + shared-network); platform-shared (link: platform.yml + shared-network)
#                + .https overlay; platform-shared-<x> (link: platform.yml + shared-<x>) + platform-shared-elasticsearch.https overlay;
#                platform-peers, platform-extra-ca (link, Generated, Requires platform.yml)
#   base and https.yml: every role. A listed entry outside its roles is dropped with a warning naming STACK_ROLE.
Update-ComposeFileList [-ComposeFiles] <string[]> [-HasSourceModules] <bool> [-Role <string> = ''] [-ServicesAnchor <string> = ''] [-GeneratedFiles <string[]> = @()] -> [string[]]
  # ServicesAnchor, when set, is emitted first and is never re-appended as a user file. A Generated entry is emitted when its
  # Name is in GeneratedFiles (platform-modules also when HasSourceModules).
Get-ComposeFeatures -> adds Shared (shared-network listed) and Services (services-network listed); Elasticsearch/Redis also true for their shared markers
Resolve-DbProvider -> also reads kind 'shared' markers with a provider Feature
Set-ComposeFeature [...] [-Role <string> = '']   # platform: elasticsearch/redis map to their shared markers
Get-ServicesAnchorEntry [-ServicesFolder] <string> [-SolutionFolder] <string> -> [string]   # relative path, '/' separators, ends '/docker-compose.yml';
  # absolute when no relative path exists (another Windows drive)
Sync-PlatformComposeFiles [-ComposeFiles] <string[]> [-ServicesInfo] <pscustomobject> [-SolutionFolder] <string> -> [string[]]
  # anchor first; the provider marker = the services provider; https.yml present iff the services stack has it (S5); the
  # services stack's server files never listed. Elasticsearch/Redis markers stay as the user set them (S17 is a preflight check).
Get-KeepDataDeletePaths -> skips an entry outside the folder (the anchor) instead of keeping it
Get-DefaultPlatformComposeFiles [-ServicesInfo] <pscustomobject> [-PlatformMode] <string> [-SolutionFolder] <string> -> [string[]]   # P16
Update-EnvForRole -> platform: an empty COMPOSE_FILE becomes Get-DefaultPlatformComposeFiles when Get-ServicesStackInfo answers (else stays
  # empty, and Test-StackRoleValues reports the services folder)
```

Switch matrix for `Update-EnvFromOptions` ("warn" means a warning naming the role, and the switch is not applied):

| Switch | services | platform |
|---|---|---|
| `-dbProvider` | applies | warn (follows the services stack) |
| `-allowInsecureHttp` | applies | warn (follows the services stack) |
| `-skipPlatform`, `-skipFrontend` | warn | apply |
| `-skipElasticsearch`, `-skipRedis` | apply | toggle the shared marker (S17) |
| `-skipKibana` | applies | warn |

`Get-MissingRequiredKeys` does not require `RELEASE_CHANNEL` for `services` (P13). For `platform` it never requires `COMPOSE_FILE`, because `Update-EnvForRole` owns it (P16). So `Request-RequiredEnvKeys` never shows a platform stack the provider prompt.

- [ ] **Step 1: Write the failing tests:**
  - `a platform list is anchor-first`: `Update-ComposeFileList @('docker-compose.yml','docker-compose/postgres.yml','docker-compose/platform.yml') $false -Role platform -ServicesAnchor '../svc/docker-compose.yml'` → starts with `../svc/docker-compose.yml`, `docker-compose.yml`; contains `docker-compose/shared-network.yml`; drops `postgres.yml` with a warning.
  - `markers drive the links`: `+ shared-postgres.yml, shared-redis.yml` → `platform-shared-postgres.yml` and `platform-shared-redis.yml`; with no `platform.yml` → neither link, but `Resolve-DbProvider` is `postgres` and `Get-ComposeFeatures` has `Redis`, `Shared` true.
  - `services list`: `-Role services` drops `platform.yml` and `frontend.yml`, adds `services-network.yml` and one `services-*` link per listed server.
  - `a standalone list is unchanged by the new entries`: each existing `ComposeFiles` case keeps its output.
  - `Sync-PlatformComposeFiles` follows the services stack's provider and HTTPS mode, and keeps a user-removed `shared-elasticsearch.yml` removed.
  - `the first run fills a platform list` (P16): an empty `COMPOSE_FILE`, services info (postgres, HTTPS, Elasticsearch, Redis), mode `docker` → anchor, `docker-compose.yml`, `https.yml`, `shared-network.yml`, `shared-postgres.yml`, `platform.yml`, `shared-elasticsearch.yml`, `shared-redis.yml`, `frontend.yml` and their links. Then `Update-EnvFromOptions -Bound @{ skipElasticsearch = $true }` removes `shared-elasticsearch.yml` with no warning.
  - `Get-MissingRequiredKeys` never lists `COMPOSE_FILE` for `STACK_ROLE=platform`.
  - `Update-EnvFromOptions` follows each row of the switch matrix (`-TestCases`).
  - `Get-KeepDataDeletePaths` neither keeps nor deletes the anchor.
- [ ] **Step 2: Run** the Unit tier. Expected: FAIL.
- [ ] **Step 3: Implement** the catalog and functions above. The existing positional call sites stay valid (new parameters are named, with defaults).
- [ ] **Step 4: Run** `-Tier All`. Expected: PASS, including the Compose test "every compose file in the repo is in the catalog".
- [ ] **Step 5: Commit:** `git add scripts/ tests/ && git commit -m "Make the compose catalog and the switches follow the stack role"`

### Task 4: Per-stack database, index scope, Redis channel and platform port

**Reads:** DESIGN S7, S9, S14, S19, §6a, §14; this plan P7, P11.

**Files:**
- Modify: `docker-compose/platform.yml`, `platform.https.yml`, `platform-frontend.yml`, `platform-postgres.yml`, `platform-mysql.yml`, `platform-sqlserver.yml`, `platform-elasticsearch.yml`, `platform-redis.yml`
- Modify: `scripts/compose-files.ps1` (`$script:PortCatalog` platform `ContainerPort`), `scripts/settings-file.ps1`
- Modify: `tests/unit/SettingsFile.Tests.ps1`, `tests/compose/SettingsDrift.Tests.ps1`, `tests/compose/ComposeConfig.Tests.ps1` (lines 194, 230, 234, 242, 249), `tests/compose/ScriptBehaviour.Tests.ps1` (the health-check helper at lines 63–66 rewrites `127.0.0.1:8080`)
- Unchanged: the storefront's container port stays 8080 (`frontend.yml`, nginx templates, `ComposeConfig.Tests.ps1:211`, `Nginx.Tests.ps1`).

**Interfaces — Produces:**
```powershell
Get-DbSettings [-Provider] [-EnvValues] [-Topology]          # Database = DB_NAME, default 'VirtoCommerce3'
Get-PlatformSettings [-EnvValues] [-ComposeFiles] [-Topology] [[-CaFingerprint]] [-BridgeAddress]
  # adds Search:Scope (SEARCH_SCOPE, default 'default'); Caching:Redis:ChannelName and PushNotifications:RedisBackplane:ChannelName
  # (REDIS_CHANNEL, default 'VirtoCommerceChannel'); the Redis connection string ends ',defaultDatabase=<REDIS_DATABASE, default 0>' (P15).
  # STACK_ROLE=platform: the PublicUrl host is PLATFORM_HOSTNAME, else localhost.
  # Container topology: the platform server port is PLATFORM_PORT.
# PortCatalog platform entry: ContainerPort = $null, meaning "same as PLATFORM_PORT" (callers read the key).
```

- [ ] **Step 1: Write the failing tests:**
  - `SettingsFile`: the Search scope, both channel names, the database name and the Redis `defaultDatabase`, each with its default and with a set value; `STACK_ROLE=platform` with `PLATFORM_HOSTNAME=mgmt.dev.internal` → `Assets:FileSystem:PublicUrl` is `https://mgmt.dev.internal:8091/assets/`.
  - `SettingsDrift`: add the platform-stack cases (3 providers × Elasticsearch on/off × Redis on/off × HTTP/HTTPS), built with `New-SharedStackFixture`, comparing against `Get-PlatformSettings` over `Get-StackEnvTable`.
  - `ComposeConfig`:
    - the platform listens on `PLATFORM_PORT` inside the container (`ASPNETCORE_URLS`, `ports[].target`, health check);
    - `PLATFORM_UPSTREAM` is `vc-platform-web:<PLATFORM_PORT>`;
    - move the `8080` assertions to `8090`.
- [ ] **Step 2: Run** `-Tier All`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `platform.yml`:
    - `"${BIND_ADDRESS:-127.0.0.1}:${PLATFORM_PORT}:${PLATFORM_PORT}"`;
    - `ASPNETCORE_URLS=http://+:${PLATFORM_PORT}`;
    - the health check's `/dev/tcp/127.0.0.1/${PLATFORM_PORT}`.

    `platform.https.yml` gets the same, with `-connect 127.0.0.1:${PLATFORM_PORT}`.
  - Standalone links take the P11 defaults, and `platform-redis.yml` gets `,defaultDatabase=${REDIS_DATABASE:-0}`.
  - `postgres.yml` / `mysql.yml` keep `VirtoCommerce3`: the platform creates `DB_NAME` (§15.5, Task 8).
- [ ] **Step 4: Run** `-Tier All`. Expected: PASS.
- [ ] **Step 5: Commit:** `git add docker-compose/ scripts/ tests/ && git commit -m "Give each stack its database, index scope, Redis channel and platform port"`

### Task 5: Generated peer and extra-CA compose files

**Reads:** DESIGN S8, S13; env-first plan P16; `scripts/source-mode.ps1` `New-ModulesComposeYaml`, `Write-ModulesComposeFile`.

**Files:**
- Create: `scripts/shared-compose.ps1` (registered in `_init.ps1` after `source-mode.ps1`), `tests/unit/SharedCompose.Tests.ps1`
- Modify: `.gitignore`, `scripts/preflight.ps1` (`Get-ProjectPublishedPorts`: a missing generated file is skipped, like `platform-modules.yml`)

**Interfaces — Produces:**
```powershell
Get-PeerHostnames [-Value] <string> -> [string[]]     # ';'-split, trimmed, empty dropped, lowercased
New-PeersComposeYaml [-Hostnames] <string[]> -> [string]   # vc-platform-web extra_hosts: "<name>:host-gateway"
Write-PeersComposeFile [-SolutionFolder] <string> [-Hostnames] <string[]> -> [void]   # docker-compose/platform-peers.yml; deleted when empty
Get-ExtraCaMountPlan [-Value] <string> [-BaseDirectory] <string> -> [pscustomobject[]]   # @{ Source (absolute); Target = /usr/local/share/start-local-ca/<n>-<leaf> }
New-ExtraCaComposeYaml [-MountPlan] <pscustomobject[]> [-WithElasticsearchCa] <bool> -> [string]
  # read-only bind mounts; SSL_CERT_DIR=/etc/ssl/certs[:/certs/ca]:/usr/local/share/start-local-ca
Write-ExtraCaComposeFile [-SolutionFolder] <string> [-MountPlan] <pscustomobject[]> [-WithElasticsearchCa] <bool> -> [void]   # docker-compose/platform-extra-ca.yml
# Missing files are an error at preflight (Task 7), not here. Paths go through ConvertTo-ComposeYamlString.
```

- [ ] **Step 1: Write the failing tests:**
  - `'mgmt.dev.internal; ;Tenant.dev.internal'` → two lowercased names.
  - The peers YAML has one `extra_hosts` line per name.
  - An empty value deletes the file.
  - The extra-CA YAML joins `SSL_CERT_DIR` with `/certs/ca` only when `-WithElasticsearchCa`.
  - A path with `$` reaches the YAML as `$$`.
  - A relative path resolves against the base directory.
- [ ] **Step 2: Run** the Unit tier. Expected: FAIL.
- [ ] **Step 3: Implement.** `.gitignore` gains `/docker-compose/platform-peers.yml` and `/docker-compose/platform-extra-ca.yml`.
- [ ] **Step 4: Run** the Unit tier, then add a `SharedStacks` Compose case listing both generated files: `extra_hosts` and `SSL_CERT_DIR` resolve as specified, and the extra-CA file wins over `platform-shared-elasticsearch.https.yml`'s `SSL_CERT_DIR`. Expected: PASS.
- [ ] **Step 5: Commit:** `git add .gitignore scripts/ tests/ && git commit -m "Generate the peer and extra-CA compose files"`

## Phase B — Registry, preflight and lifecycle

### Task 6: Stack registry and isolation rules

**Reads:** DESIGN S9, S10, S12; this plan Review Focus 2 and 4.

**Files:** Create `scripts/stack-registry.ps1` (registered after `stack-role.ps1`) and `tests/unit/StackRegistry.Tests.ps1`.

**Interfaces — Produces:**
```powershell
# <services>/stacks/<project>.json, UTF-8 without BOM, written to <file>.tmp and renamed:
# { "schema": 1, "project", "folder", "dbName", "searchScope", "redisChannel", "redisDatabase", "platformHostname",
#   "platformPort", "frontendPort", "volumePrefix", "usesElasticsearch", "usesRedis" }    — no secrets
Get-FreeRedisDatabase [-Registrations] <pscustomobject[]> [-ProjectName] <string> -> [Nullable[int]]
  # P15: the lowest 0–15 not used by a non-stale registration of another project; $null when all 16 are taken
Get-StackRegistryPath [-ServicesFolder] <string> [-ProjectName] <string> -> [string]
New-StackRegistration [-EnvValues] <IDictionary> [-ComposeFiles] <string[]> [-SolutionFolder] <string> [-ProjectName] <string> -> [pscustomobject]
Write-StackRegistration [-ServicesFolder] <string> [-Registration] <pscustomobject> -> [void]
Remove-StackRegistration [-ServicesFolder] <string> [-ProjectName] <string> -> [bool]
Get-StackRegistrations [-ServicesFolder] <string> -> [pscustomobject[]]   # each + Stale (folder gone); an unreadable file is Stale with Error
Get-IsolationConflicts [-Registration] <pscustomobject> [-Others] <pscustomobject[]> [-ServicesVolumePrefix] <string> -> [string[]]
  # Others exclude Stale entries and the same project. One message per clash:
  # "<KEY> '<value>' is already used by the stack '<project>' (<folder>). Set another <KEY> in .env."
  # and "VOLUME_PREFIX '<value>' is the services stack's own prefix. Set another VOLUME_PREFIX in .env."
```

- [ ] **Step 1: Write the failing tests:** a write → read round trip; a missing `stacks/` reads as empty; a stale entry is flagged; each of the 7 S9 keys and `REDIS_DATABASE` clashes, with its message; `Get-FreeRedisDatabase` skips 0 and 1 when they are used, ignores a stale entry's index and the stack's own, and gives `$null` when 0–15 are all taken; the same project gives no conflict (**Review Focus 2**); a stale entry gives no conflict (**Review Focus 4**); `VOLUME_PREFIX` equal to the services prefix clashes.
- [ ] **Step 2: Run** the Unit tier. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Unit tier. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/ tests/unit/ && git commit -m "Add the stack registry and the isolation rules"`

### Task 7: Preflight for services and platform stacks

**Reads:** DESIGN S4, S9, S11, S16–S18, §10; this plan P3, P5.

**Files:**
- Create: `scripts/shared-services.ps1` (registered after `preflight.ps1`), `tests/unit/SharedServices.Tests.ps1`
- Modify: `scripts/preflight.ps1`, `tests/unit/Preflight.Tests.ps1`

**Interfaces — Produces:**
```powershell
Get-ComposeProjectArguments [-EnvValues] <IDictionary> [-SolutionFolder] <string> [-ProjectName] <string> -> [string[]]
  # platform: P3; else '--project-directory', '.'
Get-ProjectPublishedPorts [-ComposeFiles] <string[]> [-ProjectArguments <string[]> = @('--project-directory','.')]
Get-ServicesHealthProblems [-ServicesFolder] <string> [-Needs] <string[]> -> [string[]]   # Needs ⊂ vc-db, es, redis; 'docker compose ps --format json' there
Get-StandaloneServerLeftovers [-VolumePrefix] <string> [-ProjectName] <string> -> [string[]]
  # server containers (label com.docker.compose.project=<p>, service vc-db|es|es-setup|kibana|redis) and server volumes
  # (<prefix>_postgres_data|mysql_data|mssql_data|esdata01|redisdata)
Test-DevCertificateCoversHostname [-CertificatePath] <string> [-Hostname] <string> -> [bool]   # SAN DNS names; '*.' covers exactly one label
Test-HostnameLoopback [-Hostname] <string> -> [bool]           # Dns.GetHostAddresses, every address IsLoopback
Get-HostsLine [-Hostnames] <string[]> -> [string]              # '127.0.0.1 <names joined by space>'
Test-StackRoleValues [-EnvValues] <IDictionary> [-SolutionFolder] <string> -> [string[]]   # called first in Test-EnvValues
Get-StackPreflightErrors [-EnvValues] [-ComposeFiles] [-SolutionFolder] [-ProjectName] -> [string[]]
Get-StackPreflightWarnings [-EnvValues] [-ComposeFiles] [-SolutionFolder] -> [string[]]
Invoke-Preflight [...] [-SolutionFolder <string>]
```

Rules and message heads (each message names its fix):
- `Test-StackRoleValues`:
  - `STACK_ROLE` is valid (`Get-StackRole`).
  - platform: `SERVICES_FOLDER` is set; `PLATFORM_HOSTNAME` matches `^[a-z0-9]([a-z0-9-]*[a-z0-9])?\.dev\.internal$`; `DB_NAME` matches `^[A-Za-z0-9_]+$`; `SEARCH_SCOPE` matches `^[a-z0-9][a-z0-9_-]*$`; `REDIS_DATABASE`, when set, is an integer 0–15; no services-owned key is present in the platform `.env` ("…would override the services stack's value…").
- `Get-StackPreflightErrors`, services stack, S18 (P17): `SERVICES_NETWORK_NAME` is empty in the `.env` start read and its server volumes exist → "The folder holds `<volume>` from a standalone start. Run ./remove.ps1 first, or use a fresh folder." Once the key is set, the volumes are its own.
- `Get-StackPreflightErrors`, platform stack:
  1. The services folder is a services stack that has been started (`Get-ServicesStackInfo`, `NetworkName` set): "… is not a services stack, or it has not been started yet. Start it first."
  2. S17: the stack uses Elasticsearch or Redis that the services stack doesn't run: "… Pass -skipElasticsearch, or add Elasticsearch to the services stack."
  3. `Get-ServicesHealthProblems` for the servers it uses.
  4. S9: `Get-IsolationConflicts`. P15: the stack uses Redis, `REDIS_DATABASE` is empty, and `Get-FreeRedisDatabase` is `$null` → "All 16 Redis databases of the services stack are used by registered stacks: <projects>. Remove one first."
  5. S18: `Get-StandaloneServerLeftovers`.
  6. S11: `PEER_PLATFORMS_FROM_SOURCE` names its own hostname, or the HTTPS dev certificate (`backend/certs/localhost.pem`) doesn't cover `PLATFORM_HOSTNAME`: "… Run: dotnet dev-certs https --clean, then dotnet dev-certs https --trust".
  7. An `EXTRA_CA_CERTS` file is missing.
- `Get-StackPreflightWarnings`: `PLATFORM_HOSTNAME` is not loopback → "Add this line to your hosts file: 127.0.0.1 <name>".
- `Get-RequiredPorts` skips the provider's port when `Shared`. `Get-ServiceUrls` lists neither Elasticsearch nor Kibana when `Shared`, and no platform for `services` (P13).

- [ ] **Step 1: Write the failing tests** for each rule above:
  - Docker calls are mocked (`Mock docker`, or `New-FakeCommand`).
  - The SAN check uses a certificate made in the test with `CertificateRequest` (SANs `localhost`, `*.dev.internal`): `mgmt.dev.internal` → true; `a.b.dev.internal` → false.
  - `Get-ComposeProjectArguments` for a platform stack is `-p tenant --project-directory <svc> --env-file <svc>/.env --env-file <tenant>/.env`.
  - S18 for a services stack: a server volume present with `SERVICES_NETWORK_NAME` empty → the error; the same with the key set → no error.
- [ ] **Step 2: Run** the Unit tier. Expected: FAIL.
- [ ] **Step 3: Implement.** `Invoke-Preflight` runs `Get-StackPreflightErrors` after the port checks. It passes `Get-ComposeProjectArguments` to `Get-ProjectPublishedPorts`.
- [ ] **Step 4: Run** the Unit tier. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/ tests/unit/ && git commit -m "Check services and platform stacks before start"`

### Task 8: `start.ps1` and `stop.ps1` per role

**Reads:** DESIGN §5, §6, S4–S6, S8, S10–S12, S14, S19, §15.4, §15.5; this plan P3, P6, P10, P12, P13, Review Focus 5.

**Files:** Modify `start.ps1`, `stop.ps1`, `scripts/https-certs.ps1` (`Get-CertsVolumeName`), `tests/unit/StartScript.Tests.ps1`, `tests/unit/Start.Tests.ps1`, `tests/compose/ScriptBehaviour.Tests.ps1`.

**Interfaces — Produces:**
```powershell
Get-CertsVolumeName [-Document] [-SolutionFolder] [-EnvValues <IDictionary>]   # platform role: EnvValues['SERVICES_CERTS_VOLUME']
Get-RunningStackProjects [-Registrations] <pscustomobject[]> -> [string[]]     # in shared-services.ps1; non-stale with running containers
Get-PlatformPublicUrl [-EnvValues] <IDictionary> [-ComposeFiles] <string[]> -> [string]   # platform: https://<PLATFORM_HOSTNAME>:<port>; else the Platform service URL
# stop.ps1 param adds [switch]$ignoreStacks
```

start, in order, for a platform stack (the services role and standalone skip what doesn't apply):
1. Migrate.
2. `Update-EnvForRole`, which fills an empty `COMPOSE_FILE` (P16).
3. `Update-EnvFromOptions`.
4. When the stack uses Redis and `REDIS_DATABASE` is empty: `Get-FreeRedisDatabase` (P15). A `$null` result is left to preflight.
5. `Sync-PlatformComposeFiles`.
6. Write the peer and extra-CA files.
7. `Update-ComposeFileList` with `-Role`, `-ServicesAnchor`, `-GeneratedFiles`.
8. Preflight. Then print the warnings.
9. A services stack: `Set-ServicesStackKeys` (P17). Write `.env`. A platform stack: `Write-StackRegistration`.
10. `Sync-DevCertificate` into `SERVICES_CERTS_VOLUME` with `-ProjectName <services project>` (P6).
11. Source platform:
    - the Host settings take the CA fingerprint read in the services folder (`Push-Location` around `Get-ElasticsearchCaFingerprint`, S14);
    - the bridge listener runs whenever a platform stack runs a platform from source (S8).
12. `up -d --remove-orphans`, unless no service is listed (P12).
13. Readiness on `localhost` (S19).
14. Print `Get-PlatformPublicUrl` and the hosts line.

A services stack skips steps 4–6 and 10–11, and lists no platform.

- [ ] **Step 1: Write the failing tests** (the `StartScript` fake-command style):
  - a services start runs `up` and never waits for a platform. It writes `SERVICES_NETWORK_NAME` only when preflight passed: a failing preflight leaves the key empty (P17);
  - a platform start fills an empty `REDIS_DATABASE` with the lowest free index and registers it;
  - a platform start writes `COMPOSE_PROJECT_NAME`, registers, syncs into `svc_certs` labelled with project `svc`, and prints `https://tenant.dev.internal:8091`;
  - a platform stack with a source platform and no storefront skips `up` (P12);
  - `stop -ignoreStacks` on a services stack with a running registered stack calls `down`; without it, stop exits 1 naming the stack;
  - **Review Focus 5:** stop on a platform `.env` without `COMPOSE_PROJECT_NAME` exits 1 and calls nothing.
- [ ] **Step 2: Run** the Unit tier. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `-Tier All`. Expected: PASS.
- [ ] **Step 5: Live, postgres.** Build a scratch services folder (`STACK_ROLE=services`, postgres, HTTPS, Elasticsearch, Redis), then two platform folders `mgmt` (`-skipElasticsearch`) and `tenant`. `build` and `start` each. Expected:
  - both platforms are healthy;
  - `docker network inspect svc-shared` lists `vc-db`, `es`, `redis` and both platforms, and no Kibana or es-setup;
  - `stacks/` holds `mgmt.json` and `tenant.json`.
- [ ] **Step 6: Stop and report.**
  - **§15.5:** `psql -l` in `vc-db` lists `VirtoCommerce_mgmt` and `VirtoCommerce_tenant`.
  - **P15:** `redis-cli -a "$REDIS_PASSWORD" -n <n> exists VirtoCommerce-Keys` returns `1` in each platform's `REDIS_DATABASE`. With both indexes ≥ 1 it returns `0` in database 0.
  - **§15.4:** in the services folder run `docker compose down` while `tenant` runs. Record the exit code and message, and make the S12 stop guard's message consistent with them. Restart.

  Report if the database isn't created, a platform's key ring lands outside its database, or `down` breaks the attached platform's network in a way the guard can't prevent.
- [ ] **Step 7: Commit:** `git add start.ps1 stop.ps1 scripts/ tests/ && git commit -m "Start and stop services and platform stacks"`

### Task 9: `remove.ps1` per role

**Reads:** DESIGN S10, S12, anti-goal 3; this plan P8, P9, P10, Review Focus 3–5.

**Files:** Modify `remove.ps1`, `scripts/compose-files.ps1` (`Get-RemovalPlan`, `Get-KeepDataDeletePaths`), `scripts/shared-services.ps1`, `tests/unit/Remove.Tests.ps1`, `tests/unit/RemoveScript.Tests.ps1`, `tests/unit/SharedServices.Tests.ps1`.

**Interfaces — Produces:**
```powershell
Get-RemovalPlan [-Folder] [-KeepData] -> adds Role, ServicesFolder, DropDatabase (name or $null), DropIndexScope (or $null), Unregister (bool)
  # platform: Volumes = <prefix>_cms-content-data, _assets-data, _modules-data (never server volumes or certs); Images as today
  # services: Images empty; -keepData keeps stacks/ beside .env
Select-StackIndexNames [-Scope] <string> [-Aliases] <hashtable> [-IndexNames] <string[]> -> [string[]]
  # P8, pure. Aliases: index name -> alias names (from GET /_alias). Scope lowercased and [regex]::Escape'd.
Remove-StackSearchIndexes [-EnvValues] <IDictionary> [-Scope] <string> -> [string]   # $null on success, else the reason
  # https|http://localhost:<ES_PORT>, user elastic, ELASTIC_PASSWORD, -SkipCertificateCheck; GET /_alias, GET /_cat/indices?format=json&h=index,
  # then DELETE /<name> one by one
Remove-StackDatabase [-ServicesFolder] <string> [-Provider] <string> [-DbName] <string> -> [string]   # $null on success
  # DbName must match ^[A-Za-z0-9_]+$ (throws otherwise). docker compose exec -T vc-db sh -c '<cmd>' in the services folder; the password from the container env:
  #   postgres:  psql -U postgres -c 'DROP DATABASE IF EXISTS "<db>" WITH (FORCE)'
  #   mysql:     mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e 'DROP DATABASE IF EXISTS `<db>`'
  #   sqlserver: /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -Q "IF DB_ID('<db>') IS NOT NULL BEGIN ALTER DATABASE [<db>] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [<db>] END"
# remove.ps1 param adds [switch]$ignoreStacks
```

Order for a full platform remove:
1. Guards: the `COMPOSE_PROJECT_NAME` check (Review Focus 5), then P9.
2. Confirm.
3. `down -v --remove-orphans`.
4. Indexes, when the stack uses Elasticsearch.
5. The database.
6. Volumes, then images.
7. `Remove-StackRegistration`.
8. The folder.

Any failure keeps `.env` and the registration, with the existing leftovers message. A services remove refuses while non-stale registrations exist, unless `-ignoreStacks`, and names them. Stale ones are listed and go with `stacks/`.

- [ ] **Step 1: Write the failing tests:**
  - **Review Focus 3:** `Select-StackIndexNames 'tenant'` over aliases `tenant-product-active→tenant-product-ab12cd34ef`, `tenant-2-product-active→tenant-2-product-zz99yy88xx`, and indexes including the orphans `tenant-product-0123456789`, `tenant-2-membership` and `tenant-member` returns exactly `tenant-product-ab12cd34ef`, `tenant-product-0123456789`. `tenant-member` is not returned: `member` is not among `tenant`'s alias doc types.
  - A platform plan never lists `postgres_data`, `esdata01` or `certs` volumes.
  - The services `-keepData` plan keeps `stacks/`.
  - A platform full remove with the services stack stopped exits 1 before `down`. With the services folder deleted, it proceeds, warns, and skips the index, database and unregister steps (P9).
  - **Review Focus 4:** a services remove with only a stale registration proceeds.
  - `Remove-StackDatabase` throws for `DbName` `a;b`.
- [ ] **Step 2: Run** the Unit tier. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `-Tier All`. Expected: PASS.
- [ ] **Step 5: Live, stop and report (§15.6).** In the Task 8 scratch set:
  1. Index once in both platforms.
  2. Fully remove `tenant`. Expected: the `tenant-*` aliases and indexes are gone; `mgmt` is healthy and its database is intact; `stacks/` holds only `mgmt.json`.
  3. Report if Elasticsearch 9.5 refuses deletion by exact name under `action.destructive_requires_name`.
- [ ] **Step 6: Commit:** `git add remove.ps1 scripts/ tests/ && git commit -m "Remove services and platform stacks without touching another stack's data"`

## Phase C — Build, install and source platforms

### Task 10: `build.ps1` and the installer per role

**Reads:** DESIGN S1, S2, S5(a), S18; this plan P13, P14, P16, P17.

**Files:** Modify `build.ps1`, `scripts/payload.ps1`, `scripts/options.ps1`, `tests/unit/BuildScript.Tests.ps1`, `tests/unit/Install.Tests.ps1`, `tests/unit/Payload.Tests.ps1`.

Changes:
- `build.ps1`:
  - `Update-EnvForRole` runs before `Update-EnvFromOptions` (P16);
  - services: no channel check, no vc-build, no images, then "Start now?" (P13);
  - platform with an empty `COMPOSE_FILE` after the role update: exit 1 with `Test-StackRoleValues`' message about the services folder.
- `Invoke-PayloadInstall`:
  - step 2 adds missing keys with `-ExcludeKeys (Get-ServicesOwnedKeys)` for a platform `.env`;
  - step 4 fills secrets only outside the platform role;
  - `Update-EnvForRole` runs after step 4, before step 5's switches, so a platform list exists and nothing is deferred;
  - it never writes the P5 keys (P17);
  - step 7 skips the vc-build question for services (P14).

- [ ] **Step 1: Write the failing tests:**
  - installing over a `.env` holding only `STACK_ROLE=platform`, `SERVICES_FOLDER=../svc` (a started services fixture), with `-skipElasticsearch -nonInteractive`:
    - no secret and no services-owned key is written; `COMPOSE_PROJECT_NAME` is written;
    - `COMPOSE_FILE` starts with `../svc/docker-compose.yml`, holds `platform.yml` and `frontend.yml`, and holds no `shared-elasticsearch.yml`;
    - no provider prompt;
  - a services install leaves `SERVICES_NETWORK_NAME` empty;
  - a services install never asks for `RELEASE_CHANNEL` and never calls vc-build;
  - `build.ps1` for services makes no `docker build` call.
- [ ] **Step 2: Run** the Unit tier. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Unit tier. Expected: PASS.
- [ ] **Step 5: Commit:** `git add build.ps1 scripts/ tests/unit/ && git commit -m "Build and install services and platform stacks"`

### Task 11: Platforms from source in a platform stack

**Reads:** DESIGN S8, S14, §5 (*From source* row); env-first plan P9; `scripts/source-mode.ps1` `Get-DockerBridgeBindAddress`, `Get-ElasticsearchCaFingerprint`.

**Files:** Modify `start.ps1`, `scripts/settings-file.ps1`, `tests/unit/StartScript.Tests.ps1`, `tests/unit/SettingsFile.Tests.ps1`.

- [ ] **Step 1: Write the failing tests:**
  - a platform stack's Host settings read the services ports from `Get-StackEnvTable` (`localhost:6380` for `REDIS_PORT=6380` in the services `.env`), with `Database=VirtoCommerce_tenant` and the scope and channels;
  - start asks `Get-DockerBridgeBindAddress` for a platform-stack source platform without a storefront;
  - `Get-ElasticsearchCaFingerprint` runs with the services folder as the location.
- [ ] **Step 2: Run** the Unit tier. Expected: FAIL.
- [ ] **Step 3: Implement** whatever Task 8 left of these rules (Task 8's start step 11 wires the calls; this task pins the Host topology).
- [ ] **Step 4: Run** the Unit tier. Expected: PASS.
- [ ] **Step 5: Live, stop and report (§15.2, this machine's Docker).**
  1. Switch the Task 8 `mgmt` to `PLATFORM_SOURCE_PATH`, and list `mgmt.dev.internal` in `tenant`'s `PEER_PLATFORMS_FROM_SOURCE`.
  2. Restart both.
  3. From the `tenant` container: `openssl s_client -connect mgmt.dev.internal:<port> -verify_return_error -verify_hostname mgmt.dev.internal -CAfile /usr/local/share/start-local-ca/<the mounted file>`. Expected: `Verify return code: 0`. (`-CApath` would need hashed file names.)

  Report on failure. The other Docker flavour is F1.
- [ ] **Step 6: Commit:** `git add start.ps1 scripts/ tests/unit/ && git commit -m "Run platforms from source in platform stacks"`

### Task 12: Smoke lane and README

**Reads:** DESIGN §6, §6a, §8 (*Smoke*), §9, §11; `tests/smoke/Invoke-Smoke.ps1`, `tests/smoke/_smoke.ps1`; README sections *Configuration*, *Run from source*, *Uninstallation*.

**Files:**
- Create: `tests/smoke/Invoke-SharedSmoke.ps1`
- Modify: `.github/workflows/smoke.yml` (a `shared` job on `ubuntu-24.04`), `README.md`

- [ ] **Step 1: Write `Invoke-SharedSmoke.ps1`**, reusing `_smoke.ps1`'s helpers:
  - services: postgres, HTTPS, Elasticsearch, Redis;
  - `mgmt` with `-skipElasticsearch`, and `tenant`, both with `EXTRA_CA_CERTS=<repo>/…/backend/certs/localhost.pem`;
  - `install -nonInteractive` and `start` each.
- [ ] **Step 2: Assert in the script:**
  - both platforms answer `/health` on `localhost`;
  - from `tenant`, `openssl s_client -verify_return_error -verify_hostname mgmt.dev.internal -CAfile <the mounted EXTRA_CA_CERTS file>` to `mgmt.dev.internal:<port>` returns `Verify return code: 0`;
  - a full remove of `tenant` leaves `mgmt` healthy and `VirtoCommerce_mgmt` present.

  Exit 1 on any failure.
- [ ] **Step 3: Write the README:**
  - a "Shared services" section: roles, the §6 setup, the hosts line, version alignment of the two payloads;
  - the new keys in the `.env` key table (§6a);
  - the run-from-source note (S8, `PEER_PLATFORMS_FROM_SOURCE`);
  - the uninstall order (platform stacks first; `-ignoreStacks`).
- [ ] **Step 4: Run** `pwsh -NoProfile -File tests/smoke/Invoke-SharedSmoke.ps1` on this Linux machine. Expected: exit 0. The `openssl` step covers §15.1 short of .NET (F3).
- [ ] **Step 5: Commit:** `git add tests/smoke/ .github/workflows/smoke.yml README.md && git commit -m "Add the shared-services smoke lane and document stack roles"`

## Amendments
