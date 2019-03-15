#!/bin/bash

set -o pipefail

function create_cluster() {
    local assets_dir

    assets_dir="$1"
    cp ocp/install-config.yaml{,.tmp}

    $GOPATH/src/github.com/openshift-metalkube/kni-installer/bin/kni-install --dir "${assets_dir}" --log-level=debug create ignition-configs
    cp ocp/master.ign{,.tmp}

    cp ocp/install-config.yaml{.tmp,}
    $GOPATH/src/github.com/openshift-metalkube/kni-installer/bin/kni-install --dir "${assets_dir}" --log-level=debug create manifests
    cp -rf additional_assets/*.yaml ocp/openshift

    cp ocp/install-config.yaml{.tmp,}
    $GOPATH/src/github.com/openshift-metalkube/kni-installer/bin/kni-install --dir "${assets_dir}" create cluster
    cp ocp/master.ign{.tmp,}

}

function net_iface_dhcp_ip() {
local netname
local hwaddr

netname="$1"
hwaddr="$2"
sudo virsh net-dhcp-leases "$netname" | grep -q "$hwaddr" || return 1
sudo virsh net-dhcp-leases "$netname" | awk -v hwaddr="$hwaddr" '$3 ~ hwaddr {split($5, res, "/"); print res[1]}'
}

function domain_net_ip() {
    local domain
    local bridge_name
    local net
    local hwaddr
    local rc

    domain="$1"
    net="$2"


    bridge_name=$(sudo virsh net-dumpxml "$net" | "${PWD}/pyxpath" "//bridge/@name" -)
    hwaddr=$(virsh dumpxml "$domain" | "${PWD}/pyxpath" "//devices/interface[source/@bridge='$bridge_name']/mac/@address" -)
    rc=$?
    if [ $rc -ne 0 ]; then
        return $rc
    fi

    net_iface_dhcp_ip "$net" "$hwaddr"
}

function wait_for_json() {
    local name
    local url
    local curl_opts
    local timeout

    local start_time
    local curr_time
    local time_diff

    name="$1"
    url="$2"
    timeout="$3"
    shift 3
    curl_opts="$@"
    echo -n "Waiting for $name to respond"
    start_time=$(date +%s)
    until curl -g -X GET "$url" "${curl_opts[@]}" 2> /dev/null | jq '.' 2> /dev/null > /dev/null; do
        echo -n "."
        curr_time=$(date +%s)
        time_diff=$(($curr_time - $start_time))
        if [[ $time_diff -gt $timeout ]]; then
            echo "\nTimed out waiting for $name"
            return 1
        fi
        sleep 5
    done
    echo " Success!"
    return 0
}

function network_ip() {
    local network
    local rc

    network="$1"
    ip="$(sudo virsh net-dumpxml "$network" | "${PWD}/pyxpath" "//ip/@address" -)"
    rc=$?
    if [ $rc -ne 0 ]; then
        return $rc
    fi
    echo "$ip"
}

function master_node_val() {
    local n
    local val

    n="$1"
    val="$2"

    jq -r ".nodes[${n}].${val}" $MASTER_NODES_FILE
}

function master_node_to_tf() {
    local master_idx
    local image_source
    local image_checksum
    local root_gb
    local root_device

    master_idx="$1"
    image_source="$2"
    image_checksum="$3"
    root_gb="$4"
    root_device="$5"

    name=$(master_node_val ${master_idx} "name")
    mac=$(master_node_val ${master_idx} "ports[0].address")
    local_gb=$(master_node_val ${master_idx} "properties.local_gb")
    cpu_arch=$(master_node_val ${master_idx} "properties.cpu_arch")

    ipmi_port=$(master_node_val ${master_idx} "driver_info.ipmi_port")
    ipmi_username=$(master_node_val ${master_idx} "driver_info.ipmi_username")
    ipmi_password=$(master_node_val ${master_idx} "driver_info.ipmi_password")
    ipmi_address=$(master_node_val ${master_idx} "driver_info.ipmi_address")

    deploy_kernel=$(master_node_val ${master_idx} "driver_info.deploy_kernel")
    deploy_ramdisk=$(master_node_val ${master_idx} "driver_info.deploy_ramdisk")

    cat <<EOF

resource "ironic_node_v1" "openshift-master-${master_idx}" {
  name = "$name"

  target_provision_state = "active"
  user_data = "\${file("master.ign")}"

  ports = [
    {
      "address" = "${mac}"
      "pxe_enabled" = "true"
    }
  ]

  properties {
    "local_gb" = "${local_gb}"
    "cpu_arch" =  "${cpu_arch}"
  }

  instance_info = {
    "image_source" = "${image_source}"
    "image_checksum" = "${image_checksum}"
    "root_gb" = "${root_gb}"
    "root_device" = "${root_device}"
  }

  driver = "ipmi"
  driver_info {
    "ipmi_port"=      "${ipmi_port}"
    "ipmi_username"=  "${ipmi_username}"
    "ipmi_password"=  "${ipmi_password}"
    "ipmi_address"=   "${ipmi_address}"
    "deploy_kernel"=  "${deploy_kernel}"
    "deploy_ramdisk"= "${deploy_ramdisk}"
  }
}
EOF
}
