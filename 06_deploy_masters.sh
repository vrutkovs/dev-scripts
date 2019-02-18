#!/usr/bin/bash

set -eux
source utils.sh
source common.sh

# Note This logic will likely run in a container (on the bootstrap VM)
# for the final solution, but for now we'll prototype the workflow here
instack="ocp/master_nodes.json"
export OS_TOKEN=fake-token
export OS_URL=http://ostest-api.test.metalkube.org:6385/

wait_for_json ironic \
    "${OS_URL}/v1/nodes" \
    10 \
    -H "Accept: application/json" -H "Content-Type: application/json" -H "User-Agent: wait-for-json" -H "X-Auth-Token: $OS_TOKEN"

# Clean previously env
nodes=$(openstack baremetal node list)
i=0
for node in $(jq -r .nodes[].name ${instack}); do
  if [[ $nodes =~ $node ]]; then
    openstack baremetal node undeploy $node --wait || true
    openstack baremetal node delete $node
  fi
  MASTER_IP=$(dig +noall +answer "${CLUSTER_NAME}-etcd-${i}.${BASE_DOMAIN}" @$(network_ip baremetal) | awk '{print $NF}')
  # Add api alias to masters to host dnsmasq and libvirt's dnsmasq
  echo "${MASTER_IP} ${CLUSTER_NAME}-api.${BASE_DOMAIN}" | sudo tee -a /etc/hosts.openshift
  # Add entries for etcd discovery
  echo "${MASTER_IP} ${CLUSTER_NAME}-master-${i}.${BASE_DOMAIN}" | sudo tee -a /etc/hosts.openshift
  echo "srv-host=etcd-server-ssl,${CLUSTER_NAME}-master-${i}.${BASE_DOMAIN},2380" | sudo tee -a /etc/NetworkManager/dnsmasq.d/openshift.conf
  i=$((i+1))
done
# Reload dnsmasq on host
sudo systemctl reload NetworkManager

openstack baremetal create $instack
mkdir -p configdrive/openstack/latest
cp ocp/master.ign configdrive/openstack/latest/user_data
for node in $(jq -r .nodes[].name $instack); do

  # FIXME(shardy) we should parameterize the image
  openstack baremetal node set $node --instance-info image_source=http://172.22.0.1/images/redhat-coreos-maipo-47.284-openstack_dualdhcp.qcow2 --instance-info image_checksum=$(md5sum images/redhat-coreos-maipo-47.284-openstack_dualdhcp.qcow2 | awk '{print $1}') --instance-info root_gb=25 --property root_device="{\"name\": \"$ROOT_DISK\"}"
  openstack baremetal node manage $node --wait
  openstack baremetal node provide $node --wait
done

for node in $(jq -r .nodes[].name $instack); do
  openstack baremetal node deploy --config-drive configdrive $node
done
# FIXME(shardy) we should wait for the node deploy to complete (or fail)
