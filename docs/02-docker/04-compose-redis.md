# 04 — Docker Compose : Redis

## 1. Objectif

Le guide [03](03-compose-postgres.md) a décrit PostgreSQL dans `docker/docker-compose.yaml`. Ce guide y ajoute Redis, la deuxième dépendance de l’application.

Dans eShop, Redis ne sert qu’à un service : `Basket.API` y conserve le panier de chaque client. Le guide 02 l’a vérifié en démarrant `Basket.API` avec Redis.

Les objectifs sont de :

- décrire Redis dans le fichier Compose, à côté de PostgreSQL ;
- protéger Redis par un mot de passe, fourni par le fichier `.env` ;
- conserver les paniers sur disque, au-delà d’un redémarrage ;
- vérifier que Redis exige son mot de passe et n’est pas exposé sur le poste.

**Périmètre :** Redis seul. RabbitMQ et les neuf services seront ajoutés dans les guides suivants.

**État au 14 octobre 2026 :** Redis démarre avec Docker Compose, passe à l’état `healthy`, refuse toute commande sans mot de passe et conserve ses données après un redémarrage.

## 2. Fichiers concernés

| Fichier | Modification |
|---|---|
| `docker/docker-compose.yaml` | Service `redis` et volume `redis_data` ajoutés |
| `docker/.env.example` | Variable `REDIS_PASSWORD` ajoutée |
| `docker/.env` | Variable `REDIS_PASSWORD` ajoutée, avec la valeur réelle ; fichier non versionné |

## 3. Le service Redis

```yaml
  redis:
    image: redis:7
    container_name: redis
    command:
      - redis-server
      - --requirepass ${REDIS_PASSWORD}
      - --maxmemory 1gb
      - --maxmemory-policy noeviction
      - --appendonly yes
      - --appendfsync everysec
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 10s
      retries: 5
    networks:
      - eshop-network
```

Et, dans la déclaration des volumes à la racine du fichier :

```yaml
volumes:
  pg_data:
  redis_data:
```

- `image: redis:7` : l’image officielle, dans sa version majeure 7. La version réellement démarrée est `7.4.11`.
- `container_name: redis` : nom fixe du conteneur. `Basket.API` joindra Redis sous le nom du service, `redis:6379`.
- `command` : remplace la commande de démarrage de l’image, pour passer des options à `redis-server`. Elles sont expliquées en section 4.
- `volumes` : le répertoire `/data`, où Redis écrit ses fichiers, est conservé dans le volume `redis_data`. Son nom réel est `docker_redis_data`, pour la raison donnée dans le guide 03, section 3.
- `healthcheck` : le contrôle de santé, voir section 6.
- `networks` : Redis rejoint le même réseau que PostgreSQL.

Comme pour PostgreSQL, aucun port n’est publié. `Basket.API` joindra Redis par le réseau Docker, sans passer par la machine hôte. Le raisonnement est détaillé dans le guide 03, section 3.

## 4. Les options de démarrage

| Option | Effet |
|---|---|
| `--requirepass ${REDIS_PASSWORD}` | Exige un mot de passe avant toute commande. Sans lui, Redis accepte toute connexion. |
| `--maxmemory 1gb` | Limite la mémoire utilisée par les données à 1 Go. |
| `--maxmemory-policy noeviction` | Une fois la limite atteinte, refuse les nouvelles écritures au lieu de supprimer des données. |
| `--appendonly yes` | Enregistre chaque modification dans un journal sur disque. Les données survivent à un redémarrage. |
| `--appendfsync everysec` | Écrit ce journal sur le disque une fois par seconde. En cas d’arrêt brutal, au plus une seconde de modifications est perdue. |

### Pourquoi `noeviction`

Redis est souvent employé comme cache, dont on peut perdre le contenu sans dommage. Dans ce rôle, la politique `allkeys-lru` est courante : à la limite de mémoire, Redis supprime les clés les moins utilisées.

Ici, Redis ne sert pas de cache : chaque clé est le panier d’un client. Avec `allkeys-lru`, un panier disparaîtrait sans erreur ni trace. Avec `noeviction`, Redis refuse l’écriture et l’application reçoit une erreur : le problème devient visible.

Ce choix est cohérent avec `--appendonly yes` : les paniers sont traités comme des données à conserver, pas comme un cache.

### Les options écrites en un seul élément

Chaque option et sa valeur sont écrites dans un même élément de liste, par exemple `--maxmemory 1gb`. Ce n’est pas la forme habituelle, qui sépare l’option et la valeur. Redis l’accepte cependant : les réglages ont été lus dans Redis lui-même, voir section 7.

## 5. Le mot de passe : le fichier `.env`

Le mot de passe suit le même chemin que celui de PostgreSQL, décrit dans le guide 03, section 4.

`docker/.env.example`, versionné, contient désormais :

```text
# ======================
# REDIS
# ======================
REDIS_PASSWORD=changez-moi
```

La même variable est ajoutée à `docker/.env`, avec la valeur réelle.

Le modèle doit être complété en même temps que le fichier réel. Sans cela, une personne qui clone le dépôt et copie le modèle obtient un Redis sans mot de passe valide, sans aucun message pour le lui signaler.

## 6. Le contrôle de santé

> **Corrigé le 15 octobre 2026.** Le contrôle décrit ci-dessous plaçait le mot de passe dans sa commande. Il est devenu `redis-cli ping | grep -q PONG`, et le mot de passe est transmis au conteneur par la variable `REDISCLI_AUTH`, que `redis-cli` lit nativement. Le `grep PONG` répond au défaut décrit dans cette section : seule la réponse `PONG` fait réussir le contrôle. Voir le guide 15, section 8.
>
> Conséquence pour les commandes de ce guide : `REDISCLI_AUTH` étant défini dans le conteneur, `docker exec redis redis-cli ping` s’authentifie désormais seul et répond `PONG`. Pour reproduire un refus, il faut vider ou fausser la variable : `docker exec -e REDISCLI_AUTH= redis redis-cli ping`.

| Réglage | Valeur | Signification |
|---|---|---|
| `test` | `redis-cli -a ${REDIS_PASSWORD} ping` | Envoie la commande `PING`, avec le mot de passe ; Redis répond `PONG` s’il fonctionne |
| `interval` | `10s` | Délai entre deux contrôles |
| `timeout` | `10s` | Durée au-delà de laquelle un contrôle est compté comme échoué |
| `retries` | `5` | Nombre d’échecs consécutifs avant l’état `unhealthy` |

`redis-cli` est fourni par l’image Redis.

### Pourquoi le mot de passe est indispensable dans le test

Sans mot de passe, Redis refuse la commande :

```text
NOAUTH Authentication required.
```

Mais `redis-cli` se termine quand même avec le code `0`, qui signifie « succès » pour Docker. Le test a été fait :

```bash
docker exec redis sh -c 'redis-cli ping; echo "code de sortie : $?"'
```

```text
NOAUTH Authentication required.
code de sortie : 0
```

Un contrôle de santé sans `-a` afficherait donc `healthy` alors que Redis refuse toutes les commandes. Avec le mot de passe, la réponse est `PONG`, visible dans l’historique du contrôle :

```bash
docker inspect redis --format '{{range .State.Health.Log}}{{.Output}}{{end}}'
```

### Le mot de passe dans la configuration du conteneur

Compose remplace `${REDIS_PASSWORD}` avant de créer le conteneur. La valeur figure donc dans sa configuration, et la commande `docker inspect redis` l’affiche. Il en va de même pour `POSTGRES_PASSWORD`, transmis par une variable d’environnement. Toute personne qui peut utiliser Docker sur la machine peut lire ces valeurs. C’est acceptable pour un poste de travail ; sur le cluster, les mots de passe seront fournis par des objets `Secret` de Kubernetes.

## 7. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

### Valider et démarrer

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d
```

Au premier démarrage, Compose crée le nouveau volume :

```text
 ✔ Network docker_eshop-network Created
 ✔ Volume docker_redis_data     Created
 ✔ Volume docker_pg_data        Created
 ✔ Container redis              Started
 ✔ Container postgres           Started
```

### État des conteneurs

```bash
docker compose -f docker/docker-compose.yaml ps
```

Résultat vérifié le 14 octobre 2026 :

```text
NAME       IMAGE                    ...   STATUS                         PORTS
postgres   ankane/pgvector:latest   ...   Up About a minute (healthy)    5432/tcp
redis      redis:7                  ...   Up About a minute (healthy)    6379/tcp
```

`6379/tcp` sans adresse : le port n’est pas publié sur l’hôte. La commande `ss -ltn | grep -c ':6379 '` renvoie `0`.

### Le mot de passe est exigé

```bash
docker exec redis redis-cli ping
docker exec redis redis-cli -a faux ping
```

Les deux commandes sont refusées. La première n’envoie aucun mot de passe, la seconde un mot de passe faux.

Depuis le 15 octobre 2026, la variable `REDISCLI_AUTH` est définie dans le conteneur (section 6) : la première commande répond `PONG`. Pour vérifier le refus, il faut écrire `docker exec -e REDISCLI_AUTH= redis redis-cli ping`, qui répond `NOAUTH Authentication required.`

### Les réglages sont appliqués

Les réglages sont lus dans Redis, avec la commande `CONFIG GET`. Le mot de passe est passé par la variable `REDISCLI_AUTH`, que `redis-cli` lit à la place de l’option `-a` : il n’apparaît pas dans la commande.

```bash
read -rs -p 'Mot de passe Redis : ' REDISCLI_AUTH; echo

docker exec -e REDISCLI_AUTH="$REDISCLI_AUTH" redis \
  redis-cli config get maxmemory-policy
```

Résultats vérifiés le 14 octobre 2026 :

| Réglage | Valeur lue |
|---|---|
| `maxmemory-policy` | `noeviction` |
| `maxmemory` | `1073741824`, soit 1 Go |
| `appendonly` | `yes` |

### Les données survivent à un redémarrage

Une clé de test est écrite, Redis est redémarré, puis la clé est relue et supprimée :

```bash
docker exec -e REDISCLI_AUTH="$REDISCLI_AUTH" redis redis-cli set test:persistance ok
docker restart redis
docker exec -e REDISCLI_AUTH="$REDISCLI_AUTH" redis redis-cli get test:persistance
docker exec -e REDISCLI_AUTH="$REDISCLI_AUTH" redis redis-cli del test:persistance
```

Résultat vérifié le 14 octobre 2026 : après le redémarrage, la clé est relue avec la valeur `ok`.

Les fichiers du journal se trouvent dans le volume :

```bash
docker exec redis ls /data/appendonlydir
```

```text
appendonly.aof.1.base.rdb
appendonly.aof.1.incr.aof
appendonly.aof.manifest
```

## 8. L’avertissement `Memory overcommit`

Au démarrage, Redis affiche :

```text
WARNING Memory overcommit must be enabled! Without it, a background save or replication may fail under low memory condition.
```

Ce message ne vient pas du fichier Compose. Il porte sur un réglage du noyau Linux, `vm.overcommit_memory`. Un conteneur n’a pas de noyau propre : il utilise celui de la machine qui l’héberge, ici celui de WSL2, où ce réglage vaut `0`. Redis recommande `1`, pour que ses sauvegardes en arrière-plan ne manquent pas de mémoire.

Avec quelques paniers de test, l’avertissement est sans conséquence. Il est conservé tel quel. Pour le faire disparaître le temps d’une session, dans WSL2 :

```bash
sudo sysctl vm.overcommit_memory=1
```

Ce réglage est perdu au redémarrage de WSL2. Il modifie aussi le comportement de tout le système, et non du seul conteneur Redis.

## 9. Problèmes rencontrés pendant la mise au point

| Constat | Cause | Correction |
|---|---|---|
| Port 6379 ouvert sur toutes les interfaces du poste | Bloc `ports: "6379:6379"` | Bloc retiré |
| `REDIS_PASSWORD` absente du modèle | Variable ajoutée à `.env` seulement | Variable ajoutée à `.env.example` |
| Paniers susceptibles d’être supprimés sans erreur | Politique `allkeys-lru`, adaptée à un cache | Politique `noeviction` |

## 10. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Fichier Compose valide | Oui |
| Conteneur `redis` à l’état `healthy` | Oui |
| Commande sans mot de passe refusée | Oui |
| Commande avec un mot de passe faux refusée | Oui |
| Réglages lus dans Redis | `noeviction`, 1 Go, `appendonly yes` |
| Données conservées après redémarrage | Oui |
| Port publié sur l’hôte | Non, volontairement |
| `REDIS_PASSWORD` présente dans le modèle versionné | Oui |
| Connexion de `Basket.API` par Compose | Non, guide suivant |

## 11. Points ouverts

1. **L’image porte l’étiquette `redis:7`.** Elle suit les nouvelles versions 7.x. Une étiquette complète, comme `redis:7.4.11`, figerait la version.
2. **L’avertissement `Memory overcommit`** reste affiché, voir section 8.
3. **Les mots de passe sont lisibles avec `docker inspect`**, voir section 6.

Depuis le 15 octobre 2026, Redis a aussi un plafond de mémoire, 1280 Mio, fixé au-dessus de `--maxmemory 1gb` pour que la politique `noeviction` puisse jouer (guide 16, section 5).

## 12. Étape suivante

Ajouter RabbitMQ, la dernière dépendance, avec son mot de passe et son contrôle de santé : voir [05 — Docker Compose : RabbitMQ](05-compose-rabbitmq.md).

`Basket.API` devra ensuite recevoir le mot de passe de Redis dans sa chaîne de connexion, sous la forme :

```text
ConnectionStrings__redis=redis:6379,password=<mot-de-passe>
```

## 13. Commandes de référence

```bash
# Démarrer
docker compose -f docker/docker-compose.yaml up -d

# État des conteneurs
docker compose -f docker/docker-compose.yaml ps

# Journaux de Redis
docker compose -f docker/docker-compose.yaml logs redis

# Saisir le mot de passe sans l'afficher
read -rs -p 'Mot de passe Redis : ' REDISCLI_AUTH; echo

# Envoyer une commande à Redis
docker exec -e REDISCLI_AUTH="$REDISCLI_AUTH" redis redis-cli ping

# Lire un réglage
docker exec -e REDISCLI_AUTH="$REDISCLI_AUTH" redis redis-cli config get maxmemory-policy
```

**Bilan :** Redis démarre avec Docker Compose, exige son mot de passe, conserve les paniers sur disque sans jamais les supprimer pour libérer de la mémoire, et n’est pas exposé sur le poste.
