provider "aws" {
  region  = "us-east-2"
  profile = "ewr-admin"
}

terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket  = "ewr-terraform"
    key     = "ewr-terraform.tfstate"
    region  = "us-east-2"
    profile = "ewr-admin"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.5.0"
    }
  }
}

