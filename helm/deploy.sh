#!/usr/bin/env bash
# Déploie toute l'application eShop sur le cluster du laboratoire : 13 releases Helm.
# Prérequis : le cluster construit par lab-local/ (rôles envoy_gateway, metallb, lab_dns, workstation).
# Relançable : helm upgrade --install met à jour ce qui existe, crée ce qui manque.
#
# Usage, depuis n'importe où dans le dépôt :
#   bash helm/deploy.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NS=eshop

# release <nom> <chart> [options] : une release, avec helm/values/<nom>.yaml
release() {
  local name=$1 chart=$2
  shift 2
  echo "=== $name"
  helm upgrade --install "$name" "helm/$chart" -n "$NS" -f "helm/values/$name.yaml" "$@" \
    | grep -E '^(STATUS|REVISION):'
}

# 1. Ce que partagent les services ; crée l'espace de noms au premier déploiement
release eshop-platform eshop-platform --create-namespace

# 2. Les dépendances, attendues prêtes : les services s'y connectent dès leur démarrage
for d in postgres redis rabbitmq; do
  release "$d" "$d" --wait=legacy --timeout 10m
done

# 3. Les services d'eShop, tous sur le chart commun
for s in identity-api catalog-api basket-api ordering-api order-processor payment-processor \
         webhooks-api webapp webhook-client; do
  release "$s" eshop-service --wait=legacy --timeout 10m
done

echo
helm list -n "$NS"
