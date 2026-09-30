# Margince on AWS

Terraform for AWS, in two flavours. Both deploy Margince the same way as
the other cloud's flavour of the same name; the overview, the shared versions
and the method are in [`../README.md`](../README.md).

| Flavour | Path | For | Shape | Rough cost per month |
|---|---|---|---|---|
| **Light** | [`light/`](light/README.md) | Proof of concept, small pilots | One Ubuntu 24.04 EC2 instance with Docker Compose (the template's `host` adapter): api, worker, web, Postgres 16 and Redis 7.2 containers, Caddy with automatic HTTPS in front of nginx (routing and credential-endpoint rate limits). Separate EBS volume with daily DLM snapshots, SSM Parameter Store for the operator secrets, basic alarms. | about USD 73 |
| **Standard** | [`standard/`](standard/README.md) | Mid-size production (about 40 users) | ALB with AWS WAF in front of ECS Fargate (api, worker, web), RDS PostgreSQL 16 Multi-AZ, ElastiCache Valkey 7.2, ECR with `make release` images, SSM Parameter Store, one customer-managed KMS key, VPC endpoints, alarms. | see the flavour README |

## Requirements

- Terraform 1.10 or newer and the AWS CLI.
- The instance repository with its `core/` submodule checked out
  (`git submodule update --init`), and a Margince licence.
- Remote Terraform state (`backend.hcl.example` in each flavour): state holds
  generated passwords and keys.
- Light: SSH access from an address in `ssh_allowed_cidrs`, and a DNS record
  for `domain`. Standard: Docker with buildx for a manual image push.

Each flavour's README lists the steps in order.
