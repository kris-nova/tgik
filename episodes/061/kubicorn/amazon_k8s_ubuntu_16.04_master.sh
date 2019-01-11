# ------------------------------------------------------------------------------------------------------------------------
# We are explicitly not using a templating language to inject the values as to encourage the user to limit their
# use of templating logic in these files. By design all injected values should be able to be set at runtime,
# and the shell script real work. If you need conditional logic, write it in bash or make another shell script.
# ------------------------------------------------------------------------------------------------------------------------

# Specify the Kubernetes version to use.
KUBERNETES_VERSION="1.13.2"
KUBERNETES_CNI="0.6.0"

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
touch /etc/apt/sources.list.d/kubernetes.list
sh -c 'echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list'

# Has to be configured before installing kubelet, or kubelet has to be restarted to pick up changes
mkdir -p /etc/systemd/system/kubelet.service.d
touch /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf
cat << EOF  > /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cloud-provider=aws"
EOF

chmod 0600 /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf

apt-get update -y
apt-get install -y \
    socat \
    ebtables \
    docker.io \
    apt-transport-https \
    kubelet=${KUBERNETES_VERSION}-00 \
    kubeadm=${KUBERNETES_VERSION}-00 \
    kubernetes-cni=${KUBERNETES_CNI}-00 \
    cloud-utils \
    jq


systemctl enable docker
systemctl start docker

PRIVATEIP=$(ec2metadata --local-ipv4 | cut -d " " -f 2)
PUBLICIP=$(ec2metadata --public-ipv4 | cut -d " " -f 2)
TOKEN=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDTOKEN')
PORT=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDPORT | tonumber')

# Necessary for joining a cluster with AWS information
HOSTNAME=$(hostname -f)

cat << EOF  > "/etc/kubicorn/kubeadm-config.yaml"
apiVersion: kubeadm.k8s.io/v1beta1
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: ${TOKEN}
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
localAPIEndpoint:
  advertiseAddress: ${PRIVATEIP}
  bindPort: ${PORT}
nodeRegistration:
  criSocket: /var/run/dockershim.sock
  kubeletExtraArgs:
    cloud-provider: aws
    pod-infra-container-image: k8s.gcr.io/pause:3.1
  name: ${HOSTNAME}
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
apiServer:
  certSANs:
  - ${PUBLICIP}
  - ${HOSTNAME}
  - ${PRIVATEIP}
  extraArgs:
    cloud-provider: aws
    audit-dynamic-configuration: "true"
    feature-gates: DynamicAuditing=true
    runtime-config: auditregistration.k8s.io/v1alpha1=true
  timeoutForControlPlane: 4m0s
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controlPlaneEndpoint: "${PUBLICIP}:${PORT}"
controllerManager:
  extraArgs:
    cloud-provider: aws
dns:
  type: CoreDNS
  imageTag: ${COREDNS_IMAGE_TAGS[0]}
etcd:
  local:
    dataDir: /var/lib/etcd
    imageTag: ${ETCD_IMAGE_TAGS[0]}
imageRepository: k8s.gcr.io
kubernetesVersion: ${KUBERNETES_VERSION}
networking:
  dnsDomain: cluster.local
  podSubnet: 192.168.0.0/16
  serviceSubnet: 10.96.0.0/12
scheduler: {}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
bindAddress: 0.0.0.0
clientConnection:
  acceptContentTypes: ""
  burst: 10
  contentType: application/vnd.kubernetes.protobuf
  kubeconfig: /var/lib/kube-proxy/kubeconfig.conf
  qps: 5
clusterCIDR: 192.168.0.0/16
configSyncPeriod: 15m0s
conntrack:
  max: null
  maxPerCore: 32768
  min: 131072
  tcpCloseWaitTimeout: 1h0m0s
  tcpEstablishedTimeout: 24h0m0s
enableProfiling: false
healthzBindAddress: 0.0.0.0:10256
hostnameOverride: ""
iptables:
  masqueradeAll: false
  masqueradeBit: 14
  minSyncPeriod: 0s
  syncPeriod: 30s
ipvs:
  excludeCIDRs: null
  minSyncPeriod: 0s
  scheduler: ""
  syncPeriod: 30s
metricsBindAddress: 127.0.0.1:10249
mode: ""
nodePortAddresses: null
oomScoreAdj: -999
portRange: ""
resourceContainer: /kube-proxy
udpIdleTimeout: 250ms
EOF

kubeadm reset
kubeadm init --config /etc/kubicorn/kubeadm-config.yaml


kubectl apply \
  -f https://docs.projectcalico.org/v3.2/getting-started/kubernetes/installation/hosted/rbac-kdd.yaml \
  -f https://docs.projectcalico.org/v3.2/getting-started/kubernetes/installation/hosted/kubernetes-datastore/calico-networking/1.7/calico.yaml \
  --kubeconfig /etc/kubernetes/admin.conf

kubectl apply \
    -f  https://raw.githubusercontent.com/kubernetes/kubernetes/release-1.8/cluster/addons/storage-class/aws/default.yaml \
    --kubeconfig /etc/kubernetes/admin.conf

mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube