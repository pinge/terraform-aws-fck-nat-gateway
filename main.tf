data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

data "aws_ami" "this" {
  most_recent = true
  owners = var.ami_owners
  filter {
    name   = "architecture"
    values = data.aws_ec2_instance_type.this.supported_architectures
  }
  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }
}

resource "aws_security_group" "this" {
  name_prefix = var.name
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "this_egress" {
  security_group_id = aws_security_group.this.id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
}

resource "aws_security_group_rule" "this_ingress" {
  security_group_id = aws_security_group.this.id
  type              = "ingress"
  cidr_blocks       = var.private_subnets
  from_port         = 0
  to_port           = 65535
  protocol          = "all"
}

resource "aws_launch_template" "this" {
  name_prefix   = var.name
  image_id      = data.aws_ami.this.id
  key_name      = var.key_name
  instance_type = var.instance_type

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.this.id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = {
      Name = var.name
    }
  }

  monitoring {
    enabled = true
  }

  tags = local.common_tags
}

resource "aws_instance" "this" {
  subnet_id         = var.subnet_id
  source_dest_check = false

  launch_template {
    id = aws_launch_template.this.id
  }
}
