#!/bin/bash
CONTROL_PLANE_IP="192.168.4.244"
CONTROL_PLANE_NODES=("192.168.4.244" "192.168.4.250" "192.168.4.251")
WORKER_IP=("192.168.4.248" "192.168.4.245" "192.168.4.249" "192.168.4.246" "192.168.4.247")

CLUSTER_NAME="rockingham-k8s"
DISK_NAME="vda"

# echo "Generating Talos config for cluster: $CLUSTER_NAME"
# talosctl gen config $CLUSTER_NAME https://$CONTROL_PLANE_IP:6443 --install-disk /dev/$DISK_NAME
#
# echo "Applying control plane configuration"
# talosctl apply-config --insecure --nodes $CONTROL_PLANE_IP --file controlplane.yaml
#
for ip in "${CONTROL_PLANE_NODES[@]}"; do
    echo "Applying config to worker node: $ip"
    # talosctl apply-config --insecure --nodes "$ip" --file worker.yaml
    MAC_ADDRESS=$(talosctl get links --nodes "$ip" --talosconfig talosconfig | grep 'ens3' | awk '{print $7}')
    talosctl apply-config \
        --nodes "$ip" \
        --file controlplane.yaml \
        --talosconfig talosconfig \
        --config-patch "[{\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/addresses/0\", \"value\": \"$ip/24\"},
                       {\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/deviceSelector/hardwareAddr\", \"value\": \"$MAC_ADDRESS\"}]" # --dry-run \

done

for ip in "${WORKER_IP[@]}"; do
    echo "Applying config to worker node: $ip"
    # talosctl apply-config --insecure --nodes "$ip" --file worker.yaml
    MAC_ADDRESS=$(talosctl get links --nodes "$ip" --talosconfig talosconfig | grep 'ens3' | awk '{print $7}')
    talosctl apply-config \
        --nodes "$ip" \
        --file worker.yaml \
        --talosconfig talosconfig \
        --config-patch "[{\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/addresses/0\", \"value\": \"$ip/24\"},
                       {\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/deviceSelector/hardwareAddr\", \"value\": \"$MAC_ADDRESS\"}]" # --dry-run \

done
