# Offline checks with mocked providers: no AWS credentials, no network.
# Run with: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "random" {}

variables {
  public_base_url          = "https://crm.example.com"
  release_version          = "v0.1.0"
  admin_bootstrap_password = "test-only-password-not-real"
  acm_certificate_arn      = "arn:aws:acm:eu-central-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  license_token            = "test-licence"
}

run "fixes_hold" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition = alltrue([
      for c in aws_lb_listener_rule.api_v1_and_ops.condition :
      !contains(flatten(c.path_pattern[*].values), "/metrics")
    ])
    error_message = "The ALB must not route /metrics from the internet to the api."
  }

  assert {
    condition     = aws_db_instance.this.engine_version == "16"
    error_message = "Postgres must be pinned to the major version only."
  }

  assert {
    condition = anytrue([
      for r in aws_security_group.db.ingress : contains(r.security_groups, aws_security_group.ops.id)
    ])
    error_message = "The bootstrap host must be able to reach RDS."
  }
}

run "defaults_plan" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition     = var.waf_mode == "count"
    error_message = "WAF must default to count mode for the first rollout."
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb.rule :
      length(r.override_action) == 0 || (length(r.override_action[0].count) == 1 && length(r.override_action[0].none) == 0)
    ])
    error_message = "In count mode every managed rule group must use override_action count."
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb.rule :
      length(r.action) == 0 || (length(r.action[0].count) == 1 && length(r.action[0].block) == 0)
    ])
    error_message = "In count mode every custom rule must use action count."
  }

  assert {
    condition = toset([for r in aws_wafv2_web_acl.alb.rule : r.name]) == toset([
      "AWS-AWSManagedRulesAmazonIpReputationList",
      "AWS-AWSManagedRulesAnonymousIpList",
      "AWS-AWSManagedRulesCommonRuleSet",
      "AWS-AWSManagedRulesKnownBadInputsRuleSet",
      "AWS-AWSManagedRulesSQLiRuleSet",
      "AWS-AWSManagedRulesLinuxRuleSet",
      "RateLimitAuthPaths",
      "RateLimitPerIP",
    ])
    error_message = "Unexpected WAF rule set: six managed rule groups and two rate rules."
  }

  assert {
    condition = anytrue([
      for r in aws_wafv2_web_acl.alb.rule :
      r.name == "RateLimitPerIP" &&
      length(r.statement[0].rate_based_statement[0].scope_down_statement[0].not_statement) == 1 &&
      strcontains(r.statement[0].rate_based_statement[0].scope_down_statement[0].not_statement[0].statement[0].regex_match_statement[0].regex_string, "/webhooks/")
    ])
    error_message = "The global per-IP rate rule must exclude the webhook paths."
  }

  assert {
    condition     = length(aws_wafv2_web_acl_logging_configuration.alb.redacted_fields) == 3 && length(aws_wafv2_web_acl_logging_configuration.alb.logging_filter) == 0
    error_message = "WAF logging must redact authorization, cookie and query string, and keep every record in count mode."
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf.name == "aws-waf-logs-margince" && aws_cloudwatch_log_group.waf.retention_in_days == 30
    error_message = "WAF log group must carry the aws-waf-logs- prefix and 30-day retention."
  }

  assert {
    condition = alltrue([
      for p in [
        aws_ssm_parameter.owner_dsn, aws_ssm_parameter.app_dsn, aws_ssm_parameter.redis_password,
        aws_ssm_parameter.keyvault_root_key, aws_ssm_parameter.webhook_key, aws_ssm_parameter.connector_state_key,
        aws_ssm_parameter.admin_password, aws_ssm_parameter.blobstore_access_key, aws_ssm_parameter.blobstore_secret_key,
        aws_ssm_parameter.rds_master_password, aws_ssm_parameter.license,
      ] : p.type == "SecureString" && p.tier == "Standard" && startswith(p.name, "/margince/")
    ])
    error_message = "Every credential must be a Standard-tier SecureString under /<name_prefix>/."
  }

  assert {
    condition = (
      length(aws_sns_topic_subscription.alert_email) == 0 &&
      aws_cloudwatch_metric_alarm.alb_elb_5xx.threshold == 25 &&
      aws_cloudwatch_metric_alarm.alb_target_5xx.threshold == 25 &&
      length(aws_cloudwatch_metric_alarm.alb_unhealthy_hosts) == 2 &&
      aws_cloudwatch_metric_alarm.alb_p95_latency.threshold == 2 &&
      length(aws_cloudwatch_metric_alarm.ecs_cpu) == 3 &&
      length(aws_cloudwatch_metric_alarm.ecs_memory) == 3 &&
      aws_cloudwatch_metric_alarm.rds_connections.threshold == 320 &&
      length(aws_cloudwatch_metric_alarm.rds_cpu_credit_balance) == 1 &&
      length(aws_cloudwatch_metric_alarm.redis_memory) == 2 &&
      length(aws_cloudwatch_metric_alarm.redis_engine_cpu) == 2 &&
      aws_cloudwatch_metric_alarm.waf_blocked_requests.threshold == 500
    )
    error_message = "Baseline alarms must always exist, with no email subscription unless alert_email is set."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.waf_blocked_requests.dimensions["Rule"] == "ALL" && aws_cloudwatch_metric_alarm.waf_blocked_requests.namespace == "AWS/WAFV2"
    error_message = "WAF blocked-requests alarm must watch the web-ACL-wide aggregate."
  }

  assert {
    condition     = contains(local.interface_endpoint_services, "ssm") && !contains(local.interface_endpoint_services, "secretsmanager")
    error_message = "Tasks read secrets through the ssm endpoint; the secretsmanager endpoint is unused."
  }
}

# Computed ARNs are unknown at plan; pin the ones the assertions compare.
run "defaults_encryption_and_wiring" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  override_resource {
    target          = aws_kms_key.data
    override_during = plan
    values          = { arn = "arn:aws:kms:eu-central-1:123456789012:key/11111111-1111-1111-1111-111111111111" }
  }

  override_resource {
    target          = aws_ssm_parameter.owner_dsn
    override_during = plan
    values          = { arn = "arn:aws:ssm:eu-central-1:123456789012:parameter/margince/owner-dsn" }
  }

  override_resource {
    target          = aws_ssm_parameter.rds_master_password
    override_during = plan
    values          = { arn = "arn:aws:ssm:eu-central-1:123456789012:parameter/margince/rds-master-password" }
  }

  assert {
    condition = alltrue([
      for p in [
        aws_ssm_parameter.owner_dsn, aws_ssm_parameter.app_dsn, aws_ssm_parameter.redis_password,
        aws_ssm_parameter.keyvault_root_key, aws_ssm_parameter.webhook_key, aws_ssm_parameter.connector_state_key,
        aws_ssm_parameter.admin_password, aws_ssm_parameter.blobstore_access_key, aws_ssm_parameter.blobstore_secret_key,
        aws_ssm_parameter.rds_master_password, aws_ssm_parameter.license,
      ] : p.key_id == aws_kms_key.data.arn
    ])
    error_message = "Every SSM parameter must be encrypted with the stack CMK."
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf.kms_key_id == aws_kms_key.data.arn && aws_sns_topic.alerts.kms_master_key_id == aws_kms_key.data.arn
    error_message = "WAF log group and SNS alert topic must be encrypted with the stack CMK."
  }

  assert {
    condition = (
      length(local.shared_secrets) == 10 &&
      anytrue([for s in local.shared_secrets : s.name == "MARGINCE_OWNER_DSN" && s.valueFrom == aws_ssm_parameter.owner_dsn.arn]) &&
      contains(keys(local.task_ssm_parameters), "MARGINCE_LICENSE")
    )
    error_message = "Task secrets must be the 10 task SSM parameters; the RDS master password is never one of them."
  }
}

# Global bucket names, the web SG split, and the Valkey 7.2 pin.
run "naming_sg_split_and_cache_version" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  override_resource {
    target          = aws_security_group.ecs_tasks
    override_during = plan
    values          = { id = "sg-0ecs0000000000000" }
  }

  override_resource {
    target          = aws_security_group.web
    override_during = plan
    values          = { id = "sg-0web0000000000000" }
  }

  override_resource {
    target          = aws_security_group.vpc_endpoints
    override_during = plan
    values          = { id = "sg-0vpce000000000000" }
  }

  override_resource {
    target          = aws_security_group.alb
    override_during = plan
    values          = { id = "sg-0alb0000000000000" }
  }

  assert {
    condition     = var.aws_region == "eu-central-1"
    error_message = "Test expectations below assume the default region eu-central-1."
  }

  assert {
    condition = (
      aws_s3_bucket.blobstore.bucket == "margince-blobstore-123456789012-eu-central-1" &&
      aws_s3_bucket.alb_logs.bucket == "margince-alb-logs-123456789012-eu-central-1" &&
      endswith(aws_s3_bucket.blobstore.bucket, "-123456789012-eu-central-1") &&
      endswith(aws_s3_bucket.alb_logs.bucket, "-123456789012-eu-central-1")
    )
    error_message = "Bucket names must end with -<account_id>-<region>."
  }

  assert {
    condition = (
      toset(aws_ecs_service.web.network_configuration[0].security_groups) == toset(["sg-0web0000000000000"]) &&
      !contains(aws_ecs_service.web.network_configuration[0].security_groups, aws_security_group.ecs_tasks.id) &&
      contains(aws_ecs_service.api.network_configuration[0].security_groups, aws_security_group.ecs_tasks.id) &&
      !contains(aws_ecs_service.api.network_configuration[0].security_groups, aws_security_group.web.id)
    )
    error_message = "web must use its own SG, distinct from api/worker's ecs_tasks SG."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.web_from_alb.referenced_security_group_id == aws_security_group.alb.id &&
      aws_vpc_security_group_ingress_rule.web_from_alb.from_port == 8080 &&
      aws_vpc_security_group_egress_rule.web_to_vpc_endpoints.referenced_security_group_id == aws_security_group.vpc_endpoints.id &&
      aws_vpc_security_group_egress_rule.web_to_vpc_endpoints.from_port == 443 &&
      aws_vpc_security_group_egress_rule.web_to_s3.from_port == 443 &&
      length(aws_security_group.web.ingress) == 0
    )
    error_message = "web SG: 8080 from the ALB only; egress 443 to the endpoints SG and the S3 prefix list."
  }

  assert {
    condition = anytrue([
      for r in aws_security_group.vpc_endpoints.ingress : contains(r.security_groups, aws_security_group.web.id) && r.from_port == 443
    ])
    error_message = "The interface endpoints SG must admit the web SG on 443."
  }

  assert {
    condition = !anytrue([
      for sg in [aws_security_group.db, aws_security_group.redis, aws_security_group.efs] :
      anytrue([for r in sg.ingress : contains(r.security_groups, aws_security_group.web.id)])
    ])
    error_message = "web must have no path to RDS, Redis or EFS."
  }

  assert {
    condition = (
      aws_elasticache_replication_group.this.engine == "valkey" &&
      aws_elasticache_replication_group.this.engine_version == "7.2" &&
      aws_elasticache_parameter_group.this.family == "valkey7" &&
      aws_elasticache_replication_group.this.transit_encryption_mode == "required"
    )
    error_message = "ElastiCache must run Valkey 7.2 (family valkey7) with TLS required."
  }
}

run "long_name_prefix_is_refused" {
  command = plan
  variables {
    name_prefix = "margince-a-very-long-production-prefix"
  }
  expect_failures = [var.name_prefix]
}

run "block_mode_and_alert_email" {
  command = plan

  variables {
    waf_mode    = "block"
    alert_email = "ops@example.com"
  }

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb.rule :
      length(r.override_action) == 0 || (
        r.name == "AWS-AWSManagedRulesAnonymousIpList"
        ? length(r.override_action[0].count) == 1
        : length(r.override_action[0].none) == 1
      )
    ])
    error_message = "Block mode: managed groups use none{}, except AnonymousIpList which stays count-only."
  }

  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.alb.rule :
      length(r.action) == 0 || length(r.action[0].block) == 1
    ])
    error_message = "Block mode: custom rules use action block."
  }

  assert {
    condition     = length(aws_wafv2_web_acl_logging_configuration.alb.logging_filter) == 1
    error_message = "Block mode drops plain ALLOW records from WAF logs."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.alert_email) == 1
    error_message = "alert_email subscribes to the alerts topic."
  }
}

run "images_follow_the_release_naming" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  override_resource {
    target          = aws_ecr_repository.api
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:eu-central-1:123456789012:repository/margince-default/api"
      repository_url = "123456789012.dkr.ecr.eu-central-1.amazonaws.com/margince-default/api"
    }
  }

  override_resource {
    target          = aws_ecr_repository.worker
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:eu-central-1:123456789012:repository/margince-default/worker"
      repository_url = "123456789012.dkr.ecr.eu-central-1.amazonaws.com/margince-default/worker"
    }
  }

  override_resource {
    target          = aws_ecr_repository.web
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:eu-central-1:123456789012:repository/margince-default/web"
      repository_url = "123456789012.dkr.ecr.eu-central-1.amazonaws.com/margince-default/web"
    }
  }

  assert {
    condition     = aws_ecr_repository.api.name == "margince-default/api" && aws_ecr_repository.worker.name == "margince-default/worker" && aws_ecr_repository.web.name == "margince-default/web"
    error_message = "ECR repositories are named <instance_name>/<role>, as make release names the images."
  }

  assert {
    condition = alltrue([
      for r in [aws_ecr_repository.api, aws_ecr_repository.worker, aws_ecr_repository.web] : r.image_tag_mutability == "IMMUTABLE"
    ])
    error_message = "Released tags are immutable."
  }

  assert {
    condition = alltrue([
      for role, ref in local.images : ref == "123456789012.dkr.ecr.eu-central-1.amazonaws.com/margince-default/${role}:v0.1.0"
    ]) && length(local.images) == 3
    error_message = "Images are <registry>/<instance_name>/<role>:<release_version>."
  }

  assert {
    condition     = var.architecture == "arm64" && aws_ecs_task_definition.api.runtime_platform[0].cpu_architecture == "ARM64"
    error_message = "The default architecture matches the linux/amd64 images make release builds by default."
  }
}

run "release_version_must_be_a_release" {
  command = plan
  variables {
    release_version = "latest"
  }
  expect_failures = [var.release_version]
}

run "missing_licence_is_refused" {
  command = plan
  variables {
    license_token = ""
  }
  expect_failures = [var.license_token]
}

run "security_group_and_iam_descriptions_are_ascii" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }

  # EC2 accepts only a-zA-Z0-9. _-:/()#,@[]+=&;{}!$* in security group and
  # rule descriptions; IAM role descriptions reject non-ASCII characters.
  # Inline rules reference security group IDs, which are unknown at plan
  # time, so only the group and standalone rule descriptions are checked.
  assert {
    condition = alltrue([
      for d in concat(
        [for sg in [aws_security_group.alb, aws_security_group.ecs_tasks, aws_security_group.web, aws_security_group.db, aws_security_group.redis, aws_security_group.efs, aws_security_group.ops, aws_security_group.vpc_endpoints] : sg.description],
        [aws_vpc_security_group_ingress_rule.web_from_alb.description, aws_vpc_security_group_egress_rule.web_to_vpc_endpoints.description, aws_vpc_security_group_egress_rule.web_to_s3.description],
      ) : can(regex("^[a-zA-Z0-9. _:/()#,@\\[\\]+=&;{}!$*-]*$", d))
    ])
    error_message = "A security group or rule description uses a character EC2 refuses."
  }

  assert {
    condition = alltrue([
      for d in [aws_iam_role.execution.description, aws_iam_role.execution_web.description, aws_iam_role.task_api.description, aws_iam_role.task_worker.description, aws_iam_role.task_web.description, aws_iam_role.vpc_flow_logs.description, aws_iam_role.ops.description] :
      can(regex("^[ -~]*$", d))
    ])
    error_message = "An IAM role description uses a non-ASCII character."
  }
}

run "release_runner" {
  command = plan

  override_resource {
    target          = aws_security_group.ops
    override_during = plan
    values          = { id = "sg-0ops0000000000000" }
  }
  override_resource {
    target          = aws_security_group.release_runner
    override_during = plan
    values          = { id = "sg-0runner000000000" }
  }
  override_resource {
    target          = aws_subnet.private
    override_during = plan
    values          = { id = "subnet-0private000000" }
  }
  override_resource {
    target          = aws_ecr_repository.api
    override_during = plan
    values          = { arn = "arn:aws:ecr:eu-central-1:123456789012:repository/margince-default/api" }
  }
  override_resource {
    target          = aws_ecr_repository.worker
    override_during = plan
    values          = { arn = "arn:aws:ecr:eu-central-1:123456789012:repository/margince-default/worker" }
  }
  override_resource {
    target          = aws_ecr_repository.web
    override_during = plan
    values          = { arn = "arn:aws:ecr:eu-central-1:123456789012:repository/margince-default/web" }
  }
  override_resource {
    target          = aws_kms_key.data
    override_during = plan
    values          = { arn = "arn:aws:kms:eu-central-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }

  assert {
    condition = (
      aws_instance.release_runner.instance_type == "t4g.large" &&
      !aws_instance.release_runner.associate_public_ip_address &&
      aws_instance.release_runner.metadata_options[0].http_tokens == "required" &&
      aws_instance.release_runner.metadata_options[0].http_put_response_hop_limit == 1 &&
      aws_instance.release_runner.root_block_device[0].encrypted &&
      aws_instance.release_runner.root_block_device[0].volume_type == "gp3" &&
      aws_instance.release_runner.root_block_device[0].volume_size == 50 &&
      aws_iam_role_policy_attachment.release_runner_ssm.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    )
    error_message = "The release runner is a t3.large with no public IP, IMDSv2 only (hop limit 1), an encrypted 50 GB gp3 root and SSM access."
  }

  assert {
    condition     = aws_instance.release_runner.subnet_id == "subnet-0private000000" && aws_subnet.private[0].map_public_ip_on_launch != true
    error_message = "The release runner sits in a private subnet."
  }

  assert {
    condition = (
      length(aws_security_group.release_runner.ingress) == 0 &&
      toset([for e in aws_security_group.release_runner.egress : e.from_port]) == toset([80, 443]) &&
      alltrue([for e in aws_security_group.release_runner.egress : e.protocol == "tcp" && e.from_port == e.to_port]) &&
      anytrue([for r in aws_security_group.vpc_endpoints.ingress : contains(r.security_groups, "sg-0runner000000000") && r.from_port == 443])
    )
    error_message = "The runner security group has no ingress and only 80/443 egress; the VPC endpoints admit it on 443."
  }

  assert {
    condition = (
      toset(flatten([for st in data.aws_iam_policy_document.release_runner_ecr.statement : st.resources if st.sid == "PushAndPullOwnImages"])) == toset([aws_ecr_repository.api.arn, aws_ecr_repository.worker.arn, aws_ecr_repository.web.arn]) &&
      toset(flatten([for st in data.aws_iam_policy_document.release_runner_ecr.statement : st.actions if st.sid == "PushAndPullOwnImages"])) == toset(["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"]) &&
      flatten([for st in data.aws_iam_policy_document.release_runner_ecr.statement : st.resources if st.sid == "EcrAuth"]) == ["*"] &&
      flatten([for st in data.aws_iam_policy_document.release_runner_ecr.statement : st.actions if st.sid == "EcrAuth"]) == ["ecr:GetAuthorizationToken"] &&
      flatten([for st in data.aws_iam_policy_document.release_runner_ecr.statement : st.resources if st.sid == "UseDataKeyThroughEcr"]) == [aws_kms_key.data.arn] &&
      length(data.aws_iam_policy_document.release_runner_ecr.statement) == 3
    )
    error_message = "The runner role pushes only to the three ECR repositories of this stack and uses the CMK only through ECR."
  }

  assert {
    condition = (
      strcontains(local.release_runner_cloud_init, "actions-runner-linux-arm64-${local.release_runner.version}.tar.gz") &&
      strcontains(local.release_runner_cloud_init, "${local.release_runner.sha256.arm64}  /tmp/actions-runner.tar.gz\" | sha256sum -c -") &&
      can(regex("^[0-9a-f]{64}$", local.release_runner.sha256.arm64)) && can(regex("^[0-9a-f]{64}$", local.release_runner.sha256.amd64)) &&
      strcontains(local.release_runner_cloud_init, "amazon-ecr-credential-helper") &&
      strcontains(local.release_runner_cloud_init, "{ \"credHelpers\": { \"123456789012.dkr.ecr.eu-central-1.amazonaws.com\": \"ecr-login\" } }") &&
      strcontains(local.release_runner_cloud_init, "docker-buildx-plugin") &&
      !strcontains(local.release_runner_cloud_init, "config.sh") &&
      aws_instance.release_runner.user_data == local.release_runner_cloud_init
    )
    error_message = "cloud-init installs the pinned, checksummed runner (unregistered) and the ECR credential helper for this registry."
  }

  assert {
    condition     = output.release_runner_label == "margince-runner" && local.ecr_registry_host == "123456789012.dkr.ecr.eu-central-1.amazonaws.com"
    error_message = "The runner label matches the RELEASE_RUNNER value in the README; the helper targets this registry."
  }

  assert {
    condition = (
      can(regex("^[a-zA-Z0-9. _:/()#,@\\[\\]+=&;{}!$*-]*$", aws_security_group.release_runner.description)) &&
      alltrue([for e in aws_security_group.release_runner.egress : can(regex("^[a-zA-Z0-9. _:/()#,@\\[\\]+=&;{}!$*-]*$", e.description))]) &&
      can(regex("^[ -~]*$", aws_iam_role.release_runner.description))
    )
    error_message = "A release runner security group or IAM description uses a character AWS refuses."
  }
}
