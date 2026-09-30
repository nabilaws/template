# Margince on Azure

Terraform for Azure, in two flavours. Both deploy Margince the same way as
the other cloud's flavour of the same name; the overview, the shared versions
and the method are in [`../README.md`](../README.md).

| Flavour | Path | For | Shape | Rough cost per month |
|---|---|---|---|---|
| **Light** | [`light/`](light/README.md) | Proof of concept, small pilots | One Ubuntu 24.04 VM with Docker Compose (the template's `host` adapter): api, worker, web, Postgres 16 and Redis 7.2 containers, Caddy with automatic HTTPS in front of nginx (routing and credential-endpoint rate limits). Separate managed disk with daily Azure Backup, Key Vault for the operator secrets, basic alerts. | about EUR 65 |
| **Standard** | [`standard/`](standard/README.md) | Mid-size production (about 40 users) | Application Gateway WAF v2 in front of an internal Container Apps environment (api with the nginx edge, worker, Redis 7.2 container), Postgres Flexible Server 16, ACR with `make release` images, Key Vault with a customer-managed key, private endpoints, NAT egress IP, flow logs, locks, alerts and backups. | about EUR 660-895 |

## Requirements

- Terraform 1.10 or newer and the Azure CLI.
- The instance repository with its `core/` submodule checked out
  (`git submodule update --init`), and a Margince licence.
- Remote Terraform state (`backend.hcl.example` in each flavour): state holds
  generated passwords and keys.
- Light: SSH access from an address in `ssh_allowed_cidrs`, and a DNS record
  for `domain`. Standard: Docker with buildx for a manual image push.

Each flavour's README lists the steps in order.
