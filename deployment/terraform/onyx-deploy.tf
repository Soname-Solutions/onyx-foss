locals {
  region                 = "eu-central-1"
  project                = "onyx-foss"
  tfstate_s3_bucket_name = "s3-sonnentag-terraform"

  default_tags = {
    cost_prj      = local.project
    cost_env      = terraform.workspace
    cost_workload = "general"
  }
}

provider "aws" {
  region = local.region

  default_tags {
    tags = local.default_tags
  }
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.95, < 6.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }

  backend "s3" {
    bucket = local.tfstate_s3_bucket_name
    key    = "${local.project}/terraform.tfstate"
    region = local.region
  }
}

#########################################################################################

resource "random_password" "postgres" {
  length           = 16
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>?"
}

resource "aws_ssm_parameter" "postgres_password" {
  name  = "param-onyx-pgpass-${terraform.workspace}"
  type  = "SecureString"
  value = random_password.postgres.result
}

#########################################################################################


module "onyx" {
  # If your root module is next to this modules/ directory:
  # source = "./modules/aws/onyx"
  # If referencing from this repo as a template, adjust the path accordingly.
  source = "./modules/aws/onyx"

  region            = local.region
  name              = "onyx" # used as a prefix and workspace-aware
  postgres_username = "pgusername"
  postgres_password = random_password.postgres.result
  # create_vpc    = true  # default true; set to false to use an existing VPC (see below)
}

resource "null_resource" "wait_for_cluster" {
  provisioner "local-exec" {
    command = "aws eks wait cluster-active --name ${module.onyx.cluster_name} --region ${local.region}"
  }
}

data "aws_eks_cluster" "eks" {
  name       = module.onyx.cluster_name
  depends_on = [null_resource.wait_for_cluster]
}

data "aws_eks_cluster_auth" "eks" {
  name       = module.onyx.cluster_name
  depends_on = [null_resource.wait_for_cluster]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.eks.token
  }
}

# Optional: expose handy outputs at the root module level
output "cluster_name" {
  value = module.onyx.cluster_name
}
output "postgres_connection_url" {
  value     = module.onyx.postgres_endpoint
  sensitive = true
}
output "redis_connection_url" {
  value     = module.onyx.redis_connection_url
  sensitive = true
}
