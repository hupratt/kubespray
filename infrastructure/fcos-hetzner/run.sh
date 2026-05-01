#!/bin/bash

#. ./env/bin/activate

./upload-fcos-to-hetzner-hcloud.sh
./generate-butane-and-ign.sh
terraform apply
# debug with
journalctl -u ignition-files.service
