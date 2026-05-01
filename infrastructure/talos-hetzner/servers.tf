
resource "hcloud_server" "controlplane" {
  count       = var.node_count
  name        = "${var.cluster_name}-cp-${count.index + 1}"
  image       = var.image_id
  server_type = var.server_type
  location    = var.location

  network {
    network_id = hcloud_network.k8s.id
    ip         = local.controlplane_ips[count.index]
  }

  depends_on = [hcloud_network_subnet.k8s_subnet]
}
