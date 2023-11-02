#!/bin/bash -e

# Azure specific variables, unset if you are not using Azure
AZURE_RG="kernelci-api-staging"
LOCATION="eastus"

CONTEXT="kernelci-api-staging-1-admin"
CLUSTER_NAME="kernelci-api-staging-1"
NS="kernelci-api-testns"
SECRET=$(openssl rand -hex 32)
DNSLABEL="kernelci-api-staging1"
# mongodb+srv://username:password@customname.mongodb.net
MONGO=""

# This might contain IP variable
if [ -f api-initial-deploy.cfg ]; then
    source api-initial-deploy.cfg
fi

function fetch_static_ip {
    # az network public-ip create --resource-group MC_myResourceGroup_myAKSCluster_eastus --name myAKSPublicIP --sku Standard --allocation-method static --query publicIp.ipAddress -o tsv
    if [ -z "$AZURE_RG" ]; then
        echo "AZURE_RG not set, not an Azure deployment"
        echo "You need to retrieve the static IP address of the ingress controller and set the IP variable in api-initial-deploy.cfg"
        exit 1
    fi
    # TODO: specify zone
    az network public-ip create --resource-group $AZURE_RG --name kernelci-api-staging-ip --sku Standard --allocation-method static --query publicIp.ipAddress -o tsv
    IP=$(az network public-ip show --resource-group $AZURE_RG --name kernelci-api-staging-ip --query ipAddress -o tsv)
    echo "export IP=\"${IP}\"" >> api-initial-deploy.cfg
}

function azure_ip_permissions {
    echo "Assign permissions for cluster to read/retrieve IPs"
    echo "Retrieving cluster resource group..."
    RG_SCOPE=$(az group show --name $AZURE_RG --query id -o tsv)
    echo "Retrieving cluster client id..."
    CLIENT_ID=$(az aks show --name $CLUSTER_NAME --resource-group $AZURE_RG --query identity.principalId -o tsv)
    echo "Assigning permissions..."
    az role assignment create \
        --assignee ${CLIENT_ID} \
        --role "Network Contributor" \
        --scope ${RG_SCOPE}
}

function local_setup {
    # obviously, do we have working kubectl?
    if ! command -v kubectl &> /dev/null
    then
        echo "kubectl not found, exiting"
        exit
    fi
    if ! kubectl config get-contexts -o name | grep -q ${CONTEXT}
    then
        echo "Context ${CONTEXT} not found, exiting"
        exit
    fi
    
    # helm
    if ! command -v helm &> /dev/null
    then
        echo "helm not found, downloading...(https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3)"
        echo "Do you want to proceed or you will install helm using your own means?"
        select yn in "Yes" "No"; do
            case $yn in
                Yes ) break;;
                No ) exit;;
            esac
        done
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
        # Clean up poodle :)
        rm get_helm.sh
        echo "helm installed"
    fi

    # ./yq (as we install mike farah go version)
    # if file yq exist and executable, we assume it is correct version
    if [ ! -f yq ]; then
        echo "yq not found, downloading..."
        VERSION=v4.35.2
        BINARY=yq_linux_amd64
        wget https://github.com/mikefarah/yq/releases/download/${VERSION}/${BINARY} -O yq
        chmod +x yq
        echo "yq installed"
    fi

    # check if MONGO is set
    if [ -z "$MONGO" ]; then
        echo "MONGO not set, exiting"
        exit
    fi
}

# function for namespace
function recreate_ns {
    # Delete namespace
    # TODO(nuclearcat): this command might hang, add timeout?
    echo "Deleting namespace ${NS}..."
    kubectl --context=${CONTEXT} delete namespace ${NS} || true
#    echo "Sleeping..."
#    sleep 5

    # Create namespace
    echo "Creating namespace ${NS}..."2
    kubectl --context=${CONTEXT} create namespace ${NS}
}

function update_fqdn {
    echo "Getting public ip ResourceID for ip ${IP}..."
    PUBLICIPID=$(az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$IP')].[id]" --output tsv)
    if [ "$PUBLICIPID" == "" ]; then
        echo "FATAL: IP ResourceID not found"
        exit 1
    fi

    # Update public IP address with DNS name
    az network public-ip update --ids $PUBLICIPID --dns-name $DNSLABEL

    # Display the FQDN
    az network public-ip show --ids $PUBLICIPID --query "[dnsSettings.fqdn]" --output tsv

}

function deploy_once {
    # Set secret
    echo "Setting secret..."
    kubectl --context=${CONTEXT} create secret generic kernelci-api-secret --from-literal=secret-key=${SECRET} --namespace=${NS}
    echo "Secret: ${SECRET}" >> .api-secret.txt

    # replace MONGOCONNECTSTRING in deploy/configmap.yaml.example to ${MONGO} and save to deploy/configmap.yaml
    cp deploy/configmap.yaml.example deploy/configmap.yaml
    ./yq e ".data.mongo_service=\"${MONGO}\"" deploy/configmap.yaml

    # Update all namespaces in deploy/* to ${NS}
    echo "Updating namespaces in deploy/* to ${NS}..."
    
    ./yq e ".metadata.namespace=\"${NS}\"" deploy/*.yaml

    # Deploy configmap
    echo "Deploying configmap..."
    kubectl --context=${CONTEXT} create -f deploy/configmap.yaml --namespace=${NS}

    # HELM misc stuff to prepare
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo add stable https://charts.helm.sh/stable
    helm repo add jetstack https://charts.jetstack.io    
    helm repo update
    # helm show values ingress-nginx/ingress-nginx

}

function deploy_update_nginx {
    echo "Deploying ingress-nginx..."
    helm uninstall ingress-nginx --namespace=${NS} || true
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        -n ${NS} \
        --set controller.replicaCount=1 \
        --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
        --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux \
        --set controller.service.externalTrafficPolicy=Local \
        --set controller.service.loadBalancerIP="${IP}" \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"="${DNSLABEL}" \
        --set controller.publishService.enabled=true \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-resource-group"="${AZURE_RG}" \
        --set controller.ingressClassResource.name=nginx-api \
        --set controller.ingressClassResource.controllerValue="k8s.io/ingress-nginx-api" \
        --set controller.ingressClassResource.enabled=true \
        --set controller.IngressClassByName=true \
        --set controller.scope.enabled=true \
        --set controller.scope.namespace=${NS} \
        --set rbac.create=true \
        --set rbac.scope=true \


    # You might spot the following warning in the output:
    # "It may take a few minutes for the LoadBalancer IP to be available."
    # You can watch the status by running 'kubectl --namespace kernelci-api-testns get services -o wide -w ingress-nginx-controller'
    # Other diagnostic commands: 
    # kubectl --namespace=kernelci-api-testns logs svc/ingress-nginx-controller
    # kubectl describe service ingress-nginx-controller --namespace=kernelci-api-testns
    # kubectl --namespace=kernelci-api-testns get svc
}

function deploy_update_cert_manager {
    # Deploy cert-manager
    echo "Deploying cert-manager..."
    helm install cert-manager jetstack/cert-manager --namespace=${NS} --set installCRDs=true
}

function deploy_update {
    # Deploy redis
    echo "Deploying redis..."
    kubectl --context=${CONTEXT} apply -f deploy/redis.yaml --namespace=${NS}

    # Deploy API
    echo "Deploying API Deployment..."
    kubectl --context=${CONTEXT} apply -f deploy/api.yaml --namespace=${NS}

    # TODO: Deploy only once, we rarely need to update them
    deploy_update_nginx
    deploy_update_cert_manager


    # Update ingress.yaml with ${DNSLABEL}.${LOCATION}.cloudapp.azure.com
    FULLHOSTNAME="${DNSLABEL}.${LOCATION}.cloudapp.azure.com"
    ./yq e "select(document_index == 0) | .spec.tls[0].hosts[0]=\"${FULLHOSTNAME}\"" deploy/ingress.yaml
    ./yq e "select(document_index == 0) | .spec.rules[0].host=\"${FULLHOSTNAME}\"" deploy/ingress.yaml

    # Deploy API
    echo "Deploying API Ingress..."
    kubectl --context=${CONTEXT} apply -f deploy/ingress.yaml --namespace=${NS}
}

function setup_admin {
    # metadata: labels: app: "api"
    API_POD_NAME=$(kubectl get pods --namespace=${NS} -l "app=api" -o jsonpath="{.items[0].metadata.name}")
    echo "Setting up admin user..."
    kubectl exec --namespace=${NS} -it $API_POD_NAME -- python3 -m api.admin --mongo ${MONGO} --email bot@kernelci.org
}

echo "This script will deploy kernelci API to your cluster"

# Local toolset setup
local_setup

# if IP not set, initial set, allocate static ip and update fqdn
if [ -z "$IP" ]; then
    echo "Likely you are running script first time"
    echo "It will assign static IP and update DNS"
    echo "Then give your cluster permission to use public IPs"
    fetch_static_ip
    update_fqdn
    azure_ip_permissions
    echo "Waiting IP to propagate, 30 seconds..."
    sleep 30
fi

recreate_ns
deploy_once
deploy_update
setup_admin

echo "----------------------------------------"
echo "Done"
echo "Test API availability by curl https://${DNSLABEL}.${LOCATION}.cloudapp.azure.com/latest/"
echo "Now you need to issue token for admin user by: kci user token admin"
echo "Then using this token create more users"

