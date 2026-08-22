# Azure Managed Redis — Onboarding Root

Self-service onboarding for the Azure Managed Redis Terraform module. One
JSON file per instance, one PR per request, no shared file to
merge-conflict over — same pattern as the Valkey onboarding root, adapted
to Azure.

## How it works

1. **`config/onboarding-files-redis/default.json`** — global technical
   defaults, plus a `environments.<env>` block per environment
   (subscription, resource group, location, VNet/subnet, DR VNet/subnet).
   Maintained by the platform team, not by requesters.
2. **`config/onboarding-files-redis/*.json`** (everything except
   `default.json`) — one file per onboarding request:
   `{ request_type, environment, requested_by, instance: {...} }`. A team
   opens a PR adding or editing exactly one file.
3. **`locals.tf`** merges default.json + the matching `environments.<env>`
   block + each request file, field by field, into exactly the variable
   names the redis module expects — then derives `dr_location` (from
   `dr_region_pairs`) and `tags` (from `application_id`/`lob`/free-form
   `tags`, plus always-derived `topology`/`environment`/`managed_by`).
4. **`main.tf`** calls `module "redis"` once per resulting instance via
   `for_each`.

`terraform plan -var env=dev` (or `qa`/`uat`/`prod`) picks up every
request file targeting that environment automatically.

## Request file shape

See [`config/redis-intake-schema.json`](./config/redis-intake-schema.json)
for the full reference — every field, default, and which fields are
computed (never request-settable). Four working examples are in
[`config/onboarding-files-redis/`](./config/onboarding-files-redis/), one
per `deployment_topology`:

| File | `deployment_topology` |
|---|---|
| `test-standalone-cache.json` | `STANDALONE` |
| `test-ha-cache.json` | `HA` |
| `test-dr-active-passive-cache.json` | `DR-ActivePassive` |
| `test-dr-active-active-cache.json` | `DR-ActiveActive` |

## Differences from the Valkey onboarding root

- **No `deployment_topology` derivation.** The redis module already made
  `deployment_topology` a single settable enum, so the request states it
  directly (`"deployment_topology": "HA"`) instead of this template
  deriving it from `replica_count`/`cross_region_replica` booleans.
- **No RDB start-time anchoring.** `azurerm_managed_redis` persistence is
  a plain frequency string, no start-time field — so there's no
  `rdb_snapshot_timing.tf` equivalent here.
- **`authorization_mode` is a real request field.** The redis module
  doesn't hard-lock this the way it hard-locks `client_protocol`/
  `public_network_access` — Azure's provider can't yet automate the
  Entra ID data-plane grant the way GCP's provider automates IAM
  bindings, so `AccessKey` vs. `MicrosoftEntraID` is a genuine,
  documented-tradeoff choice (see the schema and the redis module's own
  README).
- **No alerting module call.** The redis module has no alerting
  submodule yet — see `main.tf`'s comment for how to add one following
  the same split (separate module, same `for_each` keys, wired to
  `module.redis`'s own outputs) if/when that exists.
- **Uniqueness is enforced, not just documented.** The
  `request_names_unique_per_environment` check block fails plan (rather
  than silently applying one of two colliding requests) if two files
  targeting the same environment share an `instance.name`.

## DR region pairs

Cross-region DR (`DR-ActivePassive`/`DR-ActiveActive`) is only supported
between the specific primary/secondary region pairs listed in
`default.json`'s `dr_region_pairs` — currently just `eastus2 <->
centralus`. Requesting DR from an unpaired `location` fails plan with a
clear error (`dr_requires_supported_region_pair` check) rather than a
confusing Azure API error. Add a new pair to `dr_region_pairs` to support
more regions; no other file needs to change.

## Running it

```powershell
terraform init
terraform plan -var env=dev
terraform apply -var env=dev
```

Swap `-var env=dev` for `qa`/`uat`/`prod` to target a different
environment's request files — each environment plans and applies
independently.
