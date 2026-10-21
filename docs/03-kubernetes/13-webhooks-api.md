# 13 — Webhooks.API sur le cluster

## 1. Objectif

`Webhooks.API` gère les abonnements des applications extérieures aux événements de la boutique. Quand un prix change, ou qu'une commande est payée ou expédiée, il prévient les applications abonnées par un appel HTTP, un *webhook*.

Ce guide le déploie sur le modèle d'`Ordering.API` ([guide 10](10-ordering-api.md)). Les objectifs sont de :

- vérifier sa base, son abonnement à RabbitMQ et son contrôle d'accès ;
- prouver qu'il reçoit les événements, sans utilisateur connecté, par un événement déposé dans RabbitMQ ;
- s'assurer que cet événement de test ne modifie aucune donnée, alors qu'il est aussi livré à `Catalog.API`.

**État au 20 octobre 2026 :** `Webhooks.API` tourne sur `kube-worker`. Sa base est créée, ses trois abonnements sont en place, il refuse les appels sans jeton, et il a reçu un événement « commande payée » déposé pour le test.

## 2. Les choix

Identiques à ceux d'`Ordering.API` : `Deployment`, image `ghcr.io/josuekabangu/webhooks-api:87e28f8`, port `8080`, `Identity__Url: http://identity-api:5223` (devenu `http://identity.eshop.lab` le 21 octobre 2026, [guide 14](14-point-entree.md)), probes `/alive` et `/health`, et un `SealedSecret` `webhooks-api-secrets` avec `ConnectionStrings__webhooksdb` et `ConnectionStrings__eventbus`.

`Identity__Url` a ici une raison de plus d'être défini : le fichier `appsettings.json` du service contient `http://localhost:5223`, qui désignerait le conteneur lui-même ([guide 02-docker/12](../02-docker/12-compose-webhooks.md), section 3).

## 3. Le secret et les manifestes

Le secret suit la commande d'`Ordering.API` ([guide 10](10-ordering-api.md), section 3), avec la base `webhooksdb` et le nom `webhooks-api-secrets`. Résultat vérifié le 20 octobre 2026 : deux clés chiffrées, et `0` valeur en clair.

Les deux manifestes sont ceux d'`Ordering.API`, dont seul le nom change :

```bash
sed 's/ordering-api/webhooks-api/g' kubernetes/ordering-api/service-ordering-api.yaml \
  > kubernetes/webhooks-api/service-webhooks-api.yaml
sed 's/ordering-api/webhooks-api/g' kubernetes/ordering-api/deployment-ordering-api.yaml \
  > kubernetes/webhooks-api/deployment-webhooks-api.yaml
grep -n -E 'name:|image:|ordering' kubernetes/webhooks-api/*.yaml
```

Le `grep` vérifie le résultat : le nom `webhooks-api` partout, l'image `webhooks-api:87e28f8`, le secret `webhooks-api-secrets`, et aucune occurrence restante de `ordering`. Résultat vérifié.

```text
kubernetes/webhooks-api/
├── deployment-webhooks-api.yaml
├── sealedsecret-webhooks-api.yaml
└── service-webhooks-api.yaml
```

## 4. Appliquer

```bash
for f in kubernetes/webhooks-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status deployment/webhooks-api --timeout=300s
kubectl -n eshop get pods -l app=webhooks-api -o wide
```

Résultat vérifié le 20 octobre 2026 :

```text
NAME                            READY   STATUS    RESTARTS   AGE   IP              NODE
webhooks-api-5c98f99c75-4g22k   1/1     Running   0          12s   10.244.73.150   kube-worker
```

## 5. Vérifier

### La base, la file et ses liaisons

```bash
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d webhooksdb -At <<'SQL'
select schemaname || '.' || tablename from pg_tables where schemaname not in ('pg_catalog','information_schema') order by 1;
SQL

kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
rabbitmqctl -q list_bindings source_name destination_name routing_key | grep -P '^eshop_event_bus\tWebhooks\t'
SH
```

Résultat vérifié le 20 octobre 2026 :

```text
public.Subscriptions
public.__EFMigrationsHistory

name              consumers
OrderProcessor    1
Ordering          1
Catalog           1
Webhooks          1
Basket            1
PaymentProcessor  1

eshop_event_bus  Webhooks  OrderStatusChangedToShippedIntegrationEvent
eshop_event_bus  Webhooks  ProductPriceChangedIntegrationEvent
eshop_event_bus  Webhooks  OrderStatusChangedToPaidIntegrationEvent
```

La table des abonnements est créée, dans le schéma `public`. Les six services connectés à RabbitMQ ont chacun leur file et leur consommateur. La file `Webhooks` est liée aux trois événements déclarés dans le code du service.

### Un événement « commande payée », sans effet sur le stock

L'événement `OrderStatusChangedToPaidIntegrationEvent` n'est pas livré qu'à `Webhooks.API`. `Catalog.API` le reçoit aussi, et son gestionnaire **retire du stock** pour chaque article de la commande :

```csharp
foreach (var orderStockItem in @event.OrderStockItems)
{
    var catalogItem = catalogContext.CatalogItems.Find(orderStockItem.ProductId);
    catalogItem?.RemoveStock(orderStockItem.Units);
}
```

L'événement de test fournit donc une liste d'articles vide, `"OrderStockItems": []` :

| Contenu | Conséquence pour `Catalog.API` |
|---|---|
| Sans `OrderStockItems` | Liste nulle : le traitement échoue, et RabbitMQ retire tout de même le message de la file ([guide 02-docker/11](../02-docker/11-compose-payment-processor.md), section 5) |
| Avec un article | Du stock est réellement retiré |
| **Liste vide** | Rien n'est parcouru, rien n'est modifié |

Le dépôt passe, comme pour `PaymentProcessor`, par un pod de test qui reçoit les identifiants de RabbitMQ. Le même pod vérifie au passage le contrôle d'accès :

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: hooktest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: hooktest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
      envFrom: [ { secretRef: { name: rabbitmq-credentials } } ]
Y
kubectl -n eshop wait --for=condition=Ready pod/hooktest --timeout=120s
kubectl -n eshop exec -i hooktest -- sh <<'SH'
echo "sans jeton : $(curl -s -m 10 -o /dev/null -w '%{http_code}' 'http://webhooks-api:8080/api/webhooks?api-version=1.0')"
curl -s -m 10 -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" -H 'content-type: application/json' -X POST \
  http://rabbitmq:15672/api/exchanges/%2F/eshop_event_bus/publish \
  -d '{"properties":{},"routing_key":"OrderStatusChangedToPaidIntegrationEvent","payload":"{\"OrderId\":999999,\"OrderStockItems\":[]}","payload_encoding":"string"}'
echo
SH
kubectl -n eshop delete pod hooktest

sleep 5
kubectl -n eshop logs --since=2m deployment/webhooks-api | grep 'subscriptions to process'
kubectl -n eshop logs --since=2m deployment/catalog-api | grep -E 'Handling integration event|^warn|^fail'
```

Résultat vérifié le 20 octobre 2026, abrégé :

```text
sans jeton : 401
{"routed":true}

# webhooks-api
Received OrderStatusChangedToShippedIntegrationEvent and got 0 subscriptions to process

# catalog-api
Handling integration event: 3f1d75e8-... - (OrderStatusChangedToPaidIntegrationEvent { ..., OrderId = 999999, OrderStockItems = System.Collections.Generic.List`1[...] })
```

| Constat | Ce qu'il prouve |
|---|---|
| `401` sans jeton | Le contrôle d'accès est actif, comme pour `Ordering.API` |
| `0 subscriptions to process` | `Webhooks.API` a reçu l'événement et consulté sa table : aucune application n'est encore abonnée |
| `Catalog.API` : `Handling ...`, avec une liste, sans `warn` ni `fail` | L'événement a été traité sans erreur et sans retirer de stock |

Le message de `Webhooks.API` nomme l'événement `OrderStatusChangedToShippedIntegrationEvent` : c'est une coquille du code d'eShop, dans le gestionnaire de l'événement « payée », déjà relevée avec Compose ([guide 02-docker/12](../02-docker/12-compose-webhooks.md), point ouvert 2).

### Le journal

```bash
kubectl -n eshop logs deployment/webhooks-api | grep -E '^(fail|crit):|^Error:' | sort | uniq -c
kubectl -n eshop logs deployment/webhooks-api | grep -A1 -E '^warn:'
```

Résultat vérifié : `libgssapi` et `Connection[20004]`, une fois chacun, les deux messages attendus d'un service qui crée sa base. Les deux avertissements sur les clés de protection des données sont sans conséquence : le service n'émet pas de cookie.

## 6. Ce qui reste à vérifier

L'envoi d'un webhook à une application abonnée demande `WebhookClient`, et l'abonnement d'un utilisateur connecté ([guide 02-docker/14](../02-docker/14-compose-webhook-client.md)).

## 7. Tableau de validation

| Contrôle | Résultat au 20 octobre 2026 |
|---|---|
| Deux chaînes de connexion chiffrées, sans valeur en clair | Oui |
| Pod | `1/1 Running`, aucun redémarrage |
| Table `Subscriptions` | Créée |
| File `Webhooks` | 1 consommateur, liée aux trois événements du code |
| Appel sans jeton | Refusé, `401` |
| Événement « commande payée » reçu | Oui, `0` abonnement à traiter |
| Effet du test sur `Catalog.API` | Traité sans erreur, aucun stock retiré |
| Journal | Les deux messages attendus |

## 8. Étape suivante

Les services restants, `WebApp` et `WebhookClient`, sont ceux qu'utilise un navigateur. Ils demandent d'abord de choisir le point d'entrée du cluster, et l'adresse d'`Identity.API` commune au navigateur et aux pods ([guide 07](07-identity-api.md), point ouvert 2) : [14 — Le point d'entrée d'eShop et l'émetteur commun](14-point-entree.md).

## 9. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes de Webhooks.API
for f in kubernetes/webhooks-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# Abonnements enregistrés
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d webhooksdb -At <<'SQL'
select count(*) from "Subscriptions";
SQL

# Liaisons de la file Webhooks
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_bindings source_name destination_name routing_key
```

**Bilan :** `Webhooks.API` tourne sur le cluster avec sa base et ses trois abonnements. Il refuse les appels sans jeton, et reçoit les événements de la boutique : un événement de test, construit pour ne retirer aucun stock dans `Catalog.API`, l'a prouvé.
