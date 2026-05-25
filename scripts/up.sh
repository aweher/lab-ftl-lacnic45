#!/bin/bash
# Levanta el lab
set -e
cd "$(dirname "$0")/.."
sudo containerlab deploy -t topology.clab.yml
