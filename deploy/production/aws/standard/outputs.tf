output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecr_api_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "ecr_worker_repository_url" {
  value = aws_ecr_repository.worker.repository_url
}

output "ecr_web_repository_url" {
  value = aws_ecr_repository.web.repository_url
}

output "registry" {
  description = "The REGISTRY value for `make release` and `make package` (docs/release.md, Section 5): this account's ECR registry host."
  value       = split("/", aws_ecr_repository.api.repository_url)[0]
}

output "image_refs" {
  description = "The images this stack deploys: <registry>/<instance_name>/<role>:<release_version>."
  value       = local.images
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}

output "elasticache_primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "efs_file_system_id" {
  value = aws_efs_file_system.config.id
}

output "efs_config_access_point_id" {
  value = aws_efs_access_point.config.id
}

output "s3_blobstore_bucket" {
  value = aws_s3_bucket.blobstore.bucket
}

output "kms_key_arn" {
  value = aws_kms_key.data.arn
}

output "alerts_topic_arn" {
  description = "SNS topic every alarm in alarms.tf pages. Subscribe your own destination if alert_email is not enough."
  value       = aws_sns_topic.alerts.arn
}

output "waf_web_acl_arn" {
  value = aws_wafv2_web_acl.alb.arn
}

output "alb_access_log_bucket" {
  value = aws_s3_bucket.alb_logs.bucket
}

output "ssm_parameter_names" {
  description = "SSM Parameter Store names (not values) of every SecureString this stack writes. Read one with: aws ssm get-parameter --with-decryption --name <name> --query Parameter.Value --output text."
  value = {
    owner_dsn            = aws_ssm_parameter.owner_dsn.name
    app_dsn              = aws_ssm_parameter.app_dsn.name
    redis_password       = aws_ssm_parameter.redis_password.name
    keyvault_root_key    = aws_ssm_parameter.keyvault_root_key.name
    webhook_key          = aws_ssm_parameter.webhook_key.name
    connector_state_key  = aws_ssm_parameter.connector_state_key.name
    admin_password       = aws_ssm_parameter.admin_password.name
    blobstore_access_key = aws_ssm_parameter.blobstore_access_key.name
    blobstore_secret_key = aws_ssm_parameter.blobstore_secret_key.name
    rds_master_password  = aws_ssm_parameter.rds_master_password.name
    license              = aws_ssm_parameter.license.name
  }
}

output "ssm_parameter_arns" {
  description = "SSM Parameter Store ARNs for the same parameters as ssm_parameter_names."
  value = {
    owner_dsn            = aws_ssm_parameter.owner_dsn.arn
    app_dsn              = aws_ssm_parameter.app_dsn.arn
    redis_password       = aws_ssm_parameter.redis_password.arn
    keyvault_root_key    = aws_ssm_parameter.keyvault_root_key.arn
    webhook_key          = aws_ssm_parameter.webhook_key.arn
    connector_state_key  = aws_ssm_parameter.connector_state_key.arn
    admin_password       = aws_ssm_parameter.admin_password.arn
    blobstore_access_key = aws_ssm_parameter.blobstore_access_key.arn
    blobstore_secret_key = aws_ssm_parameter.blobstore_secret_key.arn
    rds_master_password  = aws_ssm_parameter.rds_master_password.arn
    license              = aws_ssm_parameter.license.arn
  }
}

output "waf_log_group_name" {
  description = "CloudWatch Logs group WAF writes to (CMK-encrypted)."
  value       = aws_cloudwatch_log_group.waf.name
}

output "ops_security_group_id" {
  description = "Security group for the temporary bootstrap host (README steps 2 and 4)."
  value       = aws_security_group.ops.id
}

output "ops_instance_profile_name" {
  description = "Instance profile for the temporary bootstrap host: SSM Session Manager and EFS config mount/write."
  value       = aws_iam_instance_profile.ops.name
}

output "release_runner_label" {
  description = "Label of the self-hosted release runner: the RELEASE_RUNNER repository variable (README.md, step 3)."
  value       = local.release_runner.label
}

output "release_runner_instance_id" {
  description = "The release runner EC2 instance. Connect with aws ssm start-session --target <id>."
  value       = aws_instance.release_runner.id
}

output "private_subnet_ids" {
  description = "Private subnets; launch the temporary bootstrap host in one of these."
  value       = aws_subnet.private[*].id
}

output "sso_redirect_uris" {
  description = "Redirect URIs to register in the customer's own Microsoft Entra or Google app, for optional sign-in and mailbox capture configured in Margince under Settings. Margince needs none of them to run."
  value = {
    microsoft = ["${var.public_base_url}/v1/auth/oidc/microsoft/callback", "${var.public_base_url}/v1/connectors/graph/callback", "${var.public_base_url}/v1/connectors/graphcal/callback"]
    google    = ["${var.public_base_url}/v1/auth/oidc/google/callback", "${var.public_base_url}/v1/connectors/gmail/callback"]
  }
}

output "image_platform" {
  description = "Platform the release images must include for this stack (PLATFORMS in docs/release.md)."
  value       = "linux/${var.architecture}"
}
