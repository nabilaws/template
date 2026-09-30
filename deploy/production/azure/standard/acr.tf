# Premium SKU is this stack's one deliberate cost increase over the cheapest
# option — every other service here defaults to the cheapest SKU that still
# hits the managed-service/security bar (variables.tf's own comments explain
# each one). ACR is the exception because Premium is the ONLY tier that
# supports a private endpoint (privateendpoints.tf). Basic/Standard ACR would
# make this the one public-endpoint exception in a stack that
# private-networks everything else.
resource "azurerm_container_registry" "this" {
  name                = "${local.flat_prefix}${local.suffix}acr"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Premium"
  admin_enabled       = false

  # Public endpoint only while operator_ip_allowlist is set (setup from an
  # allowlisted machine). Otherwise the registry is reachable only through
  # its private endpoint, which Container Apps pull through and the release
  # runner on the jumpbox pushes through (jumpbox.tf). Network rules do not
  # apply to private endpoint traffic.
  public_network_access_enabled = length(var.operator_ip_allowlist) > 0
  network_rule_set = [{
    default_action = "Deny"
    ip_rule = [for ip in var.operator_ip_allowlist : {
      action   = "Allow"
      ip_range = "${ip}/32"
    }]
  }]
  # Routes the registry's own underlying blob-layer traffic (image layers,
  # not just the control-plane API) through the private endpoint below too —
  # Premium-only, and specifically documented as needed once a registry sits
  # behind Private Link, or pulls fall back to ACR's regional public data
  # endpoint for the layer bytes even though the control-plane call went
  # private.
  data_endpoint_enabled = true

  # Microsoft-managed keys, not the stack's customer-managed key: the
  # registry holds images, not customer data, and ACR documents
  # firewalled-vault key access for a system-assigned identity only.

  # Untagged manifests are deleted after 14 days (Premium-only). Released tags are kept:
  #   - Immutable tags: ACR has no control-plane setting for them. After each
  #     release the operator or the CI job locks the three tags with
  #     `az acr repository update --write-enabled false` (README.md,
  #     "Releases"), the ACR counterpart of the ECR repositories'
  #     image_tag_mutability = IMMUTABLE on AWS. A locked tag refuses a
  #     re-push and a delete.
  #   - No rule keeps only the N most recent tagged images (ECR's lifecycle
  #     policy on AWS), so the number of released images kept for rollback
  #     is bounded by hand.
  retention_policy_in_days = 14

  # Not enabled: quarantine_policy_enabled is superseded by Microsoft Defender
  # for Cloud's container image scanning, a subscription-level Defender plan
  # setting rather than a property of this resource, so out of scope here.

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-acr", Component = "container-registry" })
}
