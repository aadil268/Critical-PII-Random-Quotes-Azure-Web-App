locals {
  project_slug = substr(replace(lower(var.project_name), "/[^a-z0-9]/", ""), 0, 8)
  env_slug     = substr(replace(lower(var.environment), "/[^a-z0-9]/", ""), 0, 6)

  default_tags = {
    Environment        = var.environment
    Workload           = var.project_name
    DataClassification = "CriticalPII"
    SecurityBoundary   = "PrivateNetwork"
    AvailabilityTier   = "MissionCritical"
    ManagedBy          = "Terraform"
  }

  tags = merge(local.default_tags, var.common_tags)
}
