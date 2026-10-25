#!/bin/bash

terraform destroy
./generate-butane-and-ign.sh --wipe
terraform init
terraform plan
terraform apply