# Only what an operator must set, or genuinely sizes. Everything else is a
# fixed, secure value in the file that uses it.

# ---- Placement and naming ------------------------------------------------------

variable "aws_region" {
  description = "AWS region every resource is created in."
  type        = string
  default     = "eu-central-1"
}

variable "name_prefix" {
  description = "Prefix for every resource name. Lowercase letters, digits and hyphens: it also starts the S3 bucket names (<name_prefix>-blobstore-<account_id>-<region>), which must stay within 63 characters."
  type        = string
  default     = "margince"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits and hyphens, starting and ending with a letter or digit (it is part of the S3 bucket names)."
  }
  validation {
    # Longest bucket name: "<name_prefix>-blobstore-" (11 extra chars) + the
    # 12-digit account id + "-" + the region.
    condition     = length(var.name_prefix) + 24 + length(var.aws_region) <= 63
    error_message = "name_prefix is too long: <name_prefix>-blobstore-<12-digit account id>-<aws_region> must fit S3's 63-character bucket name limit."
  }
}

variable "az_count" {
  description = "Availability Zones to spread the public and private subnets (and one NAT gateway each) across."
  type        = number
  default     = 2
  validation {
    # RDS and ElastiCache subnet groups both require two AZs; RDS refuses a
    # one-AZ subnet group only at apply time.
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2: RDS and ElastiCache subnet groups both require two Availability Zones."
  }
}

# ---- Release ------------------------------------------------------------------------
# Images are <registry>/<instance_name>/<role>:<release_version>, as
# `make release` or `make package` names them (docs/release.md, Section 6).
# The ECR repositories are IMMUTABLE (ecs.tf): a released tag never changes.

variable "instance_name" {
  description = "The instance's name from instance.yaml (`name`): the image namespace and the ECR repository prefix."
  type        = string
  default     = "margince-default"
  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.instance_name))
    error_message = "instance_name must match instance.yaml's name format: lowercase letters and digits, separated by single hyphens."
  }
}

variable "release_version" {
  description = "The release to deploy for api, worker and web: the VERSION of `make release`, which is also the image tag. Push it before the apply that references it."
  type        = string
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+(-rc\\.[1-9][0-9]*)?$", var.release_version))
    error_message = "release_version must be a release version such as v0.3.0 or v1.3.0-rc.1 (docs/release.md, Section 2)."
  }
}

variable "architecture" {
  description = "CPU architecture of the three Fargate tasks and the release runner: arm64 (Graviton, default) or amd64. The release images must include linux/<architecture> (PLATFORMS in docs/release.md)."
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "architecture must be amd64 or arm64."
  }
}

# ---- Application ----------------------------------------------------------------------

variable "public_base_url" {
  description = "MARGINCE_PUBLIC_BASE_URL, e.g. https://crm.example.com. Point its host at the ALB (alb_dns_name)."
  type        = string
  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.public_base_url))
    error_message = "public_base_url must be https://<host> with no path or trailing slash."
  }
}

variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate in aws_region covering public_base_url's host. Not created here: DNS validation needs your own zone."
  type        = string
  validation {
    condition     = startswith(var.acm_certificate_arn, "arn:aws:acm:")
    error_message = "acm_certificate_arn must be an ACM certificate ARN."
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
  description = "MARGINCE_ADMIN_PASSWORD for the first boot against an empty database. Only seeds the SSM parameter; overwrite it with an inert value after the first boot (README.md, step 5)."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.admin_bootstrap_password) > 0
    error_message = "admin_bootstrap_password must not be empty."
  }
}

# ---- Sizing ----------------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class. Burstable classes (db.t*) get a CPU-credit alarm."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_multi_az" {
  description = "RDS Multi-AZ (a synchronous standby in a second AZ)."
  type        = bool
  default     = true
}

variable "api_min_replicas" {
  description = "Minimum api tasks: the CPU autoscaling floor."
  type        = number
  default     = 2
  validation {
    condition     = var.api_min_replicas >= 1
    error_message = "api_min_replicas must be at least 1."
  }
}

variable "api_max_replicas" {
  description = "Maximum api tasks: the CPU autoscaling ceiling."
  type        = number
  default     = 4
  validation {
    condition     = var.api_max_replicas >= var.api_min_replicas
    error_message = "api_max_replicas must be at least api_min_replicas."
  }
}




# Fargate CPU units / MiB; each pair must be a valid Fargate combination.






# ---- Edge and operations ------------------------------------------------------------------------

variable "waf_mode" {
  description = "\"count\" (every rule only counts) or \"block\". Start in count, review the WAF logs for about a week, add overrides, then switch to block (README.md, \"WAF rollout\")."
  type        = string
  default     = "count"
  validation {
    condition     = contains(["count", "block"], var.waf_mode)
    error_message = "waf_mode must be \"count\" or \"block\"."
  }
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic (AWS mails a confirmation link first). Empty: no subscription; subscribe your own endpoint to alerts_topic_arn."
  type        = string
  default     = ""
}
