# The outputs shared with the AWS light stack come first, with the same
# names. Azure-only outputs follow.

locals {
  ssh_user  = local.admin_username
  public_ip = azurerm_public_ip.vm.ip_address

  kv_read = "az keyvault secret show --vault-name ${azurerm_key_vault.this.name} --query value -o tsv -n"

  # Names for deploy/production/secrets, and the commands that set their
  # values in the shell that runs make deploy.
  secret_env = local.license_set ? { MARGINCE_LICENSE = "$(${local.kv_read} margince-license)" } : {}
}

# ---- Shared with aws/light ------------------------------------------------------

output "public_ip" {
  description = "The VM's static public IP. The A record of domain points here."
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
    az vm boot-diagnostics get-boot-log -g ${azurerm_resource_group.this.name} -n ${azurerm_linux_virtual_machine.this.name} | grep -A6 'BEGIN SSH HOST KEY FINGERPRINTS'
    # The ED25519 fingerprints must match. Then:
    export HOST_KNOWN_HOSTS="$(cat known_hosts.production)"
  EOT
}

output "dns_record" {
  description = "The DNS record to create at your DNS provider."
  value       = "${var.domain} A ${local.public_ip}"
}

output "ssh_command" {
  description = "Opens a shell on the VM."
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

# ---- Azure only -----------------------------------------------------------------

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.this.name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "public_base_url" {
  value = local.public_base_url
}

output "sso_redirect_uris" {
  description = "Redirect URIs to register in the customer's own Microsoft Entra or Google app, for optional sign-in and mailbox capture configured in Margince under Settings. Margince needs none of them to run."
  value = {
    microsoft = ["${local.public_base_url}/v1/auth/oidc/microsoft/callback", "${local.public_base_url}/v1/connectors/graph/callback", "${local.public_base_url}/v1/connectors/graphcal/callback"]
    google    = ["${local.public_base_url}/v1/auth/oidc/google/callback", "${local.public_base_url}/v1/connectors/gmail/callback"]
  }
}

output "alerts_action_group_id" {
  description = "The action group that receives the alerts."
  value       = azurerm_monitor_action_group.alerts.id
}

output "image_platform" {
  description = "Platform the release images must include for this VM (PLATFORMS in docs/release.md)."
  value       = "linux/${var.architecture}"
}
