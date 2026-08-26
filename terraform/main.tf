provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

##############################################
# VPC-A: app-vpc (web tier public + app tier private)
##############################################

resource "aws_vpc" "app_vpc" {
  cidr_block           = var.app_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "app-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.app_vpc.id
  tags   = { Name = "igw-appvpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block               = var.public_subnet_cidr
  availability_zone         = var.availability_zone_a
  map_public_ip_on_launch  = true
  tags = { Name = "public-subnet-web" }
}

resource "aws_subnet" "app_private" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = var.app_subnet_cidr
  availability_zone = var.availability_zone_a
  tags = { Name = "private-subnet-app" }
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags   = { Name = "nimbuscart-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "nimbuscart-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

# Public route table: 0.0.0.0/0 -> IGW
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.app_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

# Private (app) route table: 0.0.0.0/0 -> NAT, data-vpc CIDR -> peering
resource "aws_route_table" "app_private_rt" {
  vpc_id = aws_vpc.app_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  route {
    cidr_block                = var.data_vpc_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection.app_to_data.id
  }
  tags = { Name = "app-private-rt" }
}

resource "aws_route_table_association" "app_private_assoc" {
  subnet_id      = aws_subnet.app_private.id
  route_table_id = aws_route_table.app_private_rt.id
}

##############################################
# VPC-B: data-vpc (isolated - RDS only)
##############################################

resource "aws_vpc" "data_vpc" {
  cidr_block           = var.data_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "data-vpc" }
}

resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.data_vpc.id
  cidr_block        = var.db_subnet_cidr_a
  availability_zone = var.availability_zone_a
  tags = { Name = "db-subnet-a" }
}

# Second AZ subnet - required by AWS for a DB subnet group even though RDS
# itself is single-AZ here. See REPORT.md Task C, Q1.
resource "aws_subnet" "db_b" {
  vpc_id            = aws_vpc.data_vpc.id
  cidr_block        = var.db_subnet_cidr_b
  availability_zone = var.availability_zone_b
  tags = { Name = "db-subnet-b" }
}

resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "nimbuscart-db-subnet-group"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]
  tags       = { Name = "nimbuscart-db-subnet-group" }
}

# No Internet Gateway, no NAT Gateway in data-vpc at all - fully isolated.
# Only a return route to app-vpc via peering (see REPORT.md Task A, Q2).
resource "aws_route_table" "data_rt" {
  vpc_id = aws_vpc.data_vpc.id
  route {
    cidr_block                = var.app_vpc_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection.app_to_data.id
  }
  tags = { Name = "data-rt" }
}

resource "aws_route_table_association" "db_a_assoc" {
  subnet_id      = aws_subnet.db_a.id
  route_table_id = aws_route_table.data_rt.id
}

resource "aws_route_table_association" "db_b_assoc" {
  subnet_id      = aws_subnet.db_b.id
  route_table_id = aws_route_table.data_rt.id
}

##############################################
# VPC Peering: app-vpc <-> data-vpc
##############################################

resource "aws_vpc_peering_connection" "app_to_data" {
  vpc_id      = aws_vpc.app_vpc.id
  peer_vpc_id = aws_vpc.data_vpc.id
  auto_accept = true
  tags        = { Name = "app-to-data-peering" }
}

##############################################
# Security Groups
##############################################

resource "aws_security_group" "web_sg" {
  name        = "web-sg"
  description = "Allows 80/443 from the internet"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH (restrict this in real use)"
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
  tags = { Name = "web-sg" }
}

resource "aws_security_group" "app_sg" {
  name        = "app-sg"
  description = "Allows app port only from web-sg"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    description     = "App port from web tier only"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }
  ingress {
    description = "SSH from within app-vpc (bastion-less, for provisioners)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.app_vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "app-sg" }
}

resource "aws_security_group" "db_sg" {
  name        = "db-sg"
  description = "Allows DB port from app-sg only"
  vpc_id      = aws_vpc.data_vpc.id

  ingress {
    description = "Postgres from app tier only"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.app_subnet_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "db-sg" }
}

##############################################
# ECR (image build/push target used by local-exec)
##############################################

resource "aws_ecr_repository" "api_repo" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags = { Name = "nimbuscart-api-repo" }
}

# Builds and pushes the API image to ECR as part of `terraform apply`.
# NOTE: local-exec runs on the machine executing Terraform, not on any AWS
# resource. See REPORT.md Task C, Q5 for why this is acceptable here but
# discouraged generally.
resource "null_resource" "build_and_push_image" {
  triggers = {
    dockerfile_hash = filesha256("${path.module}/../app/api/Dockerfile")
    app_hash        = filesha256("${path.module}/../app/api/app.py")
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ecr get-login-password --region ${var.aws_region} | \
        docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
      docker build -t ${var.ecr_repo_name}:latest ${path.module}/../app/api
      docker tag ${var.ecr_repo_name}:latest ${aws_ecr_repository.api_repo.repository_url}:latest
      docker push ${aws_ecr_repository.api_repo.repository_url}:latest
    EOT
  }

  depends_on = [aws_ecr_repository.api_repo]
}

##############################################
# IAM: instance profile for App tier to pull from ECR
##############################################

resource "aws_iam_role" "app_role" {
  name = "nimbuscart-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "app_profile" {
  name = "nimbuscart-app-profile"
  role = aws_iam_role.app_role.name
}

##############################################
# RDS (isolated data-vpc)
##############################################

resource "aws_db_instance" "products_db" {
  identifier             = "nimbuscart-db"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
  tags = { Name = "nimbuscart-db" }
}

##############################################
# EC2: App tier (private) - pulls image from ECR, runs container
##############################################

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "app_tier" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.app_private.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.app_profile.name
  key_name               = var.key_pair_name

  user_data = templatefile("${path.module}/user_data_app.sh.tpl", {
    aws_region     = var.aws_region
    account_id     = data.aws_caller_identity.current.account_id
    ecr_repo_name  = var.ecr_repo_name
    app_port       = var.app_port
    db_host        = aws_db_instance.products_db.address
    db_port        = aws_db_instance.products_db.port
    db_name        = var.db_name
    db_username    = var.db_username
    db_password    = var.db_password
  })

  tags = { Name = "app-tier-ec2" }

  depends_on = [null_resource.build_and_push_image, aws_db_instance.products_db]
}

##############################################
# EC2: Web tier (public) - nginx, static frontend, reverse proxy
##############################################

resource "aws_instance" "web_tier" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true
  key_name                    = var.key_pair_name

  tags = { Name = "web-tier-ec2" }

  # File provisioner copies the static frontend to the instance.
  provisioner "file" {
    source      = "${path.module}/../app/frontend/index.html"
    destination = "/home/ec2-user/index.html"

    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file(var.private_key_path)
      host        = self.public_ip
    }
  }

  # Remote-exec installs nginx, deploys the frontend, and templates the
  # reverse-proxy config pointing /api/ at the app tier's private IP.
  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y nginx",
      "sudo mv /home/ec2-user/index.html /usr/share/nginx/html/index.html",
      "sudo tee /etc/nginx/conf.d/nimbuscart.conf > /dev/null <<'NGINX'\nserver {\n    listen 80;\n    root /usr/share/nginx/html;\n    index index.html;\n\n    location / {\n        try_files $uri $uri/ /index.html;\n    }\n\n    location /api/ {\n        proxy_pass http://${aws_instance.app_tier.private_ip}:${var.app_port}/;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n    }\n}\nNGINX",
      "sudo rm -f /etc/nginx/conf.d/default.conf",
      "sudo systemctl enable nginx",
      "sudo systemctl restart nginx"
    ]

    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file(var.private_key_path)
      host        = self.public_ip
    }
  }

  depends_on = [aws_instance.app_tier]
}
