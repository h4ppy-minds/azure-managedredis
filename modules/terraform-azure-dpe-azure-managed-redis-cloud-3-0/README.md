# Terraform Module: Azure Managed Redis (instance)

Single, reusable Terraform module for an
[Azure Managed Redis](https://learn.microsoft.com/en-us/azure/redis/) (Redis
Enterprise-based) instance — sizing, HA/clustering, persistence, auth mode,
a private endpoint (always created), deletion protection, and optional DR
with active-active geo-replication.

Current module version: **5.3.0** — see [CHANGELOG.md](./CHANGELOG.md).
5.3.0 is additive (Redis modules support). If you're upgrading from 4.x,
read the CHANGELOG's `5.0.0` entry in full first — that one is breaking.

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

## node-type is required — no default

Unlike earlier versions, this module does **not** pick a default SKU for
you. `node-type` must always be supplied by the caller. Instance sizing is
a caller/template policy decision, not something this module should guess
at silently.

## A private endpoint is always created — no toggle

Every instance this module creates gets a private endpoint: the primary
unconditionally, and the DR instance too whenever `deployment-topology`
creates one. There is no `create-private-endpoint`-style variable to opt
out. Subnet info (`subnet-id`, or `subnet-name` + `vnet-name` +
`vnet-resource-group-name`) is therefore always required — and DR subnet
info is required too, whenever `deployment-topology` is a `DR-*` value.

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

## deployment-topology is the single knob for topology

```
deployment-topology = "STANDALONE" | "HA" | "DR-ActivePassive" | "DR-ActiveActive"
```

| `deployment-topology` | HA | Clustering | DR instance | Live geo-replication |
|---|---|---|---|---|
| `STANDALONE` | off | `NoCluster` | no | no |
| `HA` | on | `OSSCluster` | no | no |
| `DR-ActivePassive` | on | `OSSCluster` | yes | no |
| `DR-ActiveActive` | on | `OSSCluster` | yes | yes |

Clustering is forced to `EnterpriseCluster` for every topology when
`redis-modules` includes RediSearch — see "Redis modules" below.

### DR-ActiveActive vs. DR-ActivePassive

- **`DR-ActiveActive`**: primary and DR are linked with
  `azurerm_managed_redis_geo_replication`, giving live, bidirectional
  replication. Azure does **not** allow persistence on a geo-replicated
  database, so `persistence-mode` is automatically forced to `DISABLED` in
  this mode. Also requires a geo-replication-capable `node-type`
  (`Balanced_B10`+ or equivalent) — see the
  `geo-replication-requires-supported-sku` check.
- **`DR-ActivePassive`**: a DR instance is still provisioned, but Azure
  Managed Redis has no native "passive replica" concept — DR is a
  **standalone instance** you keep in sync yourself.

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
| None | Topology default: STANDALONE → `NoCluster`; HA and both DR → `OSSCluster` | Input, or `AllKeysLRU` |
| Includes RediSearch | **Forced `EnterpriseCluster`** (all topologies) | **Forced `NoEviction`**; an explicit conflicting input is overridden with a warning |
| JSON / Bloom / TimeSeries only | Topology default, unchanged | Any allowed value, default `AllKeysLRU` |

Allowed eviction values: `AllKeysLRU`, `AllKeysLFU`, `AllKeysRandom`,
`VolatileLRU`, `VolatileLFU`, `VolatileRandom`, `VolatileTTL`, `NoEviction`.

**Examples**

| Topology | redis-modules | Result |
|---|---|---|
| STANDALONE | `[]` | NoCluster, AllKeysLRU |
| STANDALONE | `["RediSearch", "RedisJSON"]` | EnterpriseCluster, NoEviction |
| STANDALONE | `["JSON", "Bloom"]` | NoCluster, input eviction or AllKeysLRU |
| HA | all four | EnterpriseCluster, NoEviction |
| HA | `["TimeSeries"]` | OSSCluster, input eviction or AllKeysLRU |
| DR-ActivePassive | all four | EnterpriseCluster, NoEviction, on primary and DR |
| DR-ActivePassive | `["Bloom"]` | OSSCluster, input eviction, on primary and DR |
| DR-ActiveActive | `["RediSearch", "RedisJSON"]` | EnterpriseCluster, NoEviction, persistence forced off, on both caches |
| DR-ActiveActive | `["JSON"]` | OSSCluster, input eviction, persistence forced off |
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

> ⚠️ **Create-time only.** Azure cannot load, unload or reconfigure a module
> on a running instance. Adding, removing or changing a module, its args,
> or the clustering policy (which RediSearch changes) on an existing
> instance **destroys and recreates it, and all data is lost**. Treat it as
> a migration. `deletion-protection-enabled = true` blocks the replacement
> until it's temporarily disabled. Always read the plan for
> `must be replaced` before applying.

## Persistence

```hcl
persistence-mode          = "RDB"   # or "AOF" or "DISABLED" (default)
persistence-rdb-frequency = "12h"   # 1h | 6h | 12h
persistence-aof-frequency = "1s"    # always | 1s
```

Automatically forced to `DISABLED` when `deployment-topology =
DR-ActiveActive` — check the `persistence-mode` output to confirm what
actually got applied.

## Deletion protection

```hcl
deletion-protection-enabled = true # default
```

Implemented via an `azurerm_management_lock` (`CanNotDelete`) —
`azurerm_managed_redis` has no native `deletion_protection_enabled`
argument of its own. Also blocks any change that forces resource
replacement (e.g. `node-type`) until temporarily disabled.

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
| `network.tf` | Private endpoint(s) only — no DNS zone or VNet link resources |
| `outputs.tf` | Instance identity (including port), topology/persistence/auth status, networking outputs |

## Usage

```hcl
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

module "redis" {
  source = "./"

  name                 = "cfes-amr"
  location             = "eastus2"
  resource-group-name  = "cfes-amr-eastus2-prod-rg"
  environment          = "prod"
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
- `deletion-protection-enabled = true` blocks any change that forces
  resource replacement (e.g. `node-type`) until temporarily disabled.
- Tag changes to an existing instance are ignored by design — see "Tags are
  preserved across updates" above.
- This module assumes DNS automation (Infoblox or equivalent) exists
  outside Terraform. If it doesn't, private endpoints won't resolve.
- `redis-primary-access-key` output's attribute path is inferred from the
  sibling `azurerm_managed_redis` data source's documented shape; confirm
  it against your installed provider version before depending on it.
- No diagnostic settings / Log Analytics wiring yet.
- No customer-managed key (CMK) encryption support yet.
- `node-type` changes force replacement of the instance (Azure API
  behavior).
- `redis-modules` / `redis-module-args` changes force replacement of the
  instance (Azure API behavior — modules are create-time only).
- Module versions are managed by Azure; they can't be pinned or upgraded
  from this module.

## Roadmap

- [ ] Diagnostic settings → Log Analytics / Event Hub
- [ ] Customer-managed key (CMK) encryption
- [ ] Automate the Entra ID data-plane grant once azurerm supports it