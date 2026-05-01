############################
# Control Plane Nodes
############################

locals {
  controlplane_ips = [
    "10.2.0.11",
    "10.2.0.12",
    "10.2.0.13"
  ]
}

############################
# Talos Secrets
############################

resource "talos_machine_secrets" "this" {}

############################
# Variables
############################

variable "image_id" {
  description = "Talos snapshot ID from Hetzner"
  type        = string
}

variable "ssh_key_fingerprint" {
  description = "Fingerprint of SSH key in Hetzner Cloud"
  type        = string
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "cluster_name" {
  type    = string
  default = "talos"
}

variable "region" {
  type    = string
  default = "eu-central"
}

variable "location" {
  default = "hel1"
}

variable "server_type" {
  type    = string
  default = "cx23"
}

variable "talos_version" {
  type    = string
  default = "v1.12.4"
}

variable "node_count" {
  description = "Number of cluster nodes"
  type        = number
  default     = 3
}

# released: 2026-02-10
variable "kubernetes_version" {
  type    = string
  default = "1.35.1"
}

variable "admin_ip" {
  description = "Admin IPs in CIDR notation"
  type        = list(string)
  default     = []
}