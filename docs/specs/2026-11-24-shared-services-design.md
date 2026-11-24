# Shared services: one set of servers for several start-local stacks — design

**Status:** living draft (2026-11-24), no plan yet. Once a plan is drawn against it, this document becomes historical: corrections go in a dated *Amendments* section, with the original text left intact.
**Decisions:** S1–S19 below (§4); S18 and S19 are the designer's calls, the rest settled with the user. Decisions of the env-first redesign are cited by their IDs from the [decision log](2026-10-15-redesign-decisions.md).
**Evidence:** no research note. The prior-art gate was waived by the user on 2026-11-24; the facts checked during the design session are listed in §13, and the open ones in §15.

## 1. Problem

Two or more start-local folders today are two fully isolated stacks: each runs its own database server, Elasticsearch, Kibana and Redis next to its own platform and storefront. Every extra stack pays for another set of servers (Elasticsearch alone is `ES_MEM_LIMIT=1g`), and the user changes every port by hand in `.env`.

The first use is testing RND-167 locally: a **management** stack (platform + the VirtoOZ Management module, "platform as SaaS") and one or more **tenant** stacks (platform + the AI module). The tenant's AI module calls Management's onboarding API, and Management keeps the tenant's OAuth credentials and calls back. The registry spec identifies a tenant by its `PlatformUrl`, compared as a string (vc-module-virtooz-management, `docs/specs/2026-05-14-subscription-and-tenant-registry.md`, L8/L9, D-8): **each platform must have one URL that every caller uses, byte for byte**, the developer's browser included.

## 2. Goals, non-goals, anti-goals

**Goals**

- One **services stack** runs the database server, Elasticsearch, Kibana and Redis for any number of **platform stacks**; each platform stack keeps its own platform, modules and storefront.
- Every run style works in a platform stack: Docker platform, Docker platform with modules from source (`MODULE_SOURCE_PATHS`), platform from source (`PLATFORM_SOURCE_PATH`), in any mix across stacks.
- Each platform has one URL, `https://<name>.dev.internal:<PLATFORM_PORT>`, valid from the browser, from other platforms in Docker and from platforms run from source, with certificate validation on (HTTPS is required: some RND-167 endpoints are HTTPS-only).
- Standalone mode, one folder with its own servers, stays as it is for existing folders.

**Non-goals**

- VirtoOZ itself (the standalone Python app).
- Several services stacks shared by one platform stack, or one platform stack mixing its own servers with shared ones (for example its own Redis and the shared database). Using only some of the shared servers is a goal (S17).
- Editing the user's hosts file, DNS or trust stores (E5 extends to these).

**Anti-goals** (a failure even if everything starts)

- Two platforms writing to the same database, index prefix or cache channel. This corrupts data without any error, so start refuses it (S9).
- Anything listening beyond `BIND_ADDRESS` (default `127.0.0.1`), apart from the docker0 listener of S8, which the user ruled Docker's concern. The project moved that default from `0.0.0.0` deliberately. Reach from the same machine is wanted; reach from other machines is not.
- A platform stack's `remove` deleting the services stack's data.

## 3. Approach

The services stack's servers join one extra Docker network, the **shared network**. A platform stack attaches its platform container to it and reaches the servers by their usual service names (`vc-db`, `es`, `redis`). Platforms reach each other on the same network by a name ending in `.dev.internal`, which the .NET 10 development certificate already covers, on the same port inside and outside the container. The developer adds one hosts line per name pointing at `127.0.0.1`, so the browser and platforms run from source use the same URL through the published port.

```
your machine
├─ 127.0.0.1:<ports>  ◄── browser, platforms from source (hosts: <name>.dev.internal → 127.0.0.1)
│
├─ services stack ─────────────── shared network "<services project>-shared"
│    vc-db, es, redis ──────────┤     (Kibana and es-setup stay off it)
│                               │
├─ platform stack "mgmt" ───────┤ vc-platform-web, alias mgmt.dev.internal, listens on PLATFORM_PORT
│    vc-frontend (own network)  │
└─ platform stack "tenant" ─────┘ vc-platform-web, alias tenant.dev.internal
     vc-frontend (own network)
```

### 3.1 Approaches considered

| | How a Docker platform reaches servers and peers | Verdict |
|---|---|---|
| **A. Host network** | `network_mode: host`; everything at `localhost:<port>` | One URL everywhere, but needs Docker Desktop's "Enable host networking", which is off by default and incompatible with Enhanced Container Isolation. Rejected by the user for that reason. Its one confirmed finding: Kestrel's `+:8080` would listen on every host interface, since published ports are ignored in host mode. |
| **B. Host gateway** | `host.docker.internal:<published port>` | URL differs between callers (`host.docker.internal` vs `localhost`). On native Docker Engine the servers must also publish on the docker0 address, which the LAN can reach by direct routing and which Docker's NAT lets bypass ufw (confirmed, 8/10). Rejected. |
| **C. Shared bridge** (chosen) | servers by service name, peers by alias on a shared network | No listener beyond `BIND_ADDRESS`; no confirmed security finding. Plain C gives peers a Docker-only name; S6–S8 turn that name into the one URL. |

Three naming variants were weighed for the one URL: a forwarder that makes `localhost:<port>` work inside every container (one more container per stack; browsers share cookies across ports of one host), `*.dev.localhost` names (RFC 6761 makes `*.localhost` loopback, and .NET is adopting that behaviour, dotnet/runtime#128068, so the name may never reach the alias inside a container), and the user's own domain (needs a certificate). `.dev.internal` needs neither a certificate nor a forwarder, and `.internal` is reserved by ICANN for private use, so a missing hosts line can't leak traffic to a public site.

## 4. Decisions

| # | Decision |
|---|---|
| S1 | **Three roles, one `.env` key.** `STACK_ROLE` is empty (standalone, today's behaviour), `services` or `platform`. Existing folders stay standalone. |
| S2 | **A services stack** lists the database provider, Elasticsearch, Kibana, Redis and HTTPS in `COMPOSE_FILE`, never `platform.yml` or `frontend.yml`, and adds a new catalog file that attaches `vc-db`, `es` and `redis` to the shared network. It needs no release channel and no platform image. |
| S3 | **The shared network** is named `<services project name>-shared` with a fixed `name:`, created by the services stack's Compose project. The project name comes from `Get-SolutionProjectName` on the services folder. |
| S4 | **A platform stack points at its services stack with `SERVICES_FOLDER`** (absolute, or relative to the platform stack's folder). It lists the platform and storefront files but no provider, Elasticsearch, Kibana or Redis file. Its platform joins the shared network as `external`. No `depends_on` crosses projects; the services stack's health is a preflight check (S11). |
| S5 | **`COMPOSE_FILE` stays the stack definition (C3, H9); the services stack's `.env` is read in place.** A platform stack's `COMPOSE_FILE` lists one **shared link file** per server it uses: a provider-specific database link (so the provider is still inferred from the file list, C3), and optional Elasticsearch and Redis links (S17). They carry the wiring today's `platform-*` links carry, minus the cross-project `depends_on`, plus the external certificates volume. **The services stack's `.env` is read in place, never copied:** the platform stack's `COMPOSE_FILE` starts with a file from the services folder (the one declaring the external shared network). Compose then treats the services folder as the project directory and loads its `.env` as a second env file at lower precedence ([variable interpolation](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/): "Compose loads a second `.env` file… This second `.env` file has a lower precedence"; verified on Compose 5.7.1, 2026-11-24). Consequences: (a) the platform stack's `.env` must not hold the services stack's keys (`DB_PASSWORD`, `REDIS_PASSWORD`, `ELASTIC_PASSWORD`, the server ports, `STACK_VERSION`), since its own values would win, so secret filling skips them in this role; (b) the scripts write `COMPOSE_PROJECT_NAME` into the platform stack's `.env`, else the project takes the services folder's name; (c) relative paths in the compose files a platform stack lists resolve against the services folder, so those files use none (the plan audits them); (d) the shared network's and the certificates volume's names can't come from the services stack's `COMPOSE_PROJECT_NAME` / `VOLUME_PREFIX`, which the platform stack's own values shadow (or which are empty), so the services stack's scripts write both resolved names into its `.env` under keys of their own, which only the services stack sets. Start keeps the database link matching the services stack's provider and the HTTPS mode matching the services stack's, as `-dbProvider` does today. `Get-PlatformSettings` reads both files the same way, so it stays the single source of the platform settings (the drift test holds), and plain `docker compose up` works in the platform folder with current values. |
| S6 | **Each platform has a name**, `PLATFORM_HOSTNAME`, default `<project name>.dev.internal`, a single label before `.dev.internal` (the certificate's wildcard covers one label). It is the platform's alias on the shared network. |
| S7 | **The platform listens on `PLATFORM_PORT` inside its container too**, in every role, departing from the fixed container ports of the env-first SPEC §6: `ASPNETCORE_URLS`, the port mapping (`${BIND_ADDRESS}:${PLATFORM_PORT}:${PLATFORM_PORT}`), the health check and the storefront's upstream follow it. One port per platform makes `https://<name>.dev.internal:<PLATFORM_PORT>` mean the same from every caller. |
| S8 | **Peers run from source are reached through the host.** A platform stack whose platform runs in Docker lists, in `PEER_PLATFORMS_FROM_SOURCE` (`;`-separated), the `PLATFORM_HOSTNAME`s of the other platforms it calls that run from source; each becomes `extra_hosts: <name>:host-gateway` on its platform container. The user writes it only for that combination; every other combination works with the key empty (a Docker peer resolves on the shared network; a caller run from source uses the hosts line). Docker Desktop forwards `host-gateway` to the host's loopback; native Engine sends it to the docker0 address, so **a platform run from source in a platform stack always also listens on the docker0 address** (the existing `Get-DockerBridgeBindAddress` mechanism, `$null` on Docker Desktop). It can't know which callers list it, and the user ruled the reach of docker0 from the LAN a matter of Docker and the user's network, not start-local's (2026-11-24). Chosen by the user over a forwarder container; the trade-off is that switching a peer between Docker and source means updating the callers' `PEER_PLATFORMS_FROM_SOURCE` and restarting them. |
| S9 | **Per-stack isolation keys:** `DB_NAME` (database), `SEARCH_SCOPE` (`Search:Scope`, the index prefix), `REDIS_CHANNEL` (both `Caching:Redis:ChannelName` and `PushNotifications:RedisBackplane:ChannelName`). Standalone keeps today's values (`VirtoCommerce3`, the platform defaults); a platform stack's defaults derive from its project name. Start refuses a platform stack whose `DB_NAME`, `SEARCH_SCOPE`, `REDIS_CHANNEL`, `PLATFORM_HOSTNAME`, `PLATFORM_PORT`, `FRONTEND_PORT` or `VOLUME_PREFIX` equals another registered stack's, or whose `VOLUME_PREFIX` equals the services stack's. |
| S10 | **Registry.** Each platform stack writes one file per stack into the services folder (`stacks/<project>.json`: folder and the S9 values) at start, and removes it on a full remove. The S9 check, the lifecycle guards (S12) and the hosts-line hint read it. An entry whose folder no longer exists is reported and ignored, not trusted. |
| S11 | **Preflight in a platform stack** adds: the services folder exists and is a services stack; its servers are running and healthy; the S9 uniqueness; the exported development certificate covers `PLATFORM_HOSTNAME` (SDK 10+ certificates carry `*.dev.internal`; older ones get a message naming `dotnet dev-certs https --clean` + `--trust`); `PLATFORM_HOSTNAME` resolves to a loopback address on the host, else a warning that prints the hosts line to add. |
| S12 | **Lifecycle.** A services stack's `stop` refuses while a registered stack's containers are running; its full `remove` refuses while the registry lists any stack, running or not (a stopped stack has no containers, since `stop` is `compose down`, but its database lives on the services stack). Both name the stacks, and a switch overrides. The services stack's `remove -keepData` keeps the registry with `.env`. A platform stack's full `remove` drops its database and its indexes (aliases and indexes named `<SEARCH_SCOPE>-*`, listed first, then deleted by name) and unregisters; `-keepData` keeps all three. A platform stack's removal plan never lists server volumes. |
| S13 | **Trust.** A platform container trusts the services stack's Elasticsearch CA (the services stack's certificates volume, mounted read-only as `external`) and the CAs listed in a new `EXTRA_CA_CERTS` key (`;`-separated files, joined to `SSL_CERT_DIR`). This covers a development certificate issued by a local CA, as on the user's machine, and replaces the cloud routine's hand-written `ca.yml`. A plain SDK development certificate is self-signed and trusted the same way through its own file. |
| S14 | **Platforms from source in a platform stack** use the Host topology unchanged: the services stack's published ports on `localhost`, and the Elasticsearch CA fingerprint read from the services stack's project. |
| S15 | **Off the shared network:** storefronts, Kibana and es-setup. The storefront reaches its own platform on its stack's private network as today. The platform's service-name alias on the shared network is switched off where Compose supports it (`use_service_name_alias: false`, Compose 5.7+); older Compose leaves `vc-platform-web` resolving to several containers there, which nothing on that network looks up. |
| S16 | **Everything listens on `BIND_ADDRESS`.** No role adds a listener outside it, apart from S8's docker0 listener on native Engine; a Compose-tier test asserts every published port of every role follows a non-default `BIND_ADDRESS`. |
| S17 | **A platform stack uses a subset of the shared servers.** The database is always used; Elasticsearch and Redis follow the platform stack's own `-skipElasticsearch` / `-skipRedis`, not the services stack's file list (RND-167: Management needs no Elasticsearch). Preflight refuses a platform stack that uses a server its services stack does not run. |
| S18 | **No role switch in place** *(designer's call)*. Start refuses `STACK_ROLE=platform` or `services` on a folder that still holds its own standalone server containers or volumes, naming them: the user starts from a fresh folder or runs `remove` first. This keeps `--remove-orphans` from stranding the old servers' data, and keeps a platform stack from silently starting on an empty database. Roles are set in `.env` before the first install, as `README` already describes for other keys. |
| S19 | **What `PLATFORM_HOSTNAME` drives** *(designer's call)*. In a platform stack: the alias (S6), `Assets:FileSystem:PublicUrl` and `Content:FileSystem:PublicUrl`, and the platform URL start prints. Start's readiness probe stays on `localhost`, so it does not depend on the hosts line. Standalone ignores the key. Consequence: in a platform stack, catalog and page images load in the browser only once the hosts line exists. Feeding a platform's own URL into module settings (the AI module's `platformUrl`) stays with the user. |

## 5. Run styles

| Platform runs | Reaches servers at | Reaches a peer at | Settings topology |
|---|---|---|---|
| Docker (with or without source modules) | `vc-db`, `es`, `redis` on the shared network | `https://<peer>.dev.internal:<peer port>`: the peer's alias (peer in Docker) or `host-gateway` (peer from source, S8) | Container, with the S9 keys |
| From source | `localhost:<services stack ports>` | the same URL through the hosts line and the peer's published port | Host (S14) |

## 6. Setting up the RND-167 pair (user view)

1. A services folder with `STACK_ROLE=services`; `start`.
2. Two platform folders with `STACK_ROLE=platform` and `SERVICES_FOLDER=../services`, each with its own `PLATFORM_PORT`, `FRONTEND_PORT` and `MODULE_SOURCE_PATHS` (Management also `-skipElasticsearch`); `build`, `start`. Only if a Docker platform calls one run from source: that one's name in the caller's `PEER_PLATFORMS_FROM_SOURCE`.
3. Once: `127.0.0.1 mgmt.dev.internal tenant.dev.internal` in the hosts file (start prints the line).
4. The browser, the tenant's AI module and Management all use `https://mgmt.dev.internal:<port>` and `https://tenant.dev.internal:<port>`.

### 6a. New `.env` keys

| Key | Role | Default | Decision |
|---|---|---|---|
| `STACK_ROLE` | all | empty (standalone); `services` or `platform` | S1 |
| `SERVICES_FOLDER` | platform | none, required | S4 |
| `PLATFORM_HOSTNAME` | platform | `<project name>.dev.internal` | S6, S19 |
| `PEER_PLATFORMS_FROM_SOURCE` | platform, Docker platform | empty | S8 |
| `DB_NAME` | standalone, platform | `VirtoCommerce3`; derived from the project name in a platform stack | S9 |
| `SEARCH_SCOPE` | standalone, platform | the platform default; derived in a platform stack | S9 |
| `REDIS_CHANNEL` | standalone, platform | `VirtoCommerceChannel`; derived in a platform stack | S9 |
| `EXTRA_CA_CERTS` | all | empty | S13 |

New platform settings, in the compose files and `Get-PlatformSettings` alike: `Search:Scope`, `Caching:Redis:ChannelName`, `PushNotifications:RedisBackplane:ChannelName`, the database name in the connection string, and `ASPNETCORE_URLS` on `PLATFORM_PORT` (S7).

## 7. Security

Threat model, as the user set it: exposure to other machines is the risk; exposure to other processes and containers on the same machine is wanted.

- The chosen approach publishes nothing new: the servers' ports stay where `BIND_ADDRESS` puts them, and the shared network is a Docker bridge that only attached containers reach (S16). The one addition is S8's docker0 listener, below.
- Every stack uses the servers' superuser accounts, as one stack does today; per-stack accounts are hardening, out of scope.
- S8 on native Engine relies on the existing docker0 listener of a platform run from source. The verification of option B found that an address on docker0 can be reached from the LAN by direct routing; for a listener of a host process, unlike a Docker-published port, a host firewall applies. The user accepted this as Docker's and the network's concern: docker0's private range is exposed to the same degree for any Docker setup. The comment on `Get-DockerBridgeBindAddress` ("not from the network") overstates this; correcting it is in §12.
- The services stack's certificates volume, CA key included, is mounted read-only into platform containers, as it is in a standalone stack today.

## 8. Testing

- **Unit:** the S9 uniqueness rules and their messages; the registry (write, read, stale entry); a platform stack's `.env` never gaining the services stack's keys (S5); the certificate SAN check; `PEER_PLATFORMS_FROM_SOURCE` → `extra_hosts`; the removal plan of each role (no server volumes in a platform stack); S17's subset rules; S18's refusal on a folder with standalone servers.
- **Compose:** `docker compose config` for a services stack and a platform stack (each provider, HTTP and HTTPS), on the current and the minimum Compose (2.18.0); every published port follows a non-default `BIND_ADDRESS` in every role; the platform's alias, port and `extra_hosts`; the settings drift test gains the platform-stack variant.
- **Smoke:** a services stack and two platform stacks on Linux: both platforms healthy, a call from one platform container to the other's `.dev.internal` URL with certificate validation, and a full remove of one platform stack leaving the other's data intact.

## 9. Compatibility

- Standalone folders: unchanged behaviour, apart from S7 (the platform's port inside the container becomes `PLATFORM_PORT`), which changes no published address.
- `PLATFORM_HOSTNAME`, `DB_NAME`, `SEARCH_SCOPE`, `REDIS_CHANNEL`, `EXTRA_CA_CERTS` are optional in standalone; `EXTRA_CA_CERTS` is useful there too.
- README, the `.env` key table, the run-from-source section and the uninstall section document the roles.

## 10. Left to the plan

File names of the new catalog entries, the registry file format, the switch name for S12, the exact preflight messages, and how `-skipPlatform`/`-skipFrontend` interact with roles.

## 11. Trade-offs

- **One hosts line per platform.** The price of one URL without a certificate or a forwarder; start prints it, and without it a platform stack's asset URLs (S19) don't load in the browser.
- **The services folder is the platform stack's project directory (S5).** It buys reading the services `.env` in place, with no copies and no stale values, at the cost of pinning `COMPOSE_PROJECT_NAME` and keeping relative paths out of the platform stack's compose files.
- **`PEER_PLATFORMS_FROM_SOURCE` is manual (S8).** Switching a peer between Docker and source means editing callers and restarting them.
- **Superuser accounts shared** across stacks (§7).
- **Certificate dependency.** `*.dev.internal` needs an SDK 10+ development certificate; S11 names the fix.

## 12. Follow-ups outside this design

- Correct the comment on `Get-DockerBridgeBindAddress` (scripts/source-mode.ps1:712-714) about reach from the network.
- The cloud routine's `ca.yml` (vc-module-virtooz-management) can move to `EXTRA_CA_CERTS` once S13 ships.

## 13. Checked during the design session (2026-11-24)

1. The stock .NET 10+ development certificate lists `localhost`, `*.dev.localhost`, `*.dev.internal`, `host.docker.internal` and `host.containers.internal` ([dotnet dev-certs](https://learn.microsoft.com/dotnet/core/tools/dotnet-dev-certs)). The user's development certificate (SDK 10.0.400) names `localhost`, `*.dev.localhost`, `*.dev.internal`, `host.docker.internal`, `host.containers.internal`; it is issued by a local CA (`/usr/local/share/ca-certificates/aspnet-dev-asvishnyakov.crt`), so a container must trust that CA. .NET builds the chain with the CA in `SSL_CERT_DIR` (no rehash needed); with only the leaf trusted it reports `PartialChain`. A self-signed development certificate in its own `SSL_CERT_DIR` folder builds too.
2. Two Compose projects on Docker Desktop 4.99 (engine 29.9.3) joined by an external network: a client container reached `https://mgmt.dev.internal:18443` through the alias with strict validation against the CA, failed without the CA, and the host reached the same URL through `127.0.0.1` (hosts line simulated with `curl --resolve`). The host's LAN address did not reach the `127.0.0.1`-published port.
3. Security review of A, B and C (`/security-review` method, six findings, each re-verified): confirmed A's all-interfaces Kestrel bind (9/10) and B's docker0 exposure on native Engine (8/10); nothing confirmed for C.
4. Docker Desktop host networking is off on the user's machine (`HostNetworkingEnabled: false`).

## 14. Facts carried from earlier work

`Search:Scope` (`Search__Scope`) sets the index prefix, with aliases `<scope>-<doctype>-active|backup`; `Caching:Redis:ChannelName` and `PushNotifications:RedisBackplane:ChannelName` (default `VirtoCommerceChannel`) set the Redis channels (vc-platform and vc-module-search sources, read 2026-11-24 before this session).

## 15. To verify while implementing

Each is a stop-and-report step in the plan: a failure goes back to this design.

1. A .NET client inside the platform image calling a peer's `.dev.internal` URL with `EXTRA_CA_CERTS` (§13 used curl in the container and .NET on the host). (S13)
2. A Docker platform calling a platform run from source through `extra_hosts: <name>:host-gateway`, on Docker Desktop and on native Engine. (S8)
3. An external network with `name:` and a service alias on Compose 2.18.0. (S3, S4, S6)
4. The services stack's `docker compose down` while another project's container is attached to the shared network: exit code and message. (S12)
5. A database named by `DB_NAME` that does not exist yet is created on the platform's first start, for PostgreSQL, MySQL and SQL Server. (S9)
6. Deleting indexes by name on Elasticsearch 9.5 with `action.destructive_requires_name` at its default. (S12)
7. `use_service_name_alias` takes effect on Compose 5.7+, and `docker compose config` succeeds with it on 2.18.0. (S15)
8. The second `.env` loaded through `COMPOSE_FILE`'s first entry, on Compose 2.18.0, Windows (`;` separator) and macOS. (S5)
9. What else the platform keeps in Redis beyond the two channels (distributed locks at startup or module install, cache keys): if keys are shared across platforms, S9 needs a key prefix or a Redis database index per stack. (S9, anti-goal 1)

## Amendments
