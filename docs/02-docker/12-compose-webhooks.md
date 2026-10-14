# 12 — Docker Compose : Webhooks.API

## 1. Objectif

Le guide [11](11-compose-payment-processor.md) a ajouté `PaymentProcessor`. Ce guide y ajoute `Webhooks.API`, le dernier service d’eShop qui dépend d’`Identity.API`.

`Webhooks.API` permet à des applications extérieures de s’abonner à certains événements d’eShop. Une application enregistre une adresse ; à chaque événement concerné, le service l’appelle pour la prévenir. C’est le principe d’un *webhook*.

| Élément | Déjà décrit pour |
|---|---|
| Base PostgreSQL créée et migrée par le service | `Catalog.API`, guide 07 |
| Connexion à RabbitMQ | `Catalog.API`, guide 07 |
| Adresse d’`Identity.API` et attente de son démarrage | `Basket.API`, guide 08 |
| Liaisons RabbitMQ | `PaymentProcessor`, guide 11 |

Ce guide met en avant deux points propres à ce service : une valeur incorrecte dans sa configuration d’origine, que le fichier Compose remplace, et un abonnement à trois événements.

**Périmètre :** `Webhooks.API` seul. La construction de l’image par Compose est décrite dans le guide 06, section 3.

**État au 15 octobre 2026 :** `Webhooks.API` démarre avec Docker Compose, refuse les requêtes sans jeton, a créé sa base et est abonné à ses trois événements.

## 2. Le service dans le fichier Compose

```yaml
  # =====================================================================
  # WEBHOOKS.API
  # =====================================================================
  webhooks-api:
    image: webhooks-api
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/Webhooks.API/Dockerfile
    container_name: webhooks-api
    environment:
      ConnectionStrings__webhooksdb: "Host=postgres;Port=5432;Database=webhooksdb;Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}"
      ConnectionStrings__eventbus: "amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
      Identity__Url: "http://identity-api:8080"
    ports:
      - "127.0.0.1:5227:8080"
    depends_on:
      postgres:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      identity-api:
        condition: service_started
    networks:
      - eshop-network
```

Le port `5227` est celui qu’eShop utilise en développement. Aucune variable nouvelle n’est à ajouter au fichier `.env`.

## 3. Une valeur d’origine à remplacer : `Identity:Url`

Le fichier `Webhooks.API/appsettings.json` d’eShop contient :

```json
"Identity": {
  "Url": "http://localhost:5223",
  "Audience": "webhooks",
  ...
}
```

Cette valeur convient au développement, où tous les services tournent sur le même poste. Dans un conteneur, `localhost` désigne le conteneur lui-même, où `Identity.API` ne se trouve pas. Le service y chercherait les clés de vérification des jetons, et échouerait.

La variable `Identity__Url` du fichier Compose remplace cette valeur. En .NET, une variable d’environnement l’emporte sur `appsettings.json` : `Identity__Url` correspond au réglage `Identity:Url`, le double tiret bas tenant lieu de `:`.

Les autres valeurs de la section, `Audience` et `Scopes`, restent celles du fichier d’origine : seule l’adresse change.

L’erreur ne se serait pas vue au démarrage. `Webhooks.API` ne contacte `Identity.API` qu’à la première requête munie d’un jeton : le service aurait démarré normalement, et l’échec ne serait apparu qu’avec un utilisateur connecté.

## 4. Démarrer

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d webhooks-api
until curl -s -o /dev/null http://127.0.0.1:5227/; do sleep 1; done; echo prêt
```

La sortie de `docker compose up` montre l’attente des dépendances :

```text
 ✔ Container identity-api Running
 ✔ Container rabbitmq     Healthy
 ✔ Container postgres     Healthy
 ✔ Container webhooks-api Started
```

## 5. Vérifier

### L’API répond et contrôle l’accès

```bash
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:5227/api/webhooks?api-version=1.0'
```

Résultat vérifié le 15 octobre 2026 : `401`. La liste des abonnements est réservée à un utilisateur connecté, pour la même raison que celle des commandes (guide 09, section 4).

### La base est créée

```bash
docker exec postgres psql -U postgres -d webhooksdb -Atc \
  "select schemaname || '.' || tablename from pg_tables where schemaname not in ('pg_catalog','information_schema') order by 1"
```

Résultat vérifié :

```text
public.Subscriptions
public.__EFMigrationsHistory
```

Contrairement à `Ordering.API`, ce service range sa table dans le schéma par défaut, `public`. Une seule migration est appliquée, et une seule table sert à l’application : `Subscriptions`, qui contiendra les abonnements.

### La file et ses trois événements

```bash
docker exec rabbitmq rabbitmqctl -q list_queues name consumers
docker exec rabbitmq rabbitmqctl -q list_bindings source_name destination_name routing_key | grep -P '^eshop_event_bus\tWebhooks\t'
```

Le filtre `grep -P` utilise les tabulations qui séparent les colonnes de `rabbitmqctl`. Il ne garde que les liaisons du point d’échange d’eShop vers la file `Webhooks`, sans la liaison par défaut décrite dans le guide 11.

Résultats vérifiés le 15 octobre 2026 :

```text
name              consumers
OrderProcessor    1
Ordering          1
Catalog           1
Webhooks          1
Basket            1
PaymentProcessor  1
```

```text
eshop_event_bus  Webhooks  OrderStatusChangedToShippedIntegrationEvent
eshop_event_bus  Webhooks  OrderStatusChangedToPaidIntegrationEvent
eshop_event_bus  Webhooks  ProductPriceChangedIntegrationEvent
```

Ces trois liaisons correspondent exactement aux abonnements déclarés dans le code, `Webhooks.API/Extensions/Extensions.cs` :

```csharp
eventBus.AddSubscription<ProductPriceChangedIntegrationEvent, ProductPriceChangedIntegrationEventHandler>();
eventBus.AddSubscription<OrderStatusChangedToShippedIntegrationEvent, OrderStatusChangedToShippedIntegrationEventHandler>();
eventBus.AddSubscription<OrderStatusChangedToPaidIntegrationEvent, OrderStatusChangedToPaidIntegrationEventHandler>();
```

| Événement | Publié par | Ce que les abonnés apprennent |
|---|---|---|
| `ProductPriceChangedIntegrationEvent` | `Catalog.API` | Le prix d’un article a changé |
| `OrderStatusChangedToPaidIntegrationEvent` | `Ordering.API` | Une commande est payée |
| `OrderStatusChangedToShippedIntegrationEvent` | `Ordering.API` | Une commande est expédiée |

Chaque service s’abonne seulement aux événements qui le concernent. Un même événement peut être livré à plusieurs files : `OrderStatusChangedToPaidIntegrationEvent` le sera aussi à `WebApp`, pour informer le client.

### Journal, port et compte d’exécution

```bash
docker logs webhooks-api 2>&1 | grep -E '^(fail|crit)' | sort | uniq -c
ss -ltn | grep ':5227 '
docker exec webhooks-api sh -c 'grep ^Uid: /proc/1/status'
```

Résultats vérifiés le 15 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Lignes `fail` | 1, sur la lecture de `__EFMigrationsHistory`, normale au premier démarrage |
| Port publié | `127.0.0.1:5227` seulement |
| Compte d’exécution | `1654` |
| Redémarrages du conteneur | Aucun |

## 6. Points ouverts

1. **Le service n’a pas de contrôle de santé**, comme les autres services d’eShop.
2. **L’envoi d’un webhook n’est pas testé.** Il demande d’enregistrer un abonnement, donc un utilisateur connecté. C’est le rôle de `WebhookClient`, le site de démonstration ajouté ensuite.
3. **Le port publié n’est utile qu’aux tests.**

## 7. Tableau de validation

| Contrôle | Résultat au 15 octobre 2026 |
|---|---|
| Image construite par Compose | `webhooks-api:latest`, 360 Mo |
| Attente de PostgreSQL et RabbitMQ `healthy`, et d’Identity.API démarré | Oui |
| `Identity:Url` d’origine remplacé | Oui, par `http://identity-api:8080` |
| `/api/webhooks` sans jeton | `401` |
| Base créée | Table `Subscriptions`, 1 migration |
| File `Webhooks` | 1 consommateur |
| Liaisons | 3, identiques aux abonnements du code |
| Erreurs dans le journal | 1, attendue au premier démarrage |
| Port publié | `127.0.0.1:5227` seulement |
| Compte d’exécution | `1654` |
| Envoi d’un webhook | Non testé |

## 8. Étape suivante

Tous les services sans interface sont en place. Restent les deux sites web, `WebhookClient` et `WebApp`. Avec eux se posent les questions laissées ouvertes depuis le guide 06 : les adresses des clients connues d’`Identity.API`, l’adresse d’émission des jetons, et la connexion d’un utilisateur depuis le navigateur.

## 9. Commandes de référence

```bash
# Construire l'image et démarrer le service
docker compose -f docker/docker-compose.yaml up -d webhooks-api

# Contrôle d'accès
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:5227/api/webhooks?api-version=1.0'

# Liaisons de la file Webhooks
docker exec rabbitmq rabbitmqctl -q list_bindings source_name destination_name routing_key | grep -P '^eshop_event_bus\tWebhooks\t'

# Valeur d'un réglage reçue par le conteneur
docker exec webhooks-api printenv Identity__Url
```

**Bilan :** `Webhooks.API` démarre avec Docker Compose, attend ses dépendances, contrôle l’accès à ses données, crée sa base et s’abonne aux trois événements prévus par son code. L’adresse d’`Identity.API`, incorrecte dans la configuration d’origine pour un conteneur, est remplacée par le fichier Compose.
