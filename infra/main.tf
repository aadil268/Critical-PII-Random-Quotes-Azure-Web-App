# Generates a short unique suffix so globally-scoped Azure names remain collision-free across deployments.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

# Creates a strong SQL admin password at deploy time to avoid hardcoding credentials in source or tfvars.
resource "random_password" "sql_admin" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Centralizes derived naming values so all resources follow a consistent, environment-specific naming convention.
locals {
  resource_suffix       = random_string.suffix.result
  key_vault_name        = "kv${local.project_slug}${local.env_slug}${local.resource_suffix}"
  sql_primary_name      = "sqlp${local.project_slug}${local.env_slug}${local.resource_suffix}"
  sql_secondary_name    = "sqls${local.project_slug}${local.env_slug}${local.resource_suffix}"
  web_primary_name      = "web-p-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  web_secondary_name    = "web-s-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  fd_profile_name       = "fd-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  fd_endpoint_name      = "fdep-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  failover_group_name   = "fog-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  failover_group_fqdn   = "${local.failover_group_name}.database.windows.net"
  plan_primary_name     = "asp-p-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  plan_secondary_name   = "asp-s-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  insights_primary_name = "appi-p-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  insights_second_name  = "appi-s-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
}

# Provisions the primary resource group as the lifecycle boundary that contains and tags all workload resources.
resource "azurerm_resource_group" "main" {
  name     = "rg-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  location = var.primary_location
  tags     = local.tags
}

# Deploys a shared Log Analytics workspace to collect and retain telemetry for observability and troubleshooting.
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_in_days
  tags                = local.tags
}

# Creates Application Insights in the primary region so the primary app instance can emit APM telemetry.
resource "azurerm_application_insights" "primary" {
  name                = local.insights_primary_name
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = merge(local.tags, { RegionRole = "Primary" })
}

# Creates Application Insights in the secondary region for regional telemetry continuity during failover.
resource "azurerm_application_insights" "secondary" {
  name                = local.insights_second_name
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = merge(local.tags, { RegionRole = "Secondary" })
}

# Builds the primary VNet to provide private network isolation for app, database, and endpoint traffic.
resource "azurerm_virtual_network" "primary" {
  name                = "vnet-p-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.30.0.0/16"]
  tags                = merge(local.tags, { RegionRole = "Primary" })
}

# Defines the primary delegated app subnet required for App Service VNet integration and controlled egress routing.
resource "azurerm_subnet" "primary_app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.primary.name
  address_prefixes     = ["10.30.1.0/24"]

  delegation {
    name = "webapps"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Defines the primary private-endpoint subnet to host private links for PaaS services without public exposure.
resource "azurerm_subnet" "primary_private_endpoint" {
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.primary.name
  address_prefixes                  = ["10.30.2.0/24"]
  private_endpoint_network_policies = "Enabled"
}

# Builds the secondary VNet to mirror network topology in the DR region for high availability.
resource "azurerm_virtual_network" "secondary" {
  name                = "vnet-s-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.40.0.0/16"]
  tags                = merge(local.tags, { RegionRole = "Secondary" })
}

# Defines the secondary delegated app subnet so the standby app can run with the same network controls.
resource "azurerm_subnet" "secondary_app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.secondary.name
  address_prefixes     = ["10.40.1.0/24"]

  delegation {
    name = "webapps"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Defines the secondary private-endpoint subnet to keep regional data-plane access private during failover.
resource "azurerm_subnet" "secondary_private_endpoint" {
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.secondary.name
  address_prefixes                  = ["10.40.2.0/24"]
  private_endpoint_network_policies = "Enabled"
}

# Applies NSGs to all subnets so traffic policy is explicit and centrally governable.
resource "azurerm_network_security_group" "primary_app" {
  name                = "nsg-p-app-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(local.tags, { RegionRole = "Primary", SubnetRole = "App" })

  security_rule {
    name                       = "AllowVnetPrivateEndpointOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "1433"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureMonitorOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureMonitor"
  }

  security_rule {
    name                       = "DenyInternetOutbound"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "primary_private_endpoint" {
  name                = "nsg-p-pe-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(local.tags, { RegionRole = "Primary", SubnetRole = "PrivateEndpoint" })

  security_rule {
    name                       = "AllowVnetHttpsInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowVnetSqlInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyInternetOutbound"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_network_security_group" "secondary_app" {
  name                = "nsg-s-app-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(local.tags, { RegionRole = "Secondary", SubnetRole = "App" })

  security_rule {
    name                       = "AllowVnetPrivateEndpointOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "1433"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureMonitorOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureMonitor"
  }

  security_rule {
    name                       = "DenyInternetOutbound"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "secondary_private_endpoint" {
  name                = "nsg-s-pe-${local.project_slug}-${local.env_slug}-${local.resource_suffix}"
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(local.tags, { RegionRole = "Secondary", SubnetRole = "PrivateEndpoint" })

  security_rule {
    name                       = "AllowVnetHttpsInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowVnetSqlInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyInternetOutbound"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "primary_app" {
  subnet_id                 = azurerm_subnet.primary_app.id
  network_security_group_id = azurerm_network_security_group.primary_app.id
}

resource "azurerm_subnet_network_security_group_association" "primary_private_endpoint" {
  subnet_id                 = azurerm_subnet.primary_private_endpoint.id
  network_security_group_id = azurerm_network_security_group.primary_private_endpoint.id
}

resource "azurerm_subnet_network_security_group_association" "secondary_app" {
  subnet_id                 = azurerm_subnet.secondary_app.id
  network_security_group_id = azurerm_network_security_group.secondary_app.id
}

resource "azurerm_subnet_network_security_group_association" "secondary_private_endpoint" {
  subnet_id                 = azurerm_subnet.secondary_private_endpoint.id
  network_security_group_id = azurerm_network_security_group.secondary_private_endpoint.id
}

# Peers primary to secondary VNet to enable private cross-region connectivity for dependent services.
resource "azurerm_virtual_network_peering" "primary_to_secondary" {
  name                         = "peer-primary-secondary"
  resource_group_name          = azurerm_resource_group.main.name
  virtual_network_name         = azurerm_virtual_network.primary.name
  remote_virtual_network_id    = azurerm_virtual_network.secondary.id
  allow_virtual_network_access = true
}

# Peers secondary back to primary since Azure VNet peering requires explicit links in both directions.
resource "azurerm_virtual_network_peering" "secondary_to_primary" {
  name                         = "peer-secondary-primary"
  resource_group_name          = azurerm_resource_group.main.name
  virtual_network_name         = azurerm_virtual_network.secondary.name
  remote_virtual_network_id    = azurerm_virtual_network.primary.id
  allow_virtual_network_access = true
}

# Hosts private DNS records for SQL private endpoints so clients resolve SQL over private IPs.
resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Hosts private DNS records for Key Vault private endpoints to enforce private name resolution.
resource "azurerm_private_dns_zone" "keyvault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Links the SQL private DNS zone to the primary VNet so primary workloads can resolve private SQL endpoints.
resource "azurerm_private_dns_zone_virtual_network_link" "sql_primary" {
  name                  = "sql-dns-primary-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.primary.id
}

# Links the SQL private DNS zone to the secondary VNet for consistent private resolution in DR.
resource "azurerm_private_dns_zone_virtual_network_link" "sql_secondary" {
  name                  = "sql-dns-secondary-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.secondary.id
}

# Links the Key Vault private DNS zone to the primary VNet for private vault name resolution.
resource "azurerm_private_dns_zone_virtual_network_link" "keyvault_primary" {
  name                  = "kv-dns-primary-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = azurerm_virtual_network.primary.id
}

# Links the Key Vault private DNS zone to the secondary VNet to preserve secret access during failover.
resource "azurerm_private_dns_zone_virtual_network_link" "keyvault_secondary" {
  name                  = "kv-dns-secondary-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = azurerm_virtual_network.secondary.id
}

# Deploys a hardened Key Vault to centrally store encryption material and secrets with public access disabled.
resource "azurerm_key_vault" "main" {
  name                          = local.key_vault_name
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "premium"
  soft_delete_retention_days    = 90
  purge_protection_enabled      = true
  public_network_access_enabled = false
  tags                          = local.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

# Grants the deploying identity bootstrap permissions needed to create keys, secrets, and rotation settings.
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Create",
    "Delete",
    "Get",
    "GetRotationPolicy",
    "List",
    "Purge",
    "Recover",
    "SetRotationPolicy",
    "UnwrapKey",
    "Update",
    "WrapKey"
  ]

  secret_permissions = [
    "Delete",
    "Get",
    "List",
    "Purge",
    "Recover",
    "Set"
  ]
}

# Creates a user-assigned identity for the primary SQL server to access customer-managed encryption keys.
resource "azurerm_user_assigned_identity" "sql_primary" {
  name                = "id-sql-primary-${local.resource_suffix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Creates a user-assigned identity for the secondary SQL server to keep TDE key access symmetric.
resource "azurerm_user_assigned_identity" "sql_secondary" {
  name                = "id-sql-secondary-${local.resource_suffix}"
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# Grants the primary SQL identity least-privilege key permissions for transparent data encryption operations.
resource "azurerm_key_vault_access_policy" "sql_primary_key" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.sql_primary.principal_id

  key_permissions = [
    "Get",
    "UnwrapKey",
    "WrapKey"
  ]

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

# Grants the secondary SQL identity the same TDE key permissions for failover readiness.
resource "azurerm_key_vault_access_policy" "sql_secondary_key" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.sql_secondary.principal_id

  key_permissions = [
    "Get",
    "UnwrapKey",
    "WrapKey"
  ]

  depends_on = [azurerm_key_vault_access_policy.deployer]
}

# Creates the customer-managed key used by SQL TDE to satisfy encryption and key-ownership requirements.
resource "azurerm_key_vault_key" "sql_tde" {
  name         = "sql-tde-key"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }

    expire_after         = "P365D"
    notify_before_expiry = "P29D"
  }

  depends_on = [
    azurerm_key_vault_access_policy.deployer,
    azurerm_private_endpoint.keyvault_primary,
    azurerm_private_endpoint.keyvault_secondary
  ]
}

# Stores the generated SQL admin password in Key Vault so applications can retrieve it securely at runtime.
resource "azurerm_key_vault_secret" "sql_admin_password" {
  name         = "sql-admin-password"
  value        = random_password.sql_admin.result
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [
    azurerm_key_vault_access_policy.deployer,
    azurerm_private_endpoint.keyvault_primary,
    azurerm_private_endpoint.keyvault_secondary
  ]
}

# Exposes Key Vault privately in the primary region to block public ingress and keep secret traffic internal.
resource "azurerm_private_endpoint" "keyvault_primary" {
  name                = "pe-kv-primary-${local.resource_suffix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.primary_private_endpoint.id
  tags                = merge(local.tags, { RegionRole = "Primary" })

  private_service_connection {
    name                           = "psc-kv-primary"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv-zone"
    private_dns_zone_ids = [azurerm_private_dns_zone.keyvault.id]
  }
}

# Exposes Key Vault privately in the secondary region to maintain private access paths in DR scenarios.
resource "azurerm_private_endpoint" "keyvault_secondary" {
  name                = "pe-kv-secondary-${local.resource_suffix}"
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.secondary_private_endpoint.id
  tags                = merge(local.tags, { RegionRole = "Secondary" })

  private_service_connection {
    name                           = "psc-kv-secondary"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv-zone"
    private_dns_zone_ids = [azurerm_private_dns_zone.keyvault.id]
  }
}

# Deploys the primary Azure SQL logical server with CMK-based encryption and no public network access.
resource "azurerm_mssql_server" "primary" {
  name                                         = local.sql_primary_name
  resource_group_name                          = azurerm_resource_group.main.name
  location                                     = var.primary_location
  version                                      = "12.0"
  administrator_login                          = var.sql_admin_login
  administrator_login_password                 = random_password.sql_admin.result
  public_network_access_enabled                = false
  minimum_tls_version                          = "1.2"
  transparent_data_encryption_key_vault_key_id = azurerm_key_vault_key.sql_tde.id
  primary_user_assigned_identity_id            = azurerm_user_assigned_identity.sql_primary.id
  tags                                         = merge(local.tags, { RegionRole = "Primary" })

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.sql_primary.id]
  }

  depends_on = [
    azurerm_key_vault_access_policy.sql_primary_key,
    azurerm_key_vault_key.sql_tde
  ]
}

# Deploys the secondary Azure SQL logical server for geo-failover and regional resiliency.
resource "azurerm_mssql_server" "secondary" {
  name                                         = local.sql_secondary_name
  resource_group_name                          = azurerm_resource_group.main.name
  location                                     = var.secondary_location
  version                                      = "12.0"
  administrator_login                          = var.sql_admin_login
  administrator_login_password                 = random_password.sql_admin.result
  public_network_access_enabled                = false
  minimum_tls_version                          = "1.2"
  transparent_data_encryption_key_vault_key_id = azurerm_key_vault_key.sql_tde.id
  primary_user_assigned_identity_id            = azurerm_user_assigned_identity.sql_secondary.id
  tags                                         = merge(local.tags, { RegionRole = "Secondary" })

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.sql_secondary.id]
  }

  depends_on = [
    azurerm_key_vault_access_policy.sql_secondary_key,
    azurerm_key_vault_key.sql_tde
  ]
}

# Creates the workload database with HA-oriented settings and retention policies for business continuity.
resource "azurerm_mssql_database" "quotes" {
  name                                = var.sql_database_name
  server_id                           = azurerm_mssql_server.primary.id
  collation                           = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb                         = 20
  sku_name                            = var.sql_database_sku
  zone_redundant                      = true
  read_scale                          = true
  storage_account_type                = "Geo"
  transparent_data_encryption_enabled = true
  tags                                = local.tags

  short_term_retention_policy {
    retention_days = 14
  }

  long_term_retention_policy {
    weekly_retention  = "P12W"
    monthly_retention = "P12M"
    yearly_retention  = "P5Y"
    week_of_year      = 1
  }
}

# Configures SQL failover group to replicate and automatically fail over database connectivity across regions.
resource "azurerm_mssql_failover_group" "quotes" {
  name      = local.failover_group_name
  server_id = azurerm_mssql_server.primary.id
  databases = [azurerm_mssql_database.quotes.id]
  tags      = local.tags

  partner_server {
    id = azurerm_mssql_server.secondary.id
  }

  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = 60
  }
}

# Publishes a private endpoint for the primary SQL server so app traffic stays on private networking.
resource "azurerm_private_endpoint" "sql_primary" {
  name                = "pe-sql-primary-${local.resource_suffix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.primary_private_endpoint.id
  tags                = merge(local.tags, { RegionRole = "Primary" })

  private_service_connection {
    name                           = "psc-sql-primary"
    private_connection_resource_id = azurerm_mssql_server.primary.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sql-zone"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql.id]
  }
}

# Publishes a private endpoint for the secondary SQL server to keep DR data access private.
resource "azurerm_private_endpoint" "sql_secondary" {
  name                = "pe-sql-secondary-${local.resource_suffix}"
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.secondary_private_endpoint.id
  tags                = merge(local.tags, { RegionRole = "Secondary" })

  private_service_connection {
    name                           = "psc-sql-secondary"
    private_connection_resource_id = azurerm_mssql_server.secondary.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sql-zone"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql.id]
  }
}

# Provisions the primary Linux App Service plan that provides compute capacity for the primary web app.
resource "azurerm_service_plan" "primary" {
  name                   = local.plan_primary_name
  location               = var.primary_location
  resource_group_name    = azurerm_resource_group.main.name
  os_type                = "Linux"
  sku_name               = var.app_service_plan_sku
  worker_count           = var.app_service_worker_count
  zone_balancing_enabled = true
  tags                   = merge(local.tags, { RegionRole = "Primary" })
}

# Provisions the secondary Linux App Service plan so standby application compute exists in-region.
resource "azurerm_service_plan" "secondary" {
  name                   = local.plan_secondary_name
  location               = var.secondary_location
  resource_group_name    = azurerm_resource_group.main.name
  os_type                = "Linux"
  sku_name               = var.app_service_plan_sku
  worker_count           = var.app_service_worker_count
  zone_balancing_enabled = true
  tags                   = merge(local.tags, { RegionRole = "Secondary" })
}

# Packages application source into a ZIP artifact so both web apps can deploy the same immutable build.
data "archive_file" "app_package" {
  type        = "zip"
  source_dir  = "${path.module}/../app"
  output_path = "${path.module}/quotes-app.zip"
  excludes    = ["__pycache__", ".venv", ".pytest_cache"]
}

# Deploys the primary Linux Web App with VNet integration and secure settings as the main serving endpoint.
resource "azurerm_linux_web_app" "primary" {
  name                          = local.web_primary_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.primary_location
  service_plan_id               = azurerm_service_plan.primary.id
  virtual_network_subnet_id     = azurerm_subnet.primary_app.id
  https_only                    = true
  public_network_access_enabled = false
  zip_deploy_file               = data.archive_file.app_package.output_path
  tags                          = merge(local.tags, { RegionRole = "Primary" })

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                         = true
    http2_enabled                     = true
    minimum_tls_version               = "1.2"
    ftps_state                        = "Disabled"
    health_check_path                 = "/healthz"
    health_check_eviction_time_in_min = 10
    vnet_route_all_enabled            = true
    app_command_line                  = "gunicorn --bind=0.0.0.0 --workers 3 --threads 4 app:app"

    application_stack {
      python_version = "3.12"
    }
  }

  app_settings = {
    APP_TITLE                             = "Critical PII Quote Vault"
    APPINSIGHTS_INSTRUMENTATIONKEY        = azurerm_application_insights.primary.instrumentation_key
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.primary.connection_string
    KEY_VAULT_URI                         = azurerm_key_vault.main.vault_uri
    SQL_DATABASE_NAME                     = azurerm_mssql_database.quotes.name
    SQL_PASSWORD_SECRET_NAME              = azurerm_key_vault_secret.sql_admin_password.name
    SQL_SERVER_FQDN                       = local.failover_group_fqdn
    SQL_USERNAME                          = var.sql_admin_login
    SCM_DO_BUILD_DURING_DEPLOYMENT        = "true"
    WEBSITE_DNS_SERVER                    = "168.63.129.16"
    WEBSITE_VNET_ROUTE_ALL                = "1"
  }

  depends_on = [
    azurerm_private_endpoint.sql_primary,
    azurerm_private_endpoint.keyvault_primary,
    azurerm_mssql_failover_group.quotes
  ]
}

# Deploys the secondary Linux Web App to provide regional redundancy and failover serving capacity.
resource "azurerm_linux_web_app" "secondary" {
  name                          = local.web_secondary_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.secondary_location
  service_plan_id               = azurerm_service_plan.secondary.id
  virtual_network_subnet_id     = azurerm_subnet.secondary_app.id
  https_only                    = true
  public_network_access_enabled = false
  zip_deploy_file               = data.archive_file.app_package.output_path
  tags                          = merge(local.tags, { RegionRole = "Secondary" })

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                         = true
    http2_enabled                     = true
    minimum_tls_version               = "1.2"
    ftps_state                        = "Disabled"
    health_check_path                 = "/healthz"
    health_check_eviction_time_in_min = 10
    vnet_route_all_enabled            = true
    app_command_line                  = "gunicorn --bind=0.0.0.0 --workers 3 --threads 4 app:app"

    application_stack {
      python_version = "3.12"
    }
  }

  app_settings = {
    APP_TITLE                             = "Critical PII Quote Vault"
    APPINSIGHTS_INSTRUMENTATIONKEY        = azurerm_application_insights.secondary.instrumentation_key
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.secondary.connection_string
    KEY_VAULT_URI                         = azurerm_key_vault.main.vault_uri
    SQL_DATABASE_NAME                     = azurerm_mssql_database.quotes.name
    SQL_PASSWORD_SECRET_NAME              = azurerm_key_vault_secret.sql_admin_password.name
    SQL_SERVER_FQDN                       = local.failover_group_fqdn
    SQL_USERNAME                          = var.sql_admin_login
    SCM_DO_BUILD_DURING_DEPLOYMENT        = "true"
    WEBSITE_DNS_SERVER                    = "168.63.129.16"
    WEBSITE_VNET_ROUTE_ALL                = "1"
  }

  depends_on = [
    azurerm_private_endpoint.sql_secondary,
    azurerm_private_endpoint.keyvault_secondary,
    azurerm_mssql_failover_group.quotes
  ]
}

# Grants the primary web app managed identity read access to Key Vault secrets needed at runtime.
resource "azurerm_key_vault_access_policy" "webapp_primary" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_web_app.primary.identity[0].principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}

# Grants the secondary web app managed identity equivalent secret read access for parity in failover.
resource "azurerm_key_vault_access_policy" "webapp_secondary" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_web_app.secondary.identity[0].principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}

# Enables SQL auditing so security events are captured in Azure Monitor.
resource "azurerm_mssql_server_extended_auditing_policy" "primary" {
  server_id              = azurerm_mssql_server.primary.id
  retention_in_days      = 90
  log_monitoring_enabled = true
}

resource "azurerm_mssql_server_extended_auditing_policy" "secondary" {
  server_id              = azurerm_mssql_server.secondary.id
  retention_in_days      = 90
  log_monitoring_enabled = true
}

# Sends platform/resource diagnostics to Log Analytics for incident response and compliance evidence.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-keyvault"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "web_primary" {
  name                       = "diag-web-primary"
  target_resource_id         = azurerm_linux_web_app.primary.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "web_secondary" {
  name                       = "diag-web-secondary"
  target_resource_id         = azurerm_linux_web_app.secondary.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "sql_primary" {
  name                       = "diag-sql-primary"
  target_resource_id         = azurerm_mssql_server.primary.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "sql_secondary" {
  name                       = "diag-sql-secondary"
  target_resource_id         = azurerm_mssql_server.secondary.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "sql_database" {
  name                       = "diag-sql-db"
  target_resource_id         = azurerm_mssql_database.quotes.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }
}

resource "azurerm_monitor_diagnostic_setting" "frontdoor_profile" {
  name                       = "diag-frontdoor"
  target_resource_id         = azurerm_cdn_frontdoor_profile.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }
}

# Creates the Azure Front Door profile to provide global entry, acceleration, and edge security controls.
resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = local.fd_profile_name
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Premium_AzureFrontDoor"
  tags                = local.tags
}

# Creates the Front Door endpoint that exposes the global DNS hostname for incoming client traffic.
resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = local.fd_endpoint_name
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  tags                     = local.tags
}

# Defines an origin group with health probes and load-balancing rules for resilient origin selection.
resource "azurerm_cdn_frontdoor_origin_group" "quotes" {
  name                     = "og-quotes"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 3
    additional_latency_in_milliseconds = 20
  }

  health_probe {
    interval_in_seconds = 5
    path                = "/healthz"
    protocol            = "Https"
    request_type        = "GET"
  }
}

# Registers the primary web app as an origin so Front Door can route requests to it over private link.
resource "azurerm_cdn_frontdoor_origin" "primary" {
  name                           = "origin-primary"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.quotes.id
  enabled                        = true
  host_name                      = azurerm_linux_web_app.primary.default_hostname
  origin_host_header             = azurerm_linux_web_app.primary.default_hostname
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true

  private_link {
    request_message        = "Approve Front Door private link to primary App Service origin"
    target_type            = "sites"
    location               = var.primary_location
    private_link_target_id = azurerm_linux_web_app.primary.id
  }
}

# Registers the secondary web app as a peer origin to enable active-active/automatic failover routing.
resource "azurerm_cdn_frontdoor_origin" "secondary" {
  name                           = "origin-secondary"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.quotes.id
  enabled                        = true
  host_name                      = azurerm_linux_web_app.secondary.default_hostname
  origin_host_header             = azurerm_linux_web_app.secondary.default_hostname
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true

  private_link {
    request_message        = "Approve Front Door private link to secondary App Service origin"
    target_type            = "sites"
    location               = var.secondary_location
    private_link_target_id = azurerm_linux_web_app.secondary.id
  }
}

# Maps client URL patterns to the origin group and enforces HTTPS routing behavior at the global edge.
resource "azurerm_cdn_frontdoor_route" "quotes" {
  name                          = "route-quotes"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.quotes.id
  cdn_frontdoor_origin_ids = [
    azurerm_cdn_frontdoor_origin.primary.id,
    azurerm_cdn_frontdoor_origin.secondary.id
  ]
  enabled                = true
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
  link_to_default_domain = true
}

# Deploys a WAF policy with managed and custom rate-limit rules to mitigate common web attack traffic.
resource "azurerm_cdn_frontdoor_firewall_policy" "waf" {
  name                              = "waf${local.project_slug}${local.env_slug}${local.resource_suffix}"
  resource_group_name               = azurerm_resource_group.main.name
  sku_name                          = azurerm_cdn_frontdoor_profile.main.sku_name
  enabled                           = true
  mode                              = "Prevention"
  custom_block_response_status_code = 403
  tags                              = local.tags

  custom_rule {
    name                           = "RateLimitAll"
    enabled                        = true
    priority                       = 1
    type                           = "RateLimitRule"
    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = 150
    action                         = "Block"

    match_condition {
      match_variable     = "RemoteAddr"
      operator           = "IPMatch"
      match_values       = ["0.0.0.0/0", "::/0"]
      negation_condition = false
    }
  }

  managed_rule {
    type    = "DefaultRuleSet"
    version = "2.1"
    action  = "Block"
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.0"
    action  = "Block"
  }
}

# Associates the WAF policy with the Front Door endpoint so all matched requests are inspected and enforced.
resource "azurerm_cdn_frontdoor_security_policy" "waf_association" {
  name                     = "security-policy-waf"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.waf.id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.main.id
        }

        patterns_to_match = ["/*"]
      }
    }
  }
}
