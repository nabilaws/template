# Offline plan checks with mocked providers: no Azure access needed.
#   terraform init -backend=false && terraform test
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }
}
mock_provider "random" {}
mock_provider "time" {}

variables {
  release_version          = "v0.3.0"
  public_base_url          = "https://crm.example.com"
  admin_bootstrap_password = "change-me-before-first-boot"
  license_token            = "test-licence"
  jumpbox_ssh_public_key   = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/vUmkEV7lfFP7t36rOoMbvwoNzx4r0gfQKltPmyKTIC6WILJaitH79JH2yJXHb8ePibRalweus+EV/EPKn0oUrOzjVsjVzMef9Rz5CoAovRnDe6z2+y84XnjlIeN5b58NkeBaliOlFv36enIfMluv/sOMHTjfBwbCooF+ChwYnz9p20V5y0DFe/axStpcKcmHW7RfRuijO+vxC+te9mhCbLdN1sJm6qC9pSeADHSDH/swyDK6l1526/+NJqHfryRbhuQ8uPDL7pT14Z02AFnvIMvYhvSomi4Kag9aFQLFmm2Jd1Yz6lERFj4i6+51WvD/ZPmC7OER6N09qlUdXo3qx8Amf472GAQl9VhVHtolycBNtKehQomHLNuBffSIiarnOH5hYwLQEBD3ixah4xbXlmDAb9p+Ub31ppEv9ZLA2YebcRPzUfy/bvBLxysWAJTSwrnTvP0/bJW4Egqa37prx8MQRQkB/yRiET3I3DHFlLDsSnKQnEYSEBmvvLvxE6s= test"
}

run "first_apply_without_apps" {
  command = plan
  assert {
    condition     = azurerm_key_vault.this.public_network_access_enabled && azurerm_key_vault.this.network_acls[0].default_action == "Deny" && azurerm_storage_account.this.public_network_access_enabled && azurerm_storage_account.this.network_rules[0].default_action == "Deny"
    error_message = "Key Vault and Storage keep the public endpoint behind a default-deny firewall, so trusted-service CMK access keeps working."
  }
  assert {
    condition     = anytrue([for r in azurerm_network_security_group.postgres.security_rule : r.name == "AllowPostgresSubnetInternal"])
    error_message = "The Postgres NSG admits traffic inside its own subnet for HA replication."
  }
  assert {
    condition     = length(azurerm_container_app.api) == 0 && length(azurerm_container_app.worker) == 0
    error_message = "deploy_apps defaults to false: no apps on the first apply."
  }
  assert {
    condition     = length(azurerm_private_endpoint.storage) == 2
    error_message = "Storage needs one private endpoint per sub-resource."
  }
  assert {
    condition     = startswith(azurerm_postgresql_flexible_server.this.sku_name, "B_") && contains(keys(azurerm_monitor_metric_alert.this), "postgres-cpu-credits-low")
    error_message = "The Burstable default gets a CPU-credit alert."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.auto_grow_enabled && azurerm_postgresql_flexible_server.this.authentication[0].active_directory_auth_enabled
    error_message = "Postgres has auto-grow and Entra authentication on."
  }
  assert {
    condition     = length(azurerm_management_lock.this) == 5
    error_message = "Postgres, storage, Key Vault, ACR and the Recovery Services vault are locked."
  }
  assert {
    condition = (
      azurerm_container_app.redis.ingress[0].transport == "tcp" &&
      !azurerm_container_app.redis.ingress[0].external_enabled &&
      endswith(azurerm_container_app.redis.template[0].container[0].image, "@sha256:6461ca4ac0c5c9d81d53685c3bf76aa81f464a9de6cf3a97b80a1da8d1bb1de4") &&
      azurerm_container_app.redis.template[0].max_replicas == 1
    )
    error_message = "Redis runs as one internal TCP container app on the pinned 7.2 image."
  }
  assert {
    condition     = length([for r in keys(azurerm_monitor_metric_alert.this) : r if startswith(r, "redis-")]) == 1 && contains([for e in local.common_env : e.value if e.name == "MARGINCE_REDIS"], "margince-redis:6379")
    error_message = "The apps point at the redis app, which has a restart alert."
  }
  assert {
    condition     = azurerm_network_watcher_flow_log.vnet.retention_policy[0].days == 90 && azurerm_network_watcher_flow_log.vnet.traffic_analytics[0].enabled
    error_message = "VNet flow logs are on with 90-day retention and traffic analytics."
  }
  assert {
    condition = (
      azurerm_linux_virtual_machine.jumpbox.encryption_at_host_enabled &&
      azurerm_linux_virtual_machine.jumpbox.disable_password_authentication &&
      azurerm_linux_virtual_machine.jumpbox.secure_boot_enabled &&
      azurerm_bastion_host.developer.sku == "Developer"
    )
    error_message = "The jumpbox has encryption at host, key-only SSH, Trusted Launch, and is reached through Bastion Developer."
  }
  assert {
    condition = (
      !azurerm_container_registry.this.public_network_access_enabled &&
      one(azurerm_container_registry.this.network_rule_set).default_action == "Deny" &&
      length(azurerm_storage_account.this.customer_managed_key) == 1 &&
      length(azurerm_postgresql_flexible_server.this.customer_managed_key) == 1
    )
    error_message = "The registry has no public endpoint without operator_ip_allowlist; storage and Postgres use the customer-managed key."
  }
}

run "full_apply_with_apps_and_gateway" {
  command = plan
  variables {
    deploy_apps = true
  }
  # The api app's FQDN and the environment's default domain are known only
  # after apply; pin them so the gateway backend and DNS zone can be checked.
  override_resource {
    target          = azurerm_container_app_environment.this
    override_during = plan
    values = {
      id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/margince/providers/Microsoft.App/managedEnvironments/margince-env"
      default_domain    = "example-1234.westeurope.azurecontainerapps.io"
      static_ip_address = "10.20.2.10"
    }
  }
  override_resource {
    target          = azurerm_key_vault.this
    override_during = plan
    values = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/margince/providers/Microsoft.KeyVault/vaults/margince-abcde-kv"
      vault_uri = "https://margince-abcde-kv.vault.azure.net/"
    }
  }
  override_resource {
    target          = azurerm_web_application_firewall_policy.this
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/margince/providers/Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies/margince-waf"
    }
  }
  override_resource {
    target          = azurerm_container_registry.this
    override_during = plan
    values = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/margince/providers/Microsoft.ContainerRegistry/registries/marginceabcdeacr"
      login_server = "marginceabcdeacr.azurecr.io"
    }
  }
  override_resource {
    target          = azurerm_container_app.api
    override_during = plan
    values = {
      id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/margince/providers/Microsoft.App/containerApps/margince-api"
      ingress = { fqdn = "margince-api.example-1234.westeurope.azurecontainerapps.io" }
    }
  }
  assert {
    condition     = length(azurerm_container_app.api) == 1 && length(azurerm_application_gateway.this) == 1
    error_message = "Apps and the Application Gateway are created when deploy_apps is true."
  }
  assert {
    condition = (
      one(azurerm_application_gateway.this[0].sku).name == "WAF_v2" &&
      endswith(azurerm_application_gateway.this[0].firewall_policy_id, "/margince-waf") &&
      toset(azurerm_application_gateway.this[0].zones) == toset(["1", "2"]) &&
      one(azurerm_application_gateway.this[0].autoscale_configuration).min_capacity == 1
    )
    error_message = "The gateway is WAF_v2 with the stack's WAF policy, autoscaling, in the stack's zones."
  }
  assert {
    condition = (
      one(azurerm_application_gateway.this[0].backend_address_pool).fqdns == toset(["margince-api.example-1234.westeurope.azurecontainerapps.io"]) &&
      one(azurerm_application_gateway.this[0].backend_http_settings).protocol == "Https" &&
      one(azurerm_application_gateway.this[0].backend_http_settings).pick_host_name_from_backend_address &&
      one(azurerm_application_gateway.this[0].probe).path == "/healthz"
    )
    error_message = "The gateway forwards over HTTPS to the api app's FQDN with its host name and probes /healthz."
  }
  assert {
    condition = (
      one([for l in azurerm_application_gateway.this[0].http_listener : l if l.name == "https"]).ssl_certificate_name == "public" &&
      one(azurerm_application_gateway.this[0].ssl_certificate).key_vault_secret_id == "https://margince-abcde-kv.vault.azure.net/secrets/public-tls" &&
      one(azurerm_application_gateway.this[0].redirect_configuration).target_listener_name == "https"
    )
    error_message = "HTTPS uses the Key Vault certificate, and HTTP redirects to HTTPS."
  }
  assert {
    condition     = azurerm_role_assignment.appgw_certificate[0].role_definition_name == "Key Vault Secrets User" && endswith(azurerm_role_assignment.appgw_certificate[0].scope, "/secrets/public-tls")
    error_message = "The gateway identity may read the one certificate secret only."
  }
  assert {
    condition = (
      azurerm_container_app_environment.this.internal_load_balancer_enabled &&
      azurerm_private_dns_zone.environment.name == "example-1234.westeurope.azurecontainerapps.io" &&
      azurerm_private_dns_a_record.environment["*"].records == toset(["10.20.2.10"])
    )
    error_message = "The environment is internal, and its default domain resolves to its private IP inside the VNet."
  }
  assert {
    condition = (
      !anytrue([for r in azurerm_network_security_group.containerapps.security_rule : r.access == "Allow" && r.source_address_prefix == "Internet"]) &&
      anytrue([for r in azurerm_network_security_group.containerapps.security_rule : r.name == "AllowHttpsFromAppGateway" && r.source_address_prefix == azurerm_subnet.appgw.address_prefixes[0]])
    )
    error_message = "The api is not exposed to the internet: only the gateway subnet reaches the environment."
  }
  assert {
    condition     = strcontains(local.edge_nginx_conf, "proxy_set_header Host crm.example.com;") && strcontains(local.edge_nginx_conf, "set_real_ip_from ${azurerm_subnet.appgw.address_prefixes[0]};") && !strcontains(local.edge_nginx_conf, "return 301")
    error_message = "The edge sends the public host to cmd/api and trusts the gateway's X-Forwarded-For."
  }
  assert {
    condition = (
      strcontains(local.edge_nginx_conf, "limit_req_zone $binary_remote_addr zone=auth:10m rate=30r/m;") &&
      length(regexall("limit_req zone=auth burst=30 nodelay;", local.edge_nginx_conf)) == 4 &&
      strcontains(local.edge_nginx_conf, "location = /v1/auth/login {\n            limit_req zone=auth") &&
      !strcontains(local.edge_nginx_conf, "break_glass") &&
      !strcontains(local.edge_nginx_conf, "block_password_login") &&
      !strcontains(local.edge_nginx_conf, "return 403")
    )
    error_message = "The edge rate-limits the credential endpoints and lets password login through from any address (no break-glass block)."
  }
  assert {
    condition     = !contains(keys(local.api_secrets), "entra-client-secret") && length([for e in concat(local.api_env, local.worker_env) : e if contains(["MARGINCE_GRAPH_CLIENT_ID", "MARGINCE_GRAPH_CLIENT_SECRET", "MARGINCE_GRAPH_TENANT", "MARGINCE_MICROSOFT_SIGNIN_TENANT", "MARGINCE_SECRET_GENERATION"], e.name)]) == 0
    error_message = "The apps get no Entra app settings; sign-in apps are configured in Margince under Settings."
  }
  assert {
    condition = alltrue([
      for role in ["api", "worker", "web"] :
      local.images[role] == "marginceabcdeacr.azurecr.io/margince-default/${role}:v0.3.0"
    ]) && azurerm_container_app.api[0].template[0].container[0].image == local.images.api && azurerm_container_app.api[0].template[0].container[1].image == local.images.web && azurerm_container_app.worker[0].template[0].container[0].image == local.images.worker
    error_message = "Images are <registry>/<instance_name>/<role>:<release_version>."
  }
  assert {
    condition     = contains(keys(azurerm_monitor_metric_alert.this), "waf-blocked-requests") && contains(keys(local.diagnostic_settings), "appgw")
    error_message = "The gateway sends its WAF and access logs to Log Analytics and has a blocked-requests alert."
  }
  assert {
    condition     = !contains(keys(local.worker_secrets), "owner-dsn") && contains(keys(local.api_secrets), "owner-dsn")
    error_message = "Only the api (migrations) gets the owner DSN."
  }
  assert {
    condition     = azurerm_container_app.api[0].template[0].http_scale_rule[0].concurrent_requests == "50" && azurerm_container_app.api[0].template[0].min_replicas == 3
    error_message = "The api app scales on HTTP concurrency and keeps three replicas."
  }
  assert {
    condition     = contains(keys(azurerm_monitor_metric_alert.this), "api-5xx")
    error_message = "The api app gets a 5xx alert once deployed."
  }
}

run "no_identity_resources" {
  command = plan
  assert {
    condition     = alltrue([for f in fileset(path.module, "*.tf") : !can(regex("azuread_|hashicorp/azuread|provider \"azuread\"", file("${path.module}/${f}")))])
    error_message = "The stack creates no Entra resources and declares no azuread provider."
  }
  assert {
    condition     = !strcontains(file("${path.module}/templates/edge-nginx.conf.tftpl"), "break_glass")
    error_message = "The edge template has no break-glass block."
  }
  assert {
    condition = output.sso_redirect_uris == {
      microsoft = ["https://crm.example.com/v1/auth/oidc/microsoft/callback", "https://crm.example.com/v1/connectors/graph/callback", "https://crm.example.com/v1/connectors/graphcal/callback"]
      google    = ["https://crm.example.com/v1/auth/oidc/google/callback", "https://crm.example.com/v1/connectors/gmail/callback"]
    }
    error_message = "sso_redirect_uris lists the Microsoft and Google callbacks under public_base_url."
  }
}

run "general_purpose_with_ha_and_no_locks" {
  command = plan
  variables {
    db_sku_name           = "GP_Standard_D2ds_v5"
    db_zone_redundant_ha  = true
    enable_resource_locks = false
  }
  assert {
    condition     = length(azurerm_management_lock.this) == 0 && !contains(keys(azurerm_monitor_metric_alert.this), "postgres-cpu-credits-low")
    error_message = "Locks can be turned off, and the CPU-credit alert is Burstable-only."
  }
}

run "ha_on_burstable_is_refused" {
  command = plan
  variables {
    db_zone_redundant_ha = true
  }
  expect_failures = [azurerm_postgresql_flexible_server.this]
}

run "missing_licence_is_refused" {
  command = plan
  variables {
    license_token = ""
  }
  expect_failures = [var.license_token]
}

run "waf_defaults_to_detection" {
  command = plan
  assert {
    condition     = azurerm_web_application_firewall_policy.this.policy_settings[0].mode == "Detection" && alltrue([for r in azurerm_web_application_firewall_policy.this.custom_rules : r.action == "Log"])
    error_message = "waf_mode defaults to count: Detection mode, custom rules only log."
  }
  assert {
    condition = (
      toset([for m in azurerm_web_application_firewall_policy.this.managed_rules[0].managed_rule_set : "${m.type}/${m.version}"]) == toset(["Microsoft_DefaultRuleSet/2.1", "Microsoft_BotManagerRuleSet/1.1"]) &&
      azurerm_web_application_firewall_policy.this.policy_settings[0].request_body_check &&
      azurerm_web_application_firewall_policy.this.policy_settings[0].file_upload_limit_in_mb == 50
    )
    error_message = "DRS 2.1 and Bot Manager run, the body is inspected, and uploads are bounded at nginx's 50 MB."
  }
  assert {
    condition = alltrue([
      for r in azurerm_web_application_firewall_policy.this.custom_rules : (
        r.rule_type == "RateLimitRule" ? r.rate_limit_duration == "FiveMins" && r.group_rate_limit_by == "ClientAddr" : true
      )
    ]) && length(azurerm_web_application_firewall_policy.this.custom_rules) == 2
    error_message = "Exactly two custom rules: per-IP rate limits over five minutes."
  }
  assert {
    condition = alltrue([
      for c in one([for r in azurerm_web_application_firewall_policy.this.custom_rules : r if r.name == "RateLimitPerIP"]).match_conditions :
      c.negation_condition && alltrue([for v in c.match_values : startswith(v, "/webhooks/")]) && c.operator == "BeginsWith"
    ])
    error_message = "The global rate limit excludes the /webhooks/ paths."
  }
  assert {
    condition     = toset(one(one([for r in azurerm_web_application_firewall_policy.this.custom_rules : r if r.name == "RateLimitAuthPaths"]).match_conditions).match_values) == toset(["/v1/auth/login", "/v1/auth/forgot-password", "/v1/auth/reset-password", "/oauth/token", "/oauth/register"]) && one([for r in azurerm_web_application_firewall_policy.this.custom_rules : r if r.name == "RateLimitAuthPaths"]).rate_limit_threshold == 100
    error_message = "The auth rate limit covers the same paths as the AWS stack."
  }
  assert {
    condition     = length(azurerm_application_gateway.this) == 0 && azurerm_public_ip.appgw.sku == "Standard"
    error_message = "The gateway waits for deploy_apps; its public IP exists from the first apply."
  }
}

run "waf_block_mode" {
  command = plan
  variables {
    waf_mode = "block"
  }
  assert {
    condition     = azurerm_web_application_firewall_policy.this.policy_settings[0].mode == "Prevention" && alltrue([for r in azurerm_web_application_firewall_policy.this.custom_rules : r.action == "Block"])
    error_message = "waf_mode = block sets Prevention mode and blocking custom rules."
  }
}

run "release_version_must_be_a_release" {
  command = plan
  variables {
    release_version = "latest"
  }
  expect_failures = [var.release_version]
}

run "release_runner_on_the_jumpbox" {
  command = plan
  override_resource {
    target          = random_string.suffix
    override_during = plan
    values          = { result = "abcde" }
  }
  override_resource {
    target          = azurerm_container_registry.this
    override_during = plan
    values = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/margince/providers/Microsoft.ContainerRegistry/registries/marginceabcdeacr"
      login_server = "marginceabcdeacr.azurecr.io"
    }
  }
  assert {
    condition = (
      azurerm_linux_virtual_machine.jumpbox.size == "Standard_B2ms" &&
      azurerm_linux_virtual_machine.jumpbox.identity[0].type == "SystemAssigned" &&
      alltrue([for c in azurerm_network_interface.jumpbox.ip_configuration : c.public_ip_address_id == null]) &&
      !anytrue([for r in azurerm_network_security_group.ops.security_rule : r.direction == "Inbound" && r.access == "Allow" && r.source_address_prefix != "168.63.129.16"])
    )
    error_message = "The release runner is the jumpbox: 8 GiB, managed identity, no public IP, no inbound beyond Bastion Developer SSH."
  }
  assert {
    condition = (
      azurerm_role_assignment.jumpbox_acr_push.role_definition_name == "AcrPush" &&
      azurerm_role_assignment.jumpbox_acr_push.scope == azurerm_container_registry.this.id &&
      !azurerm_container_registry.this.admin_enabled &&
      !azurerm_container_registry.this.public_network_access_enabled
    )
    error_message = "The jumpbox identity gets AcrPush on this stack's registry only; the registry stays private with no admin user."
  }
  assert {
    condition = (
      strcontains(local.jumpbox_cloud_init, "actions-runner-linux-x64-${local.release_runner.version}.tar.gz") &&
      strcontains(local.jumpbox_cloud_init, "${local.release_runner.sha256}  /tmp/actions-runner.tar.gz\" | sha256sum -c -") &&
      can(regex("^[0-9a-f]{64}$", local.release_runner.sha256)) &&
      strcontains(local.jumpbox_cloud_init, "az login --identity --allow-no-subscriptions") &&
      strcontains(local.jumpbox_cloud_init, "az acr login --name marginceabcdeacr") &&
      strcontains(local.jumpbox_cloud_init, "OnUnitActiveSec=60min") &&
      strcontains(local.jumpbox_cloud_init, "User=runner") &&
      strcontains(local.jumpbox_cloud_init, "docker-buildx-plugin") &&
      !strcontains(local.jumpbox_cloud_init, "config.sh")
    )
    error_message = "cloud-init installs the pinned, checksummed runner (unregistered) and an hourly managed-identity registry login."
  }
  assert {
    condition     = output.release_runner_label == "margince-runner"
    error_message = "The runner label matches the RELEASE_RUNNER value in the README."
  }
}

run "arm64_refused" {
  command = plan
  variables {
    architecture = "arm64"
  }
  expect_failures = [var.architecture]
}
