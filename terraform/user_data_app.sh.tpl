#!/bin/bash
set -e

# Installs Docker, authenticates to ECR using the instance's IAM role
# (no static credentials, no NAT-independent path - reaches ECR via the
# shared NAT Gateway's outbound-only route), pulls the API image, and runs
# it with DB connection details injected as environment variables.

dnf install -y docker
systemctl enable docker
systemctl start docker

aws ecr get-login-password --region ${aws_region} | \
  docker login --username AWS --password-stdin ${account_id}.dkr.ecr.${aws_region}.amazonaws.com

docker pull ${account_id}.dkr.ecr.${aws_region}.amazonaws.com/${ecr_repo_name}:latest

docker run -d \
  --name nimbuscart-api \
  --restart unless-stopped \
  -p ${app_port}:8080 \
  -e DB_HOST=${db_host} \
  -e DB_PORT=${db_port} \
  -e DB_NAME=${db_name} \
  -e DB_USER=${db_username} \
  -e DB_PASSWORD=${db_password} \
  ${account_id}.dkr.ecr.${aws_region}.amazonaws.com/${ecr_repo_name}:latest
