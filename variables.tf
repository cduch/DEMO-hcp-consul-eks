variable "region" {
  type    = string
  default = "eu-central-1"
}


variable "cluster_id" {
  type    = string
  default = "demo-cluster"
}

variable "hvn_id" {
  type    = string
  default = "demo-cluster-hvn"
}

variable "install_demo_app" {
  type    = bool
  default = false
}

variable "install_eks_cluster" {
  type = bool
  default = false
}
