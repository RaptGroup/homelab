CONTROL_PLANE_IP="192.168.4.236"
WORKER_IP=("192.168.4.238" "192.168.4.237" "192.168.4.239" "192.168.4.243" "192.168.4.242")

CLUSTER_NAME="rockingham-k8s"
DISK_NAME="vda"

# echo "Generating Talos config for cluster: $CLUSTER_NAME"
# talosctl gen config $CLUSTER_NAME https://$CONTROL_PLANE_IP:6443 --install-disk /dev/$DISK_NAME
#
# echo "Applying control plane configuration"
# talosctl apply-config --insecure --nodes $CONTROL_PLANE_IP --file controlplane.yaml
#
for ip in "${WORKER_IP[@]}"; do
    echo "Applying config to worker node: $ip"
    talosctl apply-config --insecure --nodes "$ip" --file worker.yaml
done
