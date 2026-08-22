# Terraform Module: Azure Managed Redis (instance)

Single, reusable Terraform module for an
[Azure Managed Redis](https://learn.microsoft.com/en-us/azure/redis/) (Redis
Enterprise-based) instance — sizing, HA/clustering, persistence, auth mode,
private networking (endpoint + DNS zone), deletion protection, and optional
DR with active-active geo-replication.

Current module version: **4.0.0** — see [CHANGELOG.md](./CHANGELOG.md).

## This module does not configure the azurerm provider

There is no `provider "azurerm" {}` block anywhere in this module. A
reusable module should never dictate auth or subscription context to its
caller — that's the root module's job. See `examples/` for where the
provider block belongs instead.

## No submodules

Everything in this module lives in this one directory. The primary and
(optional) DR instance are two explicit `azurerm_managed_redis` resource
blocks in `main.tf`, not two calls into a shared internal module.

## deployment_topology is the single knob for topology

```
deployment_topology = "STANDALONE" | "HA" | "DR-ActivePassive" | "DR-ActiveActive"
```

There is no separate `high_availability_enabled`-as-a-toggle or `prod_mode`
variable driving HA/clustering/DR independently — this module's prior
version had exactly that (`prod_mode` + environment-driven HA) and it could
disagree with itself. `deployment_topology` alone now drives all of it, via
`local.defaults.topology_profile` in `all-locals.tf`:

| `deployment_topology` | HA | Clustering | DR instance | Live geo-replication |
|---|---|---|---|---|
| `STANDALONE` | off | `NoCluster` | no | no |
| `HA` | on | `OSSCluster` | no | no |
| `DR-ActivePassive` | on | `OSSCluster` | yes | no |
| `DR-ActiveActive` | on | `OSSCluster` | yes | yes |

`environment` (`dev`/`qa`/`uat`/`prod`) still exists, but only for naming
and the per-environment `node_type` default — it no longer gates HA, DR, or
clustering. You can run `deployment_topology = "DR-ActiveActive"` in `dev`
if you genuinely need to (e.g. testing failover), though the
`prod_should_not_be_standalone` check exists specifically to flag the
opposite, more common mistake: `environment = prod` left at `STANDALONE`.

### DR-ActiveActive vs. DR-ActivePassive

- **`DR-ActiveActive`**: primary and DR are linked with
  `azurerm_managed_redis_geo_replication`, giving live, bidirectional
  replication. Azure does **not** allow persistence on a geo-replicated
  database, so `persistence_mode` is automatically forced to `DISABLED` in
  this mode — the `persistence_disabled_for_active_active` check warns you
  at plan time.
- **`DR-ActivePassive`**: a DR instance is still provisioned, but Azure
  Managed Redis has no native "passive replica" concept — there is
  currently no first-class way to get Azure to continuously stream data
  into a non-geo-replicated standby. DR is a **standalone instance** you
  keep in sync yourself (scheduled RDB/AOF export-import, or a secondary
  write path from your application/CI). This is a limitation of the
  underlying Azure service, not something Terraform can work around.

## node_type (renamed from sku_name)

This module's public input is `node_type`, not `sku_name`, to match the
naming this repo's GCP sibling module (`terraform-google-h4ppy-memorystore-valkey`)
uses for the same concept. Underneath, `main.tf` maps it directly onto the
`azurerm_managed_redis` resource's own `sku_name` argument — that's the
provider's fixed schema name, not renameable; only this module's
public-facing variable is renamed.

## Auth mode & TLS

`client_protocol` is locked to `Encrypted` — no override accepted, same
mandatory-not-default stance as the GCP sibling module takes on
`transit_encryption_mode`.

`authorization_mode` (`AccessKey` | `MicrosoftEntraID`), by contrast, **is**
a real, overridable choice here — unlike the GCP module's
`authorization_mode`, which only ever accepts one value. That difference is
deliberate: GCP's provider can fully automate IAM role bindings for
`IAM_AUTH`; the azurerm provider cannot yet automate the equivalent
Microsoft Entra ID data-plane grant for Managed Redis (see
[hashicorp/terraform-provider-azurerm#30938](https://github.com/hashicorp/terraform-provider-azurerm/issues/30938)).
Locking this module to `MicrosoftEntraID`-only today would mean no client
could ever connect without a manual, undocumented-by-Terraform step. So:

- Default is `AccessKey` — fully functional through Terraform alone.
- `MicrosoftEntraID` is available, sets
  `access_keys_authentication_enabled = false`, but requires you to grant
  specific principals data-plane access out-of-band (Portal/CLI) — the
  `entra_id_auth_requires_manual_grant` check exists to flag this, not to
  block it.

Revisit this once azurerm supports the Entra ID grant natively.

## Persistence

```hcl
persistence_mode          = "RDB"   # or "AOF" or "DISABLED" (default)
persistence_rdb_frequency = "12h"   # 1h | 6h | 12h
persistence_aof_frequency = "1s"    # always | 1s
```

Mirrors the GCP sibling module's `persistence_mode` naming and 3-way enum
exactly. Applied identically to the primary and DR default databases.
Automatically forced to `DISABLED` when `deployment_topology =
DR-ActiveActive` — check the `persistence_mode` output to confirm what
actually got applied.

> Data persistence protects against node failure; it is **not** a
> substitute for point-in-time backups. See
> [Microsoft's persistence guidance](https://learn.microsoft.com/en-us/azure/redis/how-to-persistence).

## DR-region networking

When `deployment_topology` is `DR-ActivePassive` or `DR-ActiveActive`, the
DR instance's private endpoint (and the corresponding second VNet link on
the private DNS zone) is **opt-in** — supply DR-region networking either
way:

```hcl
# Direct IDs
dr_subnet_id = "/subscriptions/.../subnets/..."
dr_vnet_id   = "/subscriptions/.../virtualNetworks/..."

# Or name-based lookup (all three required together)
dr_subnet_name              = "cfes-amr-centralus-prod-snet"
dr_vnet_name                = "az3-cfes-centralus-prod-vnet"
dr_vnet_resource_group_name = "az3-network-cfes-centralus-prod-rg"
```

Leave all of these unset and the DR **instance** still gets created (DR is
driven purely by `deployment_topology`) — you just won't get a DR private
endpoint or DR DNS zone link until you supply DR-region networking later.
`dr_private_dns_zone_link_requires_vnet_id` and `dr_subnet_inputs_complete`
(both in `variables.tf`) catch half-supplied DR networking at plan time.

## Deletion protection

```hcl
deletion_protection_enabled = true # default
```

Unlike GCP's `google_memorystore_instance`, `azurerm_managed_redis` has
**no `deletion_protection_enabled` argument of its own**. This module's
equivalent is an `azurerm_management_lock` (`CanNotDelete`) applied to the
primary (and DR, if present) instance in `main.tf` — a separate resource,
not an inline flag, but it blocks deletion via Portal/CLI/API/Terraform
alike for anyone without `Microsoft.Authorization/locks/delete` on that
scope. Functionally equivalent protection to GCP's version; mechanically
different because that's what Azure actually offers here.

**Operational note:** because the lock blocks *any* delete, it also blocks
Terraform's delete-then-create for changes that force replacement (e.g.
changing `node_type`). If you need to make one of those changes, set
`deletion_protection_enabled = false`, apply, make the change, then set it
back to `true`.

## Tags

`tags` (`map(string)`, default `{}`) is applied to every resource this
module creates: both Redis instances, the private endpoint(s), the private
DNS zone and its VNet link, and the deletion-protection lock(s).

## Structure

| File | Contents |
|---|---|
| `versions.tf` | `required_providers` only — no `provider "azurerm" {}` block |
| `variables.tf` | Every instance variable, plus every cross-field `check` block, checked against effective values |
| `all-locals.tf` | **The** file to edit for defaults (topology, per-environment sizing, auth, persistence, networking, deletion protection). `local.defaults` map, effective-value locals, and derived logic |
| `data.tf` | Subnet lookup, only queried when `subnet_id` isn't supplied directly |
| `main.tf` | The primary `azurerm_managed_redis`, an optional `dr`, and the deletion-protection `azurerm_management_lock`(s) |
| `geo-replication.tf` | `azurerm_managed_redis_geo_replication`, only for `deployment_topology = DR-ActiveActive` |
| `network.tf` | Private DNS zone + VNet link + private endpoint(s) |
| `outputs.tf` | Instance identity, topology/persistence/auth status, networking outputs |

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
  resource_group_name  = "cfes-amr-eastus2-prod-rg"
  environment          = "prod"
  deployment_topology  = "DR-ActiveActive"
  dr_location          = "centralus"

  subnet_id = "/subscriptions/.../subnets/cfes-amr-eastus2-prod-snet"
  vnet_id   = "/subscriptions/.../virtualNetworks/az3-cfes-eastus2-prod-vnet"

  tags = {
    costcenter = "cfes"
  }
}
```

See [`examples/`](./examples) for a `STANDALONE` dev config using
name-based subnet lookup, and a `DR-ActiveActive` prod config.

## Known limitations

- No native "passive" (non-geo-replicated) live replication target in Azure
  Managed Redis today — see DR-ActiveActive vs. DR-ActivePassive above.
- `MicrosoftEntraID` authorization mode requires an out-of-band data-plane
  grant not automatable by this module today — see "Auth mode & TLS."
- `deletion_protection_enabled = true` blocks any change that forces
  resource replacement (e.g. `node_type`) until temporarily disabled — see
  "Deletion protection."
- `redis_primary_access_key` output's attribute path is inferred from the
  sibling `azurerm_managed_redis` data source's documented shape; confirm
  it against your installed provider version before depending on it in
  automation.
- No diagnostic settings / Log Analytics wiring yet (see Roadmap).
- No customer-managed key (CMK) encryption support yet.
- `node_type` changes force replacement of the instance (Azure API
  behavior, confirmed against the provider's own issue tracker — not a
  module limitation).

## Roadmap

- [ ] Diagnostic settings → Log Analytics / Event Hub
- [ ] Customer-managed key (CMK) encryption
- [ ] Automate the Entra ID data-plane grant once azurerm supports it, and
      reconsider whether `authorization_mode` should default to
      `MicrosoftEntraID` at that point
- [ ] Optional automated RDB/AOF export-import scheduling for
      DR-ActivePassive
- [ ] Consider splitting alerting into its own module the way the GCP
      Valkey module split `terraform-google-valkey-alerts` out from the
      instance module — not done yet, since there's no alerting in this
      module at all today
