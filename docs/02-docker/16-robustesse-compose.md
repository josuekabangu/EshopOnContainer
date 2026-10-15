# 16 — Robustesse du fichier Compose

## 1. Objectif

Le guide [15](15-controles-de-sante.md) a donné un contrôle de santé à chaque conteneur. Une revue extérieure du fichier Compose a ensuite relevé d’autres faiblesses, qui ne concernent pas la santé mais la tenue de l’ensemble dans la durée :

- un service qui s’arrête reste arrêté ;
- les journaux grossissent sans limite ;
- un service peut consommer toute la mémoire de WSL2 ;
- l’image PostgreSQL n’est plus mise à jour, et son étiquette `latest` rend le résultat imprévisible.

Ce guide traite ces quatre points, puis dit ce qui a été écarté de la revue, et pourquoi.

**État au 15 octobre 2026 :** les douze conteneurs redémarrent seuls, leurs journaux sont plafonnés, leur mémoire aussi, et PostgreSQL tourne sur l’image officielle de pgvector, à une version figée.

## 2. Des réglages communs, définis une fois

Les trois premiers réglages valent pour tous les conteneurs. Ils sont regroupés en tête du fichier, dans un bloc réutilisable :

```yaml
x-defaults: &defaults
  restart: unless-stopped
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
  deploy:
    resources:
      limits:
        memory: 512M
```

Chaque service l’inclut par une ligne, placée en premier :

```yaml
  postgres:
    <<: *defaults
    image: pgvector/pgvector:0.8.7-pg15
    ...
```

`<<:` est la clé de fusion de YAML : elle recopie dans le service tout le contenu du bloc `defaults`. Une clé écrite explicitement dans le service l’emporte sur celle du bloc. Redis et RabbitMQ s’en servent pour leur plafond de mémoire, voir section 5.

Le bloc `x-service-healthcheck` du guide 15 suit le même principe.

## 3. Le redémarrage automatique

```yaml
  restart: unless-stopped
```

Sans ce réglage, un conteneur dont le processus s’arrête reste arrêté. Le guide 07 l’avait montré : `Catalog.API` s’arrête au démarrage si sa base est injoignable, ses migrations ayant échoué.

| Valeur | Comportement |
|---|---|
| `no` (par défaut) | Jamais de redémarrage |
| `on-failure` | Redémarrage si le processus s’arrête sur une erreur |
| `always` | Redémarrage dans tous les cas, y compris au démarrage de Docker, même après un arrêt manuel |
| `unless-stopped` | Comme `always`, sauf si le conteneur a été arrêté à la main |

`unless-stopped` respecte un `docker stop` volontaire, tout en relançant l’application au démarrage de WSL2.

Ce réglage ne concerne que l’arrêt du processus. Compose ne redémarre **jamais** un conteneur parce qu’il est `unhealthy`. Ce rôle reviendra aux probes de Kubernetes (guide 15, section 10).

## 4. La rotation des journaux

```yaml
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
```

Docker conserve la sortie de chaque conteneur dans un fichier, sans limite par défaut. Les services d’eShop écrivent beaucoup : chaque requête SQL apparaît dans leur journal. Avec ce réglage, Docker change de fichier à 10 Mo et n’en garde que trois : 30 Mo au plus par conteneur.

`docker logs` ne montre alors que ces trois fichiers. Pour une analyse plus longue, il faudra un système de collecte des journaux, prévu dans la phase d’observabilité du projet.

## 5. Les plafonds de mémoire

### Mesurer avant de plafonner

Un plafond trop bas fait arrêter le service par le noyau dès qu’il le dépasse. La consommation réelle a donc été mesurée d’abord, application démarrée :

```bash
docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}'
```

| Conteneurs | Consommation mesurée le 15 octobre 2026 |
|---|---|
| Services .NET | De 41 Mio (`payment-processor`) à 111 Mio (`ordering-api`, `catalog-api`) |
| PostgreSQL | 55 Mio |
| RabbitMQ | 135 Mio |
| Redis | 4 Mio |

### Les plafonds retenus

| Conteneurs | Plafond | Raison |
|---|---|---|
| Services .NET et PostgreSQL | 512 Mio, valeur du bloc `defaults` | Plus de quatre fois la mesure ; le ramasse-miettes de .NET adapte sa taille au plafond du conteneur |
| Redis | **1280 Mio** | Redis est configuré avec `--maxmemory 1gb` (guide 04). Avec un plafond plus bas, le noyau l’arrêterait avant qu’il ne refuse les écritures, et la politique `noeviction` ne jouerait jamais |
| RabbitMQ | **1 Gio** | RabbitMQ bloque les publications quand il atteint 40 % de la mémoire disponible. Avec 512 Mio, ce seuil serait à 205 Mio, trop près de sa consommation de 135 Mio |

Redis et RabbitMQ déclarent leur propre bloc `deploy`, qui remplace celui de `defaults` :

```yaml
  redis:
    <<: *defaults
    ...
    deploy:
      resources:
        limits:
          memory: 1280M
```

### Vérifier

```bash
docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}'
```

Résultat vérifié, extrait :

```text
catalog-api|71.79MiB / 512MiB
postgres|42.58MiB / 512MiB
rabbitmq|132.1MiB / 1GiB
redis|3.734MiB / 1.25GiB
```

La seconde valeur de chaque ligne est le plafond appliqué.

## 6. L’image PostgreSQL

### Le problème

eShop utilise `ankane/pgvector:latest` (guide 01, section 6). Deux défauts :

- **L’image n’est plus mise à jour.** Elle date du 11 octobre 2023. Le projet pgvector publie désormais son image officielle, `pgvector/pgvector`.
- **`latest` ne désigne pas une version.** Une étiquette qui change de contenu rend le résultat d’un `docker compose up` imprévisible d’une machine ou d’une date à l’autre.

### La version retenue

```yaml
    image: pgvector/pgvector:0.8.7-pg15
```

| Choix | Raison |
|---|---|
| `pgvector/pgvector` | Image officielle du projet pgvector |
| `0.8.7` | Version de pgvector figée. L’étiquette `pg15` désigne aujourd’hui la même image, mais suivra les futures versions |
| `pg15` | Même version majeure que le volume existant. PostgreSQL ne lit pas un répertoire de données créé par une autre version majeure : passer en 16 obligerait à recréer ou migrer le volume |

C’est un écart avec le code d’eShop, qui conserve `ankane/pgvector`. Il ne touche que le fichier Compose : le code d’eShop n’est pas modifié.

### Le changement d’image, sur le volume existant

Le changement a été fait sans supprimer le volume :

| Contrôle | Avant | Après |
|---|---|---|
| Version de PostgreSQL | 15.4 | 15.19 |
| Lecture du volume | — | Réussie, aucune erreur d’incompatibilité dans le journal |
| Articles du catalogue | 101 | 101 |
| Colonne `Embedding` | `vector(384)` | `vector(384)` |
| Douze conteneurs `healthy` | Oui | Oui |

Une version mineure plus récente de PostgreSQL lit sans difficulté les données d’une version mineure plus ancienne de la même version majeure.

### Une étape manuelle : mettre à jour l’extension

Changer d’image remplace le programme de l’extension `vector`, mais pas sa version déclarée dans chaque base :

```bash
docker exec postgres psql -U postgres -d catalogdb -Atc \
  "select extversion from pg_extension where extname = 'vector'"
docker exec postgres psql -U postgres -d catalogdb -Atc \
  "select default_version from pg_available_extensions where name = 'vector'"
```

```text
0.5.1
0.8.7
```

La base déclarait encore la version 0.5.1, alors que l’image fournit la 0.8.7. La mise à jour se fait par une commande SQL :

```bash
docker exec postgres psql -U postgres -d catalogdb -c 'ALTER EXTENSION vector UPDATE'
```

Après la commande, la version déclarée est `0.8.7`. Sur un volume neuf, l’étape est inutile : `Catalog.API` installe directement la dernière version disponible.

## 7. Ce qui a été écarté de la revue, et pourquoi

Chaque affirmation de la revue a été vérifiée sur le poste avant d’être retenue.

| Affirmation | Verdict | Vérification |
|---|---|---|
| Le contrôle PostgreSQL utilise `-U postgres` alors que l’utilisateur est différent, d’où des erreurs `role "postgres" does not exist` | Faux pour ce poste | `POSTGRES_USER` vaut `postgres`, et le journal ne contient aucune erreur de ce type. Le contrôle suit tout de même la variable désormais (guide 15) |
| Les jetons portent un émetteur `localhost:5223` différent de celui des API, d’où des erreurs 401 | Faux | Le navigateur utilise lui aussi `identity-api:5223`, grâce au fichier `hosts` (guide 13). Deux connexions ont réussi |
| Le script `init-db.sh` peut avoir des fins de ligne Windows | Déjà réglé | `.gitattributes` impose `eol=lf` aux fichiers `.sh`, et le fichier est en LF |
| `start_period` à allonger pour les services qui appliquent des migrations | Inutile | Les migrations prennent quelques secondes ; les services concernés sont `healthy` bien avant la fin de `start_period` |
| `container_name` empêche de lancer plusieurs instances d’un service | Exact, mais conservé | Toutes les commandes des guides utilisent ces noms fixes. Lancer plusieurs instances relève de Kubernetes |
| Les accès à `/mnt/f` sont lents depuis WSL2 | Exact, reporté | Chaque construction passe environ 7,5 s à transférer un contexte de 103 Ko. Déplacer le dépôt dans le système de fichiers de WSL2 est une décision à part : Vagrant, VS Code et les scripts Windows l’utilisent là où il est |

## 8. Points ouverts

1. **Les mots de passe restent lisibles avec `docker inspect`**, dans les variables des conteneurs (guide 04, section 6). Sur le cluster, ils seront fournis par des objets `Secret` de Kubernetes.
2. **L’emplacement du dépôt sur `/mnt/f` ralentit les constructions**, voir section 7.
3. **Les autres images restent sur des étiquettes mouvantes** : `redis:7` et `rabbitmq:4-management` suivent leurs versions mineures. Elles pourront être figées de la même façon que PostgreSQL.

## 9. Tableau de validation

| Contrôle | Résultat au 15 octobre 2026 |
|---|---|
| Politique de redémarrage des douze conteneurs | `unless-stopped` |
| Rotation des journaux | `max-size: 10m`, `max-file: 3` |
| Plafonds de mémoire | 512 Mio par défaut, 1280 Mio pour Redis, 1 Gio pour RabbitMQ |
| Image PostgreSQL | `pgvector/pgvector:0.8.7-pg15`, PostgreSQL 15.19 |
| Volume existant relu après changement d’image | Oui, 101 articles |
| Extension `vector` | Mise à jour de 0.5.1 à 0.8.7 |
| Douze conteneurs `healthy` après les changements | Oui |

## 10. Commandes de référence

```bash
# Politique de redémarrage et rotation des journaux d'un conteneur
docker inspect postgres --format '{{.HostConfig.RestartPolicy.Name}} {{.HostConfig.LogConfig.Config}}'

# Consommation et plafond de mémoire
docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}'

# Version de PostgreSQL et de l'extension vector
docker exec postgres psql -U postgres -Atc 'show server_version'
docker exec postgres psql -U postgres -d catalogdb -Atc "select extversion from pg_extension where extname = 'vector'"

# Mettre à jour l'extension après un changement d'image
docker exec postgres psql -U postgres -d catalogdb -c 'ALTER EXTENSION vector UPDATE'
```

**Bilan :** le fichier Compose tient désormais dans la durée : les services redémarrent seuls, leurs journaux et leur mémoire sont plafonnés, et PostgreSQL repose sur une image maintenue, à une version figée. Les points de la revue ont été retenus ou écartés après vérification sur le poste, et non sur parole.
