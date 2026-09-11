# Azure Managed Redis — Onboarding Root

Self-service onboarding for the Azure Managed Redis Terraform module. One
JSON file per instance, one PR per request, no shared file to
merge-conflict over — same pattern as the Valkey onboarding root, adapted
to Azure.

Paired with redis module **v5.0.0** — see that module's CHANGELOG for the
breaking changes this template's `v2` was updated against.

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

`terraform plan -var env=dev` (or `qa`/`uat`/`prod`) picks up every
request file targeting that environment automatically.

## Naming convention: kebab-case Terraform surface, unchanged JSON schema

The redis module's variables and outputs are all kebab-case as of v5.0.0
(`resource-group-name`, `node-type`, `redis-primary-id`, ...). This
template's own `locals.tf` Layer 3 builds a staging map with matching
kebab-case keys, so `main.tf`'s module call is close to a pass-through.

**Request-file JSON field names are deliberately NOT renamed** — they stay
`deployment_topology`, `node_type`, etc. Renaming those would ripple into
the wrapper-API mapping docs and every existing request file for no real
benefit; the translation from snake_case JSON to kebab-case Terraform
happens once, inside `locals.tf`, and nowhere else needs to know about it.

## Every instance gets a private endpoint — no toggle, no DNS zone

The redis module (v5.0.0) always creates a private endpoint for every
instance — primary unconditionally, DR whenever the topology creates one.
There's no `create_private_endpoint`-equivalent request field, and none is
needed. **The module also no longer creates or links a private DNS
zone** — DNS resolution for these private endpoints is handled by
infrastructure automation outside Terraform (Infoblox). This template has
no DNS-related resources of its own either.

Because DR private endpoints are no longer optional, `dr_networking` in
`default.json` is now effectively **required** for any environment where
a `DR-*` topology will be requested — an environment missing it will fail
plan (via the module's own checks) the first time someone submits a
`DR-ActivePassive`/`DR-ActiveActive` request there, rather than silently
creating a DR instance with no private endpoint the way earlier versions
did.

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
| `test-standalone-cache.json` | `STANDALONE` |
| `test-ha-cache.json` | `HA` |
| `test-dr-active-passive-cache.json` | `DR-ActivePassive` |
| `test-dr-active-active-cache.json` | `DR-ActiveActive` |

## Regions are first-class — any configured region works as primary OR DR

`default.json`'s `environments.<env>` has a `regions` map keyed by region
name (`eastus2`, `centralus`, ...), each with its own
`resource_group_name` and `networking` block. A request's `location` is
looked up against this map for **both** primary and DR — there's no
special-cased "primary uses one flat block, DR uses a different shaped
block" asymmetry any more. This means a client can request `centralus` as
their **primary** region (not just as a DR target) as long as
`environments.<env>.regions.centralus` exists in `default.json`.

**DR gets its own resource group**, matching the redis module's v5.2.0
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

Cross-region DR is only supported between the pairs listed in
`default.json`'s `dr_region_pairs` — currently `eastus2 <-> centralus`.
Requesting DR from an unpaired `location` fails plan with a clear error
(`dr-requires-supported-region-pair` check).

## Uniqueness is enforced, not just documented

The `request-names-unique-per-environment` check block fails plan if two
files targeting the same environment share an `instance.name`.

## Running it

```powershell
terraform init
terraform plan -var env=dev
terraform apply -var env=dev
```
