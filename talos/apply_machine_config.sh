#!/bin/bash
CONTROL_PLANE_IP="192.168.4.85"
ADDITIONAL_CONTROL_PLANE_NODES=("192.168.4.86" "192.168.4.87")
WORKER_IP=("192.168.4.164" "192.168.4.124" "192.168.4.254" "192.168.4.83" "192.168.4.84")

CLUSTER_NAME="rockingham-k8s"
DISK_NAME="vda"

# echo "Generating Talos config for cluster: $CLUSTER_NAME"
# talosctl gen config $CLUSTER_NAME https://$CONTROL_PLANE_IP:6443 --install-disk /dev/$DISK_NAME

# echo "###########################################################"
# echo "########## INITIAL CONTROL-PLANE CONFIGURATION ############"
# echo "###########################################################"
# echo "Applying initial control plane configuration..."
# echo "Applying controlplane config to node: $CONTROL_PLANE_IP"
# MAC_ADDRESS=$(talosctl get links --insecure --nodes "$CONTROL_PLANE_IP" --talosconfig talosconfig | grep 'ens3' | awk '{print $6}')
# talosctl apply-config \
#     --insecure \
#     --nodes "$CONTROL_PLANE_IP" \
#     --file controlplane.yaml \
#     --talosconfig talosconfig \
#     --config-patch "[{\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/addresses/0\", \"value\": \"$CONTROL_PLANE_IP/24\"},
#                 {\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/deviceSelector/hardwareAddr\", \"value\": \"$MAC_ADDRESS\"}]"

# echo "#############################################################"
# echo "########### WORKER NODES CONFIGURATION ######################"
# echo "#############################################################"
# for ip in "${WORKER_IP[@]}"; do
#     echo "Applying config to worker node: $ip"
#     MAC_ADDRESS=$(talosctl get --insecure links --nodes "$ip" --talosconfig talosconfig | grep 'ens3' | awk '{print $6}')
#     talosctl apply-config \
#         --insecure \
#         --nodes "$ip" \
#         --file worker.yaml \
#         --talosconfig talosconfig \
#         --config-patch "[{\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/addresses/0\", \"value\": \"$ip/24\"},
#                        {\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/deviceSelector/hardwareAddr\", \"value\": \"$MAC_ADDRESS\"}]" # --dry-run \
#
# done

# echo "#############################################################"
# echo "########### SET TALOSCONFIG CLUSTER ENDPOINT ################"
# echo "#############################################################"
# talosctl --talosconfig=./talosconfig config endpoints $CONTROL_PLANE_IP

# echo "#############################################################"
# echo "########### BOOTSTRAP CONTROLPLANE ETCD CLUSTER #############"
# echo "#############################################################"
# talosctl bootstrap --nodes $CONTROL_PLANE_IP --talosconfig=./talosconfig

# echo "#############################################################"
# echo "########### SET KUBECONFIG AND CONTEXT ######################"
# echo "#############################################################"
# talosctl kubeconfig --nodes $CONTROL_PLANE_IP --talosconfig=./talosconfig

# echo "#############################################################"
# echo "################## CHECK CLUSTER HEALTH #####################"
# echo "#############################################################"
# talosctl --nodes $CONTROL_PLANE_IP --talosconfig=./talosconfig health

# echo "#############################################################"
# echo "############ REGISTER ADDITIONAL CONTROLPLANE NODES #########"
# echo "#############################################################"
for ip in "${ADDITIONAL_CONTROL_PLANE_NODES[@]}"; do
    echo "Applying config to additional control plane node: $ip"
    MAC_ADDRESS=$(talosctl get links --insecure --nodes "$ip" --talosconfig talosconfig | grep 'ens3' | awk '{print $6}')
    talosctl apply-config \
        --nodes "$ip" \
        --insecure \
        --file controlplane.yaml \
        --talosconfig talosconfig \
        --config-patch "[{\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/addresses/0\", \"value\": \"$ip/24\"},
                       {\"op\": \"replace\", \"path\": \"/machine/network/interfaces/0/deviceSelector/hardwareAddr\", \"value\": \"$MAC_ADDRESS\"}]"

done
