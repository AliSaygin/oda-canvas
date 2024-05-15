#!/bin/bash

set -e

cd $(dirname -- $0)

AUTH_PATH="jwt-k8s-sman"

Y='\033[0;33m'
NC='\033[0m' # No Color

if [ ! $1 ] || ([ "$1" != "AWS" ] && [ "$1" != "GCP" ] && [ "$1" != "VPS2" ]) ; then
	echo "COMMAND [AWS|GCP|VPS2]"
	echo ""
	echo "Deploy and configure HashiCorp Vault as canvas vault"
    exit 1
fi

SRCDIR=.
BASEDIR=`pwd`

if [ ! -d $SRCDIR ]; then
	echo "Please check source directory (${SRCDIR})"
	exit 1
fi

cd $SRCDIR

echo -e "${Y}Deploy and configure HashiCorp Vault (in DEV mode)${NC}"
echo -e "${Y}Installing HashiCorp Vault in DEV mode${NC}"
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install canvas-vault-hc hashicorp/vault --namespace canvas-vault --create-namespace --values canvas-vault-hc/values.yaml --wait
             # --version 0.24.0

echo "waiting up to 30 seconds for the vault to be ready"
kubectl -n canvas-vault wait -l  statefulset.kubernetes.io/pod-name=canvas-vault-hc-0 --for=condition=ready pod --timeout=30s

echo -e "${Y}Creating public route to canvas vault${NC}"
kubectl apply -f canvas-vault-hc/canvas-vault-hc-vs-$1.yaml


echo -e "${Y}Configuring HashiCorp Vault to accept K8S Service Account Issuer${NC}"
X=`kubectl exec -n canvas-vault -it canvas-vault-hc-0 -- vault auth list | grep "$AUTH_PATH" || true`
if [ "$X" == "" ] ; then
    echo -e "\t${Y}exec vault enable${NC}"
    kubectl exec -n canvas-vault -it canvas-vault-hc-0 -- vault auth enable -path "$AUTH_PATH" jwt
else
	echo -e "\t${Y}auth method "$AUTH_PATH" already enabled${NC}"
fi

# see also: https://developer.hashicorp.com/vault/docs/auth/jwt/oidc-providers/kubernetes#using-service-account-issuer-discovery
CRB=`kubectl get clusterrolebinding oidc-reviewer 2>/dev/null | grep "service-account-issuer-discovery" || true`
if [ "$CRB" == "" ]; then
    echo -e "\t${Y}create cluster role binding oidc-reviewer${NC}"
    kubectl create clusterrolebinding oidc-reviewer  --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated
else 
    echo -e "\t${Y}cluster role binding oidc-reviewer already exits${NC}"
fi

echo -e "\t${Y}exec vault write oidc_discovery_url${NC}"
if [ "$1" == "AWS" ]; then
# setup on AWS
    kubectl exec -n canvas-vault -it canvas-vault-hc-0 -- vault write auth/$AUTH_PATH/config oidc_discovery_url=https://kubernetes.default.svc.cluster.local oidc_discovery_ca_pem=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    ##old kubectl exec -n canvas-vault -it canvas-vault-hc-0 -- vault write auth/$AUTH_PATH/config oidc_discovery_url=https://container.googleapis.com/v1/projects/tmforum-oda-component-cluster/locations/europe-west3/clusters/ihc-dt oidc_discovery_ca_pem=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
fi
if [ "$1" == "GCP" ]; then
    # setup on GCP
    ISSUER="$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')"
    kubectl exec -n canvas-vault -it canvas-vault-hc-0 -- vault write auth/$AUTH_PATH/config oidc_discovery_url=$ISSUER
fi
if [ "$1" == "VPS2" ]; then
    # setup on VPS2
    ISSUER="$(kubectl get --raw /.well-known/openid-configuration | jq -r '.issuer')"
    kubectl exec -n canvas-vault -it canvas-vault-hc-0 -- vault write auth/$AUTH_PATH/config oidc_discovery_url=$ISSUER oidc_discovery_ca_pem=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt 
fi

cd $BASEDIR

