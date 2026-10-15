# 11 — Docker Compose : PaymentProcessor

## 1. Objectif

Le guide [10](10-compose-order-processor.md) a ajouté `OrderProcessor`. Ce guide y ajoute `PaymentProcessor`, le service le plus simple d’eShop : il n’a ni base de données ni API, et ne dépend que de RabbitMQ.

Il simule le paiement des commandes. Quand il reçoit l’événement « stock confirmé » pour une commande, il publie en réponse « paiement réussi » ou « paiement refusé ».

Ce service permet aussi un test que les précédents n’offraient pas : **faire traverser le bus de messages à un événement**, sans utilisateur connecté. Jusqu’ici, chaque service a été vérifié isolément ; ce test montre que trois d’entre eux, RabbitMQ, `PaymentProcessor` et `Ordering.API`, communiquent réellement.

Les objectifs sont de :

- ajouter le service avec sa configuration ;
- vérifier son abonnement, et l’événement qu’il attend ;
- déposer un événement à la main dans RabbitMQ et suivre son parcours.

**Périmètre :** `PaymentProcessor` seul, et un événement de test. La construction de l’image par Compose est décrite dans le guide 06, section 3.

**État au 15 octobre 2026 :** `PaymentProcessor` démarre avec Docker Compose. Un événement déposé à la main a été traité par `PaymentProcessor`, dont la réponse a été traitée à son tour par `Ordering.API`.

## 2. Ce que fait le service

Son unique traitement se trouve dans `PaymentProcessor/IntegrationEvents/EventHandling/OrderStatusChangedToStockConfirmedIntegrationEventHandler.cs` :

```csharp
if (options.CurrentValue.PaymentSucceeded)
{
    orderPaymentIntegrationEvent = new OrderPaymentSucceededIntegrationEvent(@event.OrderId);
}
else
{
    orderPaymentIntegrationEvent = new OrderPaymentFailedIntegrationEvent(@event.OrderId);
}
```

Aucun paiement réel n’a lieu. Le résultat dépend du réglage `PaymentOptions:PaymentSucceeded`, qui vaut `true` dans `PaymentProcessor/appsettings.json` : par défaut, tous les paiements réussissent. Cette valeur est conservée.

Le parcours complet d’une commande passe ainsi par plusieurs services :

```text
Ordering.API ──« stock confirmé »──> RabbitMQ ──> PaymentProcessor
                                                       │
Ordering.API <──────────────────── RabbitMQ <──« paiement réussi »
```

## 3. Le service dans le fichier Compose

```yaml
  # =====================================================================
  # PAYMENTPROCESSOR
  # =====================================================================
  payment-processor:
    image: payment-processor
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/PaymentProcessor/Dockerfile
    container_name: payment-processor
    environment:
      ConnectionStrings__eventbus: "amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
    depends_on:
      rabbitmq:
        condition: service_healthy
    networks:
      - eshop-network
```

- **Une seule variable**, la connexion à RabbitMQ.
- **Une seule dépendance**, RabbitMQ.
- **Aucun port publié** : comme `OrderProcessor`, le service ne sert aucune page.

### Un nom écrit avec des majuscules dans le code

Le code demande sa connexion sous le nom `EventBus` :

```csharp
builder.AddRabbitMqEventBus("EventBus")
```

Les autres services écrivent `eventbus`. La configuration .NET ne distingue pas les majuscules dans les noms de réglages : la variable `ConnectionStrings__eventbus` convient pour tous. Le guide 02 l’avait déjà constaté en démarrant ce service.

## 4. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d payment-processor
docker compose -f docker/docker-compose.yaml ps payment-processor
```

Résultat vérifié le 15 octobre 2026 :

```text
NAME                IMAGE               ...   STATUS                  PORTS
payment-processor   payment-processor   ...   Up Less than a second   8080/tcp
```

La sortie de `docker compose up` ne mentionne que RabbitMQ parmi les dépendances :

```text
 ✔ Container rabbitmq          Healthy
 ✔ Container payment-processor Started
```

### L’abonnement à RabbitMQ

```bash
docker exec rabbitmq rabbitmqctl -q list_queues name consumers
```

Résultat vérifié :

```text
name              consumers
OrderProcessor    1
Ordering          1
Catalog           1
Basket            1
PaymentProcessor  1
```

### L’événement attendu par la file

Une file ne reçoit que les messages que lui transmet un point d’échange. Les règles de transmission s’appellent des liaisons (*bindings*) : chacune relie un point d’échange à une file, pour une clé donnée. Dans eShop, la clé est le nom de l’événement.

```bash
docker exec rabbitmq rabbitmqctl -q list_bindings source_name destination_name routing_key | grep PaymentProcessor
```

Résultat vérifié :

```text
                 PaymentProcessor  PaymentProcessor
eshop_event_bus  PaymentProcessor  OrderStatusChangedToStockConfirmedIntegrationEvent
```

| Ligne | Signification |
|---|---|
| Source vide, clé `PaymentProcessor` | Liaison au point d’échange par défaut, que RabbitMQ crée pour toute file |
| `eshop_event_bus`, clé `OrderStatusChangedToStockConfirmedIntegrationEvent` | Le seul événement que `PaymentProcessor` traite |

Le service s’est donc abonné au seul événement prévu par son code.

### Journal, état et compte d’exécution

```bash
docker logs payment-processor 2>&1 | grep -c -E '^(fail|crit)'
docker inspect payment-processor --format '{{.State.Status}} redémarrages={{.RestartCount}}'
docker exec payment-processor sh -c 'grep ^Uid: /proc/1/status'
```

Résultats vérifiés : `0`, `running redémarrages=0`, `1654`.

## 5. Faire traverser le bus à un événement

### Principe

Un événement « stock confirmé » est déposé à la main dans le point d’échange `eshop_event_bus`, pour une commande fictive, numéro `999999`. Si tout fonctionne :

1. RabbitMQ le transmet à la file `PaymentProcessor` ;
2. `PaymentProcessor` le traite et publie « paiement réussi » ;
3. RabbitMQ transmet ce second événement à la file `Ordering` ;
4. `Ordering.API` le traite.

Le numéro `999999` ne correspond à aucune commande : le test ne modifie aucune donnée.

### Déposer l’événement

Le dépôt passe par l’interface d’administration de RabbitMQ, publiée sur `127.0.0.1:15672` (guide 05). Elle accepte des commandes en HTTP, en plus des pages web.

```bash
read -rs -p 'Mot de passe RabbitMQ : ' RMQ_PASSWORD; echo

curl -s -u "eshop_rabbit:$RMQ_PASSWORD" -H 'content-type: application/json' -X POST \
  http://127.0.0.1:15672/api/exchanges/%2F/eshop_event_bus/publish \
  -d '{"properties":{},"routing_key":"OrderStatusChangedToStockConfirmedIntegrationEvent","payload":"{\"OrderId\":999999}","payload_encoding":"string"}'
```

- `-u` transmet l’utilisateur et le mot de passe de RabbitMQ, ceux du fichier `docker/.env`.
- `%2F` est le caractère `/` encodé : il désigne l’hôte virtuel `/`.
- `routing_key` est la clé, c’est-à-dire le nom de l’événement.
- `payload` est le contenu du message. `{"OrderId":999999}` suffit : les autres champs d’un événement, son identifiant et sa date, sont créés par le service à la lecture.

Résultat vérifié le 15 octobre 2026 :

```text
{"routed":true}
```

`routed: true` signifie que RabbitMQ a trouvé au moins une file pour ce message.

### Suivre le parcours

```bash
docker logs --since 1m payment-processor 2>&1 | grep 'integration event'
docker logs --since 1m ordering-api 2>&1 | grep -E 'integration event|SetPaidOrderStatusCommand|transaction'
```

`--since 1m` limite le journal à la dernière minute.

Résultats vérifiés le 15 octobre 2026, abrégés :

```text
# payment-processor
Handling integration event: b28024f0-... - (OrderStatusChangedToStockConfirmedIntegrationEvent { ..., OrderId = 999999 })
Publishing integration event: 3c4a5009-... - (OrderPaymentSucceededIntegrationEvent { ..., OrderId = 999999 })

# ordering-api
Handling integration event: 3c4a5009-... - (OrderPaymentSucceededIntegrationEvent { ..., OrderId = 999999 })
Sending command: SetPaidOrderStatusCommand - OrderNumber: 999999
Begin transaction 9883f65d-... for SetPaidOrderStatusCommand
Commit transaction 9883f65d-... for SetPaidOrderStatusCommand
```

L’identifiant `3c4a5009-...` relie les deux journaux : l’événement publié par `PaymentProcessor` est exactement celui que traite `Ordering.API`.

### Ce que le test établit

| Contrôle | Résultat |
|---|---|
| Message transmis par RabbitMQ | `routed: true` |
| Événement traité par `PaymentProcessor` | Oui |
| Réponse « paiement réussi » publiée | Oui, avec le même numéro de commande |
| Réponse traitée par `Ordering.API` | Oui, même identifiant d’événement |
| Erreurs ou avertissements dans les deux journaux | Aucun |
| Commandes en base après le test | `0`, aucune donnée modifiée |

`Ordering.API` a ouvert puis validé une transaction sans rien modifier : la commande `999999` n’existe pas, il n’y avait rien à mettre à jour.

Le test valide la chaîne de messages entre trois services, sans `WebApp` ni utilisateur connecté.

### Ce que le code fait d’un message en erreur

La lecture du code de réception, dans `EventBusRabbitMQ/RabbitMQEventBus.cs`, montre qu’un message est retiré de la file même si son traitement échoue :

```csharp
// Even on exception we take the message off the queue.
// in a REAL WORLD app this should be handled with a Dead Letter Exchange (DLX).
await _consumerChannel.BasicAckAsync(eventArgs.DeliveryTag, multiple: false);
```

Un message mal formé ou mal traité n’est donc ni conservé, ni retenté : seule une ligne `warn` dans le journal du service en garde la trace. Les auteurs d’eShop signalent eux-mêmes cette limite. Ce comportement n’a pas été testé.

## 6. Points ouverts

1. ~~Le service n’a pas de contrôle de santé~~ : réglé le 15 octobre 2026. Sans page métier, il expose tout de même `/health` et `/alive` quand `HealthChecks__Expose` vaut `true`, et le contrôle commun s’applique (guide 15, section 6).
2. **Un message en erreur est perdu**, voir section 5. C’est une limite du code d’eShop, pas de la configuration.
3. **Le paiement refusé n’est pas testé.** Il suffirait de transmettre `PaymentOptions__PaymentSucceeded=false` au service.

## 7. Tableau de validation

| Contrôle | Résultat au 15 octobre 2026 |
|---|---|
| Image construite par Compose | `payment-processor:latest` |
| Attente de RabbitMQ `healthy` | Oui |
| Port publié | Aucun, volontairement |
| File `PaymentProcessor` | 1 consommateur |
| Liaison | `OrderStatusChangedToStockConfirmedIntegrationEvent` seulement |
| Erreurs dans le journal | 0 |
| Compte d’exécution | `1654` |
| Événement déposé à la main | Traité par `PaymentProcessor`, puis par `Ordering.API` |

## 8. Étape suivante

Ajouter `Webhooks.API`, le dernier service qui dépend d’`Identity.API`. Il utilise PostgreSQL et RabbitMQ. Voir [12 — Docker Compose : Webhooks.API](12-compose-webhooks.md).

## 9. Commandes de référence

```bash
# Construire l'image et démarrer le service
docker compose -f docker/docker-compose.yaml up -d payment-processor

# Files, consommateurs et liaisons
docker exec rabbitmq rabbitmqctl -q list_queues name consumers
docker exec rabbitmq rabbitmqctl -q list_bindings source_name destination_name routing_key

# Déposer un événement de test
read -rs -p 'Mot de passe RabbitMQ : ' RMQ_PASSWORD; echo
curl -s -u "eshop_rabbit:$RMQ_PASSWORD" -H 'content-type: application/json' -X POST \
  http://127.0.0.1:15672/api/exchanges/%2F/eshop_event_bus/publish \
  -d '{"properties":{},"routing_key":"OrderStatusChangedToStockConfirmedIntegrationEvent","payload":"{\"OrderId\":999999}","payload_encoding":"string"}'

# Suivre l'événement
docker logs --since 1m payment-processor 2>&1 | grep 'integration event'
docker logs --since 1m ordering-api 2>&1 | grep 'integration event'
```

**Bilan :** `PaymentProcessor` démarre avec Docker Compose et s’abonne au seul événement qu’il traite. Un événement déposé à la main a traversé le bus jusqu’à `Ordering.API` : la messagerie entre services fonctionne.
