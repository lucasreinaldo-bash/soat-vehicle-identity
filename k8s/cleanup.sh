#!/usr/bin/env bash
# Remove o serviço de identidade do cluster, incluindo o volume do banco.
set -euo pipefail
kubectl delete namespace vehicle-identity --ignore-not-found
