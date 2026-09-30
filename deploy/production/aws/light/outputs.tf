# The outputs shared with the Azure light stack come first, with the same
# names. AWS-only outputs follow.

locals {
  ssh_user  = "ubuntu"
  public_ip = aws_eip.this.public_ip

  # Names for deploy/production/secrets, and the commands that set their
  # values in the shell that runs make deploy.
  secret_env = local.license_set ? {
    MARGINCE_LICENSE = "$(aws ssm get-parameter --region ${var.region} --name ${local.license_name} --with-decryption --query Parameter.Value --output text)"
  } : {}
}

# ---- Shared with azure/light ----------------------------------------------------

output "public_ip" {
  description = "The Elastic IP. The A record of domain points here."
  value       = local.public_ip
}

output "host_env" {
  description = "The lines for deploy/production/host.env."
  value       = "HOST_SSH=${local.ssh_user}@${local.public_ip}\nHOST_DOMAIN=${var.domain}\n"
}

output "ssh_known_hosts_hint" {
  description = "Commands that read the SSH host key and the fingerprints to compare it with, for HOST_KNOWN_HOSTS."
  value       = <<-EOT
    ssh-keyscan -t ed25519 ${local.public_ip} > known_hosts.production
    ssh-keygen -lf known_hosts.production
    aws ec2 get-console-output --region ${var.region} --instance-id ${aws_instance.this.id} --latest --output text | grep -A6 'BEGIN SSH HOST KEY FINGERPRINTS'
    # The ED25519 fingerprints must match. Then:
    export HOST_KNOWN_HOSTS="$(cat known_hosts.production)"
  EOT
}

output "dns_record" {
  description = "The DNS record to create at your DNS provider."
  value       = "${var.domain} A ${local.public_ip}"
}

output "ssh_command" {
  description = "Opens a shell on the instance."
  value       = "ssh ${local.ssh_user}@${local.public_ip}"
}

output "secret_names" {
  description = "Names to list in deploy/production/secrets, besides the ones you add yourself."
  value       = sort(keys(local.secret_env))
}

output "secret_exports" {
  description = "Commands that set the values of secret_names in the shell that runs make deploy."
  value       = join("", [for k in sort(keys(local.secret_env)) : "export ${k}=\"${local.secret_env[k]}\"\n"])
}

# ---- AWS only -------------------------------------------------------------------

output "instance_id" {
  value = aws_instance.this.id
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

output "license_parameter_name" {
  description = "The SSM parameter that holds MARGINCE_LICENSE. Empty without license_token."
  value       = local.license_set ? local.license_name : ""
}

output "alerts_topic_arn" {
  description = "The SNS topic that receives the alarms."
  value       = aws_sns_topic.alerts.arn
}

output "sso_redirect_uris" {
  description = "Redirect URIs to register in the customer's own Microsoft Entra or Google app, for optional sign-in and mailbox capture configured in Margince under Settings. Margince needs none of them to run."
  value = {
    microsoft = ["https://${var.domain}/v1/auth/oidc/microsoft/callback", "https://${var.domain}/v1/connectors/graph/callback", "https://${var.domain}/v1/connectors/graphcal/callback"]
    google    = ["https://${var.domain}/v1/auth/oidc/google/callback", "https://${var.domain}/v1/connectors/gmail/callback"]
  }
}

output "image_platform" {
  description = "Platform the release images must include for this instance (PLATFORMS in docs/release.md)."
  value       = "linux/${var.architecture}"
}
