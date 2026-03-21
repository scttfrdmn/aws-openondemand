packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "subnet_id" {
  type    = string
  default = ""
}

variable "git_sha" {
  type    = string
  default = ""
}

# AL2023 base AMI (Amazon-owned, x86_64)
data "amazon-ami" "al2023" {
  region = var.aws_region
  filters = {
    name                = "al2023-ami-2023.*-x86_64"
    virtualization-type = "hvm"
  }
  owners      = ["137112412989"]
  most_recent = true
}

source "amazon-ebs" "ood" {
  region        = var.aws_region
  source_ami    = data.amazon-ami.al2023.id
  instance_type = var.instance_type
  ssh_username  = "ec2-user"

  subnet_id                   = var.subnet_id != "" ? var.subnet_id : null
  associate_public_ip_address = false # C3: build in private subnet with NAT; no public IP needed

  ami_name        = "ood-base-{{isotime \"2006-01-02-150405\"}}"
  ami_description = "Open OnDemand base AMI - AL2023, OOD latest, oidc-pam, nginx/Passenger, CWAgent"

  tags = {
    Project   = "aws-openondemand"
    GitSHA    = var.git_sha
    BaseAMI   = data.amazon-ami.al2023.id
    BuildDate = "{{isotime \"2006-01-02\"}}"
  }
}

build {
  sources = ["source.amazon-ebs.ood"]

  provisioner "shell" {
    script          = "scripts/bake.sh"
    execute_command = "sudo -E bash '{{.Path}}'"
    environment_vars = [
      "GIT_SHA=${var.git_sha}",
    ]
  }
}
