# 03 — Docker Compose : PostgreSQL

## 1. Objectif

Les guides [01](01-catalog-api.md) et [02](02-autres-services.md) ont démarré les conteneurs un par un, avec des commandes `docker run` et une douzaine de variables. Cette méthode suffit pour tester une image, mais elle ne se rejoue pas facilement : la configuration n’est écrite nulle part ailleurs que dans le terminal.

Docker Compose décrit l’ensemble dans un fichier : les conteneurs, leur configuration, leurs volumes et leur réseau. Une seule commande démarre alors le tout, de façon identique à chaque fois.

Ce guide pose la première brique de ce fichier : la base de données PostgreSQL.

Les objectifs sont de :

- décrire PostgreSQL dans `docker/docker-compose.yaml` ;
- fournir les identifiants par un fichier `.env` non versionné ;
- créer les bases de l’application au premier démarrage ;
- vérifier que la base exige un mot de passe et n’est pas exposée sur le poste.

**Périmètre :** PostgreSQL seul. RabbitMQ, Redis et les neuf services seront ajoutés au même fichier dans les guides suivants.

**État au 14 octobre 2026 :** PostgreSQL démarre avec Docker Compose, passe à l’état `healthy` et refuse un mot de passe faux.

## 2. Fichiers concernés

```text
docker/
├── docker-compose.yaml          # Description des conteneurs
├── .env.example                 # Modèle des variables, versionné
├── .env                         # Valeurs réelles, non versionné
└── scripts/
    └── postgres/
        └── init-db.sh           # Création des bases au premier démarrage
```

| Fichier | Versionné | Rôle |
|---|---|---|
| `docker-compose.yaml` | Oui | Décrit le conteneur PostgreSQL, son volume et son réseau |
| `.env.example` | Oui | Indique quelles variables fournir, avec des valeurs factices |
| `.env` | Non, exclu par `.gitignore` | Contient l’utilisateur et le mot de passe réels |
| `scripts/postgres/init-db.sh` | Oui | Crée les quatre bases de l’application |

## 3. Le fichier Compose

> **Mise à jour du 15 octobre 2026.** Le bloc ci-dessous est la première version. Trois éléments ont changé depuis : l’image est désormais `pgvector/pgvector:0.8.7-pg15` (guide 16, section 6), le contrôle de santé est `pg_isready -h 127.0.0.1 -U $${POSTGRES_USER} -d postgres` (guide 15, section 8), et le service reçoit les réglages communs de redémarrage, de journaux et de mémoire (guide 16). Les explications de ce guide restent valables pour le reste.

```yaml
services:
  # =====================================================================
  # POSTGRES PGVECTOR
  # =====================================================================
  postgres:
    image: ankane/pgvector:latest
    container_name: postgres
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./scripts/postgres/init-db.sh:/docker-entrypoint-initdb.d/01-init-db.sh
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 10s
      retries: 5
    networks:
      - eshop-network

volumes:
  pg_data:

networks:
  eshop-network:
    driver: bridge
```

### Le service `postgres`

- `image: ankane/pgvector:latest` : PostgreSQL avec l’extension `vector`, dont `Catalog.API` a besoin. Le choix de cette image est expliqué dans le guide 01, section 6.
- `container_name: postgres` : nom fixe du conteneur. Sans cette ligne, Compose le nommerait `docker-postgres-1`. Sur le réseau, les autres conteneurs joignent la base par le nom du service, `postgres`, dans les deux cas.
- `environment` : les variables lues par l’image au démarrage.
  - `POSTGRES_USER` et `POSTGRES_PASSWORD` créent le compte administrateur. Leur valeur vient du fichier `.env`, voir section 4.
  - `PGDATA` place les données dans un sous-répertoire du volume. Le répertoire monté reste ainsi vide de tout autre fichier, ce que l’outil d’initialisation de PostgreSQL exige.
- `volumes` :
  - `pg_data:/var/lib/postgresql/data` conserve les données dans un volume Docker. Elles survivent à la suppression et à la recréation du conteneur.
  - la seconde ligne monte le script d’initialisation dans `/docker-entrypoint-initdb.d/`, voir section 5.
- `healthcheck` : le contrôle de santé, voir section 6.
- `networks` : le conteneur rejoint le réseau `eshop-network`.

### Les déclarations de premier niveau

Un volume ou un réseau nommé, utilisé par un service, doit être déclaré à la racine du fichier. Sans ces déclarations, Compose refuse le fichier :

```text
service "postgres" refers to undefined network eshop-network: invalid compose project
```

`driver: bridge` crée un réseau privé sur la machine hôte. C’est le comportement par défaut, écrit ici pour être explicite.

### Les noms réels

Compose préfixe les volumes et les réseaux par le nom du projet. Ce nom est celui du répertoire qui contient le fichier, ici `docker` :

| Déclaré dans le fichier | Nom réel |
|---|---|
| `pg_data` | `docker_pg_data` |
| `eshop-network` | `docker_eshop-network` |

C’est le nom réel qu’il faut utiliser dans une commande `docker`, par exemple pour lancer un conteneur de test sur ce réseau.

### Pourquoi aucun port n’est publié

Le fichier ne contient pas de bloc `ports:`. Les services de l’application joindront PostgreSQL par le réseau Docker, sous le nom `postgres:5432`, sans passer par la machine hôte. Le guide 02 l’a vérifié : tous les services ont joint leurs dépendances sans aucun port publié.

Publier le port avec `"5432:5432"` ouvrirait la base sur toutes les interfaces du poste. Elle deviendrait joignable par tout ce qui atteint la machine, et créerait un conflit avec un autre PostgreSQL installé sur le poste. Sur Kubernetes, une base n’est de même joignable que de l’intérieur du cluster.

Pour consulter la base, il suffit de passer par le conteneur :

```bash
docker exec -it postgres psql -U postgres -d catalogdb
```

Si un outil graphique de Windows doit un jour s’y connecter, le port sera publié sur l’adresse locale seulement : `"127.0.0.1:5432:5432"`.

## 4. Les identifiants : le fichier `.env`

### Pourquoi

Le mot de passe ne doit pas figurer dans `docker-compose.yaml`, qui est versionné et donc public. Compose remplace chaque `${VARIABLE}` du fichier par une valeur lue dans un fichier `.env`, qui, lui, n’est pas versionné.

### Le modèle versionné

`docker/.env.example` indique quelles variables fournir :

```text
# Modèle de configuration pour Docker Compose.
# Copier ce fichier vers docker/.env, puis remplacer les valeurs.
# Le fichier .env n'est pas versionné.

# ======================
# POSTGRES
# ======================
POSTGRES_USER=postgres
POSTGRES_PASSWORD=changez-moi
```

### Créer le fichier réel

```bash
cp docker/.env.example docker/.env
```

Remplacer ensuite `changez-moi` par un mot de passe choisi, en éditant `docker/.env`.

Vérifier que Git ignore bien ce fichier :

```bash
git check-ignore -v docker/.env
```

Résultat attendu, qui désigne la règle du `.gitignore` responsable :

```text
.gitignore:5:.env	docker/.env
```

### Où Compose cherche le fichier

Compose lit le fichier `.env` placé **dans le répertoire du fichier Compose**, ici `docker/`. Un `.env` placé à la racine du dépôt n’est pas lu, même si la commande est lancée depuis la racine.

Ce cas s’est produit pendant la mise au point. Compose affiche alors un avertissement, puis continue avec des valeurs vides :

```text
WARN[0000] The "POSTGRES_USER" variable is not set. Defaulting to a blank string.
WARN[0000] The "POSTGRES_PASSWORD" variable is not set. Defaulting to a blank string.
```

Ces avertissements ne doivent jamais être ignorés : le conteneur démarre quand même, avec une configuration incomplète.

## 5. La création des bases : `init-db.sh`

### Pourquoi

L’application utilise quatre bases : `catalogdb`, `identitydb`, `orderingdb` et `webhooksdb`. Le guide 02, section 7, a montré que les services les créent eux-mêmes à leur premier démarrage. Les créer dès le démarrage de PostgreSQL rend cependant l’état de la base prévisible, sans dépendre de l’ordre de démarrage des services. `OrderProcessor`, en particulier, utilise `orderingdb` sans jamais la créer.

### Le script

```bash
#!/bin/bash
set -e

create_db_if_not_exists() {
  local db=$1
  local exists=$(psql -U "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_database WHERE datname='$db'")
  if [ "$exists" != "1" ]; then
    psql -U "$POSTGRES_USER" -c "CREATE DATABASE $db"
    echo "Base $db créée"
  else
    echo "Base $db existe déjà — ignoré"
  fi
}

create_db_if_not_exists catalogdb
create_db_if_not_exists orderingdb
create_db_if_not_exists webhooksdb
create_db_if_not_exists identitydb
```

- `set -e` arrête le script à la première commande en échec. L’initialisation échoue alors visiblement, au lieu de continuer à moitié.
- La fonction vérifie d’abord si la base existe, avec une requête sur le catalogue `pg_database`. Elle ne la crée que si elle est absente.
- `-tAc` demande à `psql` une sortie brute, sans en-tête ni mise en forme : la requête renvoie `1` ou rien, ce qui se compare facilement.

Le panier, `Basket.API`, utilise Redis et non PostgreSQL : il n’a pas de base ici.

### Quand le script s’exécute

L’image PostgreSQL exécute les scripts de `/docker-entrypoint-initdb.d/` **une seule fois**, lorsque le répertoire de données est vide, c’est-à-dire à la création du volume. Ensuite, le script n’est plus jamais relu.

Conséquence : modifier `init-db.sh`, ou changer `POSTGRES_USER` et `POSTGRES_PASSWORD` dans `.env`, n’a aucun effet sur un volume existant. Il faut supprimer le volume pour que la modification s’applique :

```bash
docker compose -f docker/docker-compose.yaml down -v
docker compose -f docker/docker-compose.yaml up -d
```

`down -v` supprime le conteneur **et** le volume, donc toutes les données de la base. Cette commande est sans risque tant que la base ne contient que des données recréées au démarrage des services.

Le script est enregistré avec des fins de ligne Unix (LF), comme tous les fichiers `.sh` du dépôt, grâce au fichier `.gitattributes`. Avec des fins de ligne Windows, le conteneur ne pourrait pas l’exécuter.

## 6. Le contrôle de santé

### Pourquoi

Un conteneur démarré n’est pas une base prête. PostgreSQL met quelques secondes à s’initialiser, davantage au premier démarrage. Le contrôle de santé permet à Docker de distinguer les deux états. Il servira dans les guides suivants : un service pourra attendre que PostgreSQL soit `healthy` avant de démarrer.

### Les réglages

| Réglage | Valeur | Signification |
|---|---|---|
| `test` | `pg_isready -U postgres` | Commande exécutée dans le conteneur ; elle réussit quand PostgreSQL accepte les connexions |
| `interval` | `10s` | Délai entre deux contrôles |
| `timeout` | `10s` | Durée au-delà de laquelle un contrôle est compté comme échoué |
| `retries` | `5` | Nombre d’échecs consécutifs avant l’état `unhealthy` |

`pg_isready` est fourni par l’image PostgreSQL : aucun outil n’est à installer.

> **Corrigé le 15 octobre 2026.** Sans l’option `-h`, `pg_isready` interroge le serveur par son socket local. Pendant l’exécution de `init-db.sh`, l’image fait tourner un serveur temporaire joignable par ce seul socket : le contrôle le déclarait prêt alors que les services, qui passent par TCP, ne pouvaient pas encore s’y connecter. Le contrôle est devenu `pg_isready -h 127.0.0.1 -U $${POSTGRES_USER} -d postgres`, avec `start_period` et `start_interval`. Le cas, sa reproduction et la correction sont décrits dans le guide 15, section 8.

## 7. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

### Valider le fichier

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
```

`config` lit le fichier, remplace les variables et contrôle la syntaxe, sans rien démarrer. `--quiet` n’affiche que les erreurs.

Résultat vérifié le 14 octobre 2026 : `OK`, sans aucun avertissement.

### Démarrer

```bash
docker compose -f docker/docker-compose.yaml up -d
```

`-d` démarre les conteneurs en arrière-plan et rend la main.

Au premier démarrage, Compose crée le réseau et le volume :

```text
 ✔ Network docker_eshop-network Created
 ✔ Volume docker_pg_data        Created
 ✔ Container postgres           Started
```

### État du conteneur

```bash
docker compose -f docker/docker-compose.yaml ps
```

Résultat vérifié le 14 octobre 2026 :

```text
NAME       IMAGE                    ...   STATUS                    PORTS
postgres   ankane/pgvector:latest   ...   Up 19 seconds (healthy)   5432/tcp
```

La colonne `PORTS` affiche `5432/tcp` sans adresse : le port est ouvert dans le conteneur, mais pas publié sur l’hôte.

### Bases créées

```bash
docker exec postgres psql -U postgres -Atc "select datname from pg_database order by 1"
```

Résultat vérifié le 14 octobre 2026 :

```text
catalogdb
identitydb
orderingdb
postgres
template0
template1
webhooksdb
```

Les quatre bases de l’application sont présentes. Les trois autres sont créées par PostgreSQL lui-même.

### Le mot de passe est exigé

Un conteneur temporaire, placé sur le même réseau, tente une connexion avec un mot de passe volontairement faux :

```bash
docker run --rm --network docker_eshop-network -e PGPASSWORD=faux \
  ankane/pgvector:latest psql -h postgres -U postgres -c 'select 1'
```

Résultat vérifié le 14 octobre 2026 :

```text
FATAL:  password authentication failed for user "postgres"
```

C’est l’échec attendu. Ce test vérifie aussi que le mot de passe a bien été transmis au conteneur : sans lui, PostgreSQL ne pourrait pas exiger d’authentification.

### Le port n’est pas ouvert sur le poste

```bash
ss -ltn | grep -c ':5432 '
```

`ss -ltn` liste les ports en écoute sur la machine. Résultat vérifié : `0`, aucun programme n’écoute sur le port 5432 de l’hôte.

## 8. Problèmes rencontrés pendant la mise au point

Le fichier a été mis au point en plusieurs essais. Chaque défaut ci-dessous a été constaté, puis corrigé.

| Constat | Cause | Correction |
|---|---|---|
| `refers to undefined network eshop-network` | Réseau et volume utilisés sans être déclarés | Blocs `volumes:` et `networks:` ajoutés à la racine du fichier |
| Avertissements `variable is not set` | Fichier `.env` placé à la racine du dépôt, que Compose ne lit pas | Fichier déplacé dans `docker/` |
| Mot de passe non transmis à PostgreSQL | Variable nommée `RABBITMQ_DEFAULT_PASS` dans le service `postgres` | Renommée `POSTGRES_PASSWORD` |
| Connexion acceptée avec un mot de passe faux | `POSTGRES_HOST_AUTH_METHOD: trust`, qui désactive l’authentification | Ligne retirée |
| Port 5432 ouvert sur toutes les interfaces du poste | Bloc `ports: "5432:5432"` | Bloc retiré, voir section 3 |
| Base `basketdb` créée sans utilité | Le panier utilise Redis | Ligne retirée de `init-db.sh` |

Le cas le plus trompeur est la combinaison des deuxième, troisième et quatrième lignes. Le conteneur passait à l’état `healthy`, alors qu’il avait reçu un utilisateur vide et aucun mot de passe : il ne fonctionnait que parce que `trust` acceptait toute connexion. Un conteneur `healthy` ne prouve donc pas que sa configuration est correcte. Seul le test du mot de passe faux l’a montré.

Après chaque correction de l’utilisateur, du mot de passe ou du script, le volume a dû être recréé avec `down -v`, pour la raison donnée en section 5.

## 9. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Fichier Compose valide, sans avertissement | Oui |
| Identifiants lus depuis `docker/.env`, non versionné | Oui |
| Modèle `docker/.env.example` versionné | Oui |
| Conteneur `postgres` à l’état `healthy` | Oui |
| Quatre bases de l’application créées | Oui |
| Mot de passe faux refusé | Oui |
| Port publié sur l’hôte | Non, volontairement |
| Données conservées après recréation du conteneur | Oui, dans le volume `docker_pg_data` |
| Services de l’application démarrés par Compose | Non, guides suivants |

## 10. Points ouverts

1. ~~Le contrôle de santé écrit l’utilisateur en dur~~ : corrigé le 15 octobre 2026, le contrôle utilise `$${POSTGRES_USER}` (guide 15, section 8).
2. ~~L’image porte l’étiquette `latest`~~ : remplacée le 15 octobre 2026 par `pgvector/pgvector:0.8.7-pg15`, PostgreSQL 15.19 et `vector` 0.8.7 (guide 16, section 6).
3. **Les services se connectent avec le compte administrateur.** Un compte par service, limité à sa base, serait plus sûr. Ce n’est pas nécessaire pour l’apprentissage.

## 11. Étape suivante

Ajouter au même fichier les deux autres dépendances, RabbitMQ et Redis, chacune avec son contrôle de santé. Les neuf services pourront ensuite être ajoutés, en attendant que leurs dépendances soient `healthy`.

Redis est traité dans [04 — Docker Compose : Redis](04-compose-redis.md).

## 12. Commandes de référence

```bash
# Valider le fichier sans rien démarrer
docker compose -f docker/docker-compose.yaml config --quiet && echo OK

# Démarrer en arrière-plan
docker compose -f docker/docker-compose.yaml up -d

# État des conteneurs
docker compose -f docker/docker-compose.yaml ps

# Journaux de PostgreSQL
docker compose -f docker/docker-compose.yaml logs postgres

# Ouvrir une session SQL
docker exec -it postgres psql -U postgres -d catalogdb

# Arrêter en conservant les données
docker compose -f docker/docker-compose.yaml down

# Arrêter et supprimer les données (le script d'initialisation sera rejoué)
docker compose -f docker/docker-compose.yaml down -v
```

**Bilan :** PostgreSQL démarre avec Docker Compose. Les identifiants viennent d’un fichier non versionné, les quatre bases sont créées au premier démarrage, le mot de passe est exigé et la base n’est pas exposée sur le poste.
