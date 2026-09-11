# Changelog

All notable changes to this module are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Planned
- Diagnostic settings / Log Analytics integration
- Customer-managed key (CMK) encryption support
- Automate the Entra ID data-plane grant once azurerm supports it

## [5.2.0] - 2026-08-25

### Added
- **`dr-resource-group-name` variable.** DR's `azurerm_managed_redis` and
  its private endpoint now support living in a resource group separate
  from the primary's, following standard Azure resource-group design
  guidance (Cloud Adoption Framework) — one resource group per region is
  the recommended production pattern, since a resource group is Azure's
  basic blast-radius/RBAC-scoping boundary, and a DR resource logically
  tied to the same resource group as the region it exists to survive
  undermines the point of region independence. Defaults to
  `resource-group-name` (the old shared behavior) when left unset, so
  this is purely additive — no existing caller needs to change anything.
  See the variable's own description in `variables.tf` for the full
  rationale.

## [5.1.0] - 2026-08-25

Bug fix found during integration testing (flagged by Siva Rajadurai).

### Fixed
- **Both `azurerm_private_endpoint` resources now `ignore_changes` on
  `private_dns_zone_group`, not just `tags`.** Infoblox attaches a
  `private_dns_zone_group` to each private endpoint out-of-band, after
  Terraform creates it — the same class of problem tag-preservation
  already solved for `tags` in v5.0.0, just for a second field we hadn't
  covered yet. Without this, every `plan` saw Infoblox's attachment as
  drift (since this module declares no `private_dns_zone_group` block at
  all) and proposed removing it — fighting the external DNS automation on
  every single apply. This was blocking integration testing entirely.
  **Migration:** add `private_dns_zone_group` to the existing
  `ignore_changes` list on both `azurerm_private_endpoint.primary` and
  `.dr` in `network.tf`. No variable or interface changes — this is a
  drop-in patch.

## [5.0.0] - 2026-08-22

Directed change following senior leadership review. Every item below is
breaking.

### Changed — BREAKING
- **Every variable and output renamed from snake_case to kebab-case**
  (e.g. `resource_group_name` → `resource-group-name`, `node_type` →
  `node-type`, `redis_primary_id` → `redis-primary-id`). Hyphens are
  legal in HCL identifiers and were already this org's convention for
  auth variables in earlier versions of this module (`usr-client-id`
  etc.) — this extends that convention to every variable and output, and
  (as an explicit style extension beyond what was directly requested,
  flagged here for visibility) to internal locals in `all-locals.tf` too,
  so there's one consistent naming style across the whole module rather
  than a visible seam between "public" and "internal" names.
  **Migration:** every caller must update every argument name in every
  `module "redis" { ... }` block, and every `module.redis[...].<output>`
  reference. This is the module's biggest-blast-radius change to date —
  budget real review time for it, not a find/replace.
- **`node-type` (renamed from `sku_name`/`node_type`) is now a required
  variable with no default.** Previously it defaulted to a
  per-environment value (`local.defaults.environment_profile[...]
  .node_type`) when left unset. That whole per-environment default table
  is removed — the caller (an onboarding template, typically) must always
  supply `node-type` explicitly, reflecting a decision that instance
  sizing is a template/caller policy concern, not something this module
  should silently default on its own. **Migration:** every caller must
  now always pass `node-type`.
- **A private endpoint is now unconditionally created for every
  instance** — primary always, DR whenever the topology creates one.
  **The `create_private_endpoint` variable is removed entirely** — there
  is no opt-out any more. As a consequence, subnet info (`subnet-id`, or
  the `subnet-name`/`vnet-name`/`vnet-resource-group-name` trio) is now
  always required rather than only required when that toggle was left at
  its default `true`. Likewise, DR subnet info is now **required**
  whenever `deployment-topology` is a `DR-*` value — the DR private
  endpoint used to be genuinely opt-in (DR instance created, endpoint
  silently skipped without DR networking); it no longer is. **Migration:**
  remove `create_private_endpoint` from every caller; ensure DR subnet
  info is supplied wherever DR topologies are used, or the apply will now
  fail a `lifecycle.precondition` where it previously would have quietly
  skipped the DR endpoint.
- **This module no longer creates or links a private DNS zone.**
  `azurerm_private_dns_zone`, both
  `azurerm_private_dns_zone_virtual_network_link` resources, and the
  `private_dns_zone_group` block on both private endpoints are all
  removed, along with the `create_private_dns_zone`,
  `private_dns_zone_ids`, `private_dns_zone_vnet_link_enabled`, `vnet_id`,
  and `dr_vnet_id` variables, `data.azurerm_virtual_network.vnet`/
  `.dr_vnet`, and the `private_dns_zone_link_requires_vnet_id`/
  `dr_private_dns_zone_link_requires_vnet_id` checks. DNS resolution for
  these private endpoints is now handled entirely by infrastructure
  automation outside this module (Infoblox) — see README "DNS is not this
  module's job." **Migration:** remove every DNS-related argument from
  every caller. If your environment does NOT actually have Infoblox (or
  equivalent) automation wired up yet, do not upgrade to this version
  until it does — private endpoints created without any DNS mechanism
  will not resolve for clients.
- **Tags are now preserved across updates.** Every taggable resource
  (`azurerm_managed_redis.primary`, `.dr`, `azurerm_private_endpoint
  .primary`, `.dr`) now has `lifecycle { ignore_changes = [tags] }`. Tags
  are set once, on first create, and never touched by any later apply —
  protecting tags added by automation outside Terraform (Infoblox, a
  governance/policy tool) from being reverted on the next apply/patch.
  **Real tradeoff, not just a safety net:** this also means changing
  `tags` on an *existing* instance and re-applying will silently do
  nothing — Terraform will show no diff for that attribute at all. If you
  need to genuinely change an existing instance's tags going forward,
  that now has to happen out-of-band (Azure Portal/CLI), or by
  temporarily removing `ignore_changes = [tags]` for one apply.

### Added
- `redis-primary-port` / `redis-dr-port` outputs, reading
  `default_database[0].port` (confirmed against the provider's own
  schema — typically `10000` for Managed Redis, but always read from the
  real output rather than assumed).
- `geo-replication-requires-supported-sku` check — `deployment-topology =
  DR-ActiveActive` requires a geo-replication-capable `node-type`
  (`Balanced_B10`+ or an equivalent tier); smaller SKUs like
  `Balanced_B0` are rejected by the Azure API with a much less
  actionable error, this check catches it at plan time instead.
- `dr-subnet-required` check (renamed and tightened from
  `dr-subnet-inputs-complete`) — now fires whenever `create-dr` is true
  and DR subnet info is missing entirely, not just when it's partially
  supplied.

### Removed
- `create_private_endpoint`, `create_private_dns_zone`,
  `private_dns_zone_ids`, `private_dns_zone_vnet_link_enabled`,
  `vnet_id`, `dr_vnet_id` variables.
- `azurerm_private_dns_zone`, both
  `azurerm_private_dns_zone_virtual_network_link` resources.
- `data.azurerm_virtual_network.vnet`, `data.azurerm_virtual_network
  .dr_vnet`.
- `private_dns_zone_link_requires_vnet_id`,
  `dr_private_dns_zone_link_requires_vnet_id` checks.
- `private-dns-zone-ids` output.
- `local.defaults.environment_profile` (the per-environment `node_type`
  default table) — `node-type` has no default any more.
- `local.is_qa`, `local.is_uat` (dead code — nothing in this module
  actually branches on them; only `is-prod` is used, by
  `prod-should-not-be-standalone`).

## [4.1.0] - 2026-08-22

Bug-fix and DR-networking-completeness release found during live
four-topology testing (STANDALONE / HA / DR-ActivePassive /
DR-ActiveActive) against a real `terraform validate`/`plan`.

### Fixed
- **`variable "validation"` blocks used `x == null || contains(...)`.**
  Terraform's `||` does not short-circuit — `contains()` still evaluated
  against `null` and threw `Invalid function argument` even for the
  `null` case that should have passed. Every affected block
  (`node_type`, `clustering_policy`, `authorization_mode`,
  `client_protocol`, `public_network_access`, `persistence_mode`,
  `persistence_rdb_frequency`, `persistence_aof_frequency`) now uses
  `x == null ? true : contains(...)`, which does short-circuit.
- **`azurerm_private_dns_zone_virtual_network_link` used the wrong
  argument shape** for current azurerm provider versions —
  `resource_group_name` + `private_dns_zone_name` swapped for the single
  `private_dns_zone_id` argument that resource actually expects.
- **`local.create_dr_private_endpoint` read `var.dr_subnet_id` instead of
  the resolved `local.dr_subnet_id`**, so the DR private endpoint was
  silently never created for anyone using the new name-based DR subnet
  lookup (only a direct `dr_subnet_id` worked). Fixing this the naive
  way (switching to `local.dr_subnet_id`) introduced a genuine
  dependency cycle (`local.create_dr_private_endpoint` → DR subnet data
  source `count` → `local.dr_subnet_id` → back to
  `local.create_dr_private_endpoint`); the actual fix keys this local
  off the **raw** `var.dr_subnet_id`/`var.dr_subnet_name` inputs instead,
  keeping the dependency graph one-directional.
- **`data.azurerm_virtual_network.dr_vnet`'s `count` condition was
  inverted** (`var.dr_vnet_name == null`instead of `!= null`) — the
  lookup only ran when there was nothing to look up, so `dr_vnet_id`
  always resolved to `null` and the DR-region DNS zone link was never
  created even when full DR networking was supplied.

### Added
- `vnet_id` is now resolvable via a name-based lookup
  (`data.azurerm_virtual_network.vnet`, using the same `vnet_name` +
  `vnet_resource_group_name` already required for the subnet lookup)
  instead of always requiring a raw resource ID in `vnet_id`.
- DR-region networking, mirroring the primary's bring-your-own-ID-or-
  look-it-up-by-name pattern: `dr_subnet_name`, `dr_vnet_name`,
  `dr_vnet_resource_group_name`, `dr_vnet_id` variables;
  `data.azurerm_subnet.dr_subnet` / `data.azurerm_virtual_network.dr_vnet`
  data sources; `local.dr_subnet_id` / `local.dr_vnet_id` resolved
  locals.
- `azurerm_private_dns_zone_virtual_network_link.private_dns_link_dr` — a
  second VNet link on the same private DNS zone, so DR-region clients can
  actually resolve the Redis hostname (previously only the primary VNet
  was ever linked, even when a DR private endpoint existed).
- `check "dr_subnet_inputs_complete"` — catches the partial-input case
  (`dr_subnet_name` set without both `dr_vnet_name` and
  `dr_vnet_resource_group_name`) at the module boundary instead of
  failing deep inside the data source with a confusing error.
- `check "dr_private_dns_zone_link_requires_vnet_id"` — DR-region
  equivalent of `private_dns_zone_link_requires_vnet_id`.
- `local.valid_dr_subnet_inputs` / `local.valid_dr_vnet_id_for_dns_link`
  precondition helpers in `all-locals.tf`.

With DR networking fully supplied, `DR-ActivePassive` now produces 7
resources (was 5) and `DR-ActiveActive` produces 8 (was 6) — the DR
private endpoint and DR-region DNS zone link that were silently missing
before are now created.

## [4.0.0] - 2026-08-22

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

## [3.0.0] - 2026-08-22

Restructures the module to match a reviewed pattern (single defaults file,
effective-value locals, REQUIRED/OPTIONAL variable banners, cross-field
`check` blocks, no in-module provider config). Behaviorally equivalent to
`2.0.0` for every existing input **except** the provider/auth removal below,
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
  `prod_sku_name` variables from `1.0.0`). See README "The 'one file for
  defaults' design."
- **Every variable with a default now defaults to `null`** and resolves via
  `all-locals.tf`, rather than carrying a literal default in `variables.tf`.
  Functionally equivalent to `2.0.0`'s literal defaults — this only changes
  *where* the default value lives.
- **`client_protocol` and `public_network_access` are no longer
  independently tunable.** `2.0.0` allowed overriding them to `Plaintext` /
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

### Removed
- `providers.tf`, `usr-client-id`, `usr-client-secret`, `usr-tenant-id`,
  `usr-subscription-id` (see BREAKING above).
- `locals.tf` and `validate.tf` (merged into `all-locals.tf` and
  `variables.tf` respectively).

## [2.0.0] - 2026-08-22

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

## [1.0.0] - undated (initial working prototype)

Initial hardcoded proof-of-concept, captured from the working build referenced
during the `2.0.0` refactor:

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
  `usr-subscription-id` variables (removed in `3.0.0`).
