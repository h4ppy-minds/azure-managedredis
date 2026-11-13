Here's a commit message for each repo. The body doubles as the PR description.

### Module repo: `terraform-azure-dpe-azure-managed-redis-cloud-3-0`

```text
feat!: HA and clustering policy per topology, clustering policy guard (v0.5.0)
```

```text
Each deployment topology now defines its HA rule and allowed clustering
policies, instead of one fixed clustering policy per topology.

Platform policy (all-locals.tf -> topology-profile, first = default):
  STANDALONE        HA optional (default off)  EnterpriseCluster         no DR
  HA                HA always on               EnterpriseCluster | OSS   no DR
  DR-ActivePassive  HA always on               EnterpriseCluster | OSS   DR
  DR-ActiveActive   HA always on               EnterpriseCluster | OSS   DR + geo

Changes
- topology-profile: HA default, ha-optional, allowed clustering-policies,
  DR, geo-replication per topology
- Default clustering policy is EnterpriseCluster for every topology
  (single endpoint, any standard client; dev and prod use the same code)
- NoCluster is legacy only: accepted when passed explicitly, only for
  STANDALONE, only on SKUs <= 25 GB (B0-B20, X3-X20, M10-M20)
- Clustering policy guard: azurerm 4.x applies a clustering_policy change
  by deleting and recreating the database (all data lost, new keys) while
  the plan shows "update in-place". Both caches now ignore_changes on
  default_database[0].clustering_policy, with a postcondition that fails
  the plan if the requested policy differs from the actual one
- Plan-time preconditions: clustering policy allowed for the topology;
  HA off only for STANDALONE (covers geo-replication needing HA);
  persistence requires HA; legacy NoCluster only on SKUs <= 25 GB
- New output: high-availability-enabled
- Variable descriptions rewritten (deployment-topology,
  high-availability-enabled, clustering-policy, persistence-mode)

Tests
- tests/clustering-and-ha.tftest.hcl: policy per topology, HA rules,
  NoCluster limits, guard on an existing OSS cache
- tests/legacy-nocluster.tftest.hcl: a pre-0.5.0 STANDALONE cache fails
  the plan without its pin and plans cleanly with it
- tests/redis-modules.tftest.hcl: apply run moved to the end (runs share
  state); two asserts updated for the EnterpriseCluster default
- terraform test: 51 passed

Docs
- README: platform policy, what HA on/off means, DR without HA,
  clustering pros/cons, effect of a clustering change, upgrading existing
  caches; corrected "must be replaced" claims for module/clustering
  changes and the node-type limitation (sku_name is ForceNew)
- CHANGELOG: 0.5.0 entry with migration notes

BREAKING CHANGE: callers that don't pass clustering-policy now get
EnterpriseCluster. Existing caches must pass the policy they have today
(STANDALONE -> "NoCluster", HA/DR without RediSearch -> "OSSCluster"),
otherwise the plan fails with "Clustering policy change blocked for
<name>". Nothing is changed or deleted in Azure either way.
```

### Template repo: `Azure-Cld3-CFES-AMR`

```text
feat!: high_availability and clustering_policy request fields, intake client guidance (v0.5.0)
```

```text
Adopts redis module v0.5.0: per-topology HA and clustering policy,
consumer guidance in the intake, and pins for existing caches so nothing
changes in Azure.

Request fields
- high_availability (STANDALONE only): true = 2 nodes, allows persistence
- clustering_policy: STANDALONE -> EnterpriseCluster; HA/DR ->
  EnterpriseCluster (default) or OSSCluster. Fallback: request ->
  default.json (EnterpriseCluster) -> module default; RediSearch ->
  EnterpriseCluster. NoCluster accepted only as a legacy pin
- Both passed to the module (high-availability-enabled, clustering-policy)

Intake schema (config/redis-intake-schema.json)
- clustering_policy options with UI titles (x-ui-options: Enterprise,
  OSS); NoCluster marked deprecated/legacy, never offered
- high_availability shown only for STANDALONE (x-ui-show-when)
- Rules: STANDALONE -> Enterprise (or legacy NoCluster); HA/DR -> HA on;
  NoCluster only STANDALONE and <= 25 GB; RediSearch -> Enterprise;
  STANDALONE without HA -> persistence DISABLED
- x-client-guidance: connection settings per language; Enterprise = no
  code changes; OSS = cluster client, hash-slot keys, ports 10000 +
  8500-8599, shard DNS; what switching from STANDALONE means

Checks (name the offending request; the module fails the plan)
- standalone-is-enterprise-cluster-only
- ha-only-optional-for-standalone
- persistence-requires-ha
- legacy-nocluster-only-standalone-25gb
- redisearch-requires-enterprise-cluster
- prod-should-not-be-standalone now only flags STANDALONE without HA

Outputs
- redis-instances[*].high-availability-enabled
- derived-config-by-instance[*]: clustering-policy, high-availability

Config
- default.json: "clustering_policy": "EnterpriseCluster"
- test-standalone-cache: pin NoCluster; test-ha-cache: pin OSSCluster
  (both deployed before 0.5.0)
- test-dr-active-passive: shows OSSCluster
- test-dr-active-active: Balanced_B0 -> Balanced_B10 (B0 can't
  geo-replicate)
- New fixture test-standalone-ha-cache (STANDALONE + HA + RDB)

Docs
- README: HA / DR / clustering policy section, upgrade checklist for
  existing caches, follow-ups (NBA preprod, MacSpider prod)
- CHANGELOG: 0.5.0 entry with migration steps

BREAKING CHANGE: every existing request must state the clustering policy
it has today before this is applied:
  OSSCluster: Axios (dev, qa), IDAM authz (dev, qa), CodeReviewAgent
              (dev, prod), CWX AXP (qa, prod), NBA (dev, preprod)
  NoCluster:  RedisML (dev), CryptoAPI (qa), Retail semantic (qa),
              MacSpider (preprod, prod)
Then plan each environment: existing caches must show no changes and
0 to destroy. Never remove a request file to skip a cache.
Requires redis module >= 0.5.0.
```

For the template PR, link the module PR and add the dev `terraform plan` summary (0 to change, 0 to destroy for existing caches) as evidence.