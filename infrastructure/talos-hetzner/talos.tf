############################
# Apply Config to Nodes
############################
resource "talos_machine_configuration_apply" "controlplane" {
  count                       = var.node_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[count.index].machine_configuration
  node                        = hcloud_server.controlplane[count.index].ipv4_address
  depends_on                  = [hcloud_server.controlplane]
}

############################
# Bootstrap (only first node)
############################
resource "talos_machine_bootstrap" "bootstrap" {
  node                 = hcloud_server.controlplane[0].ipv4_address
  client_configuration = talos_machine_secrets.this.client_configuration
  depends_on           = [talos_machine_configuration_apply.controlplane]
}

############################
# Talos Controlplane Config
############################

data "hcloud_ssh_key" "default" {
  fingerprint = var.ssh_key_fingerprint
}

data "talos_machine_configuration" "controlplane" {
  count            = var.node_count
  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${hcloud_load_balancer.api.ipv4}:6443"
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
        allowSchedulingOnControlPlanes = true
      }
    })
  ]
}




############################
# Retrieve Kubeconfig
############################
resource "talos_cluster_kubeconfig" "kubeconfig" {
  node                 = hcloud_server.controlplane[0].ipv4_address
  client_configuration = talos_machine_secrets.this.client_configuration
  depends_on           = [talos_machine_bootstrap.bootstrap]
}