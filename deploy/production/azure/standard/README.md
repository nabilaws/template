# Margince on Azure

Terraform root module that deploys Margince into your own Azure subscription,
sized for a small team (about 40 users). The instance's release builds and publishes
the images; this module runs the images of one instance release
on Azure Container Apps.

## What it creates

| Area | Resources |
|---|---|
| Edge | Application Gateway WAF v2 with a static public IP: the only public entry. TLS with the Key Vault certificate `public-tls`, HTTP to HTTPS redirect, WAF policy (Microsoft Default Rule Set 2.1, Bot Manager 1.1, two per-IP rate limits), `waf_mode` count or block. See "WAF rollout". |
| Compute | Container Apps environment (internal: private IP only, workload profiles, Consumption profile, zone-redundant). **api** app (3 to 6 replicas, CPU and HTTP scale rules): `cmd/api` plus an **edge** nginx container that serves the SPA; its ingress is reachable only from the gateway. **worker** app: no ingress. **redis** app: Redis 7.2, one replica, internal TCP only. |
| Data | Postgres Flexible Server 16 (VNet-integrated, customer-managed key, auto-grow, Entra and password auth; single-zone Burstable B2ms (8 GiB) by default, zone-redundant HA with `db_sku_name` General Purpose and `db_zone_redundant_ha = true`), Storage account with `config`, `attachments` and `redis` file shares, Key Vault premium (RBAC, purge protection) |
| Network | VNet with apps, Postgres, private-endpoint and ops subnets; deny-by-default NSGs; private endpoints and DNS zones for Key Vault, blob and file; NAT Gateway with one fixed egress IP; VNet flow logs with traffic analytics |
| Identity | Managed identities for api, worker, Dataverse and customer-managed keys |
| Delivery | The api, web and worker images of one instance release, pulled by release tag over the NAT gateway; a one-off setup job (`setup.tf`) for `margince.yaml` and the database bootstrap; jumpbox VM with Azure Bastion Developer for operator tasks |
| Protection | Share soft delete and daily Azure Backup (attachments, redis), delete locks on the stateful resources, diagnostic settings on every resource that has them, metric alerts, Log Analytics (90 days) |

```mermaid
flowchart LR
  users(["Users, any network"]) -->|"HTTPS"| agw["Application Gateway WAF v2<br/>public IP, TLS, WAF policy"]
  subgraph vnet["VNet"]
    subgraph env["Container Apps environment (internal)"]
      subgraph apiapp["api app"]
        edge["edge nginx<br/>SPA, rate limits"] --> api["cmd/api"]
      end
      worker["worker"]
      redis[("Redis 7.2")]
    end
    pg[("Postgres Flexible 16<br/>CMK")]
    files[("Storage: config, attachments, redis<br/>CMK, private endpoint")]
    kv["Key Vault<br/>secrets, CMK, certificate"]
    jump["Jumpbox<br/>Bastion Developer, operator tasks"]
    setup["Setup job<br/>one-off, per apply"]
    nat["NAT Gateway<br/>fixed egress IP"]
  end
  agw -->|"HTTPS"| edge
  api --> pg
  api --> redis
  worker --> pg
  worker --> redis
  api -->|"SMB"| files
  api -.->|"secrets"| kv
  worker --> nat
  api --> nat
  nat --> ext(["Graph, LLM, SMTP"])
  source["Instance release.yml<br/>build, smoke-test, push"] --> reg(["Instance release images<br/>api, web, worker at one release"])
  env -.->|"pull over NAT"| reg
  setup -.->|"bootstrap"| pg
  setup -.->|"margince.yaml"| files
  logs["Log Analytics, alerts"] -.-> mail(["alert_email"])
```


Staff sign in as described in "Sign-in". Guests reach only their scoped links (booking, Deal Room,
unsubscribe), which the app protects with tokens.

## Before you start

- **Azure**: Owner, or Contributor plus User Access Administrator, on the
  target subscription. `az login --tenant <tenant>`,
  `az account set -s <subscription>`, then
  `export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)`: the
  azurerm 4.x provider requires a subscription ID and this stack does not
  hardcode one.
- **Subscription features, once**: encryption at host for the jumpbox:
  `az feature register --namespace Microsoft.Compute --name EncryptionAtHost`,
  wait until `az feature show` reports `Registered`, then
  `az provider register --namespace Microsoft.Compute`. VNet flow logs need
  Network Watcher in the region (`NetworkWatcher_<region>` in
  `NetworkWatcherRG`), which Azure creates with the first VNet unless the
  subscription opted out.
- **Tools**: Terraform 1.10 or newer, Azure CLI with the `containerapp`
  extension (`az extension add --name containerapp`; the apply runs the one-off
  setup job with it), `jq`.
- **Margince**: a licence token and one release of this instance, pushed to a
  public registry
  ([release.md](../../../../docs/release.md)). The bootstrap SQL comes from
  the pinned `core/` submodule.
- **TLS certificate** for the host in `public_base_url`, as a PFX file, to
  import into Key Vault in Section 4.
- **Remote state**: state holds every generated password and key. Create a state storage account first (`backend.hcl.example`)
  and never keep state on a laptop.

## 1. Write `margince.yaml`

The stack reads the instance's `deploy/production/config/margince.yaml`, the
same file the light stacks use. Copy core's example once and edit it:

```bash
cp core/config/margince.example.yaml deploy/production/config/margince.yaml
# edit: workspace, bootstrap_admin (password_file: secrets/admin-password),
# seeds.ai_routing for your LLM provider
```

Commit it with the instance. `margince_config_path` points elsewhere if you
keep it in another place.

## 2. Select the instance release

The instance's release builds the api, web and worker images with core's
`Dockerfile` and `docker-bake.hcl`, from core at the core pin plus the
instance's units. With the repository variable `REGISTRY` set, it pushes
them to `<REGISTRY>/<name>/<role>:<v>`
([release.md](../../../../docs/release.md)). The instance commit and the core
version identify the complete images. This Azure module
neither rebuilds nor republishes them. Do not use the images that core
publishes: they contain core only, without the instance's units.

The stack runs `<image_repo>/<role>:<release_version>` for all three roles,
pulled by tag: the references `make deploy` exports
([deploy.md](../../../../docs/deploy.md)). Core's release guard refuses a set
whose roles come from different releases (core/docs/deployment.md, "Deploy all three roles at ONE release").

The registry must be public: the stack pulls anonymously and holds no
registry credentials. Use GitHub Container Registry (`REGISTRY=ghcr.io/<org>`):
anonymous pulls carry no per-address limit, and the images keep the
template's `<name>/<role>` names. Docker Hub is the public mirror only
(`MIRROR_REGISTRY`, [release.md](../../../../docs/release.md#5-repository-settings)):
it allows one path level under a namespace, and it limits anonymous pulls per
IP address, which every task behind the NAT gateway shares.

1. Select one instance release whose pushed platforms (`PLATFORMS`) include
   `linux/amd64`, the default. Container Apps requires that image.
2. Set `image_repo` (`<REGISTRY>/<instance name>`, the `REGISTRY` the release
   used) and `release_version` (the release, for example `v1.4.0`) in
   `terraform.tfvars`. They serve the first applies (Sections 3 and 4); every
   later release ships with `make deploy` (Section 6).

## 3. Provision (apps off)

```bash
cd deploy/production/azure/standard
cp backend.hcl.example backend.hcl            # fill in
cp terraform.tfvars.example terraform.tfvars  # fill in
terraform init -backend-config=backend.hcl
terraform apply                               # deploy_apps = false
```

`terraform.tfvars` needs `image_repo`, `release_version`, `public_base_url`,
`admin_bootstrap_password`, `license_token` and `jumpbox_ssh_public_key`
(`ssh-keygen -t ed25519`; RSA also works), and usually
`operator_ip_allowlist` (your public IP, from
`curl -s https://api.ipify.org`). See "Variables".

This creates everything except the Container Apps and the gateway: network,
Key Vault and its secrets, Postgres, the redis app, storage and shares,
private endpoints and the jumpbox. `operator_ip_allowlist` lets Terraform
write Key Vault secrets and file shares from your machine; it is closed in
Section 5.

The same apply then runs the one-off setup job (`setup.tf`) with the Azure CLI
and waits for it (`scripts/run-setup.sh`). Inside the environment it:

- writes `margince.yaml` onto the config share (core's api image), which the
  apps mount read-only;
- runs core's `db-bootstrap.sql` as `pgadmin` over verified TLS through
  `scripts/bootstrap-db.sh`, the same script as the AWS stack's (the template's
  Postgres image). Running the SQL directly with `psql` fails on Flexible
  Server: `pgadmin` is not a superuser, so PostgreSQL refuses `ALTER ROLE ...
  NOSUPERUSER NOBYPASSRLS`, and on Postgres 16 `CREATE DATABASE ... OWNER
  margince_owner` fails with "must be able to SET ROLE". The script replaces
  those statements with checks that only alter a role that actually has the
  attribute, and grants `pgadmin` membership in `margince_owner` for the
  duration of the script. It creates the `margince` database and the
  `margince_owner` and `margince_app` roles. The extensions it needs
  (`vector`, `unaccent`, `pg_trgm`, `btree_gist`) are already allow-listed by
  Terraform. Migrations run later, from the api's entrypoint, with the owner
  role.

The apply fails if the job fails; its executions are listed under the job
`<name_prefix>-setup`. Only the job holds the Postgres admin password. It runs
again on any apply that changes its inputs (a new `margince.yaml`, core's SQL,
a release image); the SQL is idempotent.

## 4. Start the apps and the gateway

```bash
# DNS, in your zone: an A record for the host in public_base_url
#   crm.example.com  A  $(terraform output -raw public_ip_address)

# The gateway serves the Key Vault certificate public-tls. Import it once, from an operator_ip_allowlist address; renewals
# are new versions of the same certificate, which the gateway picks up within
# four hours without an apply.
az keyvault certificate import --vault-name "$(terraform output -raw key_vault_name)" \
  -n public-tls -f crm.example.com.pfx --password '<pfx password>'

terraform apply -var deploy_apps=true        # then set it in terraform.tfvars
```

The first apply with `deploy_apps = true` creates the Container Apps, the
Application Gateway and its WAF diagnostics. The Container Apps environment
is internal: the api app has no public endpoint, and the gateway reaches it
over the VNet through a private DNS zone for the environment's domain.

Check the entry point:

```bash
curl -s https://crm.example.com/readyz                        # 200 when dependencies are healthy
curl -s -o /dev/null -w '%{http_code}\n' https://crm.example.com/metrics                   # 404
curl -s -o /dev/null -w '%{http_code}\n' http://crm.example.com/                          # 301 to HTTPS
```

## 5. First login, then close setup access

1. Sign in with the bootstrap admin and set the permanent password.
2. Invite staff (see "Sign-in").
3. Remove `bootstrap_admin` from `deploy/production/config/margince.yaml`
   (the next apply or `make deploy` writes it to the config share), set
   `include_bootstrap_admin = false`, add the LLM provider key in
   Settings → AI.
4. Set `operator_ip_allowlist = []` and apply. From now on, run Terraform and
   `make deploy` from the jumpbox, or add your IP back for a single apply.
   Open the jumpbox from the Azure portal (VM `<name_prefix>-jumpbox` →
   Connect → Bastion → SSH with your private key), then once:

   ```bash
   az login
   gh auth login                                 # or read-only deploy keys
   git clone --recurse-submodules <instance repository URL> /opt/margince-instance
   cd /opt/margince-instance/deploy/production/azure/standard
   cp backend.hcl.example backend.hcl            # same values as on your machine
   terraform init -backend-config=backend.hcl
   ```

## 6. Releases

Ship every release after the first with `make deploy`, as on the light
stacks. The template's `hook` adapter runs this directory's `hooks/`
([deploy.md](../../../../docs/deploy.md)):

| Step | Hook |
|---|---|
| `preflight` | Records the running release, plans `image_repo` and the new `release_version` with `deploy_apps=true`; changes nothing |
| `apply` | Applies exactly that plan; all three roles move in one apply |
| `verify` | Waits until `/readyz` answers 200 and `/v1/auth/capabilities` reports the new release (`VERIFY_TIMEOUT`, default 900 seconds) |
| `rollback` | After a failed `apply` or `verify`: plans and applies the recorded release |

1. In `instance.yaml`, set the environment's adapter to `hook`, for example
   `production: { adapter: hook }`.
2. Copy `hooks/` to `deploy/<env>/hooks/` in the instance, and export
   `TERRAFORM_DIR` as the path of this directory (the default is the
   directory that holds `hooks/`).
3. On the jumpbox or an allowlisted machine where `terraform init` has run here, cut the release and
   deploy it:

   ```sh
   make release VERSION=<v>                   # wait until release.yml has pushed the images
   make deploy ENV=production VERSION=<v>
   ```

## Sign-in

Margince uses its own accounts: users sign in with email and password, and an administrator invites them. Nothing in this stack is needed for that.

Microsoft (Entra ID) or Google sign-in is optional. A Margince administrator turns it on in **Settings → General → Microsoft app** (or **Google app**) with an app the customer's IT registers in its own Entra or Google console; no restart and no apply. Register the redirect URIs from `terraform output sso_redirect_uris`. A Microsoft app saved in Settings signs in only users of the directory it is registered in. To allow only single sign-on after that, set `auth.password.enabled: false` in `margince.yaml` (core `docs/reference/configuration.md`, "Turning the password method off"); the operator's emergency route is core's `margince-migrate reset-password`.

Password login is protected by per-client rate limits on the credential endpoints (the edge nginx and the Application Gateway WAF).

## WAF rollout

`appgw.tf`'s WAF policy, the counterpart of the AWS standard stack's web ACL
with the same rules: a per-IP rate limit of 100 requests per 5 minutes on the
credential endpoints (`/v1/auth/login`, `/v1/auth/forgot-password`,
`/v1/auth/reset-password`, `/oauth/token`, `/oauth/register`), a global
per-IP rate limit of 2000 per 5 minutes that excludes
`/webhooks/gmail|graph|hubspot` (HMAC-verified provider traffic from shared
provider IPs), then the managed rule sets Microsoft Default Rule Set 2.1
(OWASP-based) and Bot Manager 1.1, always on. Request bodies are inspected up to 2000 KB;
file uploads are allowed up to 50 MB.

`waf_mode` defaults to `"count"`: the policy runs in Detection mode and the
custom rules only log. Run like that for about a week of real traffic, then
review what would have been blocked (Log Analytics):

```kusto
AGWFirewallLogs
| where TimeGenerated > ago(7d)
| where Action in ("Matched", "Detected", "Blocked")
| summarize hits = count() by RuleId, Message, RequestUri
| order by hits desc
```

Add an exclusion or a rule override in `appgw.tf` for each false positive
(the commented example there), then set `waf_mode = "block"` (Prevention
mode, custom rules block) and apply. The blocked-requests alert
(`alarms.tf`, above 500 blocked requests per 5 minutes) reports spikes once
blocking. Diagnostics send the firewall and access logs to Log Analytics,
kept 30 days, with authorization and cookie headers, cookies and argument
values scrubbed.

## Variables

Only what you must set or what genuinely sizes the installation is a
variable (`variables.tf`); everything else is a fixed value in the file that
uses it.

| Variable | Default | Purpose |
|---|---|---|
| `public_base_url` | required | `https://<host>` the gateway serves |
| `image_repo` | required | `<REGISTRY>/<instance name>` of the instance release, in a public registry |
| `release_version` | required | The release to run for api, worker and web; `make deploy` sets it |
| `license_token` | required | Licence token |
| `admin_bootstrap_password` | required | First-boot admin password |
| `jumpbox_ssh_public_key` | required | SSH key for the jumpbox |
| `deploy_apps` | `false` | Two-phase apply: `true` once the certificate is imported (Section 4) |
| `operator_ip_allowlist` | `[]` | Setup IPs through the Key Vault and Storage firewalls |
| `key_vault_admin_principal_ids` | `[]` (the applying identity) | Key Vault Administrators |
| `alert_email` | `""` | Alert receiver |
| `include_bootstrap_admin` | `true` | `false` after the first admin login (Section 5) |
| `margince_config_path`, `bootstrap_sql_path` | the instance's `deploy/production/config/margince.yaml`, core's `db-bootstrap.sql` | Inputs of the setup job |
| `azure_region`, `name_prefix` | `westeurope`, `margince` | Placement and names (`name_prefix` is also the resource group) |
| `db_sku_name`, `db_zone_redundant_ha` | `B_Standard_B2ms`, `false` | Postgres size and HA |
| `api_min_replicas`, `api_max_replicas` | `3`, `6` | api scale bounds |
| `waf_mode` | `count` | `count` then `block` |
| `enable_resource_locks` | `true` | `false` and apply before `terraform destroy` |

## Dataverse (optional)

- Power Platform admin center → environment → Settings → Application users →
  New app user, using `terraform output -raw dataverse_identity_client_id`,
  with a security role limited to the tables Margince syncs. Application
  users need no licence.
- Managed Environments: add `terraform output -raw nat_egress_ip` to the
  Dataverse IP firewall. The jumpbox shares this address.
- Margince's Dynamics overlay adapter is not built yet; the identity,
  egress IP and `/webhooks/*` route are ready for it.

## Redis

Core pins Redis 7.2 (`redis:7.2@sha256:6461…` in its `docker-compose.dev.yml`).
Azure Cache for Redis Basic and Standard offer only Redis 6 (and retire on
30 September 2028), so the stack runs that exact image, as a
single-replica container app: internal TCP ingress on 6379, password from Key
Vault, `noeviction` with a `maxmemory` cap, AOF every second on the `redis`
Azure Files share (soft delete and daily backup). AOF on an SMB share is fine
at this scale. For heavier load, or if Margince accepts Redis 7.4, move to
Azure Managed Redis (`azurerm_managed_redis` in azurerm 4.x).

## Cost

Rough list prices in West Europe, per month, before usage-based traffic:

| Item | EUR |
|---|---|
| Application Gateway WAF v2 (fixed charge, autoscale 1 to 10 units) | 250-350 |
| Container Apps: api (3 replicas), worker, redis | 170-260 |
| Postgres B_Standard_B2ms, 64 GiB, backups | 117 |
| NAT Gateway and IP | 35 |
| Private endpoints (3) | 22 |
| Log Analytics, flow logs, traffic analytics | 30-50 |
| Storage (ZRS), Backup, Key Vault | 25-35 |
| Jumpbox, Standard_B2ms (runs on demand, stops at 20:00), Bastion Developer (free) | 10-25 |
| **Total** | **about 660-895** |

Microsoft recommends General Purpose for production Postgres:
`db_sku_name = "GP_Standard_D2ds_v5"` adds about EUR 75, and
`db_zone_redundant_ha = true` on top adds about EUR 140.

## Security notes

- **Public surface**: the Application Gateway only (WAF v2). The api app's
  ingress is private, in the internal environment. `cmd/api` is reached on localhost; the worker, Redis (internal
  TCP ingress), Postgres, Key Vault and storage have no public
  endpoint once `operator_ip_allowlist` is empty.
- **Sign-in**: password login is open from any address (see "Sign-in"); the
  client address comes from the rightmost `X-Forwarded-For` entry, which the
  gateway and Container Apps append, so clients cannot spoof it. The edge
  passes that address to the api in `X-Forwarded-For`, and the api trusts it
  from the edge only (`MARGINCE_TRUSTED_PROXIES=127.0.0.1/32`), so core's own
  per-address limits (login, password reset, single sign-on) key on the
  client. The edge's `limit_req` on the sign-in paths and the gateway's WAF
  rate rules limit per client in front of it.
- **Secrets**: each app identity may read only the Key Vault secrets its
  process uses. The api app's identities are also available to its edge
  container; keep the web image current.
- **Encryption**: customer-managed key for Postgres and storage, always on
  (verify in a test subscription that both reach the firewalled vault).
  Redis data sits on the storage account's `redis` share, under the same key. TLS
  everywhere except the password-protected Redis connection, which never
  leaves the environment.
- **Postgres**: TLS 1.2 minimum, connection throttling after failed logins,
  Entra authentication alongside passwords. Add an Entra administrator in
  the portal (Authentication) if you want one.
- **Logs**: nginx logs paths without query strings and redacts capability
  tokens in public links. Key Vault, blob and file audit logs, NSG events
  and backup jobs go to Log Analytics; VNet flow logs go to
  the storage account for 90 days.
- **Jumpbox**: Trusted Launch (secure boot, vTPM), encryption at host,
  platform-managed OS patching, boot diagnostics.
- **Locks**: `CanNotDelete` locks on Postgres, storage, Key Vault and the
  Recovery Services vault (`enable_resource_locks`). Set it
  to `false` and apply before `terraform destroy`.
- **Image source**: the instance's `release.yml` builds, smoke-tests and
  publishes all three roles, core plus the instance's units. This stack only
  runs them by release tag, pulled anonymously from a public registry; no Container App holds registry credentials.
- **Images**: every Container App runs `<image_repo>/<role>:<release_version>`;
  tasks pull over the NAT gateway at revision start.
- **Storage key**: Azure Files SMB mounts need the account key, which is in
  state and in the environment's storage configuration. Rotate it with the
  secondary key on a schedule.

## Known limitations

- **Attachments on Azure Files.** Margince stores attachments with its
  filesystem store on the `attachments` share until a native Azure Blob
  adapter exists. Upload and read back one attachment after the first
  deploy.
- **nginx config is a copy.** `templates/edge-nginx.conf.tftpl`
  replaces the web image's `frontend/nginx.conf` (core); keep
  their SPA locations in step.
- **Content-Security-Policy is report-only** until the SPA has been checked
  against it.
- **Redis is one container.** It is not zone-redundant. Container Apps starts
  a new revision before stopping the old one, so an in-place change to the
  redis app (image, resources, command) would briefly run two Redis processes
  on the same `/data` and can corrupt its append-only file. The redis app
  therefore ignores changes to its template: a plain `terraform apply` leaves
  it alone. To change its image or sizing (`redis.tf`), replace the app, which stops the old Redis before the new one starts (api
  and worker reconnect once Redis is back):

  ```bash
  terraform apply -replace=azurerm_container_app.redis
  ```
- **Needs app changes**: Entra-only Postgres (no passwords) and Redis with
  Entra auth (Azure Managed Redis) both require support in Margince first.
- **No SMB protocol restrictions** on the file shares: Microsoft does not
  document Container Apps mounts with SMB 3.1.1-only, AES-256-GCM and
  NTLMv2. The shares are reached only through the private endpoint.
- **PgBouncer is off.** Flexible Server's built-in PgBouncer (port 6432) is
  optional; enable it only after checking the app's prepared statements work
  through it in transaction mode.

## Tests

```bash
cd deploy/production/azure/standard
terraform init -backend=false
terraform validate
terraform test          # offline plan checks with mocked providers (tests/)
```
