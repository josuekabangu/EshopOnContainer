# 09 — Docker Compose : Ordering.API

## 1. Objectif

Le guide [08](08-compose-basket.md) a ajouté `Basket.API` au fichier Compose. Ce guide y ajoute `Ordering.API`, qui gère les commandes des clients.

Ce service ne demande aucun réglage nouveau : il combine ce que les guides précédents ont déjà décrit.

| Élément | Déjà décrit pour |
|---|---|
| Base PostgreSQL créée et migrée par le service | `Catalog.API`, guide 07 |
| Connexion à RabbitMQ | `Catalog.API`, guide 07 |
| Adresse d’`Identity.API` et attente de son démarrage | `Basket.API`, guide 08 |

Son importance tient à la suite : c’est `Ordering.API` qui crée les tables de la base `orderingdb`. `OrderProcessor`, ajouté ensuite, les utilise sans jamais les créer.

Les objectifs sont de :

- ajouter le service avec sa configuration ;
- vérifier qu’il répond, qu’il contrôle l’accès à ses données, qu’il a créé ses tables et qu’il est abonné à RabbitMQ.

**Périmètre :** `Ordering.API` seul. La construction de l’image par Compose est décrite dans le guide 06, section 3.

**État au 14 octobre 2026 :** `Ordering.API` démarre avec Docker Compose, refuse les requêtes sans jeton, a créé ses tables et est abonné à RabbitMQ.

## 2. Le service dans le fichier Compose

```yaml
  # =====================================================================
  # ORDERING.API
  # =====================================================================
  ordering-api:
    image: ordering-api
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/Ordering.API/Dockerfile
    container_name: ordering-api
    environment:
      ConnectionStrings__orderingdb: "Host=postgres;Port=5432;Database=orderingdb;Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}"
      ConnectionStrings__eventbus: "amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
      Identity__Url: "http://identity-api:8080"
    ports:
      - "127.0.0.1:5224:8080"
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

| Réglage | Valeur | Explication détaillée |
|---|---|---|
| `ConnectionStrings__orderingdb` | Base `orderingdb` sur `postgres` | Guide 06, section 4 |
| `ConnectionStrings__eventbus` | RabbitMQ sur `rabbitmq:5672` | Guide 07, section 3 |
| `Identity__Url` | `http://identity-api:8080` | Guide 08, section 3 |
| `depends_on` | PostgreSQL et RabbitMQ `healthy`, Identity.API démarré | Guide 08, section 3 |
| Port | `127.0.0.1:5224`, celui d’eShop en développement, pour les tests | Guide 07, section 3 |

Aucune variable nouvelle n’est à ajouter au fichier `.env`.

## 3. Démarrer

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d ordering-api
until curl -s -o /dev/null http://127.0.0.1:5224/; do sleep 1; done; echo prêt
```

La boucle attend que le service réponde, quel que soit le code renvoyé. Contrairement au guide 07, l’option `-f` n’est pas utilisée : la racine du service ne renvoie pas `200`, et la boucle ne s’arrêterait jamais.

La sortie de `docker compose up` montre l’attente des dépendances :

```text
 ✔ Container postgres     Healthy
 ✔ Container rabbitmq     Healthy
 ✔ Container identity-api Running
 ✔ Container ordering-api Started
```

### Pourquoi `identity-api` est reconstruit

La même sortie contient aussi :

```text
 ✔ Image identity-api     Built
 ✔ Image ordering-api     Built
```

`docker compose up -d ordering-api` traite aussi les dépendances du service. Avec `pull_policy: build`, l’image de chacune est reconstruite à chaque `up`, même si seul `ordering-api` est demandé.

Cette reconstruction est sans conséquence :

- toutes ses étapes sont lues dans le cache (`CACHED`), elle ne prend que quelques secondes ;
- l’image obtenue est identique, et le conteneur `identity-api` n’est pas redémarré : son état reste `Running`.

C’est la contrepartie du réglage `pull_policy: build`, choisi dans le guide 06 pour que l’image suive toujours le code.

## 4. Vérifier

### L’API répond et contrôle l’accès

```bash
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:5224/api/orders?api-version=1.0'
```

Résultat vérifié le 14 octobre 2026 : `401`.

Ce code est le résultat attendu. La liste des commandes est réservée à un utilisateur connecté : sans jeton, l’API refuse la demande. La réponse prouve que le service fonctionne et applique son contrôle d’accès.

| Code | Signification |
|---|---|
| `401` | Le service répond et exige une authentification |
| `000` | Le service ne répond pas, ou pas encore |
| `500` | Le service répond, mais rencontre une erreur |

### Les tables sont créées

`Ordering.API` range ses tables dans un schéma PostgreSQL nommé `ordering`, et non dans le schéma par défaut `public`. Un schéma est un espace de noms à l’intérieur d’une base. La requête liste donc les tables de tous les schémas, sauf ceux de PostgreSQL lui-même :

```bash
docker exec postgres psql -U postgres -d orderingdb -Atc \
  "select schemaname || '.' || tablename from pg_tables where schemaname not in ('pg_catalog','information_schema') order by 1"
```

Résultat vérifié le 14 octobre 2026 :

```text
ordering.IntegrationEventLog
ordering.buyers
ordering.cardtypes
ordering.orderItems
ordering.orders
ordering.paymentmethods
ordering.requests
public.__EFMigrationsHistory
```

| Constat | Valeur |
|---|---|
| Tables de l’application | 7, dans le schéma `ordering` |
| Migrations appliquées | 4, enregistrées dans `public.__EFMigrationsHistory` |
| Types de carte de paiement chargés | 3 : `Amex`, `Visa`, `MasterCard` |

Ces tables seront partagées avec `OrderProcessor`.

### L’abonnement à RabbitMQ

```bash
docker exec rabbitmq rabbitmqctl -q list_queues name consumers
```

Résultat vérifié :

```text
name      consumers
Ordering  1
Catalog   1
Basket    1
```

### Journal, port et compte d’exécution

```bash
docker logs ordering-api 2>&1 | grep -E '^(fail|crit)' | sort | uniq -c
ss -ltn | grep ':5224 '
docker exec ordering-api sh -c 'grep ^Uid: /proc/1/status'
```

`sort | uniq -c` regroupe les lignes identiques et les compte : une erreur répétée n’apparaît qu’une fois, avec son nombre d’occurrences.

Résultats vérifiés le 14 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Lignes `fail` | 1, sur la lecture de `__EFMigrationsHistory` |
| Port publié | `127.0.0.1:5224` seulement |
| Compte d’exécution | `1654` |
| Redémarrages du conteneur | Aucun |

La ligne `fail` est normale au premier démarrage : le service cherche la liste des migrations déjà appliquées, constate que la table n’existe pas, puis la crée. Le guide 02, section 7, décrit ce comportement, commun à tous les services qui utilisent PostgreSQL.

### Un avertissement de licence

Le journal contient :

```text
warn: LuckyPennySoftware.MediatR.License[0]
      You do not have a valid license key for the Lucky Penny software MediatR.
```

`Ordering.API` utilise la bibliothèque MediatR pour organiser le traitement des commandes. Ses versions récentes sont soumises à licence pour un usage en production, et le signalent au démarrage. Pour un usage d’apprentissage, l’avertissement est sans conséquence. `Identity.API` affiche un avertissement du même type pour la bibliothèque Duende IdentityServer.

## 5. Points ouverts

1. **Le service n’a pas de contrôle de santé.** `OrderProcessor`, qui a besoin des tables créées par `Ordering.API`, ne pourra attendre que son démarrage, et non la fin de ses migrations. Ce point est traité avec `OrderProcessor`.
2. **Le port publié n’est utile qu’aux tests.**
3. **La création d’une commande n’est pas testée.** Elle demande un utilisateur connecté et un panier, donc `WebApp`.

## 6. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Image construite par Compose | `ordering-api:latest`, 361 Mo |
| Attente de PostgreSQL et RabbitMQ `healthy`, et d’Identity.API démarré | Oui |
| `/api/orders` sans jeton | `401` |
| Tables créées | 7 dans le schéma `ordering`, 4 migrations |
| Données de référence | 3 types de carte |
| File RabbitMQ `Ordering` | 1 consommateur |
| Erreurs dans le journal | 1, attendue au premier démarrage |
| Port publié | `127.0.0.1:5224` seulement |
| Compte d’exécution | `1654` |
| Création d’une commande | Non testée |

## 7. Étape suivante

Ajouter `OrderProcessor`. Ce service utilise la base `orderingdb` sans la créer : il doit donc attendre qu’`Ordering.API` ait créé ses tables, et non seulement que PostgreSQL soit prêt. Voir [10 — Docker Compose : OrderProcessor](10-compose-order-processor.md).

## 8. Commandes de référence

```bash
# Construire l'image et démarrer le service
docker compose -f docker/docker-compose.yaml up -d ordering-api

# Attendre que le service réponde
until curl -s -o /dev/null http://127.0.0.1:5224/; do sleep 1; done; echo prêt

# Contrôle d'accès
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:5224/api/orders?api-version=1.0'

# Tables de la base
docker exec postgres psql -U postgres -d orderingdb -c '\dt ordering.*'

# Erreurs du journal, regroupées
docker logs ordering-api 2>&1 | grep -E '^(fail|crit)' | sort | uniq -c
```

**Bilan :** `Ordering.API` démarre avec Docker Compose, attend ses dépendances, contrôle l’accès à ses données, crée les tables de `orderingdb` et s’abonne au bus de messages. La base est prête pour `OrderProcessor`.
