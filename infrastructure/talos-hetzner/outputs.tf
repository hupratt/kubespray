output "api_endpoint" {
  value = hcloud_load_balancer.api.ipv4
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.kubeconfig.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = talos_machine_secrets.this.client_configuration
  sensitive = true
}

output "cp0_config" {
  value     = data.talos_machine_configuration.controlplane[0].machine_configuration
  sensitive = true
}

output "ssh_key_info" {
  value = {
    name        = data.hcloud_ssh_key.default.name
    fingerprint = data.hcloud_ssh_key.default.fingerprint
  }
}

output "controlplane_ips" {
  value = hcloud_server.controlplane[*].ipv4_address
}

output "load_balancer_ip" {
  value = hcloud_load_balancer.api.ipv4
}