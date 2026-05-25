#!/bin/bash
# Destruye el lab
set -e
cd "$(dirname "$0")/.."
sudo containerlab destroy -t topology.clab.yml --cleanup
