# Terraform Module: Azure Managed Redis (instance)

Single, reusable Terraform module for an
[Azure Managed Redis](https://learn.microsoft.com/en-us/azure/redis/) (Redis
Enterprise-based) instance — sizing, HA, clustering policy, persistence, auth mode,
private endpoints in both regions, deletion protection, and optional DR
with active-active geo-replication.

Current module version: **0.5.0** — see [CHANGELOG.md](./CHANGELOG.md).
0.5.0 introduces the platform policy for HA and clustering per topology
(STANDALONE: HA optional, EnterpriseCluster; HA/DR: HA on,
EnterpriseCluster or OSSCluster) and a guard that fails the plan instead of
letting a clustering policy change wipe a cache. **Existing caches must
state the clustering policy they have today in their request** — see
"Upgrading existing caches to 0.5.0".
0.4.0 gives every instance a second private endpoint in the other region
(see "Private endpoints"). Existing STANDALONE/HA instances only gain that one
endpoint; nothing existing changes. 0.3.0 was breaking for callers only: the
`environment` input is gone and the caller passes the full name (see
"Naming: the caller owns environments"). If you're upgrading from 0.1.x, read the `0.2.0` entry in full too.

## Naming convention: hyphens, not underscores

Every variable, output, and local in this module uses kebab-case
(`resource-group-name`, `node-type`, `redis-primary-id`) rather than
snake_case. Hyphens are legal HCL identifier characters; this matches this
org's existing convention for auth variables in earlier module versions and
has been extended to the entire module. If you're writing a caller for the
first time, every argument name and output reference needs a hyphen where
you might reflexively type an underscore.

## This module does not configure the azurerm provider

There is no `provider "azurerm" {}` block anywhere in this module. A
reusable module should never dictate auth or subscription context to its
caller — that's the root module's job.

## Naming: the caller owns environments

This module has no notion of environment. The caller passes the full base
name, environment included (e.g. `orders-cache-dev`), and the module only
adds fixed affixes:

| Resource | Name |
|---|---|
| Primary cache | `<name>` |
| DR cache | `<name>-dr` |
| Private endpoints | `pe-<name>`, `pe-<name>-dr` (primary); `pe-<name>-drcache`, `pe-<name>-drcache-dr` (DR instance) |
| Private service connections | `psc-` + the same suffixes |
| Deletion locks | `lock-<name>`, `lock-<name>-dr` |

`name` must be lowercase letters, numbers and hyphens, start with a letter,
end with a letter or number, and be at most 57 characters (Azure's 60 minus
`-dr`). Which environments exist, and the rules that differ per environment
(for example warning on STANDALONE in production), live in the onboarding
template.

## node-type is required — no default

Unlike earlier versions, this module does **not** pick a default SKU for
you. `node-type` must always be supplied by the caller. Instance sizing is
a caller/template policy decision, not something this module should guess
at silently.

## Private endpoints

Same pattern as the org's PostgreSQL flexible-server module, which gives the
primary **and every replica** two endpoints (`<server>-PE` + `<server>-PE-DR`):
every instance gets an endpoint in **each** region.

| Endpoint | Points to | Sits in | Created |
|---|---|---|---|
| `pe-<name>` | Primary | Primary's region (`location`, `subnet-*`) | Always |
| `pe-<name>-dr` | Primary | Paired region (`dr-location`, `dr-subnet-*`, `dr-resource-group-name`) | Whenever `dr-location` is set, for **every** topology |
| `pe-<name>-drcache` | DR instance | DR region | DR topologies only |
| `pe-<name>-drcache-dr` | DR instance | Primary's region | DR topologies only |

| Topology | Endpoints (with `dr-location` set) |
|---|---|
| STANDALONE / HA | 2 |
| DR-ActivePassive / DR-ActiveActive | 4 |

- `-dr` at the end of an endpoint name means "sits in the other region", as
  in PostgreSQL's `-PE-DR`. The DR instance's endpoints use `drcache` so the
  names never collide with the primary's.
- Why the DR instance gets one in the primary's region: when only the
  primary **cache** fails (its region is still up), apps there switch to the
  DR instance and need a private path to it in their own region.
- Each `-dr` endpoint is created after its instance's first one
  (`depends_on`), as in the PostgreSQL module: two endpoint operations on the
  same resource at once can fail with "another operation is in progress".
- The paired-region endpoint gives clients in the paired region a private
  IP in their own region. Traffic still goes to the primary's region, so it
  adds cross-region latency and data-transfer cost, and it is **not**
  failover: if the primary's region is down, this endpoint can't reach it.
- `dr-location` must differ from `location`, and a paired-region subnet
  (`dr-subnet-id`, or `dr-subnet-name` + `dr-vnet-name` +
  `dr-vnet-resource-group-name`) is required whenever `dr-location` is set.
- Leaving `dr-location` null on a STANDALONE/HA instance keeps the old
  behaviour (one endpoint), so direct callers aren't forced to change. The
  onboarding template always sets it.
- DNS: two endpoints serve the same hostname with different private IPs.
  Infoblox must answer per region (each region's clients get their own
  region's IP), as it does for PostgreSQL.

## DNS is not this module's job

This module does **not** create or link a private DNS zone. Earlier
versions did (`privatelink.redis.azure.net`, with VNet links) — that's
removed. DNS resolution for the private endpoints this module creates is
handled by infrastructure automation outside this module (Infoblox). If
your environment doesn't have that automation in place, private endpoints
created by this module will not resolve for any client — confirm that's
wired up before deploying with this version.

## Tags are preserved across updates

Every taggable resource uses `lifecycle { ignore_changes = [tags] }`. Tags
are set once, on first create, and never modified by any later apply —
protecting tags set by automation outside Terraform (Infoblox, a
governance/policy tool) from being reverted on the next apply or patch.

**The real tradeoff:** this also means changing `tags` on an *existing*
instance and re-applying does nothing — Terraform won't even show a diff
for it. If you genuinely need to change an existing instance's tags, that
has to happen out-of-band (Azure Portal/CLI), or by temporarily removing
`ignore_changes = [tags]` for one apply.

## No submodules

Everything in this module lives in this one directory. The primary and
(optional) DR instance are two explicit `azurerm_managed_redis` resource
blocks in `main.tf`, not two calls into a shared internal module.

## Platform policy: topology, HA and clustering

```
deployment-topology       = "STANDALONE" | "HA" | "DR-ActivePassive" | "DR-ActiveActive"
high-availability-enabled = true | false          # STANDALONE only
clustering-policy         = "EnterpriseCluster" | "OSSCluster"
```

The topology decides HA, which clustering policies are allowed, DR and
geo-replication. Defined in `local.defaults.topology-profile`
(`all-locals.tf`):

| `deployment-topology` | HA | Clustering policy (first = default) | DR instance | Geo-replication |
|---|---|---|---|---|
| `STANDALONE` | **optional**, default off | `EnterpriseCluster` | no | no |
| `HA` | always on | `EnterpriseCluster`, `OSSCluster` | no | no |
| `DR-ActivePassive` | always on | `EnterpriseCluster`, `OSSCluster` | yes, not linked | no |
| `DR-ActiveActive` | always on | `EnterpriseCluster`, `OSSCluster` | yes | yes |

How an instance is resolved:

1. **HA**: `high-availability-enabled` if given, else the topology's value.
   `false` is only allowed for `STANDALONE`; anything else fails the plan.
2. **Clustering**: `clustering-policy` if given, else the topology's
   default (`EnterpriseCluster`). A value the topology doesn't allow fails
   the plan. RediSearch forces `EnterpriseCluster`.
3. **DR / geo-replication**: from the topology.

`NoCluster` is **legacy only** — see "Upgrading existing caches to 0.5.0".

### What the HA toggle means

Azure never shows "2 instances". It's one cache with one hostname; HA
decides what runs behind it.

- **HA on**: at least two nodes. Each shard has a primary on one node and
  a replica on another; Azure replicates and fails over automatically. In
  regions with availability zones the nodes are in different zones. Comes
  with the availability SLA. Azure's "PAYG Two Node" price; reservations
  exist only for this mode.
- **HA off** (`STANDALONE` default): one node, no replica, roughly half
  the price ("PAYG One Node"). No SLA, no zone redundancy, no persistence
  (the plan fails for HA off + RDB/AOF). If the node fails, or during
  Azure patching, the cache is unavailable and its data is lost.
  Dev/test only.
- **`STANDALONE` with HA on**: two nodes in one region, no DR — same
  shape as `HA` with `EnterpriseCluster`. Moving such a cache to the `HA`
  topology later changes nothing in Azure.
- **Changing HA on an existing cache replaces it** (new cache, new
  private endpoint, new keys, all data lost): `high_availability_enabled`
  is ForceNew in azurerm, even though Azure itself can turn HA on in
  place. The plan shows `must be replaced`.

### Does DR work without HA?

No — not in this module. `DR-ActiveActive` can't by Azure's rules (every
geo-replicated instance needs HA). `DR-ActivePassive` technically could,
because the two caches aren't linked, but the platform policy keeps HA on
for both: a node failure in the main region is far more likely than a
region outage, and a DR copy doesn't help with that.

### DR-ActiveActive vs. DR-ActivePassive

- **`DR-ActiveActive`**: primary and DR are linked with
  `azurerm_managed_redis_geo_replication`, giving live, bidirectional
  replication. Both caches must have HA on and identical SKU, clustering
  policy, eviction policy and modules (the module gives them the same
  values). Azure does **not** allow persistence on a geo-replicated
  database, so `persistence-mode` is automatically forced to `DISABLED` in
  this mode. Also requires a geo-replication-capable `node-type`
  (`Balanced_B10`+ or equivalent) — see the
  `geo-replication-requires-supported-sku` check.
- **`DR-ActivePassive`**: a DR instance is still provisioned, but Azure
  Managed Redis has no native "passive replica" concept — DR is a
  **standalone instance** you keep in sync yourself.

## Clustering policy

Every cache runs several Redis processes (**shards**); the SKU decides how
many — you never set a shard count. The clustering policy only decides
**how clients reach those shards**.

| | `EnterpriseCluster` (default) | `OSSCluster` (HA/DR opt-in) |
|---|---|---|
| How clients connect | One endpoint (`<name>.<region>.redis.azure.net:10000`); an Azure proxy routes each command to its shard | Client discovers the shards (`CLUSTER NODES`) and connects to each directly |
| Client library | Any standard Redis client — no code changes | **Must be cluster-aware** (Lettuce `RedisClusterClient`, Jedis cluster client, redis-py `RedisCluster`, node-redis `createCluster`, …) |
| Performance | Good; small extra hop through the proxy | Best throughput and latency |
| Multi-key commands | Across slots only `DEL`, `MSET`, `MGET`, `EXISTS`, `UNLINK`, `TOUCH`; `MULTI`/`EXEC`, multi-key Lua and others need one hash slot (`{hash-tags}`) | Every multi-key command, transaction and Lua script needs one hash slot |
| Network / DNS | Port 10000, one hostname | Ports 10000 **and 8500–8599**; per-shard hostnames must resolve to the private endpoint (Infoblox) |
| RediSearch | Required (forced automatically) | Not supported |
| Change after creation | Not possible — new cache | Not possible — new cache |
| Topologies | All | `HA`, `DR-ActivePassive`, `DR-ActiveActive` |

Why `EnterpriseCluster` is the default everywhere: a `STANDALONE` dev cache
and an `HA` prod cache then need the same client code, so promotion
(`STANDALONE` in dev → `HA` in preprod/prod) needs no code change.

What a consumer changes for each choice is spelled out for the intake UI
in the onboarding template's `config/redis-intake-schema.json`
(`x-client-guidance`).

### Changing the clustering policy of an existing cache

Treat the clustering policy as **create-time only**. The azurerm
provider (4.x) applies a change by **deleting the database and creating
it again — all data is lost — while `terraform plan` shows only
`~ update in-place`**. A reviewer looking for `must be replaced` would
never see it.

So the module guards against it:

1. Both cache resources have
   `ignore_changes = [default_database[0].clustering_policy]`, so Terraform
   never sends that change to the provider.
2. A postcondition compares the cache's **actual** policy with the
   requested one. On an existing cache they differ, so **the plan fails**,
   naming the cache and both values. A new cache is built from config, so
   it always passes.

To keep the cache: set `clustering-policy` (request field
`clustering_policy`) back to what it has. To change it on purpose:
back up or export the data, set `deletion-protection-enabled = false`,
keep the new value, run
`terraform apply -replace='<address of azurerm_managed_redis.primary>'`
(and `.dr[0]` for DR topologies), then reload the data and switch the
application's client mode (cluster-aware for OSSCluster, standard for
EnterpriseCluster).

The same "in-place in the plan, data wiped at apply" behavior applies to
`redis-modules` / `redis-module-args` and the geo-replication group —
see "Redis modules".

What a clustering policy change would do to an existing cache:

| | Through Terraform (azurerm 4.x) — blocked by the guard | Recreating the cache (`-replace`) |
|---|---|---|
| Data | All lost (database deleted and re-created) | All lost |
| Private endpoint / IP | Unchanged | Endpoint re-created; IP may change (Infoblox) |
| Access keys | New (keys belong to the database) | New |
| Client connections | Dropped | Dropped |
| Hostname | Unchanged | Unchanged (same name) |

### Upgrading existing caches to 0.5.0

Caches created before 0.5.0 got their clustering policy **implicitly** from
the old topology profile (`STANDALONE` → `NoCluster`, `HA`/`DR-*` →
`OSSCluster`); their request files have no `clustering_policy`. Under 0.5.0
they would resolve to `EnterpriseCluster`, the guard would fail their plan,
and a failed plan blocks the whole workspace. So, **before** upgrading,
the platform team adds the policy each cache already has to its request
file — one line, no change in Azure:

| Created as | Add to the request's `instance` |
|---|---|
| `STANDALONE` | `"clustering_policy": "NoCluster"` |
| `HA`, `DR-ActivePassive`, `DR-ActiveActive` without RediSearch | `"clustering_policy": "OSSCluster"` |
| Any topology with RediSearch | nothing (already `EnterpriseCluster`) |

`NoCluster` is **legacy only**: never a default, not offered in the
intake, and accepted only when stated explicitly, only for `STANDALONE`,
and only on SKUs of 25 GB or less (otherwise the plan fails):

| Series | Legacy NoCluster allowed |
|---|---|
| Balanced | `B0`, `B1`, `B3`, `B5`, `B10`, `B20` (1–24 GB) |
| Compute Optimized | `X3`, `X5`, `X10`, `X20` (3–24 GB) |
| Memory Optimized | `M10`, `M20` (12–24 GB) |
| Flash Optimized | none |

After pinning, every existing cache must plan as **0 to change, 0 to
destroy**. Don't remove a request file to "skip" a cache: Terraform then
plans to destroy it.

## Auth mode & TLS

`client-protocol` is locked to `Encrypted` — no override accepted.

`authorization-mode` (`AccessKey` | `MicrosoftEntraID`) is a real,
overridable choice. `MicrosoftEntraID` disables access-key auth but
requires a **manual, out-of-band** Microsoft Entra ID data-plane grant —
the azurerm provider cannot automate this yet.

## Redis modules

```hcl
redis-modules     = ["RediSearch", "RedisJSON", "Bloom", "TimeSeries"]
redis-module-args = { Bloom = "ERROR_RATE 0.01 INITIAL_SIZE 400" } # optional
```

Enables Redis modules on the default database of the primary **and** the DR
instance (DR always gets the identical list, as geo-replication requires).
Default: `[]`, no modules.

**Names.** Canonical Azure names or short aliases, case-insensitive, with
surrounding spaces ignored:

| Canonical (sent to Azure) | Also accepted |
|---|---|
| `RediSearch` | `Search` |
| `RedisJSON` | `JSON` |
| `RedisBloom` | `Bloom` |
| `RedisTimeSeries` | `TimeSeries` |

Inputs are normalised to the canonical name and **sorted**, so the order a
caller sends them in never causes a diff. Check the `redis-modules` output
for what was actually applied.

**Rules — plan fails when broken** (variable validation, then lifecycle
preconditions on `azurerm_managed_redis.primary`):

| Rule | Why |
|---|---|
| Every name must be one of the four modules above | Azure only offers these |
| No duplicates, where an alias and its canonical name are the same module (`["Bloom", "RedisBloom"]` fails) | One module block per module |
| `deployment-topology = DR-ActiveActive` allows only RediSearch and RedisJSON | Active geo-replication supports only these two |
| `FlashOptimized_*` allows only RedisJSON; `EnterpriseFlash_*` only RediSearch and RedisJSON | Flash tiers don't host the other modules |
| Every `redis-module-args` key must be a valid module name that is also in `redis-modules`; values must be non-empty | Args for a module that isn't enabled can't be applied |

**Forced values.** RediSearch requires `EnterpriseCluster` clustering and
`NoEviction`. When `redis-modules` includes RediSearch, `clustering-policy`
and `eviction-policy` are forced to those values whatever was passed. The
`redisearch-forces-cluster-and-eviction-policy` check warns when that
overrides an explicit input. The `clustering-policy` and `eviction-policy`
outputs show what was applied.

**Module args.** `FT.CONFIG` and other runtime config commands are not
supported on Azure Managed Redis. `redis-module-args` at create time is the
only way to configure a module. Keys use the same names or aliases as
`redis-modules`.

### Compatibility and outcomes

Every topology supports modules. Only DR-ActiveActive limits which ones.

**Topology × modules**

| Topology | RediSearch | RedisJSON | RedisBloom | RedisTimeSeries | DR cache gets the same modules? |
|---|---|---|---|---|---|
| STANDALONE | ✅ | ✅ | ✅ | ✅ | No DR cache |
| HA | ✅ | ✅ | ✅ | ✅ | No DR cache |
| DR-ActivePassive | ✅ | ✅ | ✅ | ✅ | Yes, automatically |
| DR-ActiveActive | ✅ | ✅ | ❌ plan fails | ❌ plan fails | Yes, automatically |

**SKU × modules**

| node-type family | Modules allowed |
|---|---|
| Balanced, MemoryOptimized, ComputeOptimized, Enterprise_E* | All four |
| FlashOptimized_* | RedisJSON only |
| EnterpriseFlash_* | RediSearch and RedisJSON |

DR-ActiveActive also needs a geo-replication-capable SKU (`Balanced_B10`
or above, or a supported Memory, Compute or Flash SKU); see the
`geo-replication-requires-supported-sku` check.

**Clustering and eviction applied**

| Modules requested | clustering-policy applied | eviction-policy applied |
|---|---|---|
| None | Input, or the topology default `EnterpriseCluster` | Input, or `AllKeysLRU` |
| Includes RediSearch | **Forced `EnterpriseCluster`** (all topologies) | **Forced `NoEviction`**; an explicit conflicting input is overridden with a warning |
| JSON / Bloom / TimeSeries only | Input, or `EnterpriseCluster` | Any allowed value, default `AllKeysLRU` |

Allowed eviction values: `AllKeysLRU`, `AllKeysLFU`, `AllKeysRandom`,
`VolatileLRU`, `VolatileLFU`, `VolatileRandom`, `VolatileTTL`, `NoEviction`.

**Examples**

| Topology | redis-modules | Result |
|---|---|---|
| STANDALONE | `[]` | EnterpriseCluster, AllKeysLRU |
| STANDALONE | `["RediSearch", "RedisJSON"]` | EnterpriseCluster, NoEviction |
| STANDALONE | `["JSON", "Bloom"]` | EnterpriseCluster, input eviction or AllKeysLRU |
| HA | all four | EnterpriseCluster, NoEviction |
| HA | `["TimeSeries"]` | EnterpriseCluster (or OSSCluster input), input eviction or AllKeysLRU |
| DR-ActivePassive | all four | EnterpriseCluster, NoEviction, on primary and DR |
| DR-ActivePassive | `["Bloom"]` | EnterpriseCluster (or OSSCluster input), input eviction, on primary and DR |
| DR-ActiveActive | `["RediSearch", "RedisJSON"]` | EnterpriseCluster, NoEviction, persistence forced off, on both caches |
| DR-ActiveActive | `["JSON"]` | EnterpriseCluster (or OSSCluster input), input eviction, persistence forced off |
| DR-ActiveActive | anything with Bloom or TimeSeries | ❌ plan fails |

**Tuning without recreating.** Module args are create-time defaults only;
changing `redis-module-args` later recreates the instance. Instead, tune per
object from the application at runtime:

| Module | Runtime tuning |
|---|---|
| RedisBloom | `BF.RESERVE key <error_rate> <capacity>` per filter (or `CF.RESERVE`) |
| RediSearch | Per-index options in `FT.CREATE` |
| RedisTimeSeries | `TS.CREATE` per series; `TS.ALTER` to change later |
| RedisJSON | Nothing to tune |

For example, `ERROR_RATE 0.01 INITIAL_SIZE 400` for RedisBloom only sets
the false-positive rate and starting capacity of filters auto-created by
the first `BF.ADD`. Filters created with `BF.RESERVE` ignore it. RedisBloom's
built-in defaults are `ERROR_RATE 0.01 INITIAL_SIZE 100`, so leave
`redis-module-args` empty unless a team has a specific reason.

**Custom data-access policies.** Azure doesn't support custom access
strings (read-only or limited ACLs) on an instance with any module enabled;
only full-access assignments work there.

> ⚠️ **Create-time only.** Azure cannot load, unload or reconfigure a module
> on a running instance. Adding, removing or changing a module or its args
> on an existing instance **deletes and re-creates its database, and all
> data is lost**. With azurerm 4.x the plan shows this only as
> `~ update in-place` on `default_database` — **not** `must be replaced` —
> so review any diff in `module` blocks as data loss. Treat it as a
> migration. Adding RediSearch to an existing non-Enterprise cache also
> changes its clustering policy, which the clustering policy guard blocks
> at plan (see "Changing the clustering policy of an existing cache").

## Persistence

```hcl
persistence-mode          = "RDB"   # or "AOF" or "DISABLED" (default)
persistence-rdb-frequency = "12h"   # 1h | 6h | 12h
persistence-aof-frequency = "1s"    # always | 1s
```

Automatically forced to `DISABLED` when `deployment-topology =
DR-ActiveActive` — check the `persistence-mode` output to confirm what
actually got applied. Requires HA: `STANDALONE` with `RDB`/`AOF` fails the
plan unless `high-availability-enabled = true`.

## Deletion protection

```hcl
deletion-protection-enabled = true # default
```

Implemented via an `azurerm_management_lock` (`CanNotDelete`) —
`azurerm_managed_redis` has no native `deletion_protection_enabled`
argument of its own. The lock blocks deletes made **outside** Terraform
(Portal, CLI, another pipeline). It does **not** block a Terraform-driven
destroy or forced replacement: the lock depends on the instance, so
Terraform removes the lock first. Guard those with a plan review or a
pipeline check on `delete` actions.

## DR gets its own resource group — production recommendation

```hcl
resource-group-name    = "cfes-amr-eastus2-prod-rg"
dr-resource-group-name = "cfes-amr-centralus-prod-rg"  # separate from primary
```

`dr-resource-group-name` defaults to `resource-group-name` (DR shares the
primary's resource group) purely for backward compatibility. **Production
deployments should set it explicitly to a separate, region-matching
resource group.** A resource group is Azure's basic blast-radius and
RBAC-scoping boundary — sharing one resource group across regions means
an incident, bad policy, or accidental deletion scoped to that resource
group doesn't respect the region boundary you're relying on for
disaster recovery in the first place. This mirrors standard guidance from
Microsoft's own Cloud Adoption Framework: one resource group per region
for workloads with a documented DR/secondary-region posture.

## Structure

| File | Contents |
|---|---|
| `versions.tf` | `required_providers` only — no `provider "azurerm" {}` block |
| `variables.tf` | Every instance variable, plus every cross-field `check` block |
| `all-locals.tf` | **The** file to edit for defaults. `local.defaults` map, effective-value locals, and derived logic |
| `data.tf` | Subnet lookups (primary and DR), only queried when an ID isn't supplied directly |
| `main.tf` | The primary `azurerm_managed_redis`, an optional `dr`, and the deletion-protection `azurerm_management_lock`(s) |
| `geo-replication.tf` | `azurerm_managed_redis_geo_replication`, only for `deployment-topology = DR-ActiveActive` |
| `network.tf` | Private endpoints only (primary, primary paired-region, DR) — no DNS zone or VNet link resources |
| `outputs.tf` | Instance identity (including port), topology/persistence/auth status, applied modules and policies, networking outputs |
| `tests/redis-modules.tftest.hcl` | Plan-only `terraform test` suite for naming and Redis modules (Terraform >= 1.7, uses `mock_provider`, no Azure access needed) |

## Usage

```hcl
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

module "redis" {
  source = "./"

  name                 = "cfes-amr-prod" # full name, environment included
  location             = "eastus2"
  resource-group-name  = "cfes-amr-eastus2-prod-rg"
  deployment-topology  = "DR-ActiveActive"
  dr-location          = "centralus"
  node-type            = "Balanced_B10"

  # Only RediSearch + RedisJSON are allowed with DR-ActiveActive
  redis-modules = ["RediSearch", "RedisJSON"]

  subnet-id    = "/subscriptions/.../subnets/cfes-amr-eastus2-prod-snet"
  dr-subnet-id = "/subscriptions/.../subnets/cfes-amr-centralus-prod-snet"

  tags = {
    costcenter = "cfes"
  }
}
```

## Known limitations

- No native "passive" (non-geo-replicated) live replication target in Azure
  Managed Redis today.
- `MicrosoftEntraID` authorization mode requires an out-of-band data-plane
  grant not automatable by this module today.
- Tag changes to an existing instance are ignored by design — see "Tags are
  preserved across updates" above.
- This module assumes DNS automation (Infoblox or equivalent) exists
  outside Terraform. If it doesn't, private endpoints won't resolve.
- `redis-primary-access-key` output's attribute path is inferred from the
  sibling `azurerm_managed_redis` data source's documented shape; confirm
  it against your installed provider version before depending on it.
- No diagnostic settings / Log Analytics wiring yet.
- No customer-managed key (CMK) encryption support yet.
- `node-type` changes: Azure can scale many SKUs in place, but the azurerm
  provider marks `sku_name` as ForceNew, so through this module any
  `node-type` change **replaces** the instance (the plan shows
  `must be replaced`).
- `redis-modules` / `redis-module-args` changes delete and re-create the
  database (data loss) while the plan shows only an in-place update — see
  the warning under "Redis modules". Only clustering-policy changes are
  blocked by a guard today.
- `high-availability-enabled` (STANDALONE HA on/off, or STANDALONE
  without HA ↔ HA/DR) is ForceNew in azurerm: changing it replaces the
  instance.
- Module versions are managed by Azure; they can't be pinned or upgraded
  from this module.
- `deletion-protection-enabled = true` does **not** stop a Terraform-driven
  destroy (removing the instance from the caller's config, or a forced
  replacement): Terraform removes the lock first. It protects against
  deletes outside Terraform (Portal, CLI).

## Roadmap

- [ ] Diagnostic settings → Log Analytics / Event Hub
- [ ] Customer-managed key (CMK) encryption
- [ ] Automate the Entra ID data-plane grant once azurerm supports it
