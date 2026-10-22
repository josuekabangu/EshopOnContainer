# 04 — Le déploiement par Helm, sur un cluster neuf

## 1. Objectif

La reprise a prouvé que les charts décrivent les objets existants ([02-reprise.md](02-reprise.md)). Il restait à prouver qu'ils suffisent à **construire** l'application sur un cluster neuf, sans les manifestes de `kubernetes/`, sans `kubectl apply` et sans reprise d'objets.

**État au 22 octobre 2026 :** le script `helm/deploy.sh` déploie les 13 releases en 2 min 54 sur un cluster tout juste reconstruit. Les 12 pods démarrent sans redémarrage, et les 7 files RabbitMQ ont leur consommateur.

## 2. Le script : `helm/deploy.sh`

```bash
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
```

Il remplace la séquence de `kubectl apply` de [kubernetes/README.md](../../kubernetes/README.md).

## 3. Les choix

### L'attente : `--wait=legacy`

L'aide de Helm 4.3.1 propose trois stratégies :

| Stratégie | Ce qu'elle attend | Retenue ? |
|---|---|---|
| `hookOnly`, par défaut | Rien, sauf les *hooks* | Non : n'attend pas les pods |
| `watcher` | L'état de chaque objet, selon les conditions qu'il publie | Non : le `Gateway` et les `SealedSecret` publient des conditions propres à leur contrôleur, dont l'interprétation par ce mode n'a pas été vérifiée. Un script bloqué serait pire qu'un script qui n'attend pas |
| **`legacy`** | Le comportement de Helm 3 : `Deployment`, `StatefulSet` et leurs pods prêts | **Oui** |

### L'ordre

Les dépendances, attendues prêtes, puis les services : RabbitMQ accepte les connexions avant le premier service. L'`initContainer` `wait-for-rabbitmq` reste la sécurité quand l'ordre n'est pas garanti, par exemple quand un outil GitOps synchronisera tout en parallèle ([docs/03-kubernetes/17-ordre-de-demarrage.md](../03-kubernetes/17-ordre-de-demarrage.md)).

### Sans `--take-ownership` ni `--force-conflicts`

Sur un cluster neuf, Helm crée tout. Si l'une de ces options devenait nécessaire, c'est qu'un objet aurait été créé par un autre chemin : le script échouerait, et ce serait voulu. `set -euo pipefail` l'arrête à la première release en échec.

## 4. La preuve : une reconstruction, Helm seul

Dans PowerShell, à la racine du dépôt :

```powershell
powershell -ExecutionPolicy Bypass -File .\lab-local\scripts\rebuild.ps1 -Rebuild
```

Le rôle `workstation` a recopié le fichier d'accès au nouveau cluster dans WSL2 ([01-lab-local/19-workstation.md](../01-lab-local/19-workstation.md)). Puis, dans WSL2 :

```bash
time bash helm/deploy.sh
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }
kubectl -n eshop get pods
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
SH
```

Résultats vérifiés le 22 octobre 2026 :

```text
=== eshop-platform
STATUS: deployed
REVISION: 1
=== postgres
...
=== webhook-client
STATUS: deployed
REVISION: 1

real    2m54.535s

NAME                                READY   STATUS    RESTARTS   AGE
postgres-0                          1/1     Running   0          2m54s
redis-0                             1/1     Running   0          2m13s
rabbitmq-0                          1/1     Running   0          117s
identity-api-686d55c96d-lk7sw       1/1     Running   0          86s
...
webhook-client-6c8dcc4d8c-4bw6c     1/1     Running   0          6s
```

| Contrôle | Résultat |
|---|---|
| Reconstruction du laboratoire | `kube-control` `ok=80 changed=49 failed=0`, `kube-worker` `ok=28 changed=22 failed=0`, en 17 min 46 |
| Releases | 13 en `deployed`, révision 1 |
| Durée du déploiement | 2 min 54 |
| Ordre de démarrage | PostgreSQL, Redis, RabbitMQ, puis les services un par un |
| Pods | 12 en `1/1 Running`, aucun redémarrage |
| Files RabbitMQ | Les 7, avec 1 consommateur chacune |

Le parcours complet dans le navigateur, connexion et commande, n'a pas été rejoué après cette reconstruction ; il l'avait été la veille sur l'application déployée par `kubectl apply`, et les objets produits par les charts ont été comparés à ceux-ci ([02-reprise.md](02-reprise.md)).

## 5. Les limites

| Limite | Conséquence |
|---|---|
| Le déploiement reste lancé à la main | L'étape suivante, Argo CD, le confiera à un outil qui synchronise le cluster avec le dépôt |
| Les étiquettes d'image sont dans les fichiers de valeurs | Publier une nouvelle image demande de modifier le fichier du service ; la chaîne d'intégration continue le fera |
| Les manifestes de `kubernetes/` sont conservés | Comme trace de l'étape précédente. Ils ne doivent plus être appliqués : leurs objets appartiennent à Helm |

## 6. Commandes de référence

```bash
# Tout déployer, ou mettre à jour
bash helm/deploy.sh

# Un seul service
helm upgrade --install webapp helm/eshop-service -n eshop -f helm/values/webapp.yaml --wait=legacy

# État et historique
helm list -n eshop
helm history webapp -n eshop

# Revenir à la révision précédente
helm rollback webapp -n eshop

# Ce que produirait un chart, comparé au cluster
helm template webapp helm/eshop-service -n eshop -f helm/values/webapp.yaml | kubectl diff -f -
```

**Bilan :** un cluster neuf reçoit toute l'application eShop par une commande, `bash helm/deploy.sh`, en moins de trois minutes, sans les manifestes écrits à la main. Les charts sont désormais la description de référence de l'application.
