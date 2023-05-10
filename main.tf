terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.66.1"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region     = "your_aws_iam_region_code"
  access_key = "your_aws_access_key_id"
  secret_key = "your_aws_secret_access_key"
}

data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.7.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

resource "aws_eks_addon" "ebs-csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.5.2-eksbuild.1"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
  tags = {
    "eks_addon" = "ebs-csi"
    "terraform" = "true"
  }
}

data "aws_availability_zones" "available" {}

locals {
  cluster_name = "simple_express_app-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 9
  special = false
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.19.0"

  name = "simpleexpressapp-vpc"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  private_subnets = ["10.0.1.0/24", "10.0.7.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.5.1"

  cluster_name    = local.cluster_name
  cluster_version = "1.24"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

  }

  eks_managed_node_groups = {
    one = {
      name = "node_group_1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 2
    }

    two = {
      name = "node_group_2"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

resource "kubernetes_namespace" "simple-express-app" {
  metadata {
    name = "simple-express-app"
  }
}

resource "kubernetes_deployment" "simple-express-app" {
  metadata {
    name      = "simple-express-app"
    namespace = kubernetes_namespace.simple-express-app.metadata.0.name
  }
  spec {
    replicas = 0
    selector {
      match_labels = {
        app = "simple-express-app"
      }
    }
    template {
      metadata {
        labels = {
          app = "simple-express-app"
        }
      }
      spec {
        container {
          image = "rosechege/simple_express_app"
          name  = "simple-express-app-container"
          port {
            container_port = 4000
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "simple-express-app" {
  metadata {
    name      = "simple-express-app"
    namespace = kubernetes_namespace.simple-express-app.metadata.0.name
  }
  spec {
    selector = {
      app = kubernetes_deployment.simple-express-app.spec.0.template.0.metadata.0.labels.app
    }
    type = "LoadBalancer"
    port {
      port        = 80
      target_port = 4000
    }
  }
}
