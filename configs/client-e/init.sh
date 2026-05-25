#!/bin/bash
# client-e - sede A de un cliente con E-Line (VNI 10300), L2 puro punto a punto
set -e
ip link set eth1 up
ip addr add 203.0.113.1/30 dev eth1
