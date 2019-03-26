#!/usr/bin/env bash
set -e

function etcd_members {
    local domain

    domain="$1"
    dig +noall +answer -t SRV "_etcd-server-ssl._tcp.$domain" | awk '{print $NF}'
}

function first_a_addr {
    local name

    name="$1"
    dig +noall +answer "$name"  | awk '$4 == "A" {print $NF; exit}'
}

function generate_haproxy_cfg {
    local ip
    local template_path
    local cfg_path
    local domain
    local api_port
    local stat_port

    domain="$1"
    template_path="${2}/haproxy.cfg.template"
    cfg_path="${2}/haproxy.cfg"
    api_port="$3"
    stat_port="$4"

    sudo tee "$cfg_path" < "$template_path"
    for item in $(etcd_members "$domain"); do
        if ip=$(first_a_addr "$item") && [[ -n "$ip" ]]; then
            sudo echo "   server $item ${ip}:$api_port weight 1 verify none check check-ssl inter 3s fall 3 rise 3" | sudo tee -a "$cfg_path"
        fi
    done
    cat >> "$cfg_path" << EOL
listen stats
  bind 127.0.0.1:$stat_port
  mode http
  stats enable
  stats hide-version
  stats uri /haproxy_stats
  stats refresh 30s
  stats auth Username:Password
EOL
}

function has_master_api_lb_topology_changed {
    local ip
    local haproxy_cfg_ip
    local domain
    local cfg

    domain="$1"
    cfg="$2"
    for item in $(etcd_members "$domain"); do
        ip=$(first_a_addr "$item")
        haproxy_cfg_ip=$(awk -v "server=$item" '$2 == server {print substr($3, 0, index($3, ":") - 1); exit}' "$cfg")
        if [[ -n "$ip" ]]; then
           if [[ "$haproxy_cfg_ip" != "$ip" ]]; then
               return 0
           fi
        fi
    done
    return 1
}

function start_haproxy {
    local domain
    local api_vip

    domain="$1"
    api_vip="$2"
    declare -r image=docker.io/library/haproxy:latest
    declare -r cfg_dir=/etc/haproxy
    declare -r lb_port=7443
    declare -r api_port=6443
    declare -r stat_port=50000

    sudo mkdir --parents "$cfg_dir"

    generate_haproxy_cfg "$domain" "$cfg_dir" "$api_port" "$stat_port"

    if ! podman inspect "$image" &>/dev/null; then
        (>&2 echo "Pulling haproxy release image $image...")
        podman pull "$image"
    fi

    MATCHES="$(sudo podman ps -a --format "{{.Names}}" | grep "^${CONTAINER_NAME}$")" || /bin/true
    if [[ -z "$MATCHES" ]]; then
        (>&2 echo "Creating container...")
        sudo podman create \
            -d \
            --name "$CONTAINER_NAME" \
            --network=host \
            --cap-add=NET_ADMIN \
            -v "$cfg_dir:/usr/local/etc/haproxy:ro" \
            "$image"
    fi

    sudo podman start "$CONTAINER_NAME"

    # Update LB if masters topology changed
    while true; do
        sleep 15
        if has_master_api_lb_topology_changed "$domain" "${cfg_dir}/haproxy.cfg"; then
            (>&2 echo "Master topology changed. Reconfiguring and hot restarting HAProxy")
            generate_haproxy_cfg "$domain" "$cfg_dir" "$api_port"
            sudo podman kill -s HUP "$CONTAINER_NAME"
        fi
        if curl -o /dev/null -kLs "https://0:${lb_port}/healthz"; then
            (>&2 echo "API is accessible via LB")
            ensure_prerouting_rules "$api_vip" "$api_port" "$lb_port"
        fi
    done
}

function ensure_prerouting_rules {
    local api_vip
    local api_port
    local lb_port

    api_vip="$1"
    api_port="$2"
    lb_port="$3"
    rules=$(sudo iptables -L PREROUTING -n -t nat --line-numbers | awk '/OCP_API_LB_REDIRECT/ {print $1}'  | tac)
    if [[ -z "$rules" ]]; then
            (>&2 echo "Setting prerouting rule from ${api_vip}:${api_port} to port $lb_port")
            sudo iptables -t nat -I PREROUTING --src 0/0 --dst "$api_vip" -p tcp --dport "$api_port" -j REDIRECT --to-ports "$lb_port" -m comment --comment "OCP_API_LB_REDIRECT"
    fi
}

function sighandler {
    (>&2 echo "Exiting...")
    (>&2 echo "Delete API HAProxy IPtables rule")
    rules=$(sudo iptables -L PREROUTING -n -t nat --line-numbers | awk '/OCP_API_LB_REDIRECT/ {print $1}'  | tac)
    for rule in $rules; do
       sudo iptables -t nat -D PREROUTING  "$rule"
    done

    (>&2 echo "Killing API HAProxy container")
    sudo podman kill "$CONTAINER_NAME"
    trap - SIGINT SIGTERM
}

CLUSTER_DOMAIN="$(awk '/search/ {print $2}' /etc/resolv.conf)"
API_VIP="$(dig +noall +answer "api.${CLUSTER_DOMAIN}" | awk '{print $NF}')"
declare -r CONTAINER_NAME="api-haproxy"

trap sighandler SIGINT SIGTERM
start_haproxy "$CLUSTER_DOMAIN" "$API_VIP"
