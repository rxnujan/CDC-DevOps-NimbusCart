variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "app_vpc_cidr" {
  description = "CIDR block for the app-vpc (web + app tiers)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "data_vpc_cidr" {
  description = "CIDR block for the data-vpc (RDS)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "app_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "db_subnet_cidr_a" {
  type    = string
  default = "10.1.1.0/24"
}

variable "db_subnet_cidr_b" {
  description = "Second AZ subnet for the RDS DB subnet group (required by AWS even for single-AZ RDS)"
  type        = string
  default     = "10.1.2.0/24"
}

variable "availability_zone_a" {
  type    = string
  default = "us-east-1a"
}

variable "availability_zone_b" {
  type    = string
  default = "us-east-1b"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_name" {
  type    = string
  default = "nimbuscart"
}

variable "db_username" {
  type    = string
  default = "nimbuscart"
}

variable "db_password" {
  description = "RDS master password. Pass via TF_VAR_db_password, never commit."
  type        = string
  sensitive   = true
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name for SSH access (used by remote-exec)"
  type        = string
}

variable "private_key_path" {
  description = "Local path to the private key matching key_pair_name, used by remote-exec provisioners"
  type        = string
}

variable "app_port" {
  type    = number
  default = 8080
}

variable "ecr_repo_name" {
  type    = string
  default = "nimbuscart-api"
}
