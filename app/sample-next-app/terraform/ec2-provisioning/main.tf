# terraform block
terraform {
    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "~> 6.0"
        }
    }
}

# configure the AWS provider
provider "aws" {
    region = "us-east-1"
}

# resource blocks

# security group 
resource "aws_security_group_rule" "example" {
    type = "ingress"
    from_port = 0
    to_port = 65535
    cidr_blocks = [aws_vpc.example.cidr_block]
    ipv6_cidr_blocks = [aws_vpc.example.ipv6_cidr_block]
    security_group_id = "sg-1-terraform-provisioning-aws"
}
# aws instance 
resource "aws_instance" "example" {
    ami = data.aws_ami.linux.id
    instance_type = "t3.micro"

    tags = {
        Name = "Day-10-ec2-provisioned-by-terraform"
    }
}
# aws keypair
resource "aws_key_pair" "deployer" {
    key_name = "deployer_key"
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC/+f5YcTmUz23Xrxjt6NWXQSlKW40wzFbpjvJvetRcjHBFx/4lDc3TN+rNZ3TUwM+LYCy+kAB0R6okXG+n/1QrY16FHf85gaMLhe2U0rLCIQSyVo3yq00FqT2s4RL1S6jXRE2fiLviUT3WqfT52j92Q+nxRRE0yunHrPfflLzh+cUDUkR9BgzbmUO8J9Dqll0FATPEAR9ZlLLP/pTmFPPGxOLQ12Vj0X+hu2Bb6/HoOxlFth4DtZEcU5YIJkwjx1bUk55MUmgSN0vuyFgCycsJ23VN/0o1cG9WOJNGSx24BQsv+lYfRBUnDQbRowQduWlx6hMM+5xc7wozwajQg7TTgfMk7v2A8XHlUNPv8pgzhG2cBAFnu4/PesPjaJ0va4XsDiBZLFX2bdp7JngbzTIB+WrfYAYtJ6MPY3VmKyKYm8wvdEjaU49LCeOjxnTyZmzL8+tcPHZXut0r9Y9Zsjz31PBISVliRfJ5KuPk9gnlPn+0WB69AoYA7mVgH9bzcRoAiQow72rBPp2IHKnriRHJFW+/zqhm0a0dl8xoTqV1WZTUEGpKUeLSB1xBs/y62M5yqrY3dnxH+Eq8xINyYRJQN+siF0yeXkPY/oqbZv1PRkqe8lRBX8n+xTmsKG236hYRfzTKNYzJ5e/Vmo/8uX6bkI9KjNSjoBFZqkneKuNbUQ== xrig@DESKTOP-0AA3J7N"
}