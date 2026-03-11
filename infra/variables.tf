variable "project_name" {
  description = "Short project name used in resource naming."
  type        = string
  default     = "quotes"
}

variable "environment" {
  description = "Environment label (for tags and naming)."
  type        = string
  default     = "prod"
}

variable "primary_location" {
  description = "Primary Azure region."
  type        = string
  default     = "eastus"
}

variable "secondary_location" {
  description = "Secondary Azure region."
  type        = string
  default     = "westus2"
}

variable "app_service_plan_sku" {
  description = "SKU for both regional App Service plans."
  type        = string
  default     = "P1v3"
}

variable "app_service_worker_count" {
  description = "Worker instances per App Service plan."
  type        = number
  default     = 2
}

variable "sql_admin_login" {
  description = "SQL administrator login name."
  type        = string
  default     = "sqladminquotes"
}

variable "sql_database_name" {
  description = "Primary SQL database name."
  type        = string
  default     = "quotesdb"
}

variable "sql_database_sku" {
  description = "Azure SQL SKU. Business Critical supports zone redundancy and fast failover."
  type        = string
  default     = "BC_Gen5_2"
}

variable "common_tags" {
  description = "Additional user-supplied tags merged with default governance tags."
  type        = map(string)
  default     = {}
}
