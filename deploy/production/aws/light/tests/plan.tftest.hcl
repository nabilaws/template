# Offline checks with mocked providers: no AWS credentials, no network.
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.7" }
  }
  mock_resource "aws_instance" {
    defaults = { id = "i-0123456789abcdef0" }
  }
  mock_resource "aws_ebs_volume" {
    defaults = { id = "vol-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/margince-light-dlm" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:eu-central-1:123456789012:margince-light-alerts" }
  }
}

variables {
  domain               = "crm.example.com"
  license_token        = "test-licence"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test"
  ssh_allowed_cidrs    = ["203.0.113.10/32", "198.51.100.0/24"]
}

run "single_ubuntu_instance" {
  command = plan
  assert {
    condition     = data.aws_ssm_parameter.ubuntu.name == "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
    error_message = "The AMI is Canonical Ubuntu 24.04 LTS for amd64."
  }
  assert {
    condition     = aws_instance.this.instance_type == "t4g.large" && aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "One t3.large instance with IMDSv2 required."
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.root_block_device[0].volume_type == "gp3"
    error_message = "The root volume is encrypted gp3."
  }
  assert {
    condition     = aws_key_pair.admin.public_key == var.admin_ssh_public_key
    error_message = "The key pair holds admin_ssh_public_key."
  }
  assert {
    condition     = aws_eip.this.domain == "vpc"
    error_message = "An Elastic IP gives the instance a static address."
  }
  assert {
    condition     = strcontains(file("${path.module}/ec2.tf"), "ignore_changes = [ami]")
    error_message = "A newer AMI does not replace the instance."
  }
}

run "arm64" {
  command = plan
  variables {
    architecture  = "arm64"
    instance_type = "t4g.large"
  }
  assert {
    condition     = strcontains(data.aws_ssm_parameter.ubuntu.name, "/current/arm64/")
    error_message = "A Graviton instance type picks the arm64 AMI."
  }
}

run "firewall" {
  command = plan
  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.ssh : r.cidr_ipv4]) == toset(["203.0.113.10/32", "198.51.100.0/24"]) && alltrue([for r in aws_vpc_security_group_ingress_rule.ssh : r.from_port == 22 && r.to_port == 22])
    error_message = "SSH is allowed from ssh_allowed_cidrs only."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.http.cidr_ipv4 == "0.0.0.0/0" && aws_vpc_security_group_ingress_rule.http.from_port == 80 && aws_vpc_security_group_ingress_rule.https.cidr_ipv4 == "0.0.0.0/0" && aws_vpc_security_group_ingress_rule.https.from_port == 443
    error_message = "80 and 443 are open to the internet."
  }
  assert {
    condition = alltrue([
      for d in concat(
        [aws_security_group.host.description, aws_vpc_security_group_ingress_rule.http.description, aws_vpc_security_group_ingress_rule.https.description, aws_vpc_security_group_egress_rule.all.description],
        [for r in aws_vpc_security_group_ingress_rule.ssh : r.description],
      ) : can(regex("^[a-zA-Z0-9. _:/()#,@\\[\\]+=&;{}!$*-]+$", d))
    ])
    error_message = "Security group descriptions use only the characters AWS allows."
  }
}

run "data_volume" {
  command = plan
  assert {
    condition     = aws_ebs_volume.data.size == 64 && aws_ebs_volume.data.encrypted && aws_ebs_volume.data.type == "gp3"
    error_message = "A 64 GB encrypted gp3 data volume."
  }
  assert {
    condition     = aws_ebs_volume.data.availability_zone == aws_subnet.public.availability_zone
    error_message = "The data volume is in the instance's zone."
  }
  assert {
    condition     = strcontains(regex("resource \"aws_ebs_volume\" \"data\" \\{((?s:.*?))\\n\\}", file("${path.module}/ec2.tf"))[0], "prevent_destroy = true")
    error_message = "The data volume has prevent_destroy."
  }
}

run "cloud_init" {
  command = apply
  assert {
    condition = alltrue([
      strcontains(local.cloud_init, "mount_point=/var/lib/docker"),
      strcontains(local.cloud_init, "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0"),
      strcontains(local.cloud_init, "nofail"),
      strcontains(local.cloud_init, "UUID=$uuid"),
      strcontains(local.cloud_init, "RequiresMountsFor=/var/lib/docker"),
      strcontains(local.cloud_init, "$host_src $host_root none bind,nofail"),
      strcontains(local.cloud_init, "host_root=/opt/margince"),
      strcontains(local.cloud_init, "admin_user=\"ubuntu\""),
      !strcontains(local.cloud_init, "docker-ce"),
      !strcontains(local.cloud_init, "nginx"),
      !strcontains(local.cloud_init, "git clone"),
    ])
    error_message = "user_data only mounts the data volume at /var/lib/docker by UUID with nofail."
  }
  assert {
    condition     = aws_instance.this.user_data_replace_on_change
    error_message = "A user_data change replaces the instance."
  }
}

run "backup_and_alarms" {
  command = plan
  assert {
    condition     = aws_dlm_lifecycle_policy.daily.state == "ENABLED" && aws_dlm_lifecycle_policy.daily.policy_details[0].schedule[0].retain_rule[0].count == 7
    error_message = "Daily snapshots, 7 kept."
  }
  assert {
    condition     = aws_dlm_lifecycle_policy.daily.policy_details[0].target_tags["Backup"] == "margince-light-daily" && length(aws_dlm_lifecycle_policy.daily.policy_details[0].target_tags) == 1
    error_message = "The snapshots select the volumes tagged Backup = <name_prefix>-daily."
  }
  assert {
    condition     = aws_ebs_volume.data.tags["Backup"] == "margince-light-daily" && aws_instance.this.root_block_device[0].tags["Backup"] == "margince-light-daily"
    error_message = "The data volume and the root volume carry the backup tag."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.cpu_high.threshold == 90 && aws_cloudwatch_metric_alarm.cpu_high.period * aws_cloudwatch_metric_alarm.cpu_high.evaluation_periods == 900
    error_message = "CPU alarm: over 90% for 15 minutes."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.instance_status_check_failed.period * aws_cloudwatch_metric_alarm.instance_status_check_failed.evaluation_periods == 300
    error_message = "Instance status alarm: failed for 5 minutes."
  }
  assert {
    condition     = contains(aws_cloudwatch_metric_alarm.system_status_check_failed.alarm_actions, "arn:aws:automate:eu-central-1:ec2:recover")
    error_message = "The system status alarm recovers the instance."
  }
}

run "outputs" {
  command = apply
  assert {
    condition     = output.host_env == "HOST_SSH=ubuntu@198.51.100.7\nHOST_DOMAIN=crm.example.com\n"
    error_message = "host_env holds HOST_SSH and HOST_DOMAIN."
  }
  assert {
    condition     = output.dns_record == "crm.example.com A 198.51.100.7" && output.public_ip == "198.51.100.7"
    error_message = "dns_record points domain at the public IP."
  }
  assert {
    condition     = strcontains(output.ssh_known_hosts_hint, "ssh-keyscan -t ed25519 198.51.100.7") && strcontains(output.ssh_known_hosts_hint, "HOST_KNOWN_HOSTS")
    error_message = "ssh_known_hosts_hint reads the host key of the public IP."
  }
  assert {
    condition     = output.secret_names == tolist(["MARGINCE_LICENSE"]) && strcontains(output.secret_exports, "--name /margince-light/margince-license --with-decryption")
    error_message = "secret_names lists the license and secret_exports reads it from SSM."
  }
  assert {
    condition     = aws_ssm_parameter.license[0].type == "SecureString"
    error_message = "The license is an SSM SecureString."
  }
}

run "no_license" {
  command = plan
  variables {
    license_token = ""
  }
  assert {
    condition     = length(aws_ssm_parameter.license) == 0 && length(output.secret_names) == 0
    error_message = "Without a license no parameter is stored or listed."
  }
}

run "empty_ssh_allowed_cidrs_refused" {
  command = plan
  variables {
    ssh_allowed_cidrs = []
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "ssh_from_anywhere_refused" {
  command = plan
  variables {
    ssh_allowed_cidrs = ["203.0.113.10/32", "0.0.0.0/0"]
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "ssh_from_anywhere_ipv6_refused" {
  command = plan
  variables {
    ssh_allowed_cidrs = ["::/0"]
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "graviton_type_without_arm64_refused" {
  command = plan
  variables {
    architecture  = "amd64"
    instance_type = "t4g.large"
  }
  expect_failures = [var.instance_type]
}

run "arm64_with_x86_type_refused" {
  command = plan
  variables {
    architecture  = "arm64"
    instance_type = "t3.large"
  }
  expect_failures = [var.instance_type]
}
