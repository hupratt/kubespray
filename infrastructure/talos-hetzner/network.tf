############################
# Networking
############################
resource "hcloud_network" "k8s" {
  name     = "${var.cluster_name}-net"
  ip_range = "10.2.0.0/16"
}

resource "hcloud_network_subnet" "k8s_subnet" {
  network_id   = hcloud_network.k8s.id
  type         = "cloud"
  network_zone = var.region
  ip_range     = "10.2.0.0/24"
}

############################
# Firewall
############################
resource "hcloud_firewall" "k8s" {
  name = "${var.cluster_name}-fw"

  # Allow 6443 only from the load balancer's private network range
  # Blocks all direct public access to the apiserver
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = var.admin_ip
  }

  # Allow Talos apid (required for talosctl)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "50000"
    source_ips = var.admin_ip
  }

  # Allow internal cluster traffic
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "any"
    source_ips = ["10.2.0.0/24"]
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "any"
    source_ips = ["10.2.0.0/24"]
  }

  # ICMP (ping)
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_firewall_attachment" "k8s" {
  firewall_id = hcloud_firewall.k8s.id
  server_ids  = hcloud_server.controlplane[*].id
}

############################
# Load Balancer
############################
resource "hcloud_load_balancer" "api" {
  name               = "${var.cluster_name}-api"
  load_balancer_type = "lb11"
  location           = var.location
}

resource "hcloud_load_balancer_network" "api_net" {
  load_balancer_id = hcloud_load_balancer.api.id
  network_id       = hcloud_network.k8s.id
}

resource "hcloud_load_balancer_target" "api_targets" {
  count            = var.node_count
  type             = "server"
  load_balancer_id = hcloud_load_balancer.api.id
  server_id        = hcloud_server.controlplane[count.index].id
  use_private_ip   = true  # target nodes via private IP, not public
}

resource "hcloud_load_balancer_service" "api_service" {
  load_balancer_id = hcloud_load_balancer.api.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 15
    timeout  = 10
    retries  = 3
  }
}
