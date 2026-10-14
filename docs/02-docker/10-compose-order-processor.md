# 10 — Docker Compose : OrderProcessor

## 1. Objectif

Le guide [09](09-compose-ordering.md) a ajouté `Ordering.API`, qui crée les tables de la base `orderingdb`. Ce guide y ajoute `OrderProcessor`, qui lit ces tables sans jamais les créer.

`OrderProcessor` n’a pas d’API. C’est une tâche de fond : toutes les 30 secondes, il cherche les commandes à l’état `Submitted` depuis plus d’une minute. Pour chacune, il publie un message sur RabbitMQ, qui fait avancer la commande vers l’étape suivante.

Ce service pose une question nouvelle : **que se passe-t-il s’il démarre avant que ses tables existent ?** Compose ne peut pas l’empêcher, puisqu’`Ordering.API` n’a pas de contrôle de santé. Ce guide répond à la question par la lecture du code, puis par un test.

Les objectifs sont de :

- ajouter le service avec sa configuration ;
- vérifier qu’il fonctionne, alors qu’il n’a aucun port à interroger ;
- observer son comportement quand il démarre avant les tables.

**Périmètre :** `OrderProcessor` seul. La construction de l’image par Compose est décrite dans le guide 06, section 3.

**État au 14 octobre 2026 :** `OrderProcessor` démarre avec Docker Compose, lit les tables d’`Ordering.API` toutes les 30 secondes et est abonné à RabbitMQ. Démarré avant les tables, il signale l’erreur puis se rétablit seul.

## 2. Le service dans le fichier Compose

```yaml
  # =====================================================================
  # ORDERPROCESSOR
  # =====================================================================
  order-processor:
    image: order-processor
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/OrderProcessor/Dockerfile
    container_name: order-processor
    environment:
      ConnectionStrings__orderingdb: "Host=postgres;Port=5432;Database=orderingdb;Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}"
      ConnectionStrings__eventbus: "amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
    depends_on:
      postgres:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      ordering-api:
        condition: service_started
    networks:
      - eshop-network
```

Trois différences avec les services précédents :

| Différence | Raison |
|---|---|
| Pas de bloc `ports:` | Le service ne sert aucune page : toute requête HTTP reçoit `404` (guide 02, section 7) |
| Pas d’`Identity__Url` | Le service ne reçoit aucune requête d’utilisateur |
| Dépendance à `ordering-api` | Le service lit les tables qu’`Ordering.API` crée |

La chaîne de connexion à `orderingdb` est la même que celle d’`Ordering.API` : les deux services partagent la base.

Deux réglages du service gardent leur valeur par défaut, définie dans `OrderProcessor/appsettings.json` :

| Réglage | Valeur | Signification |
|---|---|---|
| `BackgroundTaskOptions:CheckUpdateTime` | `30` | Délai, en secondes, entre deux recherches |
| `BackgroundTaskOptions:GracePeriodTime` | `1` | Durée, en minutes, pendant laquelle une commande reste à l’état `Submitted` avant d’être traitée |

## 3. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d order-processor
docker compose -f docker/docker-compose.yaml ps order-processor
```

Résultat vérifié le 14 octobre 2026 :

```text
NAME              IMAGE             ...   STATUS                  PORTS
order-processor   order-processor   ...   Up Less than a second   8080/tcp
```

`8080/tcp` sans adresse : le port existe dans le conteneur, mais n’est pas publié.

Le service n’ayant pas de port à interroger, la vérification passe par ses dépendances et par son journal. Il faut attendre au moins 30 secondes après le démarrage, pour que la tâche de fond ait fait un premier passage.

### L’abonnement à RabbitMQ

```bash
docker exec rabbitmq rabbitmqctl -q list_queues name consumers
```

Résultat vérifié :

```text
name            consumers
OrderProcessor  1
Ordering        1
Catalog         1
Basket          1
```

### Le travail réel du service : sa requête dans PostgreSQL

Un service sans API ne peut pas être testé par une requête. La preuve de son travail se lit dans PostgreSQL, qui expose les connexions ouvertes et leur dernière requête dans la vue `pg_stat_activity` :

```bash
docker exec postgres psql -U postgres -Atc \
  "select client_addr, state, left(query, 40) from pg_stat_activity where datname = 'orderingdb'"
```

L’adresse affichée se compare à celle des conteneurs :

```bash
docker inspect order-processor --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

Résultat vérifié le 14 octobre 2026 :

| Adresse du client | Conteneur | État | Dernière requête |
|---|---|---|---|
| `172.19.0.9` | `order-processor` | `idle` | `SELECT "Id" FROM ordering.orders WHERE ...` |

La requête est exactement celle du code d’`OrderProcessor`. Elle prouve que la tâche de fond s’exécute et lit les tables d’`Ordering.API`.

La connexion reste ouverte entre deux recherches, à l’état `idle` (inactive) : le service la réutilise toutes les 30 secondes. `Ordering.API`, sans requête à traiter, n’avait à ce moment aucune connexion ouverte. Le nombre de connexions ne dit donc pas quels services fonctionnent : seule leur dernière requête l’indique.

### Journal et compte d’exécution

```bash
docker logs order-processor 2>&1 | grep -c -E '^(fail|crit)'
docker inspect order-processor --format '{{.State.Status}} redémarrages={{.RestartCount}}'
docker exec order-processor sh -c 'grep ^Uid: /proc/1/status'
```

Résultats vérifiés : `0` erreur, `running redémarrages=0`, et le compte `1654`.

## 4. Démarrer avant les tables

### Ce que dit le code

Compose attend seulement le démarrage d’`Ordering.API`, pas la fin de ses migrations. Sur des volumes vides, `OrderProcessor` peut donc interroger `ordering.orders` avant que la table existe.

La requête est écrite dans `OrderProcessor/Services/GracePeriodOrdersRepository.cs` :

```csharp
catch (NpgsqlException exception)
{
    logger.LogError(exception, "Error querying confirmed grace period orders after grace period {GracePeriod}", gracePeriod);
    return [];
}
```

Une erreur de PostgreSQL est interceptée : le service l’écrit dans son journal, considère qu’il n’y a aucune commande, et réessaie au passage suivant. Il ne devrait donc ni s’arrêter, ni rester bloqué.

### Le test

Le test provoque volontairement le cas, au lieu d’attendre qu’il se produise par hasard.

> **Attention :** `down -v` supprime les volumes, donc toutes les données de PostgreSQL, Redis et RabbitMQ. Elles sont recréées au démarrage des services. Ce test ne convient qu’à un environnement de travail.

```bash
C='docker compose -f docker/docker-compose.yaml'

# 1. Repartir de volumes vides
$C down -v

# 2. Démarrer les dépendances seules
$C up -d postgres rabbitmq

# 3. Vérifier que les tables n'existent pas
docker exec postgres psql -U postgres -d orderingdb -Atc \
  "select count(*) from pg_tables where schemaname = 'ordering'"

# 4. Démarrer OrderProcessor sans Ordering.API
$C up -d --no-deps order-processor
```

`C` est une variable du terminal qui raccourcit la commande Compose. `--no-deps` démarre le service sans ses dépendances : `Ordering.API` reste arrêté, et les tables n’existent pas.

Après 70 secondes, le journal est consulté, puis `Ordering.API` est démarré :

```bash
docker logs -t order-processor 2>&1 | grep 'Error querying'
$C up -d ordering-api
```

Résultats vérifiés le 14 octobre 2026 :

| Heure (UTC) | Événement |
|---|---|
| `21:28:50` | Tables dans le schéma `ordering` : `0` |
| `21:28:50` | Démarrage d’`OrderProcessor` seul |
| `21:28:57` | Erreur n° 1 |
| `21:29:27` | Erreur n° 2 |
| `21:29:57` | Erreur n° 3 |
| `21:30:07` | `OrderProcessor` toujours `running`, aucun redémarrage ; démarrage d’`Ordering.API` |
| `21:30:18` | `Ordering.API` répond ; tables dans le schéma `ordering` : `7` |
| `21:31:29` | Toujours 3 erreurs au total : aucune nouvelle depuis la création des tables |

Chaque erreur contient :

```text
fail: eShop.OrderProcessor.Services.GracePeriodOrdersRepository[0]
      Error querying confirmed grace period orders after grace period 00:01:00
      Npgsql.PostgresException (0x80004005): 42P01: relation "ordering.orders" does not exist
```

`42P01` est le code PostgreSQL d’une table inexistante.

### Ce que le test établit

- Les erreurs arrivent exactement toutes les 30 secondes, au rythme de `CheckUpdateTime`.
- Le service ne s’arrête pas et ne redémarre pas.
- Dès que les tables existent, les erreurs cessent sans aucune intervention. La dernière requête de sa connexion redevient la recherche dans `ordering.orders`.

Le démarrage dans le désordre est donc sans conséquence durable : au pire, quelques lignes `fail` dans le journal. Aucune protection supplémentaire n’est nécessaire dans le fichier Compose.

Avec `depends_on` sur `ordering-api`, ce cas reste possible lors d’un démarrage sur des volumes vides : `Ordering.API` met quelques secondes à créer ses tables après son démarrage. Une ou deux lignes `fail` au premier démarrage d’`OrderProcessor` ne signalent donc pas une panne.

Après le test, l’ensemble a été redémarré avec `docker compose up -d` : les huit conteneurs sont revenus en fonctionnement.

## 5. Points ouverts

1. **Le service n’a pas de contrôle de santé**, comme les autres services d’eShop. Un contrôle HTTP n’aurait d’ailleurs pas de sens pour lui : il ne sert aucune page.
2. ~~Le traitement d’une commande n’est pas testé~~ : testé le 15 octobre 2026. Pour la commande n° 1, `OrderProcessor` a publié `GracePeriodConfirmed` 83 secondes après sa création, soit au premier passage suivant la fin du délai de grâce d’une minute. Voir le guide 13, section 6.

## 6. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Image construite par Compose | `order-processor:latest` |
| Attente de PostgreSQL et RabbitMQ `healthy`, et d’Ordering.API démarré | Oui |
| Port publié | Aucun, volontairement |
| File RabbitMQ `OrderProcessor` | 1 consommateur |
| Requête périodique sur `ordering.orders` | Observée dans `pg_stat_activity` |
| Erreurs dans le journal, tables présentes | 0 |
| Démarrage avant les tables | Une erreur toutes les 30 s, aucun arrêt |
| Rétablissement après création des tables | Automatique, aucune nouvelle erreur |
| Compte d’exécution | `1654` |
| Traitement d’une commande | Testé le 15 octobre 2026, `GracePeriodConfirmed` publié pour la commande n° 1 (guide 13) |

## 7. Étape suivante

Ajouter `PaymentProcessor`, le second service sans API, qui simule le paiement des commandes. Il ne dépend que de RabbitMQ. Voir [11 — Docker Compose : PaymentProcessor](11-compose-payment-processor.md).

## 8. Commandes de référence

```bash
# Construire l'image et démarrer le service
docker compose -f docker/docker-compose.yaml up -d order-processor

# Dernière requête de chaque connexion à orderingdb
docker exec postgres psql -U postgres -Atc \
  "select client_addr, state, left(query, 40) from pg_stat_activity where datname = 'orderingdb'"

# Adresse du conteneur, à comparer
docker inspect order-processor --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

# Erreurs de la tâche de fond, horodatées
docker logs -t order-processor 2>&1 | grep 'Error querying'

# Démarrer un service sans ses dépendances
docker compose -f docker/docker-compose.yaml up -d --no-deps order-processor
```

**Bilan :** `OrderProcessor` démarre avec Docker Compose et lit toutes les 30 secondes les tables créées par `Ordering.API`. Démarré avant elles, il signale l’erreur sans s’arrêter et se rétablit seul dès qu’elles existent.
