# 02 — La reprise des objets existants, sans coupure

## 1. Objectif

Les objets de l'application tournaient déjà, créés par `kubectl apply`. Les supprimer pour les recréer par Helm aurait coupé le service, et, pour les bases, aurait exigé de la prudence avec les volumes. Ce guide décrit leur reprise par Helm, sans recréation.

**État au 22 octobre 2026 :** les 13 releases ont repris les objets existants. Les pods de `catalog-api`, `order-processor`, `payment-processor`, PostgreSQL, Redis et RabbitMQ n'ont pas été recréés ; les données sont intactes.

## 2. La méthode, pour chaque release

| Étape | Commande | But |
|---|---|---|
| 1. Comparer | `helm template ... \| kubectl diff -f -` | Voir ce que le chart changerait aux objets **réels** du cluster. Rien d'inattendu ne doit apparaître |
| 2. Reprendre | `helm upgrade --install ... --take-ownership --force-conflicts` | Helm prend possession des objets, sans les recréer |
| 3. Vérifier | Le pod, son âge, le service | Rien n'a été cassé |

`kubectl diff` compare avec l'état réel, et non avec les fichiers de `kubernetes/` : c'est la vérification la plus fiable. Une modification interdite, par exemple d'un champ non modifiable, y apparaîtrait aussi, comme une erreur de l'API.

## 3. Premier essai : catalog-api

### Le `diff`

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

helm template catalog-api helm/eshop-service -n eshop -f helm/values/catalog-api.yaml > /tmp/catalog-api.yaml
kubectl diff -f - < /tmp/catalog-api.yaml
```

Résultat vérifié le 22 octobre 2026 :

| Objet | Différences |
|---|---|
| `Deployment` | Étiquettes de l'objet seulement : **rien dans `spec.template`**, donc aucun pod recréé |
| `SealedSecret` | Étiquettes seulement : mêmes valeurs chiffrées, même nom |
| `Service` | Étiquettes, et `targetPort: 8080` devenu `targetPort: http`, le même port désigné par son nom |

### `--take-ownership`

Helm refuse normalement de gérer un objet qu'il n'a pas créé. Depuis Helm 3.17, l'option `--take-ownership` lui permet d'en prendre possession ; sa présence dans Helm 4.3.1 a été vérifiée dans l'aide de `helm install`.

```bash
helm install catalog-api helm/eshop-service -n eshop -f helm/values/catalog-api.yaml --take-ownership
```

```text
Error: INSTALLATION FAILED: conflict occurred while applying object eshop/catalog-api /v1, Kind=Service:
Apply failed with 1 conflict: conflict with "kubectl-client-side-apply" using v1: .spec.ports[port=8080,protocol="TCP"].targetPort
```

La release est restée à l'état `failed`, avec des objets à demi repris : le `Deployment` portait déjà les annotations de Helm. Le pod n'avait pas bougé, et le catalogue répondait toujours.

### La cause : Helm 4 applique côté serveur

Helm 4 applique ses objets **côté serveur** (*server-side apply*), là où Helm 3 les appliquait côté client. Dans ce mode, l'API du cluster enregistre le **propriétaire de chaque champ**. Le champ `targetPort` appartenait au dernier `kubectl apply`, qui y avait écrit `8080` ; Helm voulait y écrire `http`. L'API refuse d'écraser en silence la valeur d'un autre gestionnaire.

`--take-ownership` lève la vérification propre à Helm, ses annotations de propriété. Les conflits de **champs**, eux, sont vérifiés par l'API.

### `--force-conflicts`

L'aide de `helm upgrade` en Helm 4.3.1 :

```text
--force-conflicts    if set server-side apply will force changes against conflicts
--server-side string must be "true", "false" or "auto" ... (default "auto")
--take-ownership     if set, upgrade will ignore the check for helm annotations and take ownership of the existing resources
```

Forcer était sans risque : le seul champ en conflit désignait le même port. La reprise s'est terminée par une mise à jour de la release en échec :

```bash
helm upgrade catalog-api helm/eshop-service -n eshop -f helm/values/catalog-api.yaml \
  --take-ownership --force-conflicts
```

Résultat vérifié : `STATUS: deployed`, `REVISION: 2` ; le même pod, `catalog-api-84cbb9967f-v4d4x`, âgé de 18 h ; `targetPort: http` et les annotations `meta.helm.sh/release-name` et `meta.helm.sh/release-namespace` sur le `Service`.

Pour les releases suivantes, la commande est devenue `helm upgrade --install ... --take-ownership --force-conflicts` : `--install` crée la release si elle n'existe pas.

L'annotation `kubectl.kubernetes.io/last-applied-configuration`, laissée par le `kubectl apply` d'origine, est restée sur les objets repris : elle n'a plus aucun rôle. Elle disparaît d'elle-même sur un cluster reconstruit, où Helm crée tout.

## 4. Les huit autres services

```bash
for s in identity-api basket-api ordering-api order-processor payment-processor webhooks-api webapp webhook-client; do
  echo "=================== $s"
  helm lint helm/eshop-service -f helm/values/$s.yaml | grep -E 'ERROR|failed'
  helm template $s helm/eshop-service -n eshop -f helm/values/$s.yaml \
    | kubectl diff -f - 2>&1 \
    | grep -E '^[+-] ' | grep -v -E 'app.kubernetes.io/|helm.sh/chart|^[+-]  labels:|^\+    app: '
done
```

Résultat vérifié le 22 octobre 2026, hors étiquettes :

| Service | Différences | Pods recréés ? |
|---|---|---|
| `identity-api` | `HealthChecks__Expose` et `ASPNETCORE_HTTP_PORTS` changent de place ; `targetPort` passe au nom | Oui |
| `basket-api` | `Identity__Url` change de place ; `targetPort` était déjà `grpc` | Oui |
| `ordering-api`, `webhooks-api` | `Identity__Url` change de place ; `targetPort` passe au nom | Oui |
| `webapp`, `webhook-client` | `HealthChecks__Expose` change de place ; `targetPort` passe au nom | Oui |
| `order-processor`, `payment-processor` | Aucune | Non |

Aucune valeur ne change. Le chart place `HealthChecks__Expose` en tête des variables, alors que les manifestes le plaçaient souvent ailleurs ; Kubernetes compare la liste dans l'ordre, la voit modifiée, et recrée les pods. C'est sans conséquence, sinon que les utilisateurs connectés doivent se reconnecter après le redémarrage d'`identity-api` ou de `webapp`.

```bash
for s in identity-api basket-api ordering-api order-processor payment-processor webhooks-api webapp webhook-client; do
  helm upgrade --install $s helm/eshop-service -n eshop -f helm/values/$s.yaml \
    --take-ownership --force-conflicts | grep -E '^(NAME|STATUS|REVISION):'
done
```

Résultats vérifiés le 22 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Releases | Neuf en `deployed`, sur `eshop-service-0.1.0` |
| Pods recréés | Ceux annoncés par le `diff` ; `catalog-api`, `order-processor` et `payment-processor` gardent leurs 18 h |
| Files RabbitMQ | Les 7, avec 1 consommateur chacune |
| Point d'entrée, depuis un pod | Boutique `200`, émetteur `http://identity.eshop.lab`, `WebhookClient` `200` : les routes reprises fonctionnent |

## 5. Les dépendances et la plateforme

Même méthode, avec un `diff` affiché sans filtre : c'est là que sont les données ([03-dependances-plateforme.md](03-dependances-plateforme.md)).

| Release | Différences | Résultat après reprise |
|---|---|---|
| `postgres` | Étiquettes ; `targetPort: 5432` devient `postgres` | `postgres-0` âgé de 19 h ; même volume `pvc-6a1f1e38-…` ; les quatre bases et la commande `1|Paid` intactes |
| `redis` | Étiquettes ; `targetPort: 6379` devient `redis` | `PONG` |
| `rabbitmq` | Étiquettes ; `targetPort` passe à `amqp` et `management` | Les 7 files et leurs consommateurs |
| `eshop-platform` | Étiquettes seulement | Boutique `200` depuis Windows |

Aucune ligne `generation` n'est apparue pour les `StatefulSet` : ni leurs pods ni leurs modèles de volume n'ont changé.

## 6. Les leçons

| Leçon | Explication |
|---|---|
| Comparer avec le cluster, pas avec les fichiers | `kubectl diff` montre l'état réel, et révèle d'avance les changements de pods |
| Helm 4 applique côté serveur | Reprendre des objets créés par `kubectl apply` demande `--take-ownership` **et** `--force-conflicts` |
| Désigner les ports par leur nom | La seule différence de valeur de toute la reprise ; elle est sans effet |
| Ne plus utiliser `kubectl apply` sur `kubernetes/` | Les objets appartiennent à Helm. Les manifestes de `kubernetes/` restent dans le dépôt comme trace de l'étape précédente ([kubernetes/README.md](../../kubernetes/README.md)) |

**Bilan :** les 13 releases ont repris les objets créés à la main, sans coupure et sans toucher aux données. Le seul obstacle, propre à Helm 4, a été levé en forçant la reprise d'un champ sans effet.
