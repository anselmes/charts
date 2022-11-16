#!/bin/sh

set -ex

: "${HELM_VERSION:="v3.6.3"}"
: "${KUBE_VERSION:="v1.23.12"}"
: "${MINIKUBE_VERSION:="v1.25.2"}"
: "${CALICO_VERSION:="v3.20"}"
: "${YQ_VERSION:="v4.6.0"}"

: ${OSH_INFRA_EXTRA_HELM_ARGS:=""}
: ${OSH_INFRA_EXTRA_HELM_ARGS_POSTGRESQL:=""}

export DEBCONF_NONINTERACTIVE_SEEN=true
export DEBIAN_FRONTEND=noninteractive

sudo swapoff -a

echo "DefaultLimitMEMLOCK=16384" | sudo tee -a /etc/systemd/system.conf
sudo systemctl daemon-reexec

# NOTE: Add docker repo
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo apt-key fingerprint 0EBFCD88
sudo add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"

# Install required packages for K8s on host
wget -q -O- 'https://download.ceph.com/keys/release.asc' | sudo apt-key add -
RELEASE_NAME=$(grep 'CODENAME' /etc/lsb-release | awk -F= '{print $2}')
sudo add-apt-repository "deb https://download.ceph.com/debian-nautilus/
${RELEASE_NAME} main"

sudo -E apt-get update
sudo -E apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io=1.5.11-1 \
  socat \
  jq \
  util-linux \
  bridge-utils \
  iptables \
  conntrack \
  libffi-dev \
  ipvsadm \
  make \
  bc \
  git-review \
  notary \
  ceph-common \
  rbd-nbd \
  nfs-common

# Prepare tmpfs for etcd when running on CI
# CI VMs can have slow I/O causing issues for etcd
# Only do this on CI (when user is zuul), so that local development can have a kubernetes
# environment that will persist on reboot since etcd data will stay intact
if [ "$USER" = "zuul" ]; then
  sudo mkdir -p /var/lib/minikube/etcd
  sudo mount -t tmpfs -o size=512m tmpfs /var/lib/minikube/etcd
fi

# Install YQ
wget https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64.tar.gz -O - | tar xz && sudo mv yq_linux_amd64 /usr/local/bin/yq

# Install minikube and kubectl
URL="https://storage.googleapis.com"
sudo -E curl -sSLo /usr/local/bin/minikube "${URL}"/minikube/releases/"${MINIKUBE_VERSION}"/minikube-linux-amd64
sudo -E curl -sSLo /usr/local/bin/kubectl "${URL}"/kubernetes-release/release/"${KUBE_VERSION}"/bin/linux/amd64/kubectl
sudo -E chmod +x /usr/local/bin/minikube
sudo -E chmod +x /usr/local/bin/kubectl

# Install Helm
TMP_DIR=$(mktemp -d)
sudo -E bash -c \
  "curl -sSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar -zxv --strip-components=1 -C ${TMP_DIR}"
sudo -E mv "${TMP_DIR}"/helm /usr/local/bin/helm
rm -rf "${TMP_DIR}"

# NOTE: Deploy kubernetes using minikube. A CNI that supports network policy is
# required for validation; use calico for simplicity.
sudo -E systemctl enable --now kubelet

sudo -E minikube config set kubernetes-version "${KUBE_VERSION}"
sudo -E minikube config set vm-driver none

sudo -E minikube start \
  --docker-env HTTP_PROXY="${HTTP_PROXY}" \
  --docker-env HTTPS_PROXY="${HTTPS_PROXY}" \
  --docker-env NO_PROXY="${NO_PROXY},10.96.0.0/12" \
  --network-plugin=cni \
  --wait=apiserver,system_pods \
  --apiserver-names="$(hostname -f)" \
  --extra-config=controller-manager.allocate-node-cidrs=true \
  --extra-config=controller-manager.cluster-cidr=192.168.0.0/16 \
  --extra-config=kube-proxy.mode=ipvs \
  --extra-config=apiserver.service-node-port-range=1-65535 \
  --extra-config=kubelet.cgroup-driver=systemd \
  --extra-config=kubelet.resolv-conf=/run/systemd/resolve/resolv.conf \
  --feature-gates=RemoveSelfLink=false \
  --embed-certs

sudo -E minikube addons list

curl -LSs https://docs.projectcalico.org/archive/"${CALICO_VERSION}"/manifests/calico.yaml -o /tmp/calico.yaml

sed -i -e 's#docker.io/calico/#quay.io/calico/#g' /tmp/calico.yaml

# Download images needed for calico before applying manifests, so that `kubectl wait` timeout
# for `k8s-app=kube-dns` isn't reached by slow download speeds
awk '/image:/ { print $2 }' /tmp/calico.yaml | xargs -I{} sudo docker pull {}

kubectl apply -f /tmp/calico.yaml

# Note: Patch calico daemonset to enable Prometheus metrics and annotations
tee /tmp/calico-node.yaml <<EOF
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9091"
    spec:
      containers:
        - name: calico-node
          env:
            - name: FELIX_PROMETHEUSMETRICSENABLED
              value: "true"
            - name: FELIX_PROMETHEUSMETRICSPORT
              value: "9091"
            - name: FELIX_IGNORELOOSERPF
              value: "true"
EOF
kubectl -n kube-system patch daemonset calico-node --patch "$(cat /tmp/calico-node.yaml)"

kubectl get pod -A
kubectl -n kube-system get pod -l k8s-app=kube-dns

# NOTE: Wait for dns to be running.
# END=$(($(date +%s) + 240))
# until kubectl --namespace=kube-system \
#   get pods -l k8s-app=kube-dns --no-headers -o name | grep -q "^pod/coredns"; do
#   NOW=$(date +%s)
#   [ "${NOW}" -gt "${END}" ] && exit 1
#   echo "still waiting for dns"
#   sleep 10
# done
# kubectl -n kube-system wait --timeout=240s --for=condition=Ready pods -l k8s-app=kube-dns

# add node labels
kubectl label node --all openstack-control-plane=enabled --overwrite
kubectl label node --all ucp-control-plane=enabled --overwrite

# create maas namespace
kubectl create namespace ucp --dry-run=client -o yaml | kubectl apply -f -

# configure storageclass
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: general
  labels:
    addonmanager.kubernetes.io/mode: EnsureExists
provisioner: k8s.io/minikube-hostpath
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

# deploy ingress
cat <<EOF >/tmp/ingress.yaml
controller:
  admissionWebhooks:
    enabled: false
  config:
    enable-underscores-in-headers: "true"
    ssl-reject-handshake: "true"
  ingressClass: maas-ingress
  ingressClassByName: true
  ingressClassResource:
    controllerValue: k8s.io/maas-ingress
    enabled: true
    name: maas-ingress
  kind: DaemonSet
  nodeSelector:
    ucp-control-plane: enabled
defaultBackend:
  enabled: true
  nodeSelector:
    ucp-control-plane: enabled
fullnameOverride: maas-ingress
udp:
  "53": ucp/maas-region:region-dns
  "514": ucp/maas-syslog:syslog
EOF

helm dependency update ./openstack-helm-infra/ingress
helm upgrade --install ingress-ucp ./openstack-helm-infra/ingress \
  --namespace=ucp \
  --values /tmp/ingress.yaml \
  ${OSH_INFRA_EXTRA_HELM_ARGS} \
  ${OSH_INFRA_EXTRA_HELM_ARGS_INGRESS_OPENSTACK}

./openstack-helm-infra/tools/deployment/common/wait-for-pods.sh ucp
