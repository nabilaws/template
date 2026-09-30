output "public_ip_address" {
  description = "The Application Gateway's public IP. Point public_base_url's host at it with an A record (README.md, step 5)."
  value       = azurerm_public_ip.appgw.ip_address
}

output "api_internal_fqdn" {
  description = "The api app's ingress FQDN inside the VNet: the Application Gateway's backend. Resolves only inside the VNet. Empty until deploy_apps = true."
  value       = var.deploy_apps ? azurerm_container_app.api[0].ingress[0].fqdn : ""
}

output "environment_static_ip" {
  description = "Private IP of the internal Container Apps environment's load balancer (appgw.tf's private DNS zone points the default domain at it)."
  value       = azurerm_container_app_environment.this.static_ip_address
}

output "public_certificate_secret_id" {
  description = "Key Vault secret ID the Application Gateway reads its TLS certificate from. Import the certificate as public-tls (README.md, step 5)."
  value       = local.public_certificate_secret_id
}

output "waf_policy_mode" {
  description = "Detection (waf_mode = \"count\") or Prevention (waf_mode = \"block\")."
  value       = azurerm_web_application_firewall_policy.this.policy_settings[0].mode
}

output "nat_egress_ip" {
  description = "The one address api and worker call out from. Add it to the Dataverse environment's IP firewall (Managed Environments) and to any partner allowlist."
  value       = azurerm_public_ip.nat.ip_address
}

output "sso_redirect_uris" {
  description = "Redirect URIs to register in the customer's own Microsoft Entra or Google app, for optional sign-in and mailbox capture configured in Margince under Settings. Margince needs none of them to run."
  value = {
    microsoft = ["${var.public_base_url}/v1/auth/oidc/microsoft/callback", "${var.public_base_url}/v1/connectors/graph/callback", "${var.public_base_url}/v1/connectors/graphcal/callback"]
    google    = ["${var.public_base_url}/v1/auth/oidc/google/callback", "${var.public_base_url}/v1/connectors/gmail/callback"]
  }
}

output "dataverse_identity_client_id" {
  description = "Client ID to register as a Dataverse application user (Power Platform admin center, Environment, Settings, Application users)."
  value       = azurerm_user_assigned_identity.dataverse.client_id
}

output "dataverse_identity_principal_id" {
  value = azurerm_user_assigned_identity.dataverse.principal_id
}

output "container_app_environment_name" {
  value = azurerm_container_app_environment.this.name
}

output "registry" {
  description = "The REGISTRY value for `make release` and `make package` (docs/release.md, Section 5): this stack's registry login server."
  value       = azurerm_container_registry.this.login_server
}

output "image_refs" {
  description = "The images this stack deploys: <registry>/<instance_name>/<role>:<release_version>. ACR creates the repositories on the first push."
  value       = local.images
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "redis_address" {
  description = "Redis inside the Container Apps environment (internal TCP ingress)."
  value       = "${azurerm_container_app.redis.name}:6379"
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "jumpbox_name" {
  value = azurerm_linux_virtual_machine.jumpbox.name
}

output "jumpbox_private_ip" {
  value = azurerm_linux_virtual_machine.jumpbox.private_ip_address
}

output "release_runner_label" {
  description = "Label of the self-hosted release runner: the RELEASE_RUNNER repository variable (README.md, step 3)."
  value       = local.release_runner.label
}

output "release_runner_vm_name" {
  description = "The release runner is the jumpbox VM. Start it for a release with `az vm start`."
  value       = azurerm_linux_virtual_machine.jumpbox.name
}

output "release_runner_vm_id" {
  value = azurerm_linux_virtual_machine.jumpbox.id
}

output "jumpbox_admin_username" {
  value = local.jumpbox_admin_username
}

# ---- Database bootstrap (README.md step 2) --------------------------------------
# Generated without special characters, so they go into a DSN unescaped. Read
# with `terraform output -raw <name>`; never printed by a plain `terraform output`.

output "postgres_admin_password" {
  value     = random_password.postgres_admin.result
  sensitive = true
}

output "margince_owner_password" {
  value     = random_password.margince_owner.result
  sensitive = true
}

output "margince_app_password" {
  value     = random_password.margince_app.result
  sensitive = true
}

output "postgres_server_name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "image_platform" {
  description = "Platform the release images must include for this stack (PLATFORMS in docs/release.md)."
  value       = "linux/${var.architecture}"
}
