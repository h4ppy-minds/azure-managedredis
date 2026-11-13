# Changelog

All notable changes to this onboarding root are documented here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioned independently of the redis module it calls, but each entry notes
which module version it's paired with.

## [Unreleased]

## [0.5.0] - 2026-11-12 (paired with redis module v0.5.0)

### Added
- **`clustering_policy` request field**: `EnterpriseCluster` (default) for
  every topology, `OSSCluster` for HA/DR only. Fallback: request →
  `default.json.clustering_policy` (new, `EnterpriseCluster`) → module
  topology default. RediSearch requests get `EnterpriseCluster`
  automatically. Passed to the module (`clustering-policy`).
- **`high_availability` request field** (STANDALONE only): `true` = two
  nodes, allows persistence. HA/DR always have HA. Passed to the module
  (`high-availability-enabled`).
- Intake schema:
  - `clustering_policy` as `oneOf` options with title/description for the
    UI (`x-ui-options`: EnterpriseCluster, OSSCluster); `NoCluster` listed
    as deprecated/legacy-only, never to be offered.
  - `high_availability` with `x-ui-show-when` STANDALONE.
  - Rules: STANDALONE → EnterpriseCluster (or legacy NoCluster); HA/DR →
    `high_availability` true; NoCluster only STANDALONE and ≤ 25 GB;
    RediSearch → EnterpriseCluster; STANDALONE without HA → persistence
    DISABLED.
  - Top-level **`x-client-guidance`**: per policy, how to connect (Spring
    Boot, Lettuce, Jedis, StackExchange.Redis, redis-py, node-redis /
    ioredis, go-redis), code changes and network/DNS needs for
    OSSCluster, and what switching from STANDALONE means (Enterprise: no
    code change; OSS: listed changes).
  - `deployment_topology` description rewritten around the policy.
- Advisory checks naming the request: `standalone-is-enterprise-cluster-only`,
  `ha-only-optional-for-standalone`, `persistence-requires-ha`,
  `legacy-nocluster-only-standalone-25gb`,
  `redisearch-requires-enterprise-cluster`.
- Outputs: `redis-instances[*].high-availability-enabled`;
  `derived-config-by-instance[*]` `clustering-policy`, `high-availability`.
- Fixture `test-standalone-ha-cache.json` (STANDALONE + HA + RDB).
- README: "High availability, DR and clustering policy" and "Upgrading
  existing caches to 0.5.0" with the checklist of existing consumer caches.

### Changed
- `prod-should-not-be-standalone` now flags only STANDALONE requests
  without `high_availability: true`.
- Fixtures: `test-standalone-cache.json` pins `NoCluster` and
  `test-ha-cache.json` pins `OSSCluster` (both deployed before 0.5.0);
  `test-dr-active-passive-cache.json` shows `OSSCluster`;
  `test-dr-active-active-cache.json` `Balanced_B0` → `Balanced_B10` (B0/B1
  can't geo-replicate, so it was never deployable).

### Migration
- Upgrade the module to 0.5.0 at the same time.
- **Before applying**, add `clustering_policy` to every existing request
  (README checklist): STANDALONE → `"NoCluster"`, HA/DR without
  RediSearch → `"OSSCluster"`. Then plan each environment: existing caches
  must show no changes and the plan 0 to destroy.
- Never remove a request file to skip a cache — Terraform would destroy it.

## [0.4.0] - 2026-11-09 (paired with redis module v0.4.0)

### Added
- **A second private endpoint for every instance, in the other region**,
  matching the org's PostgreSQL module. The paired region (from
  `dr_region_pairs`) and its resource group and subnet (from
  `environments.<env>.regions`) are now resolved for **every** request, not
  only DR topologies, and passed to the module. Endpoint counts:
  STANDALONE/HA 2, DR topologies 4. No request-file changes.
- `redis-instances` output: `private-endpoint-primary-paired-region-id` and
  `private-endpoint-dr-paired-region-id`.

### Changed
- `dr-requires-supported-region-pair` now applies to every request (every
  location needs a pair) and names the offending requests.
- `dr-location-is-a-configured-region` message now covers the paired-region
  endpoint as well as DR instances.

### Migration
- Upgrade the module to 0.4.0 at the same time; template 0.4.0 does not
  work with module 0.3.0 (it reads the module's new endpoint outputs).
- Every existing STANDALONE/HA cache plans as **1 to add, 0 to change, 0 to
  destroy**: its new paired-region endpoint. Verified by applying template
  0.3.0 + module 0.3.0 and planning 0.4.0 + 0.4.0 against the same state.
- Infoblox must register the new endpoints' IPs per region before clients
  in the paired region can use them.

## [0.3.0] - 2026-10-28 (paired with redis module v0.3.0)

### Changed
- **This template now owns environments.** Module 0.3.0 removed its
  `environment` input, so `main.tf` passes the full name
  `"<instance.name>-<env>"` as `name` and no longer passes `environment`.
  Azure resource names are unchanged, so existing caches plan with **no
  changes**.
- The `redis-instances` output keeps its `resolved-environment` key; its
  value now comes from `var.env` (the module no longer outputs it).
- Intake schema: `instance.name` is now capped at 49 characters (was 57),
  so `<name>-preprod-dr` stays within Azure's 60-character limit.

### Added
- **`preprod` environment:** `env` validation in `variables.tf`, the intake
  schema's `environment` enum, and an `environments.preprod` block in
  `default.json`. The block ships with a placeholder subscription ID and
  `REPLACE-ME` networking values: fill in the real subscription, resource
  groups, VNets and subnets for both regions before the first preprod run.
- `prod-should-not-be-standalone` check (moved here from the module): warns
  when a production-like environment (`preprod`, `prod`, listed in
  `_production_like_envs`) has STANDALONE requests. Advisory only.
- `instance-name-fits-with-environment` check: names any request whose
  `<name>-<env>` exceeds 57 characters (the module then fails the plan).

### Migration
- Upgrade the module to 0.3.0 at the same time; template 0.3.0 does not
  work with module 0.2.6 (it no longer passes `environment`).
- Run `terraform plan` on every workspace before applying: expect no
  resource changes, only output changes if any.

## [0.2.1] - 2026-09-24 (paired with redis module v0.2.6)

### Added
- **`redis_modules` / `redis_module_args` request fields**, for example
  `"redis_modules": ["RediSearch", "RedisJSON", "Bloom", "TimeSeries"]`.
  They are passed to the module's `redis-modules` / `redis-module-args`
  inputs; the module does the hard validation. Unlike other fields, there
  is deliberately **no `default.json` fallback**: a platform-wide module
  default would force-replace every existing cache that doesn't list its
  own modules. Omitted or null means none.
- Per-request advisory checks in `locals.tf`: `redis-modules-valid-shape`,
  `redis-modules-valid-names`, `redis-modules-no-duplicates`,
  `redis-modules-active-active-compatible`,
  `redis-modules-sku-compatible` and `redisearch-requires-noeviction`.
  Each names the offending request.
- A request whose `redis_modules` / `redis_module_args` has the wrong JSON
  shape now fails the plan. It is replaced with a sentinel value that the
  module rejects, rather than being silently ignored.
- `eviction_policy` now defaults to `NoEviction`, not `default.json`'s
  value, when a request enables RediSearch and doesn't set it.
- The `redis-instances` output now includes `redis-modules`,
  `clustering-policy` and `eviction-policy`. The
  `derived-config-by-instance` output now includes `redis-modules` and
  `eviction-policy`.
- `redis-intake-schema.json`: `redis_modules` / `redis_module_args`
  properties, plus `allOf` if/then rules rejecting Bloom/TimeSeries with
  DR-ActiveActive, unsupported modules on Flash node types, and RediSearch
  with any eviction_policy other than NoEviction.
- New fixture `test-ha-modules-cache.json` with all four modules. The
  existing four fixtures are unchanged, so already-deployed test caches
  are not replaced.

### Fixed
- The `dr-location-is-a-configured-region` check errored ("argument must not
  be null") for every non-DR request, because `dr_loc == null || contains(...)`
  does not short-circuit on all Terraform/OpenTofu versions. It now uses a
  conditional.

## [0.2.0] - 2026-08-25 (paired with redis module v0.2.6)

### Changed — BREAKING (default.json schema)
- **`environments.<env>.location` and `environments.<env>.networking`
  replaced by `environments.<env>.default_location` and
  `environments.<env>.regions.<region-name>`.** Each region entry has its
  own `resource_group_name` and `networking` block. Both primary and DR
  now look up whichever region they need from this single map, instead
  of primary using a flat block and DR using a separately-shaped
  `dr_networking` key. **Migration:** restructure every environment in
  `default.json` — wrap the existing `resource_group_name`/`networking`
  under a `regions.<original-location>` key, and add a second
  `regions.<dr-region>` entry using what used to be `dr_networking`
  (now with its own `resource_group_name` too, not shared with primary —
  see below).
- **`environments.<env>.dr_networking` removed** — folded into the
  unified `regions` map above.
- **DR now resolves its own resource group**, via the redis module's new
  `dr-resource-group-name` variable (v0.2.6), instead of implicitly
  sharing the primary's resource group. Every environment's `default.json`
  entry in this release gives each region (including the DR region) a
  distinct resource group name, following standard Azure guidance (one
  resource group per region) — see the redis module's own README for the
  rationale.
- `locals.tf` restructured internally: primary `location` and derived
  `dr_location` are now resolved as their own intermediate maps
  (`_instance_locations`, `_instance_dr_locations`) computed BEFORE the
  per-instance staging object, rather than inline — HCL object
  construction can't reference a sibling key of the same object literal,
  and the region-lookup-by-location this release adds needed that
  ordering. No behavioral difference for existing requests; only
  internal.

### Added
- `location-is-a-configured-region` / `dr-location-is-a-configured-region`
  checks — clear plan-time errors instead of a Terraform "attribute not
  found" crash if a request's region isn't configured for that
  environment.
- Any region present in an environment's `regions` map can now be
  requested as a **primary** `location`, not only as a DR target — this
  was the actual gap that prompted this release (a client requesting
  `centralus` as their primary previously landed in the eastus2 resource
  group and eastus2 subnet, since neither was region-aware).

## [0.1.1] - 2026-08-22 (paired with redis module v0.2.3)

Directed change following senior leadership review, following the same
breaking changes made to the redis module. See that module's `0.2.0`
CHANGELOG entry for the full rationale; this entry covers only what
changed in the template itself.

### Changed — BREAKING
- **`locals.tf` Layer 3's staging map now uses kebab-case keys**
  (`resource-group-name`, `node-type`, `deployment-topology`, ...),
  matching the redis module's v0.2.3 variable names 1:1. Request-file
  JSON field names are unchanged (still snake_case) — only the
  Terraform-side staging map and the module call in `main.tf` changed.
- **`geo_replication_group_name` fallback fixed.** Previously fell back to
  `null` on the (incorrect) assumption that Azure auto-generates a name
  when omitted — it doesn't; the API requires a real value. Now falls
  back to a deterministic `<name>-<env>-geo` when a request doesn't
  override it.
- **`vnet_id` / DNS-zone arguments removed from the module call
  entirely.** The redis module no longer accepts `create_private_dns_zone`,
  `private_dns_zone_ids`, or `vnet_id`/`dr_vnet_id` — it no longer creates
  or links a private DNS zone at all (Infoblox handles this outside
  Terraform now). This template never actually shipped a `dns.tf` file
  (it was discussed but not yet written before this rework), so there was
  no shared-zone workaround to remove — this entry exists mainly so the
  absence is understood as deliberate, not an oversight.
- **DR-region networking (`dr_networking` in `default.json`) is now
  effectively required** for any environment where a `DR-*` topology will
  be requested — the module no longer treats a missing DR private
  endpoint as a valid opt-out state.
- **`output.tf` renamed to match**: `redis_instances` → `redis-instances`,
  `redis_primary_access_keys` → `redis-primary-access-keys`,
  `derived_config_by_instance` → `derived-config-by-instance`, and every
  field inside them.
- **`private_dns_zone_ids` removed from `redis-instances` output** — the
  module no longer produces it.

### Added
- `redis-primary-port` / `redis-dr-port` passed through in the
  `redis-instances` output.
- Note in README on tag preservation now being module-level
  (`lifecycle { ignore_changes = [tags] }`) rather than something this
  template needs to handle — Layer 4's tag computation only takes effect
  on an instance's first apply.
