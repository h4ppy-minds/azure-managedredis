############################################
# Private endpoints.
#
# This module does NOT create or link a private DNS zone itself (removed
# in v0.2.0) — DNS resolution for these private endpoints is handled by
# infrastructure automation outside this module (Infoblox). That
# automation attaches a private_dns_zone_group to each endpoint AFTER
# Terraform creates it — out-of-band, not through this config. Both
# endpoints below therefore ignore_changes on private_dns_zone_group:
# without that, every plan would see Infoblox's attachment as drift from
# "no private_dns_zone_group block declared here" and try to remove it,
# fighting the external automation on every single apply. (Bug found
# during integration testing — v0.2.3.)
#
# Two endpoints per instance, one in each region — the same pattern as the
# org's PostgreSQL flexible-server module (<server>-PE + <server>-PE-DR on
# the primary AND on every replica):
#
#   primary                 pe-<name>             primary's region   always
#   primary-paired-region   pe-<name>-dr          paired region      whenever dr-location is set (every topology)
#   dr                      pe-<name>-drcache     DR's region        DR topologies only
#   dr-paired-region        pe-<name>-drcache-dr  primary's region   DR topologies only
#
# "-dr" at the END of an endpoint name means "this endpoint sits in the
# other region", matching PostgreSQL's -PE-DR. The DR instance's endpoints
# use "drcache" so they never collide with the primary's.
# (Before v0.4.0 the DR instance's endpoint was named pe-<name>-dr.)
#
# Each "-dr" endpoint depends_on its instance's first endpoint, as the
# PostgreSQL module does: creating two private endpoints on the same
# resource at the same time can fail with "another operation is in
# progress". For the same reason the DR endpoint (0.2.5 fix) and the
# primary's paired-region endpoint also wait for geo-replication, which
# operates on both instances (DR-ActiveActive only; otherwise a no-op).
############################################

resource "azurerm_private_endpoint" "primary" {
  name                = "pe-${var.name}"
  location            = var.location
  resource_group_name = var.resource-group-name
  subnet_id           = local.subnet-id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_managed_redis.primary.id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  lifecycle {
    # tags: see main.tf's note on tag preservation.
    # private_dns_zone_group: Infoblox attaches this out-of-band after
    # create — without ignoring it, every plan tries to remove what
    # Infoblox just set up.
    ignore_changes = [tags, private_dns_zone_group]

    precondition {
      condition     = local.valid-subnet-for-private-endpoint
      error_message = "No subnet could be resolved for the primary private endpoint. Set subnet-id, or all of subnet-name/vnet-name/vnet-resource-group-name."
    }
  }
}

# The primary instance, reached from the paired region: same target as
# "primary" above, but the endpoint sits in the paired region's subnet so
# clients there get a private IP in their own region. Traffic still goes
# to the primary's region; this is regional access, not failover.
resource "azurerm_private_endpoint" "primary-paired-region" {
  count      = local.create-paired-region-endpoint ? 1 : 0
  depends_on = [azurerm_private_endpoint.primary, azurerm_managed_redis_geo_replication.geo]

  name                = "pe-${var.name}-dr"
  location            = var.dr-location
  resource_group_name = local.dr-resource-group-name
  subnet_id           = local.dr-subnet-id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}-dr"
    private_connection_resource_id = azurerm_managed_redis.primary.id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  lifecycle {
    ignore_changes = [tags, private_dns_zone_group]

    precondition {
      condition     = local.valid-paired-region
      error_message = "dr-location ('${coalesce(var.dr-location, "null")}') must be a different region from location ('${var.location}') — the paired-region private endpoint has to sit in the other region."
    }
    precondition {
      condition     = local.valid-dr-subnet-inputs
      error_message = "dr-location is set, so the primary gets a private endpoint in the paired region, which needs a subnet there. Set dr-subnet-id, or all of dr-subnet-name/dr-vnet-name/dr-vnet-resource-group-name."
    }
  }
}

# The DR instance's endpoint in its own (DR) region.
resource "azurerm_private_endpoint" "dr" {
  count = local.create-dr ? 1 : 0

  # 0.2.5 fix: wait for geo-replication to finish linking the DR instance
  # before touching it. No-op unless deployment-topology = DR-ActiveActive.
  depends_on = [azurerm_managed_redis_geo_replication.geo]

  name                = "pe-${var.name}-drcache"
  location            = coalesce(var.dr-location, var.location)
  resource_group_name = local.dr-resource-group-name
  subnet_id           = local.dr-subnet-id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}-drcache"
    private_connection_resource_id = azurerm_managed_redis.dr[0].id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  lifecycle {
    ignore_changes = [tags, private_dns_zone_group]

    precondition {
      condition     = local.valid-dr-subnet-inputs
      error_message = "deployment-topology = '${local.deployment-topology}' creates a DR instance, which always gets a private endpoint. Set dr-subnet-id, or all of dr-subnet-name/dr-vnet-name/dr-vnet-resource-group-name."
    }
  }
}

# The DR instance, reached from the primary's region — like PostgreSQL's
# <replica>-PE-DR. Needed when only the PRIMARY CACHE fails (its region is
# still up): apps in the primary's region switch to the DR instance and
# need a private path to it in their own region.
resource "azurerm_private_endpoint" "dr-paired-region" {
  count      = local.create-dr ? 1 : 0
  depends_on = [azurerm_private_endpoint.dr]

  name                = "pe-${var.name}-drcache-dr"
  location            = var.location
  resource_group_name = var.resource-group-name
  subnet_id           = local.subnet-id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}-drcache-dr"
    private_connection_resource_id = azurerm_managed_redis.dr[0].id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  lifecycle {
    ignore_changes = [tags, private_dns_zone_group]

    precondition {
      condition     = local.valid-subnet-for-private-endpoint
      error_message = "No subnet could be resolved in the primary's region for the DR instance's second private endpoint. Set subnet-id, or all of subnet-name/vnet-name/vnet-resource-group-name."
    }
  }
}
