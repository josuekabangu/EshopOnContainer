# 12 — PaymentProcessor sur le cluster

## 1. Objectif

`PaymentProcessor` simule le paiement des commandes. Il reçoit de RabbitMQ l'événement « stock confirmé » d'une commande, et répond par l'événement « paiement réussi ». Il n'a ni base de données, ni API métier.

Ce guide le déploie sur le modèle d'`OrderProcessor` ([guide 11](11-order-processor.md)), puis fait traverser le bus à un événement, de `PaymentProcessor` jusqu'à `Ordering.API`. Les objectifs sont de :

- déployer la seconde tâche de fond, avec RabbitMQ pour seule dépendance ;
- vérifier son abonnement, jusqu'à l'événement précis qu'elle attend ;
- prouver la chaîne de messages entre trois composants du cluster, sans utilisateur connecté.

**État au 20 octobre 2026 :** `PaymentProcessor` tourne sur `kube-worker`. Un événement déposé dans RabbitMQ a été traité par `PaymentProcessor`, dont la réponse a été traitée par `Ordering.API`. Son journal ne contient ni erreur ni avertissement.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Probes | HTTP, sur `/alive` et `/health`, port 8080 | Son `Program.cs` crée une `WebApplication` et appelle `MapDefaultEndpoints()`, comme `OrderProcessor` |
| `Service` | Aucun | Personne ne l'appelle |
| Chaîne de connexion | `SealedSecret` `payment-processor-secrets`, une seule clé : `ConnectionStrings__eventbus` | Sa seule dépendance est RabbitMQ |
| Nombre de copies | 1, **par choix** | Contrairement à `OrderProcessor`, plusieurs copies seraient possibles : elles se partageraient les messages de la file, chacun traité une seule fois. C'est le modèle des consommateurs concurrents. Rien ne le demande ici |

Le code demande sa connexion sous le nom `EventBus`, les autres services sous `eventbus`. La configuration .NET ne distingue pas les majuscules : `ConnectionStrings__eventbus` convient ([guide 02-docker/11](../02-docker/11-compose-payment-processor.md), section 3).

## 3. Le secret

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

mkdir -p kubernetes/payment-processor
RMQ_USER=$(kubectl -n eshop get secret rabbitmq-credentials -o jsonpath='{.data.RABBITMQ_DEFAULT_USER}' | base64 -d)
RMQ_PASS=$(kubectl -n eshop get secret rabbitmq-credentials -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d)
printf 'ConnectionStrings__eventbus=amqp://%s:%s@rabbitmq:5672/\n' "$RMQ_USER" "$RMQ_PASS" \
  | kubectl -n eshop create secret generic payment-processor-secrets \
      --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/payment-processor/sealedsecret-payment-processor.yaml
unset RMQ_USER RMQ_PASS
```

Résultat vérifié le 20 octobre 2026 : une clé chiffrée, `ConnectionStrings__eventbus`, et aucune adresse `amqp` en clair.

## 4. Le manifeste

Le `Deployment` est celui d'`OrderProcessor`, avec son nom, son image (`ghcr.io/josuekabangu/payment-processor:87e28f8`) et son secret, et sans le commentaire qui impose une seule copie. Il n'y a pas de `Service`.

```text
kubernetes/payment-processor/
├── deployment-payment-processor.yaml
└── sealedsecret-payment-processor.yaml
```

## 5. Appliquer

```bash
for f in kubernetes/payment-processor/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status deployment/payment-processor --timeout=300s
kubectl -n eshop get pods -l app=payment-processor -o wide
```

Résultat vérifié le 20 octobre 2026 :

```text
NAME                                 READY   STATUS    RESTARTS   AGE   IP              NODE
payment-processor-698fbfd7b6-cg92j   1/1     Running   0          6s    10.244.73.148   kube-worker
```

## 6. Vérifier

### L'abonnement, jusqu'à l'événement attendu

Une file ne reçoit que les messages que lui transmet un point d'échange, selon des liaisons (*bindings*). Dans eShop, la clé d'une liaison est le nom de l'événement :

```bash
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
rabbitmqctl -q list_bindings source_name destination_name routing_key | grep PaymentProcessor
SH
```

Résultat vérifié le 20 octobre 2026 :

```text
name              consumers
OrderProcessor    1
Ordering          1
Catalog           1
Basket            1
PaymentProcessor  1
                  PaymentProcessor  PaymentProcessor
eshop_event_bus   PaymentProcessor  OrderStatusChangedToStockConfirmedIntegrationEvent
```

Les cinq files des services sont en place, chacune avec son consommateur. La file `PaymentProcessor` est liée au point d'échange `eshop_event_bus` pour le seul événement `OrderStatusChangedToStockConfirmedIntegrationEvent`. La première liaison, à source vide, est celle que RabbitMQ crée pour toute file.

### Faire traverser le bus à un événement

Un événement « stock confirmé » est déposé dans `eshop_event_bus`, pour une commande fictive, `999999`. Le numéro ne correspond à aucune commande : le test ne modifie aucune donnée.

Avec Compose, le dépôt passait par l'interface d'administration publiée sur le poste, avec un mot de passe saisi au clavier ([guide 02-docker/11](../02-docker/11-compose-payment-processor.md), section 5). Sur le cluster, il part d'un pod de test qui reçoit les identifiants du secret `rabbitmq-credentials`, et joint l'API d'administration par le `Service` `rabbitmq` : aucune saisie.

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: bustest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: bustest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
      envFrom: [ { secretRef: { name: rabbitmq-credentials } } ]
Y
kubectl -n eshop wait --for=condition=Ready pod/bustest --timeout=120s
kubectl -n eshop exec -i bustest -- sh <<'SH'
curl -s -m 10 -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" -H 'content-type: application/json' -X POST \
  http://rabbitmq:15672/api/exchanges/%2F/eshop_event_bus/publish \
  -d '{"properties":{},"routing_key":"OrderStatusChangedToStockConfirmedIntegrationEvent","payload":"{\"OrderId\":999999}","payload_encoding":"string"}'
echo
SH
kubectl -n eshop delete pod bustest

sleep 5
kubectl -n eshop logs --since=2m deployment/payment-processor | grep 'integration event'
kubectl -n eshop logs --since=2m deployment/ordering-api | grep -E 'integration event|SetPaidOrderStatusCommand|transaction'
```

- `%2F` est le caractère `/` encodé : il désigne l'hôte virtuel `/`.
- `routing_key` est le nom de l'événement ; `payload`, son contenu. Les autres champs, identifiant et date, sont créés par le service à la lecture.

Résultat vérifié le 20 octobre 2026, abrégé :

```text
{"routed":true}

# payment-processor
Handling integration event: 6d0a8a58-... - (OrderStatusChangedToStockConfirmedIntegrationEvent { ..., OrderId = 999999 })
Publishing integration event: 420bc795-... - (OrderPaymentSucceededIntegrationEvent { ..., OrderId = 999999 })

# ordering-api
Handling integration event: 420bc795-... - (OrderPaymentSucceededIntegrationEvent { ..., OrderId = 999999 })
Sending command: SetPaidOrderStatusCommand - OrderNumber: 999999
Begin transaction 57a57bac-... for SetPaidOrderStatusCommand
Commit transaction 57a57bac-... for SetPaidOrderStatusCommand
Command SetPaidOrderStatusCommand handled - response: False
```

| Étape | Preuve |
|---|---|
| RabbitMQ transmet l'événement | `{"routed":true}` : au moins une file l'a reçu |
| `PaymentProcessor` le traite et répond | `Handling ... StockConfirmed`, puis `Publishing ... PaymentSucceeded`, pour la commande `999999` |
| `Ordering.API` traite la réponse | Le même identifiant d'événement, `420bc795-...`, dans les deux journaux |
| Aucune donnée modifiée | `response: False` : la commande `999999` n'existe pas, `Ordering.API` n'avait rien à marquer comme payé |

La chaîne `RabbitMQ → PaymentProcessor → RabbitMQ → Ordering.API` fonctionne sur le cluster.

### Le journal

```bash
kubectl -n eshop logs deployment/payment-processor | grep -E '^(fail|crit):|^Error:' | sort | uniq -c
kubectl -n eshop logs deployment/payment-processor | grep -A1 -E '^warn:'
```

Résultat vérifié : aucune ligne. Pas même `libgssapi`, puisque le service n'utilise pas PostgreSQL, ni d'avertissement sur les clés de protection des données.

## 7. Tableau de validation

| Contrôle | Résultat au 20 octobre 2026 |
|---|---|
| Chaîne de connexion chiffrée, sans valeur en clair | Oui |
| Pod | `1/1 Running`, probes HTTP sur le port 8080 |
| File `PaymentProcessor` | 1 consommateur, liée au seul événement attendu |
| Événement déposé, transmis | `routed: true` |
| Traité par `PaymentProcessor`, réponse publiée | Oui |
| Réponse traitée par `Ordering.API` | Oui, même identifiant d'événement |
| Données modifiées | Aucune |
| Journal | Vide : ni erreur, ni avertissement |

## 8. Étape suivante

Déployer `Webhooks.API`, qui gère les abonnements des applications extérieures aux événements de la boutique ([guide 02-docker/12](../02-docker/12-compose-webhooks.md)) : [13 — Webhooks.API sur le cluster](13-webhooks-api.md).

## 9. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes de PaymentProcessor
for f in kubernetes/payment-processor/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# Files et liaisons
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_queues name consumers
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_bindings source_name destination_name routing_key

# Événements traités ces deux dernières minutes
kubectl -n eshop logs --since=2m deployment/payment-processor | grep 'integration event'
```

**Bilan :** `PaymentProcessor` tourne sur le cluster, abonné au seul événement qu'il traite. Un événement déposé dans RabbitMQ a traversé le bus jusqu'à `Ordering.API` en passant par lui, sans utilisateur connecté et sans modifier aucune donnée.
