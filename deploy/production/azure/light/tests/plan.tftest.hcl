# Offline checks with mocked providers: no Azure access needed.
#   terraform init -backend=false && terraform test
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }

  # Resource IDs in the shape the provider validates, for the mocked apply.
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/virtualNetworks/vnet" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/virtualNetworks/vnet/subnets/subnet" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/networkSecurityGroups/nsg" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/publicIPAddresses/pip", ip_address = "198.51.100.7" }
  }
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Network/networkInterfaces/nic" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Compute/virtualMachines/vm" }
  }
  mock_resource "azurerm_managed_disk" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Compute/disks/data" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.KeyVault/vaults/kv" }
  }
  mock_resource "azurerm_recovery_services_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.RecoveryServices/vaults/rsv" }
  }
  mock_resource "azurerm_backup_policy_vm" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.RecoveryServices/vaults/rsv/backupPolicies/daily" }
  }
  mock_resource "azurerm_monitor_action_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/margince-light/providers/Microsoft.Insights/actionGroups/alerts" }
  }
}
mock_provider "random" {}

variables {
  domain               = "crm.example.com"
  license_token        = "test-licence"
  admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/vUmkEV7lfFP7t36rOoMbvwoNzx4r0gfQKltPmyKTIC6WILJaitH79JH2yJXHb8ePibRalweus+EV/EPKn0oUrOzjVsjVzMef9Rz5CoAovRnDe6z2+y84XnjlIeN5b58NkeBaliOlFv36enIfMluv/sOMHTjfBwbCooF+ChwYnz9p20V5y0DFe/axStpcKcmHW7RfRuijO+vxC+te9mhCbLdN1sJm6qC9pSeADHSDH/swyDK6l1526/+NJqHfryRbhuQ8uPDL7pT14Z02AFnvIMvYhvSomi4Kag9aFQLFmm2Jd1Yz6lERFj4i6+51WvD/ZPmC7OER6N09qlUdXo3qx8Amf472GAQl9VhVHtolycBNtKehQomHLNuBffSIiarnOH5hYwLQEBD3ixah4xbXlmDAb9p+Ub31ppEv9ZLA2YebcRPzUfy/bvBLxysWAJTSwrnTvP0/bJW4Egqa37prx8MQRQkB/yRiET3I3DHFlLDsSnKQnEYSEBmvvLvxE6s= test"
  ssh_allowed_cidrs    = ["203.0.113.10/32", "198.51.100.0/24"]
}

run "single_ubuntu_vm" {
  command = plan
  assert {
    condition = (
      azurerm_linux_virtual_machine.this.source_image_reference[0].publisher == "Canonical" &&
      azurerm_linux_virtual_machine.this.source_image_reference[0].offer == "ubuntu-24_04-lts" &&
      azurerm_linux_virtual_machine.this.source_image_reference[0].sku == "server-arm64"
    )
    error_message = "The VM runs Canonical Ubuntu 24.04 LTS server, Arm64 by default."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.size == "Standard_B2ps_v2" && azurerm_linux_virtual_machine.this.admin_username == "azureadmin" && azurerm_linux_virtual_machine.this.disable_password_authentication
    error_message = "One Standard_B2ps_v2 VM (Ampere, the default), admin user azureadmin, key login only."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.secure_boot_enabled && azurerm_linux_virtual_machine.this.vtpm_enabled && azurerm_linux_virtual_machine.this.encryption_at_host_enabled
    error_message = "Trusted Launch and encryption at host are on."
  }
  assert {
    condition     = azurerm_public_ip.vm.allocation_method == "Static" && azurerm_public_ip.vm.sku == "Standard"
    error_message = "The public IP is static."
  }
}

run "firewall" {
  command = plan
  assert {
    condition = one([
      for r in azurerm_network_security_group.vm.security_rule : r
      if r.access == "Allow" && r.destination_port_range == "22"
    ]).source_address_prefixes == toset(["203.0.113.10/32", "198.51.100.0/24"])
    error_message = "SSH is allowed from ssh_allowed_cidrs only."
  }
  assert {
    condition = one([
      for r in azurerm_network_security_group.vm.security_rule : r
      if r.name == "AllowHttpHttpsFromInternet"
    ]).destination_port_ranges == toset(["80", "443"]) && one([for r in azurerm_network_security_group.vm.security_rule : r if r.name == "AllowHttpHttpsFromInternet"]).source_address_prefix == "Internet"
    error_message = "80 and 443 are open to the internet."
  }
  assert {
    condition     = anytrue([for r in azurerm_network_security_group.vm.security_rule : r.access == "Deny" && r.destination_port_range == "22" && r.source_address_prefix == "*"])
    error_message = "Every other SSH source is denied."
  }
  assert {
    condition     = azurerm_key_vault.this.network_acls[0].default_action == "Deny" && toset(azurerm_key_vault.this.network_acls[0].ip_rules) == toset(["203.0.113.10", "198.51.100.0/24"])
    error_message = "The Key Vault firewall admits ssh_allowed_cidrs only, /32 as a single address."
  }
}

run "data_disk" {
  command = plan
  assert {
    condition     = azurerm_managed_disk.data.disk_size_gb == 64 && azurerm_virtual_machine_data_disk_attachment.data.lun == 0
    error_message = "A 64 GB data disk on LUN 0."
  }
  assert {
    condition     = strcontains(regex("resource \"azurerm_managed_disk\" \"data\" \\{((?s:.*?))\\n\\}", file("${path.module}/vm.tf"))[0], "prevent_destroy = true")
    error_message = "The data disk has prevent_destroy."
  }
  assert {
    condition = alltrue([
      strcontains(local.cloud_init, "mount_point=/var/lib/docker"),
      strcontains(local.cloud_init, "/dev/disk/azure/scsi1/lun0"),
      strcontains(local.cloud_init, "nofail"),
      strcontains(local.cloud_init, "UUID=$uuid"),
      strcontains(local.cloud_init, "RequiresMountsFor=/var/lib/docker"),
      strcontains(local.cloud_init, "$host_src $host_root none bind,nofail"),
      strcontains(local.cloud_init, "host_root=/opt/margince"),
      strcontains(local.cloud_init, "admin_user=\"azureadmin\""),
      !strcontains(local.cloud_init, "docker-ce"),
      !strcontains(local.cloud_init, "nginx"),
      !strcontains(local.cloud_init, "git clone"),
    ])
    error_message = "cloud-init only mounts the data disk at /var/lib/docker by UUID with nofail."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.custom_data == base64encode(local.cloud_init)
    error_message = "The VM boots with the cloud-init document."
  }
}

run "backup_and_alarms" {
  command = plan
  assert {
    condition     = azurerm_backup_policy_vm.daily.backup[0].frequency == "Daily" && azurerm_backup_policy_vm.daily.retention_daily[0].count == 7
    error_message = "Daily backup of the VM with 7-day retention."
  }
  assert {
    condition     = azurerm_monitor_metric_alert.cpu_high.criteria[0].threshold == 90 && azurerm_monitor_metric_alert.cpu_high.window_size == "PT15M"
    error_message = "CPU alert: over 90% for 15 minutes."
  }
  assert {
    condition     = azurerm_monitor_metric_alert.vm_unavailable.criteria[0].metric_name == "VmAvailabilityMetric" && azurerm_monitor_metric_alert.vm_unavailable.window_size == "PT5M"
    error_message = "Availability alert: unavailable for 5 minutes."
  }
}

run "outputs" {
  command = apply
  assert {
    condition     = output.host_env == "HOST_SSH=azureadmin@198.51.100.7\nHOST_DOMAIN=crm.example.com\n"
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
    condition     = output.secret_names == tolist(["MARGINCE_LICENSE"])
    error_message = "secret_names lists the license only."
  }
  assert {
    condition     = keys(azurerm_key_vault_secret.this) == ["margince-license"]
    error_message = "Key Vault holds the license only."
  }
  assert {
    condition = output.sso_redirect_uris == {
      microsoft = ["https://crm.example.com/v1/auth/oidc/microsoft/callback", "https://crm.example.com/v1/connectors/graph/callback", "https://crm.example.com/v1/connectors/graphcal/callback"]
      google    = ["https://crm.example.com/v1/auth/oidc/google/callback", "https://crm.example.com/v1/connectors/gmail/callback"]
    }
    error_message = "sso_redirect_uris lists the Microsoft and Google callbacks under https://<domain>."
  }
}

run "no_license" {
  command = plan
  variables {
    license_token = ""
  }
  assert {
    condition     = !contains(keys(local.kv_secrets), "margince-license") && !contains(output.secret_names, "MARGINCE_LICENSE")
    error_message = "Without a license no license secret is stored or listed."
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

run "no_identity_resources" {
  command = plan
  assert {
    condition     = alltrue([for f in fileset(path.module, "*.tf") : !can(regex("azuread_|hashicorp/azuread|provider \"azuread\"", file("${path.module}/${f}")))])
    error_message = "The stack creates no Entra resources and declares no azuread provider; sign-in apps are set up in Margince under Settings."
  }
}

run "arm64_size_gets_arm64_image" {
  command = plan
  variables {
    architecture = "arm64"
    vm_size      = "Standard_B2pls_v2"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.source_image_reference[0].sku == "server-arm64" && output.image_platform == "linux/arm64"
    error_message = "An Ampere size gets the Arm64 Ubuntu image and needs linux/arm64 images."
  }
}

run "x86_size_gets_x86_image" {
  command = plan
  variables {
    architecture = "amd64"
    vm_size      = "Standard_B2ms"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.source_image_reference[0].sku == "server" && output.image_platform == "linux/amd64"
    error_message = "The default size gets the x86_64 Ubuntu image and needs linux/amd64 images."
  }
}

run "ampere_size_without_arm64_refused" {
  command = plan
  variables {
    architecture = "amd64"
    vm_size      = "Standard_B2pls_v2"
  }
  expect_failures = [var.vm_size]
}

run "arm64_with_x86_size_refused" {
  command = plan
  variables {
    architecture = "arm64"
    vm_size      = "Standard_B2ms"
  }
  expect_failures = [var.vm_size]
}
