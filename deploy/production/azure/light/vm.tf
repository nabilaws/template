# One Ubuntu 24.04 VM. Terraform creates the machine only; the host adapter
# deploys Margince to it (make host-bootstrap, make deploy). cloud-init only
# mounts the data disk at /var/lib/docker (templates/cloud-init.yaml.tftpl).
#
# A change of custom_data replaces the VM. The data disk and the public IP
# stay; run make host-bootstrap and make deploy again afterwards.

locals {
  # Azure's udev rules name the data disk by LUN: the first path on images
  # with azure-vm-utils (NVMe and SCSI), the second on older images.
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    disk_paths = "/dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0"
    admin_user = local.admin_username
  })
}

resource "azurerm_network_interface" "vm" {
  name                = "${var.name_prefix}-vm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = "${var.name_prefix}-vm"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.vm_size
  admin_username                  = local.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]
  custom_data                     = base64encode(local.cloud_init)
  tags                            = local.common_tags

  # Trusted Launch (the Canonical server image is Gen2).
  secure_boot_enabled = true
  vtpm_enabled        = true

  # Temp disk and disk caches encrypted on the host; needs the
  # EncryptionAtHost feature on the subscription (README.md).
  encryption_at_host_enabled = true

  # Azure-orchestrated guest patching: critical and security updates outside
  # peak hours, reboot only when an update needs one. The containers restart
  # after a reboot (restart: unless-stopped).
  patch_mode            = "AutomaticByPlatform"
  patch_assessment_mode = "AutomaticByPlatform"
  reboot_setting        = "IfRequired"

  admin_ssh_key {
    username   = local.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = local.os_disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = var.architecture == "arm64" ? "server-arm64" : "server"
    version   = "latest"
  }

  # Managed boot diagnostics: serial console, boot log (the SSH host key
  # fingerprints, see the ssh_known_hosts_hint output).
  boot_diagnostics {}
}

resource "azurerm_managed_disk" "data" {
  name                 = "${var.name_prefix}-data"
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
  storage_account_type = local.data_disk_type
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_gb
  tags                 = local.common_tags

  lifecycle {
    # Holds /var/lib/docker: the database, Redis, the files and the
    # certificates. Remove this line on purpose to allow a replacement.
    prevent_destroy = true
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                = 0
  caching            = "None"
}
