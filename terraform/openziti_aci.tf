resource "random_password" "ziti" {
  count   = var.deploy_demo_controller ? 1 : 0
  length  = 20
  special = false
}

# Dedicated small storage account for the controller's persistent identity
# snapshot (PKI + config). Restarts restore it so the controller does not
# re-mint its PKI (ACI Azure Files mounts are key-based).
resource "azurerm_storage_account" "ziti" {
  count                           = var.deploy_demo_controller ? 1 : 0
  name                            = local.ziti_storage_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  tags                            = local.tags
}

resource "azurerm_storage_share" "ziti" {
  count              = var.deploy_demo_controller ? 1 : 0
  name               = "ziti-controller-state"
  storage_account_id = azurerm_storage_account.ziti[0].id
  quota              = 5
}

locals {
  # ACI FQDN is <dns_name_label>.<region>.azurecontainer.io. Built here (not
  # read from the container group) because ZITI_CTRL_ADVERTISED_ADDRESS must be
  # set on the same resource - the bootstrap mints the PKI SANs from it.
  ziti_dns_label  = "ziti-${var.prefix}-${local.suffix}"
  controller_fqdn = "${local.ziti_dns_label}.${var.location}.azurecontainer.io"

  # Wrapper around the image's own bootstrap. The PKI/config/database are
  # generated on container-local disk (ZITI_HOME=/ziti-controller), NOT on the
  # Azure Files mount: ziti's PKI store hard-links the intermediate CA bundle
  # (os.Link in ziti/pki/store/local.go) and CIFS does not support hard links,
  # so bootstrapping directly on the share wedges half-way. Instead the share
  # (at /persist) holds a snapshot of the identity (PKI + config) taken after
  # first bootstrap; restarts restore it so the PKI/SANs are never re-minted.
  # The runtime raft/bbolt database stays local (mmap on CIFS is unsafe) and is
  # re-initialised on restart - the stock entrypoint's clusterInit recreates the
  # admin from ZITI_PWD, which is idempotent.
  #
  # bootstrap.bash is functions-only when sourced; bootstrap() writes DEBUG to
  # fd 3, which the stock entrypoint opens but a bare shell does not - hence the
  # exec 3>&1. The events: append is guarded against a duplicate top-level key,
  # same as the VM cloud-init did. Handler field names (connectionString/queue/
  # bufferSize/format) verified against v2.0.0 controller/events/servicebus_logger.go.
  controller_boot_script = <<-EOT
    set -euo pipefail
    exec 3>&1
    cd /ziti-controller
    if [ -s /persist/config.yml ]; then
      echo "INFO: restoring controller identity (PKI + config) from the Azure Files snapshot"
      cp -a /persist/. /ziti-controller/
    else
      source /bootstrap.bash
      bootstrap config.yml
      if grep -qE '^events:' config.yml; then
        echo "INFO: events: block already present in config.yml - not appending; check the servicebus handler manually"
      else
        cat >> config.yml <<EOF

    events:
      serviceBusLogger:
        subscriptions:
          - type: authentication
          - type: apiSession
          - type: session
          - type: circuit
          - type: entityChange
        handler:
          type: servicebus
          format: json
          connectionString: "$SB_CONNECTION_STRING"
          queue: "$SB_QUEUE"
          bufferSize: 100
    EOF
      fi
      echo "INFO: snapshotting controller identity (PKI + config) to the Azure Files share"
      find /persist -mindepth 1 -delete 2>/dev/null || true
      # -L dereferences: the PKI tree contains hard links (os.Link in ziti's
      # PKI store) that CIFS cannot recreate. config.yml goes last - it is the
      # sentinel the restore branch keys on, so a half-written snapshot is
      # retried rather than restored.
      cp -rL /ziti-controller/pki /persist/pki
      cp /ziti-controller/config.yml /persist/config.yml
    fi
    exec /entrypoint.bash run config.yml
  EOT

  # Sidecar loop: one successful and one failed admin login per minute against
  # the edge management API, so the controller emits real authentication events
  # (success and failure) with no routers or data plane. localhost works because
  # containers in an ACI group share a network namespace; -k because the PKI is
  # self-signed and the SAN is the public FQDN, not localhost.
  event_gen_script = <<-EOT
    AUTH_URL='https://localhost:1280/edge/management/v1/authenticate?method=password'
    echo "waiting for the controller edge API"
    until curl -skf -o /dev/null https://localhost:1280/edge/client/v1/version; do sleep 5; done
    echo "controller is up - generating auth events every 60s"
    while true; do
      curl -sk -o /dev/null -X POST -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"$ZITI_PWD\"}" "$AUTH_URL"
      curl -sk -o /dev/null -X POST -H 'Content-Type: application/json' \
        -d '{"username":"admin","password":"definitely-wrong-password"}' "$AUTH_URL"
      sleep 60
    done
  EOT
}

resource "azurerm_container_group" "ziti" {
  count               = var.deploy_demo_controller ? 1 : 0
  name                = "ci-ziti-${var.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Linux"
  ip_address_type     = "Public"
  dns_name_label      = local.ziti_dns_label
  restart_policy      = "Always"
  tags                = local.tags

  container {
    name   = "controller"
    image  = "openziti/ziti-controller:2.0.0"
    cpu    = 1
    memory = 2

    ports {
      port     = 1280
      protocol = "TCP"
    }

    commands = ["bash", "-c", local.controller_boot_script]

    environment_variables = {
      ZITI_CTRL_ADVERTISED_ADDRESS = local.controller_fqdn
      ZITI_CTRL_ADVERTISED_PORT    = "1280"
      # Cluster vars the compose file normally supplies; the image ENV does not
      # set them and makePki hard-fails on unset ZITI_BOOTSTRAP_CLUSTER (nounset)
      # or empty ZITI_CLUSTER_TRUST_DOMAIN.
      ZITI_BOOTSTRAP_CLUSTER    = "true"
      ZITI_CLUSTER_TRUST_DOMAIN = "ziti"
      ZITI_CLUSTER_NODE_NAME    = "ziti-controller1"
      SB_QUEUE                  = local.queue_name
    }

    # The servicebus sink is SAS-connection-string-only (no managed identity),
    # so the Send-only rule's connection string goes in as a secure env var.
    secure_environment_variables = {
      ZITI_PWD             = random_password.ziti[0].result
      SB_CONNECTION_STRING = azurerm_servicebus_namespace_authorization_rule.ziti_send.primary_connection_string
    }

    # Snapshot target only - the controller cannot run directly on CIFS (no
    # hard links, unsafe mmap). See controller_boot_script above.
    volume {
      name                 = "ziti-state"
      mount_path           = "/persist"
      share_name           = azurerm_storage_share.ziti[0].name
      storage_account_name = azurerm_storage_account.ziti[0].name
      storage_account_key  = azurerm_storage_account.ziti[0].primary_access_key
    }
  }

  container {
    name   = "event-gen"
    image  = "curlimages/curl:8.21.0"
    cpu    = 0.25
    memory = 0.5

    commands = ["/bin/sh", "-c", local.event_gen_script]

    secure_environment_variables = {
      ZITI_PWD = random_password.ziti[0].result
    }
  }
}
