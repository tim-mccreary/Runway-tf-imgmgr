# Backend Setup
terraform {
  backend "s3" {
  key = "bestappdev.tfstate"
  }
}

# Adding VPC Outputs as Inputs in Bestapp
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "best-common-tf-state-terraformstatebucket-cxlzbj2ir944"
    region = "us-west-2"
    key    = "env:/common/vpc.tfstate"
  }
}

# S3 Bucket
resource "aws_s3_bucket" "appbucket" {
  bucket_prefix = "${var.customerName}-${terraform.workspace}-apps3bucket"
}

#Server IAM Role
resource "aws_iam_role" "ec2_role" {
  name = "${terraform.workspace}-${var.applicationName}-ec2Role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
      tag-key = "tag"
  }
}

# Attaching SSM Role for Access
resource "aws_iam_role_policy_attachment" "aws-managed-policy-attachment" {
  role = "${aws_iam_role.ec2_role.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

# Server IAM Policy for Role
resource "aws_iam_role_policy" "ec2_policy" {
  name = "${terraform.workspace}-${var.applicationName}-ec2Policy"
  role = "${aws_iam_role.ec2_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListObject"
      ],
      "Effect": "Allow",
      "Resource": [
        "${aws_s3_bucket.appbucket.arn}/*",
        "${aws_s3_bucket.appbucket.arn}"
      ]
    }
  ]
}
EOF
}

# Server IAM Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${terraform.workspace}-${var.applicationName}-ec2Profile"
  role = "${aws_iam_role.ec2_role.name}"
}

# LB Security Group
resource "aws_security_group" "lb_sg" {
  name = "${terraform.workspace}-${var.applicationName}-lbSg"
  description = "IMG_MGR ALB SG"
  vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id

  ingress {
    from_port = "80"
    to_port = "80"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = "0"
    to_port = "0"
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# LB to Server Security Group
resource "aws_security_group" "lb-server-sg" {
  name = "${terraform.workspace}-${var.applicationName}-ec2Sg"
  description = "IMG_MGR LB-SERVER SG"
  vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id

  ingress {
    from_port = "80"
    to_port = "80"
    protocol = "tcp"
    security_groups = ["${aws_security_group.lb_sg.id}"]
    }

  egress {
    from_port = "0"
    to_port = "0"
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ALB
resource "aws_lb" "alb" {
  name               = "${terraform.workspace}-${var.applicationName}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = data.terraform_remote_state.vpc.outputs.public_subnets
}

# ALB Target Group
resource "aws_alb_target_group" "lb_targets" {
  name = "${terraform.workspace}-${var.applicationName}-tf-best-lb-tg"
  port = 80
  protocol = "HTTP"
  vpc_id   = data.terraform_remote_state.vpc.outputs.vpc_id
}

# ALB Listener
resource "aws_lb_listener" "lb_listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.lb_targets.arn
  }
}

## autoscaling group
resource "aws_autoscaling_group" "best_asg" {
  name                      = "${terraform.workspace}-${var.applicationName}-asg"
  max_size                  = 1
  min_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "EC2"
  desired_capacity          = 1
  force_delete              = true
  vpc_zone_identifier       = data.terraform_remote_state.vpc.outputs.private_subnets
  target_group_arns = [aws_alb_target_group.lb_targets.arn]

  launch_template {
    id = aws_launch_template.best-lt.id
    version =  aws_launch_template.best-lt.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    triggers = ["tag", "launch_template"]
    }
  }

## Launch Templete
resource "aws_launch_template" "best-lt" {
  name = "${terraform.workspace}-${var.applicationName}-launchTemplate"
  update_default_version = true
  image_id = var.imageID
  instance_initiated_shutdown_behavior = "terminate"
iam_instance_profile {
  name = aws_iam_instance_profile.ec2_profile.name
}
  instance_type = "t2.micro"
  key_name = "us-west-2-key"
  vpc_security_group_ids = [aws_security_group.lb-server-sg.id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {S3Bucket = aws_s3_bucket.appbucket.id }))

    tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.applicationName}-web1-${var.customerName}-${terraform.workspace}"
      Environment = "${terraform.workspace}"
    }
  }
}

# Cloudfront Distribution in front of ALB
resource "aws_cloudfront_distribution" "cloudfront" {
  enabled = true

  origin {
    domain_name   = aws_lb.alb.dns_name
    origin_id            = "${terraform.workspace}-${var.applicationName}-alb"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
  allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
  cached_methods   = ["GET", "HEAD"]
  target_origin_id     = "${terraform.workspace}-${var.applicationName}-alb"

  forwarded_values {
    query_string = false

    cookies {
      forward = "all"
    }
  }

    min_ttl                = 0
    default_ttl            = 300
    max_ttl                = 86400
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }


  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["MX", "AU", "US", "CA", "GB"]
    }
  }

  viewer_certificate {
  cloudfront_default_certificate = true
  }
}
