# Release runner: one EC2 instance in a private subnet that is the
# repository's self-hosted GitHub Actions runner. release.yml builds core's
# images on it, smoke-tests them and pushes them to this stack's ECR
# repositories with the instance role below: no registry password exists.
#
# cloud-init installs Docker and the pinned runner package but does not
# register it (registration needs a one-time GitHub token, README.md
# step 3). No public IP, no inbound rule; operators reach it through SSM
# Session Manager. t3.large (8 GiB) is the smallest size that builds the Go
# and pnpm images comfortably; it is x86_64 and builds linux/arm64 too, by
# cross-compilation and QEMU.

locals {
  release_runner = {
    label = "margince-runner"
    # github.com/actions/runner/releases, v2.337.0: the SHA-256 values are the
    # ones the release notes publish. The runner updates itself after
    # registration; bump the version and both checksums together.
    version = "2.337.0"
    sha256 = {
      amd64 = "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"
      arm64 = "9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393"
    }
  }

  # The ECR registry host, the same value as the `registry` output.
  ecr_registry_host = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

  release_runner_cloud_init = templatefile("${path.module}/templates/release-runner-cloud-init.yaml.tftpl", {
    registry_host  = local.ecr_registry_host
    runner_version = local.release_runner.version
    runner_arch    = var.architecture == "arm64" ? "arm64" : "x64"
    runner_sha256  = local.release_runner.sha256[var.architecture]
  })
}

# Canonical's Ubuntu 24.04 LTS image, resolved at the first apply (the
# instance ignores later image updates; it patches itself with apt).
data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/${var.architecture}/hvm/ebs-gp3/ami-id"
}

resource "aws_security_group" "release_runner" {
  name_prefix = "${var.name_prefix}-runner-"
  description = "Release runner: no ingress; HTTPS and HTTP egress for GitHub, package repositories, SSM and ECR."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-release-runner", Component = "operations" }

  egress {
    description = "HTTPS: GitHub, registries, SSM, ECR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP: Ubuntu package repositories"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

data "aws_iam_policy_document" "release_runner_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "release_runner" {
  name_prefix        = "${var.name_prefix}-runner-"
  description        = "Release runner: SSM Session Manager, and push plus pull on the three ECR repositories of this stack."
  assume_role_policy = data.aws_iam_policy_document.release_runner_assume.json
  tags               = { Name = "${var.name_prefix}-release-runner", Component = "operations" }
}

resource "aws_iam_role_policy_attachment" "release_runner_ssm" {
  role       = aws_iam_role.release_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "release_runner_ecr" {
  # ECR requires Resource="*" for this one action.
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushAndPullOwnImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [
      aws_ecr_repository.api.arn,
      aws_ecr_repository.worker.arn,
      aws_ecr_repository.web.arn,
    ]
  }

  # The repositories are encrypted with the stack CMK (ecs.tf). Only through
  # ECR: this role cannot decrypt the SSM parameters under the same key.
  statement {
    sid       = "UseDataKeyThroughEcr"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.data.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ecr.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "release_runner_ecr" {
  name   = "${var.name_prefix}-release-runner-ecr"
  role   = aws_iam_role.release_runner.id
  policy = data.aws_iam_policy_document.release_runner_ecr.json
}

resource "aws_iam_instance_profile" "release_runner" {
  name_prefix = "${var.name_prefix}-runner-"
  role        = aws_iam_role.release_runner.name
}

resource "aws_instance" "release_runner" {
  ami = data.aws_ssm_parameter.ubuntu_2404.insecure_value
  # The runner has the tasks' architecture, so the smoke test runs the
  # images that get deployed. 2 vCPU, 8 GiB either way.
  instance_type               = var.architecture == "arm64" ? "t4g.large" : "t3.large"
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.release_runner.id]
  iam_instance_profile        = aws_iam_instance_profile.release_runner.name
  associate_public_ip_address = false
  user_data                   = local.release_runner_cloud_init
  tags                        = { Name = "${var.name_prefix}-release-runner", Component = "operations" }

  # IMDSv2 only. Hop limit 1: containers on the runner (builds, the smoke
  # test) cannot reach the instance role's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Encrypted with the account's AWS-managed EBS key: the disk holds build
  # caches, not customer data.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    delete_on_termination = true
  }

  lifecycle {
    # A new image or cloud-init change must not replace the runner. To pick up
    # a cloud-init change (a new runner version, say):
    # terraform apply -replace=aws_instance.release_runner
    ignore_changes = [ami, user_data]
  }

  # Egress and the role's grants exist before cloud-init runs, also when the
  # instance is created with -target (README.md step 1).
  depends_on = [
    aws_route_table_association.private,
    aws_route_table_association.public,
    aws_iam_role_policy_attachment.release_runner_ssm,
    aws_iam_role_policy.release_runner_ecr,
  ]
}
