# Azure Managed Redis — Onboarding Root

Self-service onboarding for the Azure Managed Redis Terraform module. One
JSON file per instance, one PR per request, no shared file to
merge-conflict over — same pattern as the Valkey onboarding root, adapted
to Azure.

Template **0.5.0**, paired with redis module **v0.5.0**. 0.5.0 adds the
platform policy for HA and clustering per topology, the `high_availability`
and `clustering_policy` request fields, and consumer client guidance in the
intake schema. **Existing request files must state their current
clustering policy before this is applied** — see "Upgrading existing
caches to 0.5.0". 0.4.0 gives every
instance a second private endpoint in the other region (see "Private
endpoints in both regions"). 0.3.0 / module 0.3.0 moved environments into
this template (see "Environments are owned by this template"). See both
CHANGELOGs.

## How it works

1. **`config/onboarding-files-redis/default.json`** — global technical
   defaults, plus a `environments.<env>` block per environment
   (subscription, resource group, location, VNet/subnet, DR VNet/subnet).
   Maintained by the platform team, not by requesters. **Field names in
   this JSON are unchanged snake_case** (`deployment_topology`,
   `node_type`, etc.) — the kebab-case rename below is scoped to the
   Terraform variable/output surface only, not the request-file schema.
2. **`config/onboarding-files-redis/*.json`** (everything except
   `default.json`) — one file per onboarding request. A team opens a PR
   adding or editing exactly one file.
3. **`locals.tf`** merges default.json + the matching `environments.<env>`
   block + each request file, field by field, into a staging map whose
   keys match the redis module's kebab-case variable names 1:1 — then
   derives `dr-location` (from `dr_region_pairs`) and `tags`.
4. **`main.tf`** calls `module "redis"` once per resulting instance via
   `for_each`, passing that staging map through almost verbatim.

`terraform plan -var env=dev` (or `qa`/`uat`/`preprod`/`prod`) picks up
every request file targeting that environment automatically.

## Environments are owned by this template

The redis module (v0.3.0+) has no notion of environment. Everything
environment-specific lives here:

| What | Where |
|---|---|
| The list of environments: `dev`, `qa`, `uat`, `preprod`, `prod` | `variables.tf` (`env` validation) and the intake schema's `environment` enum |
| Subscription, resource group and network per environment and region | `default.json` → `environments.<env>` |
| Resource names: `<instance.name>-<env>` passed to the module as `name` | `main.tf` |
| Which environments are production-like (`preprod`, `prod`) | `locals.tf` → `_production_like_envs`, used by the `prod-should-not-be-standalone` check |
| `environment` tag | `locals.tf` Layer 4 |

The module then adds only fixed affixes, so a request named `orders-cache`
in `preprod` creates `orders-cache-preprod`, `orders-cache-preprod-dr`,
`pe-orders-cache-preprod`, `pe-orders-cache-preprod-dr`,
`lock-orders-cache-preprod`, and so on.

**Name length.** The module caps the full name at 57 characters (Azure's
60 minus `-dr`). The intake schema therefore caps `instance.name` at 49
characters, so `<name>-preprod` (the longest suffix) always fits, and the
`instance-name-fits-with-environment` check names any request that doesn't.

**Adding another environment** means: add it to the `env` validation in
`variables.tf` and to the schema's `environment` enum, add an
`environments.<env>` block to `default.json` (every region it will use),
add it to `_production_like_envs` if it's production-like, then create its
pipeline workspace with `env = <name>`. The module needs no change.

## Naming convention: kebab-case Terraform surface, unchanged JSON schema

The redis module's variables and outputs are all kebab-case as of v0.2.0
(`resource-group-name`, `node-type`, `redis-primary-id`, ...). This
template's own `locals.tf` Layer 3 builds a staging map with matching
kebab-case keys, so `main.tf`'s module call is close to a pass-through.

**Request-file JSON field names are deliberately NOT renamed** — they stay
`deployment_topology`, `node_type`, etc. Renaming those would ripple into
the wrapper-API mapping docs and every existing request file for no real
benefit; the translation from snake_case JSON to kebab-case Terraform
happens once, inside `locals.tf`, and nowhere else needs to know about it.

## Private endpoints in both regions — no toggle, no DNS zone

Every instance gets **two** private endpoints, one in each region: the
primary always, and the DR instance in DR topologies. This is the same
pattern as the org's PostgreSQL module (`-PE` / `-PE-DR` on the primary and
on every replica).

| Request (`orders-cache`, dev, East US 2) | Endpoints |
|---|---|
| STANDALONE / HA (2) | `pe-orders-cache-dev` (East US 2), `pe-orders-cache-dev-dr` (Central US) |
| DR-ActivePassive / DR-ActiveActive (4) | the two above + `pe-orders-cache-dev-drcache` (Central US) and `pe-orders-cache-dev-drcache-dr` (East US 2) for the DR instance |

The paired region comes from `dr_region_pairs`, and its resource group and
subnet from `environments.<env>.regions.<paired region>`, for **every**
request, not only DR topologies. A Central US request gets its second
endpoint in East US 2. There's no request field for any of this, and none
is needed. DNS must answer per region (Infoblox), as for PostgreSQL. **The module also no longer creates or links a private DNS
zone** — DNS resolution for these private endpoints is handled by
infrastructure automation outside Terraform (Infoblox). This template has
no DNS-related resources of its own either.

Because every request now uses the paired region, **every** environment
in `default.json` needs a `regions` entry for both regions of a pair. A
missing one fails the `dr-location-is-a-configured-region` check for any
request in that environment.

## Tags are preserved across updates (module-level, not template-level)

The redis module sets `lifecycle { ignore_changes = [tags] }` on every
taggable resource. This template's Layer 4 tag computation
(`local.redis[...].tags`) therefore only actually takes effect on an
instance's **first** apply — changing `application_id`/`lob`/`tags` in an
existing request file and resubmitting will not update that instance's
tags on Azure. See the module's README "Tags are preserved across
updates" for the full tradeoff and the manual workaround.

## Request file shape

See [`config/redis-intake-schema.json`](./config/redis-intake-schema.json)
for the full reference. Four working examples are in
[`config/onboarding-files-redis/`](./config/onboarding-files-redis/), one
per `deployment_topology`:

| File | `deployment_topology` |
|---|---|
| `test-standalone-cache.json` | `STANDALONE`, legacy pin `clustering_policy: NoCluster` (deployed before 0.5.0) |
| `test-standalone-ha-cache.json` | `STANDALONE` + `high_availability: true` + RDB persistence |
| `test-ha-cache.json` | `HA`, pin `clustering_policy: OSSCluster` (deployed before 0.5.0) |
| `test-dr-active-passive-cache.json` | `DR-ActivePassive` + `clustering_policy: OSSCluster` |
| `test-dr-active-active-cache.json` | `DR-ActiveActive` |
| `test-ha-modules-cache.json` | `HA` + all four Redis modules (see below) |

## High availability, DR and clustering policy

| `deployment_topology` | `high_availability` | `clustering_policy` (first = default) | DR | Geo-replication |
|---|---|---|---|---|
| `STANDALONE` | optional, default `false` | `EnterpriseCluster` | no | no |
| `HA` | always on (omit) | `EnterpriseCluster`, `OSSCluster` | no | no |
| `DR-ActivePassive` | always on (omit) | `EnterpriseCluster`, `OSSCluster` | yes | no |
| `DR-ActiveActive` | always on (omit) | `EnterpriseCluster`, `OSSCluster` | yes | yes |

- Fallback order for `clustering_policy`: request → `default.json`
  (`EnterpriseCluster`) → module topology default (`EnterpriseCluster`).
  RediSearch requests get `EnterpriseCluster` automatically.
- **HA off** = one node, about half the price, no SLA, no zone redundancy,
  no persistence, data lost on node failure or patching (dev/test).
  **HA on** = two nodes with primary + replica shards and automatic
  failover. `STANDALONE` + `high_availability: true` is allowed and may
  use persistence.
- **`EnterpriseCluster`**: any standard client, no code changes.
  **`OSSCluster`**: cluster-aware client, hash-slot rules for multi-key
  commands, ports 10000 + 8500–8599, per-shard DNS records — only for
  HA/DR. The exact changes per language are in the intake schema's
  `x-client-guidance` block, for the UI to show next to the choice.
- **Promotion** (`STANDALONE` in dev → `HA` in preprod/prod) is a new
  request in the higher environment. With `EnterpriseCluster` on both it
  needs no code change; only the hostname and key differ.
- Violations fail the plan in the module; these checks name the request:
  `standalone-is-enterprise-cluster-only`, `ha-only-optional-for-standalone`,
  `persistence-requires-ha`, `legacy-nocluster-only-standalone-25gb`,
  `redisearch-requires-enterprise-cluster`.
- **`clustering_policy` and `high_availability` are create-time only.**
  Changing `clustering_policy` on an existing cache fails the plan (the
  provider would otherwise wipe it); changing `high_availability`
  replaces the cache. Switching means a new request plus a data migration.

### Upgrading existing caches to 0.5.0

Before 0.5.0 the clustering policy came implicitly from the topology
(`STANDALONE` → `NoCluster`, `HA`/`DR-*` → `OSSCluster`), so existing
request files don't have `clustering_policy`. Under 0.5.0 they would
resolve to `EnterpriseCluster`; the redis module's guard then fails their
plan, which blocks the whole environment's workspace. **Before applying
0.5.0**, add the line below to each existing request's `instance` block.
It only states what the cache already has — nothing changes in Azure.

| Consumer | Environments | Topology | SKU | Add |
|---|---|---|---|---|
| Axios | dev, qa | HA | B1 | `"clustering_policy": "OSSCluster"` |
| IDAM authz | dev, qa | HA | B5 | `"clustering_policy": "OSSCluster"` |
| CodeReviewAgent | dev, prod | HA | B10 | `"clustering_policy": "OSSCluster"` |
| CWX AXP | qa, prod | HA | B3 | `"clustering_policy": "OSSCluster"` |
| NBA | dev | HA | B20 | `"clustering_policy": "OSSCluster"` |
| NBA | preprod | HA | B150 | `"clustering_policy": "OSSCluster"` |
| RedisML | dev | STANDALONE | B1 | `"clustering_policy": "NoCluster"` |
| CryptoAPI | qa | STANDALONE | B1 | `"clustering_policy": "NoCluster"` |
| Retail semantic | qa | STANDALONE | B10 | `"clustering_policy": "NoCluster"` |
| MacSpider | preprod, prod | STANDALONE | B0 | `"clustering_policy": "NoCluster"` |
| `test-ha-cache` (fixture) | dev | HA | B0 | already added |
| `test-standalone-cache` (fixture) | dev | STANDALONE | B0 | already added |

Then, per environment:

1. Run `terraform plan` for the environment.
2. Every existing cache must show **no changes**, and the plan **0 to
   destroy**. A "Clustering policy change blocked for <name>" error means
   that request is still missing its line.
3. Apply.

Never remove or filter out an existing request file to skip it:
Terraform then plans to **destroy** that cache.

`NoCluster` is legacy only: accepted when stated explicitly, only for
`STANDALONE` and SKUs of 25 GB or less, never offered in the intake.

**Follow-ups to raise with consumers (not part of this upgrade):**

- **NBA preprod** (HA, OSS, B150) has standalone-style client code. A
  plain client on an OSS cache fails for keys on other shards (`MOVED`).
  Recommended: a new HA + `EnterpriseCluster` cache (new request, ideally
  a new name), migrate, then delete the old request. Check NBA dev too.
- **MacSpider prod** is a single-node B0 cache in production (no replica,
  no SLA). Recommended: a new HA + `EnterpriseCluster` cache, migrate,
  retire the old one.
- **RedisML, CryptoAPI, Retail semantic, MacSpider** will land on
  `EnterpriseCluster` when they promote. Their connection code stays the
  same; multi-key commands other than DEL/MSET/MGET/EXISTS/UNLINK/TOUCH,
  `MULTI`/`EXEC` and multi-key Lua need their keys in one hash slot. Ask
  Retail semantic and RedisML whether they need vector search
  (RediSearch): it has to be chosen when the cache is created.

## Redis modules

A request can enable Redis modules with an optional `redis_modules` array,
plus optional per-module `redis_module_args`:

```json
"instance": {
  "name": "orders-cache",
  "deployment_topology": "HA",
  "node_type": "Balanced_B10",
  "redis_modules": ["RediSearch", "RedisJSON", "Bloom", "TimeSeries"],
  "redis_module_args": { "Bloom": "ERROR_RATE 0.01 INITIAL_SIZE 400" }
}
```

- **Names:** `RediSearch`/`Search`, `RedisJSON`/`JSON`,
  `RedisBloom`/`Bloom` and `RedisTimeSeries`/`TimeSeries`. Terraform
  accepts any letter case; the intake schema is case-sensitive. Omitting
  the field, or sending `[]` or `null`, means no modules.
- **No `default.json` default, by design.** Every other field falls back to
  `default.json`; modules deliberately don't. Modules are create-time only,
  so a platform-wide module default would destroy and recreate every
  existing cache in the environment that doesn't list its own modules.
- **Validation is enforced by the redis module** and fails the plan for:
  unknown names, duplicates (an alias counts as the same module),
  Bloom/TimeSeries with `DR-ActiveActive`, a module the `node_type` doesn't
  support (Flash tiers), and args for a module that isn't enabled. A
  malformed field (for example a string instead of an array) also fails
  the plan; it is never silently ignored.
- **Early warnings per request:** `locals.tf` adds `redis-modules-*` and
  `redisearch-requires-noeviction` check blocks that name the offending
  request file's instance, so a reviewer can see which request is wrong.
- **RediSearch** requires `NoEviction` eviction and `EnterpriseCluster`
  clustering. If a RediSearch request doesn't set `eviction_policy`, this
  template defaults it to `NoEviction` instead of `default.json`'s value.
  An explicit conflicting value is forced to `NoEviction` by the module,
  with a warning, and rejected by the intake schema.
- **Data-access grants:** on a cache with any module, Azure allows only
  full-access assignments (no read-only or limited ACLs).

> ⚠️ **Modules are create-time only.** Adding, removing or changing
> `redis_modules` / `redis_module_args` on an **existing** request
> destroys and recreates that cache, and all data is lost. Review every PR
> that touches these fields for `must be replaced` in the plan. The four
> original fixtures deliberately don't use modules, so already-deployed
> test caches are never replaced; module coverage lives in
> `test-ha-modules-cache.json`.

## Regions are first-class — any configured region works as primary OR DR

`default.json`'s `environments.<env>` has a `regions` map keyed by region
name (`eastus2`, `centralus`, ...), each with its own
`resource_group_name` and `networking` block. A request's `location` is
looked up against this map for **both** primary and DR — there's no
special-cased "primary uses one flat block, DR uses a different shaped
block" asymmetry any more. This means a client can request `centralus` as
their **primary** region (not just as a DR target) as long as
`environments.<env>.regions.centralus` exists in `default.json`.

**DR gets its own resource group**, matching the redis module's v0.2.4
production recommendation (one resource group per region, per Azure's
Cloud Adoption Framework guidance) — `dr-resource-group-name` is now
resolved from the DR region's own `regions` entry, not the primary's
resource group. This is a real change from earlier versions of this
template, which silently put DR in the same resource group as primary.

Two checks guard this:
- `location-is-a-configured-region` — the requested primary `location`
  must have a `regions` entry for this environment.
- `dr-location-is-a-configured-region` — same, for the derived DR
  location. This can fail even when `dr_region_pairs` (below) allows the
  pairing globally, if this specific environment hasn't been given
  `resource_group_name`/`networking` for that region yet — two separate
  facts (can these regions pair at all vs. does this environment have
  infra there) are checked separately, deliberately.

## DR region pairs

Pairs are listed in `default.json`'s `dr_region_pairs`, currently
`eastus2 <-> centralus`. They decide where the primary's second private
endpoint goes (every request) and where a DR instance goes (DR topologies).
A request in a `location` with no pair is reported by the
`dr-requires-supported-region-pair` check.

## Uniqueness is enforced, not just documented

The `request-names-unique-per-environment` check block fails plan if two
files targeting the same environment share an `instance.name`.

## Running it

```powershell
terraform init
terraform plan -var env=dev        # or qa / uat / preprod / prod
terraform apply -var env=dev
```

Each environment has its own pipeline workspace with `env` set; a
`preprod` workspace needs the preprod subscription's credentials, and the
`preprod` block in `default.json` must have real values (the shipped block
has `REPLACE-ME` placeholders for networking and a placeholder
subscription ID).
