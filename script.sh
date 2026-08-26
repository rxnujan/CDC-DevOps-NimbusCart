#!/bin/bash
# NimbusCart infrastructure automation.
# Per assignment spec: this script does exactly three things.
set -e

cd "$(dirname "$0")/terraform"

terraform init
terraform plan
terraform apply -auto-approve
