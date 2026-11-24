# Only what an operator must set, or genuinely sizes. Everything else is a
# fixed, secure value in the file that uses it.

# ---- Placement and naming ------------------------------------------------------

variable "azure_region" {
  description = "Azure region for every resource. westeurope supports every service this stack uses (Container Apps, Postgres zone-redundant HA); confirm availability before choosing another."
  type        = string
  default     = "westeurope"
}

variable "name_prefix" {
  description = "Prefix for every resource name, and the resource group's name. Globally unique names add a random suffix (naming.tf)."
  type        = string
  default     = "margince"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,12}$", var.name_prefix))
    error_message = "name_prefix: 3-13 characters, lowercase letters, digits and hyphens, starting with a letter (storage and key vault names have length limits)."
  }
}

# ---- Release ------------------------------------------------------------------------
# One release of this instance (docs/release.md): release.yml builds api, web
# and worker with core's Dockerfile and bake definition and pushes them as
# <image_repo>/<role>:<release_version>, the references `make deploy` exports
# as IMAGE_API, IMAGE_WEB and IMAGE_WORKER. All three roles run at one release
# and are pulled by tag; core's release guard refuses a mixed set
# (core/docs/deployment.md, "Deploy all three roles at ONE release").

variable "image_repo" {
  description = "The image repository of the instance release: <REGISTRY>/<instance name>, the IMAGE_REPO of `make deploy`, for example ghcr.io/acme/margince-default. A public registry: the images are pulled anonymously."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$", var.image_repo))
    error_message = "image_repo must be <registry host>/<path> with no tag or digest, for example ghcr.io/acme/margince-default."
  }
}

variable "release_version" {
  description = "The release to run for api, worker and web: the VERSION of `make release`, which is the image tag. `make deploy` sets it."
  type        = string
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-rc\\.[1-9][0-9]*)?$", var.release_version))
    error_message = "release_version must be a release version such as v0.3.0 or v1.3.0-rc.1 (docs/release.md, Section 2)."
  }
}

variable "margince_config_path" {
  description = "margince.yaml for the config share. Default: the instance's deploy/production/config/margince.yaml, the file the light stacks use. The setup job writes it on every apply that changes it."
  type        = string
  default     = null
}

variable "bootstrap_sql_path" {
  description = "Core's db-bootstrap.sql. Default: core/scripts/deploy/db-bootstrap.sql at the pinned core version."
  type        = string
  default     = null
}

variable "deploy_apps" {
  description = "false on the first apply: everything except the Container Apps and the Application Gateway. Set true once the images are pushed, the database bootstrapped, margince.yaml uploaded and the public certificate imported (README.md)."
  type        = bool
  default     = false
}

# ---- Application ----------------------------------------------------------------------

variable "public_base_url" {
  description = "MARGINCE_PUBLIC_BASE_URL, e.g. https://crm.example.com. Its host is served by the Application Gateway and is the base of every sso_redirect_uris entry."
  type        = string
  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.public_base_url))
    error_message = "public_base_url must be https://<host> with no path or trailing slash."
  }
}

variable "license_token" {
  description = "MARGINCE_LICENSE. Required: a production role refuses to boot unlicensed."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.license_token) > 0
    error_message = "license_token is required: the api refuses to boot unlicensed in production."
  }
}

variable "admin_bootstrap_password" {
  description = "MARGINCE_ADMIN_PASSWORD for the first boot against an empty database. Only seeds the Key Vault secret; set include_bootstrap_admin = false once the first admin has signed in."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.admin_bootstrap_password) > 0
    error_message = "admin_bootstrap_password must not be empty."
  }
}

variable "include_bootstrap_admin" {
  description = "Passes the bootstrap admin password to the api. Set false once the first admin has signed in and changed it (README.md, step 6)."
  type        = bool
  default     = true
}

# ---- Access -----------------------------------------------------------------------------

variable "operator_ip_allowlist" {
  description = "Public IPv4 addresses (no /prefix) let through the Key Vault and Storage firewalls while you set up. Leave empty in steady state; Postgres and Redis are never reachable this way (use the jumpbox)."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for ip in var.operator_ip_allowlist : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", ip))])
    error_message = "operator_ip_allowlist takes plain IPv4 addresses such as 203.0.113.10 (Storage rejects /31 and /32 prefixes)."
  }
}

variable "key_vault_admin_principal_ids" {
  description = "Entra object IDs granted Key Vault Administrator, ideally one group holding every operator and the CI identity. Empty: the identity running apply, which only works while one person applies."
  type        = list(string)
  default     = []
}

variable "jumpbox_ssh_public_key" {
  description = "OpenSSH public key (ssh-ed25519 or ssh-rsa) for the jumpbox's admin user. Password login is disabled."
  type        = string
  validation {
    condition     = startswith(var.jumpbox_ssh_public_key, "ssh-rsa ") || startswith(var.jumpbox_ssh_public_key, "ssh-ed25519 ")
    error_message = "jumpbox_ssh_public_key must be an ssh-ed25519 or ssh-rsa public key."
  }
}

# ---- Sizing ----------------------------------------------------------------------------------

variable "db_sku_name" {
  description = "Postgres Flexible Server SKU. B_Standard_B2ms (Burstable, 2 vCPU, 8 GiB) by default; B_Standard_B2s (4 GiB) is about EUR 52/month cheaper. Microsoft recommends General Purpose for production, e.g. GP_Standard_D2ds_v5 (about +EUR 35/month over B_Standard_B2ms), which also allows db_zone_redundant_ha."
  type        = string
  default     = "B_Standard_B2ms"
}

variable "db_zone_redundant_ha" {
  description = "Zone-redundant HA (a standby in another zone). Needs a General Purpose or Memory Optimized db_sku_name; about +EUR 140/month for the standby."
  type        = bool
  default     = false
}

variable "api_min_replicas" {
  description = "Minimum api replicas (cmd/api plus the edge container that serves the SPA). Never scales to zero."
  type        = number
  default     = 3
  validation {
    condition     = var.api_min_replicas >= 1
    error_message = "api_min_replicas must be at least 1."
  }
}

variable "api_max_replicas" {
  description = "Maximum api replicas for the CPU and HTTP concurrency scale rules."
  type        = number
  default     = 6
  validation {
    condition     = var.api_max_replicas >= var.api_min_replicas
    error_message = "api_max_replicas must be at least api_min_replicas."
  }
}

# ---- Edge and operations ------------------------------------------------------------------------

variable "waf_mode" {
  description = "\"count\" (Detection, custom rules log only) or \"block\" (Prevention, custom rules block). Start in count, review the firewall logs for about a week, add exclusions, then switch to block (README.md, \"WAF rollout\")."
  type        = string
  default     = "count"
  validation {
    condition     = contains(["count", "block"], var.waf_mode)
    error_message = "waf_mode must be \"count\" or \"block\"."
  }
}

variable "alert_email" {
  description = "Email address added to the alerts action group. Empty: alerts fire with no receiver until you add one."
  type        = string
  default     = ""
}

variable "enable_resource_locks" {
  description = "CanNotDelete locks on Postgres, storage, Key Vault and the Recovery Services vault. Set false and apply before terraform destroy."
  type        = bool
  default     = true
}
