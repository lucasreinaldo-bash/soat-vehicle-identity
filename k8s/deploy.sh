#!/usr/bin/env bash
# Publica o serviço de identidade no cluster Kubernetes local (minikube).
# É o mesmo script executado pelo pipeline de CD a cada merge na main.
set -euo pipefail

NAMESPACE="vehicle-identity"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1/3 Aplicando os manifestos"
kubectl apply -f "${ROOT_DIR}/k8s/00-namespace.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/01-configmap.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/02-secret.yaml"

# O realm vira ConfigMap a partir do mesmo JSON usado no Docker Compose: uma
# única fonte da verdade para a configuração do Keycloak.
kubectl -n "${NAMESPACE}" create configmap vehicle-sales-realm \
  --from-file="${ROOT_DIR}/realm/vehicle-sales-realm.json" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${ROOT_DIR}/k8s/03-postgres.yaml"
# Configuração mudou -> o pod do Keycloak precisa reiniciar para lê-la. O hash
# na anotação do pod torna isso determinístico.
HASH=$(cat "${ROOT_DIR}/k8s/01-configmap.yaml" "${ROOT_DIR}/k8s/02-secret.yaml" \
  "${ROOT_DIR}/realm/vehicle-sales-realm.json" | shasum -a 256 | cut -c1-16)
sed "s/__CONFIG_HASH__/${HASH}/" "${ROOT_DIR}/k8s/04-keycloak.yaml" | kubectl apply -f -

echo "==> 2/3 Aguardando o banco de identidade"
kubectl -n "${NAMESPACE}" rollout status deployment/identity-db --timeout=180s

echo "==> 3/3 Aguardando o Keycloak"
kubectl -n "${NAMESPACE}" rollout status deployment/keycloak --timeout=420s

echo
kubectl -n "${NAMESPACE}" get all
echo
echo "Serviço de identidade publicado. Para acessar do host:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/keycloak 8180:8080"
echo "  Cadastro de cliente: http://localhost:8180/realms/vehicle-sales/account"
