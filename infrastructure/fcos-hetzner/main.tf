terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

variable "fcos_image_id" {
  description = "Fedora CoreOS snapshot ID from Hetzner"
  type        = string
}

variable "ssh_key_fingerprint" {
  description = "Fingerprint of SSH key in Hetzner Cloud"
  type        = string
}

variable "node_count" {
  description = "Number of cluster nodes"
  type        = number
  default     = 3
}

variable "admin_ip" {
  description = "Admin IPs in CIDR notation"
  type        = list(string)
  default     = []
}

data "hcloud_ssh_key" "default" {
  fingerprint = var.ssh_key_fingerprint
}

# Merge the containerd cleanup unit into each node's ignition config
locals {
  cleanup_unit = {
    name    = "containerd-state-cleanup.service"
    enabled = true
    contents = "[Unit]\nDescription=Clean stale containerd state from snapshot\nBefore=containerd.service\nDefaultDependencies=no\n\n[Service]\nType=oneshot\nExecStart=/bin/rm -rf /var/lib/containerd\nRemainAfterExit=yes\n\n[Install]\nWantedBy=sysinit.target"
  }

  ignition_configs = [
    for i in range(var.node_count) : merge(
      jsondecode(file("${path.module}/ignition-node-${i + 1}.json")),
      {
        systemd = {
          units = concat(
            try(jsondecode(file("${path.module}/ignition-node-${i + 1}.json")).systemd.units, []),
            [local.cleanup_unit]
          )
        }
      }
    )
  ]
}

resource "hcloud_network" "private_network" {
  name     = "coreos-network"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "private_subnet" {
  network_id   = hcloud_network.private_network.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}
# Fedora CoreOS servers
resource "hcloud_server" "node" {
  count       = var.node_count
  name        = "fedora-coreos-node-${count.index + 1}"
  server_type = "cpx22"
  location    = "hel1"
  image       = var.fcos_image_id
  ssh_keys    = [data.hcloud_ssh_key.default.id]
  user_data   = jsonencode(local.ignition_configs[count.index])

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  labels = {
    type = "coreos-cluster"
    node = "node-${count.index + 1}"
  }

  depends_on = [hcloud_network_subnet.private_subnet]
}

resource "hcloud_server_network" "node_network" {
  count      = var.node_count
  server_id  = hcloud_server.node[count.index].id
  network_id = hcloud_network.private_network.id
  ip         = "10.0.1.${count.index + 10}"
}

resource "hcloud_firewall" "cluster_firewall" {
  name = "coreos-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.admin_ip
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = var.admin_ip
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "any"
    source_ips = ["10.0.0.0/16"]
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "any"
    source_ips = ["10.0.0.0/16"]
  }
}

# Attach firewall to servers
resource "hcloud_firewall_attachment" "node_firewall" {
  firewall_id = hcloud_firewall.cluster_firewall.id
  server_ids  = [for server in hcloud_server.node : server.id]
}

# Outputs
output "node_ips" {
  description = "IP addresses of all nodes"
  value = {
    for idx, server in hcloud_server.node :
    server.name => {
      public_ipv4 = server.ipv4_address
      public_ipv6 = server.ipv6_address
      private_ip  = "10.0.1.${idx + 10}"
    }
  }
}

output "ssh_commands" {
  description = "SSH commands to connect to nodes"
  value = {
    for server in hcloud_server.node :
    server.name => "ssh core@${server.ipv4_address}"
  }
}

output "private_network" {
  description = "Private network details"
  value = {
    network_id = hcloud_network.private_network.id
    subnet     = "10.0.1.0/24"
    nodes = {
      for idx, server in hcloud_server.node :
      server.name => "10.0.1.${idx + 10}"
    }
  }
}

output "firewall_id" {
  value = hcloud_firewall.cluster_firewall.id
}

output "ssh_key_info" {
  value = {
    name        = data.hcloud_ssh_key.default.name
    fingerprint = data.hcloud_ssh_key.default.fingerprint
  }
}