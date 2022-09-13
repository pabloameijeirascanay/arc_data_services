#!/bin/bash
exec >installKubeadm.log
exec 2>&1

sudo apt-get update

sudo sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config
sudo adduser staginguser --gecos "First Last,RoomNumber,WorkPhone,HomePhone" --disabled-password
sudo echo "staginguser:ArcPassw0rd" | sudo chpasswd

# Injecting environment variables from Azure deployment
echo '#!/bin/bash' >> vars.sh
echo $adminUsername:$1 | awk '{print substr($1,2); }' >> vars.sh
echo $SPN_CLIENT_ID:$2 | awk '{print substr($1,2); }' >> vars.sh
echo $SPN_CLIENT_SECRET:$3 | awk '{print substr($1,2); }' >> vars.sh
echo $SPN_TENANT_ID:$4 | awk '{print substr($1,2); }' >> vars.sh
echo $vmName:$5 | awk '{print substr($1,2); }' >> vars.sh
echo $location:$6 | awk '{print substr($1,2); }' >> vars.sh
echo $stagingStorageAccountName:$7 | awk '{print substr($1,2); }' >> vars.sh
echo $logAnalyticsWorkspace:$8 | awk '{print substr($1,2); }' >> vars.sh
echo $arcK8sClusterName:$9 | awk '{print substr($1,2); }' >> vars.sh
echo $templateBaseUrl:${10} | awk '{print substr($1,2); }' >> vars.sh
sed -i '2s/^/export adminUsername=/' vars.sh
sed -i '3s/^/export SPN_CLIENT_ID=/' vars.sh
sed -i '4s/^/export SPN_CLIENT_SECRET=/' vars.sh
sed -i '5s/^/export SPN_TENANT_ID=/' vars.sh
sed -i '6s/^/export vmName=/' vars.sh
sed -i '7s/^/export location=/' vars.sh
sed -i '8s/^/export stagingStorageAccountName=/' vars.sh
sed -i '9s/^/export logAnalyticsWorkspace=/' vars.sh
sed -i '10s/^/export arcK8sClusterName=/' vars.sh
sed -i '11s/^/export templateBaseUrl=/' vars.sh

chmod +x vars.sh 
. ./vars.sh

# Creating login message of the day (motd)
sudo curl -o /etc/profile.d/welcomeKubeadm.sh ${templateBaseUrl}artifacts/welcomeKubeadm.sh

# Syncing this script log to 'jumpstart_logs' directory for ease of troubleshooting
sudo -u $adminUsername mkdir -p /home/${adminUsername}/jumpstart_logs
while sleep 1; do sudo -s rsync -a /var/lib/waagent/custom-script/download/0/installKubeadm.log /home/${adminUsername}/jumpstart_logs/installKubeadm.log; done &

# Installing Azure CLI & Azure Arc extensions
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

sudo -u $adminUsername az extension add --name connectedk8s --yes
sudo -u $adminUsername az extension add --name k8s-configuration --yes
sudo -u $adminUsername az extension add --name k8s-extension --yes

echo "Log in to Azure"
sudo -u $adminUsername az login --service-principal --username $SPN_CLIENT_ID --password $SPN_CLIENT_SECRET --tenant $SPN_TENANT_ID
subscriptionId=$(sudo -u $adminUsername az account show --query id --output tsv)
export AZURE_RESOURCE_GROUP=$(sudo -u $adminUsername az resource list --query "[?name=='$stagingStorageAccountName']".[resourceGroup] --resource-type "Microsoft.Storage/storageAccounts" -o tsv)
az -v
echo ""

# Installing Helm 3
curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
sudo apt-get install apt-transport-https --yes
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm

# Create single node Kubeadm cluster
echo ""
echo "######################################################################################"
echo "Create Kubeadm cluster..." 

sudo apt update
sudo apt -y install curl apt-transport-https </dev/null


curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt -y install vim git curl wget kubelet kubeadm kubectl containerd </dev/null


sudo apt-mark hold kubelet kubeadm kubectl

kubectl version --client && kubeadm version

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

sudo sysctl --system
sudo kubeadm init

mkdir -p /home/$adminUsername/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/$adminUsername/.kube/config
sudo chown -R $adminUsername /home/$adminUsername/.kube/config

sudo -u $adminUsername kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"

# To enable a single node cluster remove the taint that limits the first node to master only service.
sudo -u $adminUsername kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Onboarding the cluster to Azure Arc
echo ""
echo "Adding extensions and providers..."
echo
sudo -u $adminUsername az provider register --namespace Microsoft.Kubernetes
sudo -u $adminUsername az provider register --namespace Microsoft.ExtendedLocation
sudo -u $adminUsername az provider register --namespace Microsoft.KubernetesConfiguration
until [[ $kubernetes_configuration == "Registered" && $extended_location == "Registered" && $kubernetes == "Registered" ]]; do
    kubernetes_configuration=$(sudo -u $adminUsername az provider show -n Microsoft.KubernetesConfiguration --query registrationState -o tsv | sed 's/\r$//')
    extended_location=$(sudo -u $adminUsername az provider show -n Microsoft.ExtendedLocation --query registrationState -o tsv | sed 's/\r$//')
    kubernetes=$(sudo -u $adminUsername az provider show -n Microsoft.Kubernetes --query registrationState -o tsv | sed 's/\r$//')
    sleep 1
done

workspaceResourceId=$(sudo -u $adminUsername az resource show --resource-group $AZURE_RESOURCE_GROUP --name $logAnalyticsWorkspace --resource-type "Microsoft.OperationalInsights/workspaces" --query id -o tsv)
sudo -u $adminUsername az connectedk8s connect --name $arcK8sClusterName --resource-group $AZURE_RESOURCE_GROUP --location $location --tags 'Project=jumpstart_azure_arc_data_services' --correlation-id "d009f5dd-dba8-4ac7-bac9-b54ef3a6671a" --debug

echo ""
sudo -u $adminUsername az k8s-extension create --name "azuremonitor-containers" --cluster-name $arcK8sClusterName --resource-group $AZURE_RESOURCE_GROUP --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers --configuration-settings logAnalyticsWorkspaceResourceID=$workspaceResourceId --debug

# Copying workload Kubeadm kubeconfig file to staging storage account
echo ""
sudo -u $adminUsername az extension add --upgrade -n storage-preview  --yes
storageAccountRG=$(sudo -u $adminUsername az storage account show --name $stagingStorageAccountName --query 'resourceGroup' | sed -e 's/^"//' -e 's/"$//')
storageContainerName="staging-kubeadm"
export localPath="/home/${adminUsername}/.kube/config"
storageAccountKey=$(sudo -u $adminUsername az storage account keys list --resource-group $storageAccountRG --account-name $stagingStorageAccountName --query [0].value | sed -e 's/^"//' -e 's/"$//')
sudo -u $adminUsername az storage container create -n $storageContainerName --account-name $stagingStorageAccountName --account-key $storageAccountKey
sudo -u $adminUsername az storage azcopy blob upload --container $storageContainerName --account-name $stagingStorageAccountName --account-key $storageAccountKey --source $localPath

# Uploading this script log to staging storage for ease of troubleshooting
echo ""
export log="/home/${adminUsername}/jumpstart_logs/installKubeadm.log"
sudo -u $adminUsername az storage azcopy blob upload --container $storageContainerName --account-name $stagingStorageAccountName --account-key $storageAccountKey --source $log
