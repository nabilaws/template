# The variables shared with the Azure light stack, with the same names. The
# Azure stack adds entra_access_group_object_id. Everything else is fixed in
# the stack.

# ---- Shared with azure/light ----------------------------------------------------

variable "name_prefix" {
  description = "Short prefix for resource names."
  type        = string
  default     = "margince-light"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name_prefix))
    error_message = "name_prefix: 3-31 characters, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  description = "AWS region, for example eu-central-1."
  type        = string
  default     = "eu-central-1"
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region))
    error_message = "region must be an AWS region name such as eu-central-1."
  }
}

variable "domain" {
  description = "The public host name of Margince, for example crm.example.com. It becomes HOST_DOMAIN in deploy/production/host.env. Create its A record for the public_ip output."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain))
    error_message = "domain must be a lowercase DNS name without scheme, port or path, for example crm.example.com."
  }
}

variable "architecture" {
  description = "CPU architecture of the instance: amd64 or arm64. The release images must include linux/<architecture> (PLATFORMS in docs/release.md), and instance_type must be a size of that architecture."
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "architecture must be amd64 or arm64."
  }
}

variable "instance_type" {
  description = "EC2 instance type, of the chosen architecture. t4g.large (2 vCPU, 8 GiB, Graviton arm64) runs api, worker, web, Postgres, Redis, Caddy and nginx; for amd64, t3.large."
  type        = string
  default     = "t4g.large"
  # Graviton types (t4g, m7g, c7gn, a1, ...) carry a g after the generation.
  validation {
    condition     = can(regex("^(a1|[a-z]+[0-9]+g[a-z]*)\\.", var.instance_type)) == (var.architecture == "arm64")
    error_message = "instance_type does not match architecture: an arm64 instance needs a Graviton type (t4g.large), an amd64 instance a non-Graviton one."
  }
}

variable "admin_ssh_public_key" {
  description = "OpenSSH public key of the ubuntu user, ed25519 or RSA. The host adapter connects with the matching private key."
  type        = string
  validation {
    condition     = startswith(var.admin_ssh_public_key, "ssh-ed25519 ") || startswith(var.admin_ssh_public_key, "ssh-rsa ")
    error_message = "admin_ssh_public_key must be an ed25519 or RSA key (ssh-ed25519 ... or ssh-rsa ...)."
  }
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 ranges allowed to reach SSH (port 22): the addresses that run make host-bootstrap and make deploy."
  type        = list(string)
  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs needs at least one range, for example the /32 of the address you deploy from (curl -s https://ifconfig.me)."
  }
  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : !endswith(c, "/0")])
    error_message = "ssh_allowed_cidrs must not contain 0.0.0.0/0 or ::/0: SSH is never open to the internet."
  }
  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : can(cidrhost(c, 0)) && can(regex("^[0-9.]+/[0-9]+$", c))])
    error_message = "ssh_allowed_cidrs entries must be IPv4 CIDR ranges such as 203.0.113.10/32."
  }
}

variable "data_disk_gb" {
  description = "Data volume mounted at /var/lib/docker: the postgres, redis, blobs and caddy volumes, and the images."
  type        = number
  default     = 64
  validation {
    condition     = var.data_disk_gb >= 16
    error_message = "data_disk_gb must be at least 16."
  }
}

variable "alert_email" {
  description = "Optional email address subscribed to the alerts topic. Empty adds no subscription. AWS sends a confirmation link first."
  type        = string
  default     = ""
  validation {
    condition     = var.alert_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be empty or a single email address."
  }
}

variable "license_token" {
  description = "MARGINCE_LICENSE. Stored as an SSM SecureString for make deploy. Empty stores nothing; the environment then needs MARGINCE_ENV=test (docs/deploy.md Section 5.8)."
  type        = string
  default     = ""
  sensitive   = true
}
