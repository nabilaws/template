# Operator jumpbox: one Linux VM inside the VNet, for everything that must
# reach the private endpoints (Postgres has no public endpoint at all):
#
#   - the one-time database bootstrap (README.md step 2);
#   - building and pushing releases, as this stack's self-hosted GitHub
#     Actions runner (step 3);
#   - writing margince.yaml onto the config share (step 4);
#   - terraform apply once operator_ip_allowlist is empty (step 6).
#
# Release runner: cloud-init installs Docker and the pinned runner package
# but does not register it (registration needs a one-time GitHub token,
# README.md step 3). release.yml then builds, smoke-tests and pushes on this
# VM, which logs in to the registry with its own managed identity (AcrPush on
# this registry only, below): no registry password exists, and the registry
# stays private behind its private endpoint. Standard_B2ms (8 GiB) is the
# smallest size that builds the Go and pnpm images comfortably.
#
# No public IP. Reach it through Azure Bastion's free Developer tier (browser
# SSH from the portal) or `az vm run-command invoke` from any machine logged
# in to Azure. It shuts down every evening at 20:00 West Europe time; start
# it on demand with `az vm start`. A release started while it is off waits in
# GitHub's queue until the VM is running.

locals {
  jumpbox_admin_username = "margince"

  release_runner = {
    label = "margince-runner"
    # github.com/actions/runner/releases, v2.337.0, linux-x64: the SHA-256 is
    # the one the release notes publish. The jumpbox is amd64, the
    # architecture Container Apps runs, so the smoke test covers the deployed
    # images. The runner updates itself after registration; bump the version
    # and checksum together.
    version = "2.337.0"
    sha256  = "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"
  }

  jumpbox_cloud_init = templatefile("${path.module}/templates/jumpbox-cloud-init.yaml.tftpl", {
    admin_username = local.jumpbox_admin_username
    acr_name       = azurerm_container_registry.this.name
    runner_version = local.release_runner.version
    runner_arch    = "x64"
    runner_sha256  = local.release_runner.sha256
  })
}

resource "azurerm_subnet" "ops" {
  name                 = "${var.name_prefix}-ops"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(local.vnet_cidr, 8, 6)]
}

# Outbound through the same NAT (apt, GitHub) from the same fixed
# address as the apps.
resource "azurerm_subnet_nat_gateway_association" "ops" {
  subnet_id      = azurerm_subnet.ops.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_network_security_group" "ops" {
  name                = "${var.name_prefix}-ops"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-ops", Component = "network" })

  # Bastion Developer connects to the VM's private IP from Azure's platform
  # address 168.63.129.16. Nothing else may open SSH.
  security_rule {
    name                       = "AllowBastionDeveloperSsh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "168.63.129.16"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenySshFromElsewhere"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "ops" {
  subnet_id                 = azurerm_subnet.ops.id
  network_security_group_id = azurerm_network_security_group.ops.id
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "${var.name_prefix}-jumpbox"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-jumpbox", Component = "operations" })

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.ops.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                            = "${var.name_prefix}-jumpbox"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = "Standard_B2ms" # billed only while running
  admin_username                  = local.jumpbox_admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.jumpbox.id]
  custom_data                     = base64encode(local.jumpbox_cloud_init)
  tags                            = merge(local.common_tags, { Name = "${var.name_prefix}-jumpbox", Component = "operations" })

  # Trusted Launch (the Ubuntu "server" image is Gen2).
  secure_boot_enabled = true
  vtpm_enabled        = true
  # Temp disk and caches encrypted on the host. Needs the subscription
  # feature once (README.md, "Before you start").
  encryption_at_host_enabled = true

  # Azure installs security and critical updates in off-peak hours and
  # checks for missing ones every 24 hours.
  patch_mode            = "AutomaticByPlatform"
  patch_assessment_mode = "AutomaticByPlatform"
  reboot_setting        = "IfRequired"

  # Managed storage account: serial console and screenshots for a VM with no
  # public IP.
  boot_diagnostics {}

  admin_ssh_key {
    username   = local.jumpbox_admin_username
    public_key = var.jumpbox_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    # A new image version or cloud-init change must not replace the jumpbox.
    # To pick up a cloud-init change (a new runner version, say):
    # terraform apply -replace=azurerm_linux_virtual_machine.jumpbox
    ignore_changes = [custom_data, source_image_reference]
  }
}

# The release runner pushes with the VM's system-assigned identity. AcrPush
# (push and pull) on this stack's registry, nothing else: the identity has no
# other role anywhere.
resource "azurerm_role_assignment" "jumpbox_acr_push" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_linux_virtual_machine.jumpbox.identity[0].principal_id
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "jumpbox" {
  virtual_machine_id    = azurerm_linux_virtual_machine.jumpbox.id
  location              = azurerm_resource_group.this.location
  enabled               = true
  daily_recurrence_time = "2000"
  timezone              = "W. Europe Standard Time"

  notification_settings {
    enabled = false
  }
}

# Free tier: browser SSH from the portal to VMs in this VNet, no public IP and
# no subnet of its own.
resource "azurerm_bastion_host" "developer" {
  name                = "${var.name_prefix}-bastion"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Developer"
  virtual_network_id  = azurerm_virtual_network.this.id
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-bastion", Component = "operations" })
}
