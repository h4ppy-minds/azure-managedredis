# Terraform Module: Azure Managed Redis (instance)

Single, reusable Terraform module for an
[Azure Managed Redis](https://learn.microsoft.com/en-us/azure/redis/) (Redis
Enterprise-based) instance — sizing, HA/clustering, persistence, auth mode,
a private endpoint (always created), deletion protection, and optional DR
with active-active geo-replication.

Current module version: **5.0.0** — see [CHANGELOG.md](./CHANGELOG.md). This
is a breaking release; read the CHANGELOG's `5.0.0` entry in full before
upgrading.

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

## Roadmap

- [ ] Diagnostic settings → Log Analytics / Event Hub
- [ ] Customer-managed key (CMK) encryption
- [ ] Automate the Entra ID data-plane grant once azurerm supports it
