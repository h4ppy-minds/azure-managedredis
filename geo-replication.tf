############################################
# Geo replication — only prod + prod_mode = active-active.
############################################

resource "azurerm_managed_redis_geo_replication" "geo" {
  count = local.create_geo_replication ? 1 : 0

  managed_redis_id         = azurerm_managed_redis.primary.id
  linked_managed_redis_ids = [azurerm_managed_redis.dr[0].id]
}
