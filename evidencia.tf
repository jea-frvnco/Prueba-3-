provider "aws" {
  region = "us-east-1"
}
 
resource "random_pet" "bucket_name" {
  length = 2
}
 
data "aws_ami" "amazon_linux" {
  most_recent = true
 
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
 
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
 
  owners = ["137112412989"] # Amazon AMI account ID
}
 
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.5.0"
 
  name = "my-vpc"
  cidr = "10.0.0.0/16"
 
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
 
  enable_nat_gateway = true
  enable_vpn_gateway = false
 
  tags = {
    Terraform   = "true"
    Environment = "prd"
  }
}
 
resource "aws_security_group" "allow_http_https_ssh" {
  name        = "allow_http_https_ssh"
  description = "Allow HTTP, HTTPS, and SSH inbound traffic"
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
}
 
resource "aws_s3_bucket" "my_bucket" {
  bucket = "my-bucket-${random_pet.bucket_name.id}"
  acl    = "private"
}
 
resource "aws_s3_bucket_object" "index_php" {
  bucket = aws_s3_bucket.my_bucket.bucket
  key    = "index.php"
  source = "path/to/index.php"
  acl    = "public-read"
}
 
resource "aws_instance" "web" {
  count         = 3
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  key_name      = "vockey"
  subnet_id     = element(module.vpc.public_subnets, count.index)
  security_groups = [aws_security_group.allow_http_https_ssh.name]
 
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd php
              systemctl start httpd
              systemctl enable httpd
              aws s3 cp s3://${aws_s3_bucket.my_bucket.bucket}/index.php /var/www/html/
              EOF
 
  tags = {
    Name = "WebServer-${count.index}"
  }
}
 
resource "aws_efs_file_system" "efs" {
  creation_token = "my-efs"
}
 
resource "aws_efs_mount_target" "efs_mount" {
  count          = 3
  file_system_id = aws_efs_file_system.efs.id
  subnet_id      = element(module.vpc.private_subnets, count.index)
  security_groups = [aws_security_group.allow_http_https_ssh.id]
}
 
resource "aws_efs_access_point" "efs_ap" {
  file_system_id = aws_efs_file_system.efs.id
 
  posix_user {
    gid = 1000
    uid = 1000
  }
 
  root_directory {
    path = "/web"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = 755
    }
  }
}
 
resource "aws_lb" "alb" {
  name               = "my-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_http_https_ssh.id]
  subnets            = module.vpc.public_subnets
 
  enable_deletion_protection = false
}
 
resource "aws_lb_target_group" "tg" {
  name     = "tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
 
  health_check {
    interval            = 30
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
    healthy_threshold   = 2
  }
}
 
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"
 
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}
 
resource "aws_lb_target_group_attachment" "attach" {
  count            = 3
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = element(aws_instance.web.*.id, count.index)
  port             = 80
}
