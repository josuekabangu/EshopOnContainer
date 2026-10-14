# 07 — Docker Compose : Catalog.API

## 1. Objectif

Le guide [06](06-compose-identity.md) a ajouté `Identity.API` au fichier Compose. Ce guide y ajoute `Catalog.API`, qui fournit le catalogue des articles.

Comme `Identity.API`, ce service ne dépend d’aucun autre service de l’application. Il est en revanche le premier à utiliser RabbitMQ : il publie des messages quand un article change, par exemple quand son prix est modifié.

Les objectifs sont de :

- transmettre au service ses deux chaînes de connexion, vers PostgreSQL et vers RabbitMQ ;
- le faire attendre que ses deux dépendances soient prêtes ;
- vérifier qu’il répond, qu’il charge son catalogue et qu’il est relié au bus de messages.

**Périmètre :** `Catalog.API` seul. La construction de l’image par Compose (`build`, `image`, `pull_policy`) fonctionne comme pour `Identity.API` et n’est pas réexpliquée : voir le guide 06, section 3.

**État au 14 octobre 2026 :** `Catalog.API` démarre avec Docker Compose, répond depuis le poste, a chargé ses 101 articles et est abonné à RabbitMQ.

## 2. Le service dans le fichier Compose

```yaml
  # =====================================================================
  # CATALOG.API
  # =====================================================================
  catalog-api:
    image: catalog-api
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/Catalog.API/Dockerfile
    container_name: catalog-api
    environment:
      ConnectionStrings__catalogdb: "Host=postgres;Port=5432;Database=catalogdb;Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}"
      ConnectionStrings__eventbus: "amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
    ports:
      - "127.0.0.1:5102:8080"
    depends_on:
      postgres:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    networks:
      - eshop-network
```

Aucune variable nouvelle n’est à ajouter au fichier `.env` : le service réutilise celles de PostgreSQL et de RabbitMQ.

## 3. La configuration du service

### Les deux chaînes de connexion

| Variable | Ce qu’elle désigne |
|---|---|
| `ConnectionStrings__catalogdb` | La base `catalogdb` sur le conteneur `postgres` |
| `ConnectionStrings__eventbus` | RabbitMQ, sur le conteneur `rabbitmq`, port `5672` |

Les noms `catalogdb` et `eventbus` sont ceux que le code de `Catalog.API` attend. Les hôtes, `postgres` et `rabbitmq`, sont les noms des services dans le fichier Compose.

### Le mot de passe dans une adresse

La connexion à RabbitMQ s’écrit sous forme d’adresse :

```text
amqp://<utilisateur>:<mot-de-passe>@rabbitmq:5672/
```

Dans une adresse, les caractères `@`, `:`, `/`, `?`, `#` et `%` ont un sens particulier. Un mot de passe qui en contient serait mal découpé, et la connexion échouerait avec un message trompeur. Le mot de passe RabbitMQ doit donc éviter ces caractères, ou les encoder : `@` s’écrit alors `%40`, par exemple.

La chaîne vers PostgreSQL n’a pas cette contrainte. Seul le caractère `;`, qui y sépare les paramètres, est à éviter.

### Deux dépendances à attendre

```yaml
    depends_on:
      postgres:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
```

Compose ne démarre `Catalog.API` qu’une fois PostgreSQL **et** RabbitMQ à l’état `healthy`.

La sortie de `docker compose up` montre cette attente :

```text
 ✔ Container postgres    Healthy
 ✔ Container rabbitmq    Healthy
 ✔ Container catalog-api Started
```

Le contrôle de santé de RabbitMQ prend ici toute son importance. `check_port_connectivity`, choisi dans le guide 05, garantit que le port `5672` est ouvert. Avec `ping`, `Catalog.API` aurait pu démarrer avant l’ouverture du port, et sa première connexion aurait échoué.

### Le port

```yaml
    ports:
      - "127.0.0.1:5102:8080"
```

Aucun navigateur n’a besoin de joindre `Catalog.API` : `WebApp` l’interrogera par le réseau Docker. Le port sert seulement à tester l’API depuis le poste, et n’est donc ouvert que sur l’adresse locale. Il pourra être retiré une fois `WebApp` en place.

La première version publiait le port sans adresse (`"5102:8080"`), donc sur toutes les interfaces du poste. La commande `ss -ltn` affichait alors deux lignes, `0.0.0.0:5102` et `[::]:5102`.

## 4. Démarrer

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d catalog-api
docker compose -f docker/docker-compose.yaml ps catalog-api
```

Résultat vérifié le 14 octobre 2026 :

```text
NAME          IMAGE         ...   STATUS         PORTS
catalog-api   catalog-api   ...   Up 7 minutes   127.0.0.1:5102->8080/tcp
```

### Attendre que le service réponde

Un conteneur démarré n’est pas un service prêt. Le journal de `Catalog.API` a montré :

| Événement | Heure |
|---|---|
| Démarrage du conteneur | `15:57:37.80` |
| `Now listening on: http://[::]:8080` | `15:57:39.45` |

Pendant 1,6 seconde, le port `5102` est ouvert par Docker, mais l’application n’y répond pas encore. Une requête envoyée juste après `docker compose up` renvoie alors le code `000`, qui signifie « aucune réponse ». Ce cas s’est produit pendant la mise au point.

Pour attendre la première réponse :

```bash
until curl -sf -o /dev/null 'http://127.0.0.1:5102/api/catalog/catalogTypes?api-version=1.0'; do sleep 1; done; echo prêt
```

`-f` fait échouer `curl` sur tout code d’erreur, y compris l’absence de réponse. La boucle recommence donc jusqu’à la première réponse réussie.

`docker compose ps` ne peut pas indiquer ce moment : le service n’a pas de contrôle de santé, voir section 6.

## 5. Vérifier

### L’API répond et lit la base

```bash
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:5102/api/catalog/catalogTypes?api-version=1.0'
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:5102/api/catalog/items?api-version=1.0&pageSize=1'
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:5102/api/catalog/items/1/pic?api-version=1.0'
```

Résultats vérifiés le 14 octobre 2026 : `200` pour les trois. La dernière requête renvoie l’image d’un article. Depuis le navigateur de Windows, `http://localhost:5102/api/catalog/catalogTypes?api-version=1.0` répond aussi `200`.

### La base est initialisée

```bash
docker exec postgres psql -U postgres -d catalogdb -Atc 'select count(*) from "Catalog"'
```

Résultat vérifié : `101` articles.

Au premier démarrage, `Catalog.API` a créé cinq tables (`Catalog`, `CatalogBrand`, `CatalogType`, `IntegrationEventLog`, `__EFMigrationsHistory`) et installé l’extension `vector`, en version `0.5.1`. Le script `init-db.sh` du guide 03 ne crée que la base : l’extension est installée par le service lui-même.

### La connexion à RabbitMQ

La connexion se vérifie du côté du broker. Le journal du service indique seulement qu’il tente de se connecter.

```bash
docker exec rabbitmq rabbitmqctl -q list_connections user state
docker exec rabbitmq rabbitmqctl -q list_queues name consumers
docker exec rabbitmq rabbitmqctl -q list_exchanges name type | grep eshop
```

Résultats vérifiés le 14 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Connexion | `eshop_rabbit`, à l’état `running` |
| File | `Catalog`, avec `1` consommateur |
| Point d’échange | `eshop_event_bus`, de type `direct` |

`Catalog.API` a créé le point d’échange commun à tous les services, puis sa propre file, à laquelle il s’est abonné.

### Le port et le compte d’exécution

```bash
ss -ltn | grep ':5102 '
docker exec catalog-api sh -c 'grep ^Uid: /proc/1/status'
```

Résultats vérifiés : une seule ligne, `127.0.0.1:5102`, puis le compte `1654`, non privilégié.

## 6. Points ouverts

1. **Le service n’a pas de contrôle de santé.** `/health` répond `404`, comme pour `Identity.API`. `WebApp`, qui dépendra de `Catalog.API`, ne pourra attendre que son démarrage, et non le moment où il répond.
2. **Le port publié n’est utile qu’aux tests.** Il pourra être retiré une fois `WebApp` en place.

## 7. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Image construite par Compose | `catalog-api:latest`, 381 Mo |
| Attente de PostgreSQL et de RabbitMQ `healthy` | Oui |
| Types, articles, image d’un article | HTTP 200 |
| Articles en base | 101 |
| Extension `vector` | Installée par le service, version `0.5.1` |
| Connexion RabbitMQ | Établie, `running` |
| File `Catalog` | 1 consommateur |
| Port publié | `127.0.0.1:5102` seulement |
| Compte d’exécution | `1654` |
| Contrôle de santé | Absent |

## 8. Étape suivante

Ajouter les services qui dépendent d’`Identity.API` : `Basket.API`, `Ordering.API` et `Webhooks.API`. `Basket.API` utilisera aussi Redis, avec le mot de passe défini dans le guide 04.

## 9. Commandes de référence

```bash
# Construire l'image et démarrer le service
docker compose -f docker/docker-compose.yaml up -d catalog-api

# Attendre que le service réponde
until curl -sf -o /dev/null 'http://127.0.0.1:5102/api/catalog/catalogTypes?api-version=1.0'; do sleep 1; done; echo prêt

# Journaux du service
docker compose -f docker/docker-compose.yaml logs catalog-api

# Files RabbitMQ et consommateurs
docker exec rabbitmq rabbitmqctl -q list_queues name consumers
```

**Bilan :** `Catalog.API` démarre avec Docker Compose, attend PostgreSQL et RabbitMQ, charge son catalogue et s’abonne au bus de messages. C’est le premier service relié à RabbitMQ.
