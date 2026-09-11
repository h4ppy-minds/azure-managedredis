# Changelog

All notable changes to this onboarding root are documented here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioned independently of the redis module it calls, but each entry notes
which module version it's paired with.

## [Unreleased]

## [3.0.0] - 2026-08-25 (paired with redis module v5.2.0)

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
  `dr-resource-group-name` variable (v5.2.0), instead of implicitly
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

## [2.0.0] - 2026-08-22 (paired with redis module v5.0.0)

Directed change following senior leadership review, following the same
breaking changes made to the redis module. See that module's `5.0.0`
CHANGELOG entry for the full rationale; this entry covers only what
changed in the template itself.

### Changed — BREAKING
- **`locals.tf` Layer 3's staging map now uses kebab-case keys**
  (`resource-group-name`, `node-type`, `deployment-topology`, ...),
  matching the redis module's v5.0.0 variable names 1:1. Request-file
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
