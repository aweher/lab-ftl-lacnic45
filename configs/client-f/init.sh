#!/bin/bash
# client-f - sede B del mismo cliente, otro extremo del E-Line (VNI 10300)
set -e
ip link set eth1 up
ip addr add 203.0.113.2/30 dev eth1
