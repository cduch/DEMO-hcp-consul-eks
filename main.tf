terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }

    hcp = {
      source  = "hashicorp/hcp"
      version = ">= 0.18.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.14.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.7.0"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
  }

}

provider "hcp" {
  client_id     = var.hcp_client_id
  client_secret = var.hcp_client_secret
}


provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster[0].endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster[0].certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.cluster[0].token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster[0].endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster[0].certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster[0].token
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.cluster[0].endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster[0].certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster[0].token
  load_config_file       = false
}

data "aws_availability_zones" "available" {
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.19.0"

  name                 = "${var.cluster_id}-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  public_subnets       = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets      = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

data "aws_eks_cluster" "cluster" {
  name = module.eks[0].cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks[0].cluster_id
}

module "eks" {
  count                  = var.install_eks_cluster ? 1 : 0
  source                 = "terraform-aws-modules/eks/aws"
  version                = "17.24.0"
  kubeconfig_api_version = "client.authentication.k8s.io/v1beta1"

  cluster_name    = "${var.cluster_id}-eks"
  cluster_version = "1.23"
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  manage_aws_auth = false

  node_groups = {
    application = {
      name_prefix    = "hashicups"
      instance_types = ["t3a.medium"]

      desired_capacity = 3
      max_capacity     = 3
      min_capacity     = 3
    }
  }
}


data "terraform_remote_state" "consul" {
  backend = "remote"

  config = {
    organization = var.organization
    workspaces = {
      name = var.consulworkspace
    }
  }
}



module "eks_consul_client" {
  source  = "hashicorp/hcp-consul/aws//modules/hcp-eks-client"
  version = "~> 0.9.3"

  boostrap_acl_token = data.terraform_remote_state.consul.outputs.consul_root_token
  cluster_id         = data.terraform_remote_state.consul.outputs.consul_cluster_id

  # strip out url scheme from the public url
  consul_hosts     = tolist([substr(data.terraform_remote_state.consul.outputs.consul_url, 8, -1)])
  consul_version   = data.terraform_remote_state.consul.outputs.consul_version
  datacenter       = data.terraform_remote_state.consul.outputs.consul_datacenter
  k8s_api_endpoint = module.eks[0].cluster_endpoint

  # The EKS node group will fail to create if the clients are
  # created at the same time. This forces the client to wait until
  # the node group is successfully created.
  depends_on = [module.eks]
}

module "demo_app" {
  count   = var.install_demo_app ? 1 : 0
  source  = "hashicorp/hcp-consul/aws//modules/k8s-demo-app"
  version = "~> 0.9.3"

  depends_on = [module.eks_consul_client]
}

output "kubeconfig_filename" {
  value = "abspath(one(module.eks[*].kubeconfig_filename))"
}

output "helm_values_filename" {
  value = "abspath(module.eks_consul_client.helm_values_file)"
}

output "hashicups_url" {
  value = "${one(module.demo_app[*].hashicups_url)}:8080"
}