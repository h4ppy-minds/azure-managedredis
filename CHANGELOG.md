# Changelog

All notable changes to this module are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned
- Diagnostic settings / Log Analytics integration
- Customer-managed key (CMK) encryption support
- Automate the Entra ID data-plane grant once azurerm supports it

## [0.0.4] - 2026-08-22

### Changed — BREAKING
- **`prod_mode` replaced by `deployment_topology`.** The single topology
  knob is now `deployment_topology` (`STANDALONE` | `HA` |
  `DR-ActivePassive` | `DR-ActiveActive`), mirroring the GCP sibling
  module's single-variable topology pattern. It now drives
  `high_availability_enabled`, `clustering_policy`, DR instance creation,
  and geo-replication all at once via `local.defaults.topology_profile`
  (`all-locals.tf`) — previously HA was driven by `environment` and DR/geo
  by `prod_mode`, two independent inputs that could disagree with each
  other. **Migration:** replace `prod_mode = "active-active"` with
  `deployment_topology = "DR-ActiveActive"`, and `prod_mode =
  "active-passive"` with `deployment_topology = "DR-ActivePassive"`. If you
  weren't in prod at all, add `deployment_topology = "HA"` explicitly if
  you want the old always-HA-outside-dev behavior — the new default
  (`STANDALONE`) has HA off, matching the GCP module's STANDALONE-is-the-
  default stance instead of this module's old dev-only-is-unprotected one.
- **`sku_name` variable renamed to `node_type`.** Purely a module input
  rename — it still maps onto the `azurerm_managed_redis` resource's own
  `sku_name` argument internally (that provider argument name can't
  change). **Migration:** rename `sku_name = "..."` to `node_type = "..."`
  in every caller.
- **`enable_backup` / `backup_method` / `backup_rdb_frequency` /
  `backup_aof_frequency` replaced by `persistence_mode` /
  `persistence_rdb_frequency` / `persistence_aof_frequency`.**
  `persistence_mode` is now a 3-way enum (`RDB` | `AOF` | `DISABLED`),
  matching the GCP sibling module's `persistence_mode` naming and shape
  exactly, instead of a boolean + separate method string. **Migration:**
  `enable_backup = false` → omit `persistence_mode` (defaults to
  `DISABLED`); `enable_backup = true, backup_method = "rdb"` →
  `persistence_mode = "RDB"`; `backup_rdb_frequency` /
  `backup_aof_frequency` renamed to `persistence_rdb_frequency` /
  `persistence_aof_frequency` with the same accepted values.
- **`environment` no longer drives HA, clustering, or DR.** It still drives
  naming and the per-environment `node_type` default
  (`local.defaults.environment_profile`) — everything else moved to
  `deployment_topology`. A caller relying on `environment = prod`
  implicitly turning on HA now needs `deployment_topology = HA` (or one of
  the `DR-*` values) set explicitly.

### Added
- `authorization_mode` variable (`AccessKey` | `MicrosoftEntraID`), mapped
  to the real `default_database.access_keys_authentication_enabled`
  argument. Default `AccessKey`. See README "Auth mode & TLS" for why this
  is a real overridable choice here, unlike the GCP module's
  authorization_mode.
- `deletion_protection_enabled` variable (default `true`), implemented via
  a new `azurerm_management_lock` (`CanNotDelete`) on the primary (and DR,
  if present) instance — `azurerm_managed_redis` has no native
  `deletion_protection_enabled` argument the way GCP's
  `google_memorystore_instance` does, so this module adds the closest
  available Azure-native equivalent. See README "Deletion protection" for
  the operational tradeoff this introduces with forced-replacement changes.
- `check "prod_should_not_be_standalone"` — advisory warning if
  `environment = prod` and `deployment_topology = STANDALONE`.
  Replaces the old `prod_requires_high_availability` check, which no
  longer made sense once HA became purely topology-driven rather than
  environment-driven.
- `check "entra_id_auth_requires_manual_grant"` — advisory warning when
  `authorization_mode = MicrosoftEntraID`, since this module cannot
  automate the corresponding Entra ID data-plane grant.
- `check "persistence_disabled_for_active_active"` — renamed from
  `backup_disabled_for_active_active`, same behavior against the new
  `persistence_mode` variable.
- New outputs: `resolved_deployment_topology`, `authorization_mode`,
  `deletion_protection_enabled`, `persistence_mode` (replaces
  `backup_enabled`).
- `local.defaults.topology_profile` and (renamed)
  `local.defaults.environment_profile[...].node_type` in `all-locals.tf`.

### Removed
- `prod_mode`, `sku_name`, `enable_backup`, `backup_method`,
  `backup_rdb_frequency`, `backup_aof_frequency` variables (see BREAKING
  above for replacements).
- `check "dr_requires_location"` renamed in place — same check, now keyed
  off `deployment_topology` (`local.create_dr`) instead of
  `environment == "prod"`.
- `backup_enabled` output (replaced by `persistence_mode`).

## [0.0.3] - 2026-08-22

Restructures the module to match a reviewed pattern (single defaults file,
effective-value locals, REQUIRED/OPTIONAL variable banners, cross-field
`check` blocks, no in-module provider config). Behaviorally equivalent to
`0.0.2` for every existing input **except** the provider/auth removal below,
which is breaking.

### Changed — BREAKING
- **Provider configuration removed from this module.** `providers.tf` and
  the `usr-client-id` / `usr-client-secret` / `usr-tenant-id` /
  `usr-subscription-id` variables are gone. This module no longer contains
  a `provider "azurerm" {}` block and never authenticates to Azure itself —
  that's the calling root module's responsibility now, same as any other
  well-behaved reusable module. **Migration:** move your
  `provider "azurerm" { ... }` block (and whatever supplies
  `subscription_id` / `client_id` / `tenant_id` / `client_secret` to it)
  out of this module and into the root configuration that calls it. Nothing
  else needs to change — every other input/output is unchanged from
  `2.0.0`.
- **`locals.tf` replaced by `all-locals.tf`.** All tunable defaults now live
  in a single `local.defaults` map (plus `local.defaults.environment_profile`
  for the per-environment sku/HA/clustering values previously spread across
  `main.tf`'s inline ternaries and the dead `dev_sku_name`/`qa_sku_name`/
  `prod_sku_name` variables from `0.0.1`). See README "The 'one file for
  defaults' design."
- **Every variable with a default now defaults to `null`** and resolves via
  `all-locals.tf`, rather than carrying a literal default in `variables.tf`.
  Functionally equivalent to `0.0.2`'s literal defaults — this only changes
  *where* the default value lives.
- **`client_protocol` and `public_network_access` are no longer
  independently tunable.** `0.0.2` allowed overriding them to `Plaintext` /
  `Enabled`; validation now rejects both. See README "Network exposure and
  transit encryption are mandatory, not defaults." If you were relying on
  either override, this module is no longer the right fit for that use
  case — that was intentionally narrowed.
- **`validate.tf`'s `check` blocks moved into `variables.tf`**, immediately
  after the variables they validate, and now assert against
  `local.*` effective values consistently (some previously referenced
  `var.*` directly).

### Added
- `REQUIRED` / `OPTIONAL` banner comments on every variable in
  `variables.tf`.
- `check "prod_requires_high_availability"` — advisory warning (does not
  block apply) if `high_availability_enabled` resolves to `false` in prod.
- `lifecycle { precondition {} }` blocks on `azurerm_managed_redis.primary`,
  `azurerm_managed_redis.dr`, and
  `azurerm_private_dns_zone_virtual_network_link.private_dns_link` as a
  second, resource-level guard alongside the `check` blocks in
  `variables.tf` — belt-and-suspenders, matching the pattern used
  elsewhere for this kind of cross-field validation.
- `resolved_environment` output.
- `.terraform-docs.yml` for generating a Requirements/Providers/Resources/
  Inputs/Outputs table (not yet injected into this README — run
  `terraform-docs` locally to generate it).


## [0.0.2] - 2026-08-22

### Added
- Data persistence / backup support (`enable_backup`, `backup_method`,
  `backup_rdb_frequency`, `backup_aof_frequency`), wired to
  `persistence_redis_database_backup_frequency` /
  `persistence_append_only_file_backup_frequency` on `default_database`.
- `azurerm_private_dns_zone_virtual_network_link` so the private DNS zone
  actually resolves inside a VNet (previously missing entirely).
- Optional DR private endpoint (`azurerm_private_endpoint.dr`), created when
  `dr_subnet_id` is supplied.
- Loosely-coupled networking: `subnet_id` (direct) or `subnet_name` /
  `vnet_name` / `vnet_resource_group_name` (lookup) instead of hardcoded
  values in `locals.tf`.
- `create_private_dns_zone` / `private_dns_zone_ids` toggle to bring your own
  DNS zone instead of always creating one.
- `create_private_endpoint` toggle to disable private endpoint creation
  entirely when managed elsewhere.
- `tags` variable, applied to every resource in the module.
- `check` blocks (`validate.tf`) that warn at plan time on: missing subnet
  input, missing VNet link target, backup silently disabled by
  active-active mode, and missing `dr_location` in prod.
- Per-environment SKU defaults, actually wired into `main.tf` this time.
- `geo-replication.tf` split out from `main.tf` for clarity.
- `examples/` directory with dev (name-lookup) and prod active-active
  sample `.tfvars`.
- New outputs: `redis_dr_hostname`, `geo_replication_enabled`,
  `backup_enabled`, `private_dns_zone_ids`, `private_endpoint_primary_id`,
  `private_endpoint_dr_id`, `redis_primary_access_key`.

### Changed
- `high_availability_enabled` variable changed from `string` (`"true"`/
  `"false"`) to `bool`, matching the underlying resource attribute type.
- `eviction_policy` is now a single variable applied consistently to both
  the primary and DR databases (previously `AllKeysLRU` on primary,
  `VolatileLRU` on DR, with no apparent reason for the difference).
- `sku_name`, `high_availability_enabled`, `clustering_policy` default to
  `null` and resolve via per-environment locals rather than a single
  hardcoded literal.
- `environment` validation now accepts `uat`, matching the `is_uat` local
  that already existed but was previously unreachable (validation only
  allowed `dev`/`qa`/`prod`).
- Split `providers.tf` into `versions.tf` (required_providers) and
  `providers.tf` (provider block) — later removed entirely in `3.0.0`.
- `outputs.tf`: the previously-unnamed private DNS zone output is now named
  `private_dns_zone_ids` (plural, list) to also support the bring-your-own
  zone case.

### Fixed
- **active-active / active-passive detection**: `locals.tf` compared
  `var.prod_mode` against `"active_active"` / `"active_passive"`
  (underscores) while the variable's `validation` block only allowed
  `"active-active"` / `"active-passive"` (hyphens). `prod_active_active`
  and `prod_active_passive` were therefore always `false`, and
  `azurerm_managed_redis_geo_replication` never got created regardless of
  the configured `prod_mode`.
- `subnet_id` variable was declared with a description but never referenced
  anywhere — the subnet used for the private endpoint was always resolved
  from hardcoded `locals.subnet_name` / `vnet_name` / `vnet_rg`.
- `private_dns_zone_ids` variable was declared but never referenced — the
  private endpoint's `private_dns_zone_group` always pointed at the
  module's own self-created zone only.
- Persistence is now explicitly disabled when active-active geo-replication
  is enabled, matching an Azure API constraint (persistence is not
  supported on geo-replicated databases) that the previous version had no
  awareness of.

## [0.0.1] - undated (initial working prototype)

Initial hardcoded proof-of-concept, captured from the working build referenced
during the `0.0.2` refactor:

- Single environment's subnet/VNet/resource group names hardcoded in
  `locals.tf`.
- Primary + conditional DR `azurerm_managed_redis` resources.
- `azurerm_managed_redis_geo_replication` resource present but effectively
  dead code due to the `prod_mode` comparison bug described above.
- Self-created private DNS zone with no VNet link.
- Single private endpoint for the primary instance only.
- No data persistence / backup support.
- `high_availability_enabled` typed as `string`.
- `provider "azurerm" {}` configured inline in the module, authenticated via
  `usr-client-id` / `usr-client-secret` / `usr-tenant-id` /
  `usr-subscription-id` variables