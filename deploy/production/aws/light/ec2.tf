# One Ubuntu 24.04 instance. Terraform creates the machine only; the host
# adapter deploys Margince to it (make host-bootstrap, make deploy). user_data
# only mounts the data volume at /var/lib/docker
# (templates/cloud-init.yaml.tftpl).
#
# A change of user_data replaces the instance. The data volume and the
# Elastic IP stay; run make host-bootstrap and make deploy again afterwards.

locals {

  # The same backup tag on the root and the data volume (backup.tf).
  backup_tag = { Backup = "${var.name_prefix}-daily" }

  # On Nitro instances EBS volumes are NVMe devices named after the volume
  # ID; Xen instances use the device name.
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    disk_paths = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")} /dev/xvdf /dev/sdf"
    admin_user = "ubuntu"
  })
}

# Canonical's current Ubuntu 24.04 LTS server AMI. ignore_changes below keeps
# a newer AMI from replacing the instance.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/${var.architecture}/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "admin" {
  key_name   = "${var.name_prefix}-admin"
  public_key = var.admin_ssh_public_key
}

resource "aws_instance" "this" {
  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = true
  user_data                   = local.cloud_init
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
    tags                  = merge({ Name = "${var.name_prefix}-root" }, local.backup_tag)
  }

  tags = { Name = "${var.name_prefix}-host" }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  type              = "gp3"
  size              = var.data_disk_gb
  encrypted         = true
  tags              = merge({ Name = "${var.name_prefix}-data" }, local.backup_tag)

  lifecycle {
    # Holds /var/lib/docker: the database, Redis, the files and the
    # certificates. Remove this line on purpose to allow a replacement.
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.this.id
  stop_instance_before_detaching = true
}

resource "aws_eip" "this" {
  domain   = "vpc"
  instance = aws_instance.this.id
  tags     = { Name = "${var.name_prefix}-host" }

  depends_on = [aws_internet_gateway.this]
}
