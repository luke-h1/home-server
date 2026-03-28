terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }

  backend "s3" {
    bucket  = "lho-home-server-tf-state"
    key     = "terraform.tfstate"
    region  = "eu-west-2"
    encrypt = true
  }
}
