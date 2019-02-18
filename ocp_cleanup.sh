#!/bin/bash

set -e

source ocp_install_env.sh

sudo virsh destroy "${CLUSTER_NAME}-bootstrap"
sudo virsh undefine "${CLUSTER_NAME}-bootstrap" --remove-all-storage
VOL_POOL=$(sudo virsh vol-pool "/var/lib/libvirt/images/${CLUSTER_NAME}-bootstrap.ign")
sudo virsh vol-delete "${CLUSTER_NAME}-bootstrap.ign" --pool "${VOL_POOL}"
rm -rf ocp
sudo rm -rf /etc/NetworkManager/dnsmasq.d/openshift.conf
sudo rm -rf /etc/hosts.openshift
sudo systemctl reload NetworkManager
