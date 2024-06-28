terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.53.0" # Ajusta la versión según tus necesidades
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Crear una VPC
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
 
  name = "jean-vpc"
  cidr = "10.0.0.0/16"
 
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
 
  enable_nat_gateway = true
  enable_vpn_gateway = false
 
  tags = {
    Terraform = "true"
    Environment = "prd"
  }
}

# Crear un Security Group
resource "aws_security_group" "jean_allow_traffic" {
  name        = "jean_allow_traffic"
  description = "Allow traffic on ports 80, 443, and 22"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "jean_allow_traffic"
  }
}

# Crear un bucket S3 y copiar archivo index.php
resource "aws_s3_bucket" "jean_bucket" {
  bucket = "jean-website-bucket"
  acl    = "private"

  tags = {
    Name        = "jean-website-bucket"
    Environment = "prd"
  }
}

resource "aws_s3_bucket_object" "index_php" {
  bucket = aws_s3_bucket.jean_bucket.bucket
  key    = "index.php"
  source = "index.php"
  acl    = "public-read"
}

# Lanzar 3 instancias EC2 en diferentes AZs
resource "aws_instance" "jean_web" {
  count         = 3
  ami           = "ami-0c55b159cbfafe1f0" # Amazon Linux 2 AMI
  instance_type = "t2.micro"
  key_name      = "vockey"

  subnet_id = element(module.vpc.public_subnets, count.index)
  security_groups = [aws_security_group.jean_allow_traffic.name]

  user_data = <<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install -y httpd php amazon-efs-utils
              sudo systemctl start httpd
              sudo systemctl enable httpd
              sudo mkdir -p /var/www/html
              sudo mount -t efs -o tls ${aws_efs_file_system.efs.id}:/ /var/www/html
              aws s3 cp s3://${aws_s3_bucket.jean_bucket.bucket}/index.php /var/www/html/
              EOF

  tags = {
    Name = "JeanWebServer-${count.index}"
  }
}

# Crear un volumen EFS y montarlo en las instancias EC2
resource "aws_efs_file_system" "jean_efs" {
  creation_token = "jean-efs"
  tags = {
    Name = "jean-efs"
  }
}

resource "aws_efs_mount_target" "jean_efs_mount" {
  count          = 3
  file_system_id = aws_efs_file_system.jean_efs.id
  subnet_id      = element(module.vpc.public_subnets, count.index)
  security_groups = [aws_security_group.jean_allow_traffic.id]
}

# Crear un Load Balancer y adjuntar las instancias
resource "aws_lb" "jean_alb" {
  name               = "jean-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.jean_allow_traffic.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false

  tags = {
    Name = "jean-alb"
  }
}

resource "aws_lb_target_group" "jean_target_group" {
  name     = "jean-targets"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "jean-targets"
  }
}

resource "aws_lb_listener" "jean_listener" {
  load_balancer_arn = aws_lb.jean_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jean_target_group.arn
  }
}

resource "aws_lb_target_group_attachment" "jean_target_attachment" {
  count            = 3
  target_group_arn = aws_lb_target_group.jean_target_group.arn
  target_id        = element(aws_instance.jean_web.*.id, count.index)
  port             = 80
}
