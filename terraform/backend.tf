# Remote backend: S3 for state storage + DynamoDB for state locking.
#
# IMPORTANT: The S3 bucket and DynamoDB table referenced here are NOT created
# by this configuration. They must exist before `terraform init` is run.
# This is intentional (see REPORT.md, Task C Q6): if this same state file
# tracked the bucket/table it depends on, destroying the stack would delete
# the very backend the state relies on to run - a bootstrapping problem.
# Provision them once, out-of-band, e.g.:
#
#   aws s3api create-bucket --bucket nimbuscart-tfstate-<unique-suffix> \
#     --region us-east-1
#   aws s3api put-bucket-versioning --bucket nimbuscart-tfstate-<unique-suffix> \
#     --versioning-configuration Status=Enabled
#   aws dynamodb create-table --table-name nimbuscart-tf-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "nimbuscart-tfstate-REPLACE-ME"
    key            = "nimbuscart/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "nimbuscart-tf-lock"
    encrypt        = true
  }
}
