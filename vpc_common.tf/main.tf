# Backend setup
terraform {
backend "s3" {
key = "vpc.tfstate"
}
}

provider "aws" {}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name  =  var.name
  cidr = "10.132.128.0/21"

  default_vpc_enable_dns_hostnames = true
  default_vpc_enable_dns_support   = true

  azs             = ["us-west-2a", "us-west-2b"]
  private_subnets = ["10.132.128.0/24", "10.132.129.0/24"]
  public_subnets  = ["10.132.130.0/24", "10.132.131.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false
  create_igw         = true
  
  manage_default_route_table = true
  manage_default_network_acl = true
}

