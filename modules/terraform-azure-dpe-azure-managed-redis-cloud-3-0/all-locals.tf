############################################################################
# all-locals.tf — THE file to edit when you want to change an AZURE MANAGED
# REDIS INSTANCE default (topology, HA/clustering, persistence, auth,
# networking, deletion protection).
#
# Naming note: every local in this file uses hyphens, matching the
# kebab-case convention now used for every variable and output in this
# module (see variables.tf). Hyphens are legal in HCL identifiers; this
# extends that convention from the module's public interface (variables/
# outputs, which is what was specifically requested) into its internal
# locals too, for one consistent style across the whole file rather than
# a visible seam between "public" and "internal" names.
#
# Layout, top to bottom:
#   1. local.defaults      — every literal instance default value.
#   2. local.<name>        — the "effective" value of every variable that
#                            has a default: var.<name> if the caller set
#                            it, else local.defaults.<name>.
#   3. Derived locals       — values computed FROM the effective values
#                            above.
############################################################################

locals {

  ##########################################################################
  # 1. DEFAULTS — edit this map to change an instance default.
  ##########################################################################
  defaults = {
    deployment-topology = "STANDALONE"

    topology-profile = {
      STANDALONE = {
        high-availability-enabled = false
        clustering-policy         = "NoCluster"
        create-dr                 = false
        create-geo-replication    = false
      }
      HA = {
        high-availability-enabled = true
        clustering-policy         = "OSSCluster"
        create-dr                 = false
        create-geo-replication    = false
      }
      "DR-ActivePassive" = {
        high-availability-enabled = true
        clustering-policy         = "OSSCluster"
        create-dr                 = true
        create-geo-replication    = false
      }
      "DR-ActiveActive" = {
        high-availability-enabled = true
        clustering-policy         = "OSSCluster"
        create-dr                 = true
        create-geo-replication    = true
      }
    }

    # NOTE: there is deliberately no per-environment node-type default here
    # any more (v5.0.0). node-type is a REQUIRED variable — the caller
    # (typically an onboarding template with its own sizing policy) always
    # supplies it explicitly. See the CHANGELOG for the migration this
    # implies if you're upgrading from an earlier version.

    eviction-policy = "AllKeysLRU"

    authorization-mode = "MicrosoftEntraID"

    persistence-mode          = "DISABLED"
    persistence-rdb-frequency = "12h"
    persistence-aof-frequency = "1s"

    deletion-protection-enabled = true

    create-timeout = "60m"
    tags           = {}
  }

  ##########################################################################
  # 2. EFFECTIVE VALUES — var override wins, else local.defaults.*.
  ##########################################################################

  environment         = var.environment
  deployment-topology = coalesce(var.deployment-topology, local.defaults.deployment-topology)

  # node-type has no default/coalesce — it's a required variable now, so
  # var.node-type is always already a real value. Referenced directly as
  # var.node-type in main.tf/variables.tf rather than duplicated as a
  # local with nothing left to do.

  high-availability-enabled = (
    var.high-availability-enabled != null
    ? var.high-availability-enabled
    : local.defaults.topology-profile[local.deployment-topology].high-availability-enabled
  )
  clustering-policy = coalesce(
    var.clustering-policy,
    local.defaults.topology-profile[local.deployment-topology].clustering-policy
  )

  eviction-policy = coalesce(var.eviction-policy, local.defaults.eviction-policy)

  # Not tunable — see "Network exposure and transit encryption are
  # mandatory, not defaults" in variables.tf / README.md.
  client-protocol       = "Encrypted"
  public-network-access = "Disabled"

  authorization-mode                 = coalesce(var.authorization-mode, local.defaults.authorization-mode)
  access-keys-authentication-enabled = local.authorization-mode == "AccessKey"

  persistence-mode          = coalesce(var.persistence-mode, local.defaults.persistence-mode)
  persistence-rdb-frequency = coalesce(var.persistence-rdb-frequency, local.defaults.persistence-rdb-frequency)
  persistence-aof-frequency = coalesce(var.persistence-aof-frequency, local.defaults.persistence-aof-frequency)

  deletion-protection-enabled = (
    var.deletion-protection-enabled != null ? var.deletion-protection-enabled : local.defaults.deletion-protection-enabled
  )

  create-timeout = coalesce(var.create-timeout, local.defaults.create-timeout)
  tags           = var.tags != null ? var.tags : local.defaults.tags

  ##########################################################################
  # 3. DERIVED LOCALS
  ##########################################################################

  is-dev  = local.environment == "dev"
  is-prod = local.environment == "prod"

  create-dr              = local.defaults.topology-profile[local.deployment-topology].create-dr
  create-geo-replication = local.defaults.topology-profile[local.deployment-topology].create-geo-replication

  persistence-mode-effective = local.create-geo-replication ? "DISABLED" : local.persistence-mode

  # --- Networking resolution ---
  # Every instance gets a private endpoint — primary always, DR whenever
  # create-dr is true. There is no toggle to opt out of either. Subnet
  # info is therefore always required (enforced by the checks below and a
  # matching lifecycle.precondition in main.tf/network.tf).
  subnet-id = coalesce(var.subnet-id, try(data.azurerm_subnet.subnet[0].id, null))

  dr-subnet-id = var.dr-subnet-id != null ? var.dr-subnet-id : try(data.azurerm_subnet.dr-subnet[0].id, null)

  # --- Precondition helpers (see main.tf / network.tf lifecycle blocks) ---
  valid-subnet-for-private-endpoint = local.subnet-id != null

  valid-dr-location-for-dr = !local.create-dr || var.dr-location != null

  # Whenever create-dr is true, DR must have a resolvable subnet — either
  # a direct dr-subnet-id, or a complete name-based lookup trio.
  valid-dr-subnet-inputs = (
    !local.create-dr ||
    var.dr-subnet-id != null ||
    (var.dr-subnet-name != null && var.dr-vnet-name != null && var.dr-vnet-resource-group-name != null)
  )
}
