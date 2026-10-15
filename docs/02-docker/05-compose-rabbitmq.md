# 05 — Docker Compose : RabbitMQ

## 1. Objectif

Les guides [03](03-compose-postgres.md) et [04](04-compose-redis.md) ont décrit PostgreSQL et Redis dans `docker/docker-compose.yaml`. Ce guide y ajoute RabbitMQ, la dernière dépendance de l’application.

Les services d’eShop s’échangent des messages par RabbitMQ. Quand une commande change d’état, par exemple, `Ordering.API` publie un message que `PaymentProcessor`, `OrderProcessor` et `WebApp` reçoivent. Le guide 02 a vérifié que sept files de messages se créent au démarrage des services.

Les objectifs sont de :

- décrire RabbitMQ dans le fichier Compose, avec un utilisateur et un mot de passe fournis par le fichier `.env` ;
- conserver ses données au-delà de la recréation du conteneur ;
- rendre l’interface d’administration accessible depuis le poste, et seulement depuis lui ;
- disposer d’un contrôle de santé qui indique quand RabbitMQ accepte réellement les connexions.

**Périmètre :** RabbitMQ seul. Les neuf services seront ajoutés au fichier dans les guides suivants.

**État au 14 octobre 2026 :** les trois dépendances, PostgreSQL, Redis et RabbitMQ, démarrent avec Docker Compose et passent à l’état `healthy`.

## 2. Fichiers concernés

| Fichier | Modification |
|---|---|
| `docker/docker-compose.yaml` | Service `rabbitmq` et volume `rmq_data` ajoutés |
| `docker/.env.example` | Variables `RABBITMQ_USER` et `RABBITMQ_PASSWORD` ajoutées |
| `docker/.env` | Mêmes variables, avec les valeurs réelles ; fichier non versionné |

## 3. Le service RabbitMQ

```yaml
  rabbitmq:
    image: rabbitmq:4-management
    container_name: rabbitmq
    hostname: rabbitmq
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USER}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}
      RABBITMQ_DEFAULT_VHOST: /
    ports:
      - "127.0.0.1:15672:15672"
    volumes:
      - rmq_data:/var/lib/rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "check_port_connectivity"]
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
  rmq_data:
```

- `image: rabbitmq:4-management` : l’image officielle, version majeure 4, avec l’extension d’administration web. La version démarrée est `4.3.6`. C’est la même série que celle utilisée pour tester les services dans les guides 01 et 02.
- `container_name: rabbitmq` : nom fixe du conteneur. Les services joindront RabbitMQ sous le nom du service, `rabbitmq:5672`.
- `hostname: rabbitmq` : nom de machine du conteneur, indispensable à la conservation des données, voir section 4.
- `environment` :
  - `RABBITMQ_DEFAULT_USER` et `RABBITMQ_DEFAULT_PASS` créent l’utilisateur au premier démarrage. Leurs valeurs viennent du fichier `.env`, voir section 6.
  - `RABBITMQ_DEFAULT_VHOST: /` désigne l’hôte virtuel par défaut, un espace isolé de files et de messages. `/` est déjà la valeur par défaut : la ligne n’a pas d’effet, elle rend seulement le choix visible.
- `ports` : seule l’interface d’administration est publiée, et seulement sur l’adresse locale, voir section 5.
- `volumes` : `/var/lib/rabbitmq` contient les utilisateurs, les files et les messages conservés. Le volume a pour nom réel `docker_rmq_data`.
- `healthcheck` : voir section 7.

## 4. Le nom de machine et la conservation des données

### Le problème

RabbitMQ range ses données dans un répertoire qui porte le nom de son nœud, `rabbit@<nom de machine>`. Sans réglage, le nom de machine d’un conteneur est son identifiant, tiré au hasard par Docker. La première version du service a ainsi produit :

```text
/var/lib/rabbitmq/mnesia/rabbit@d735032d93ea
```

À chaque recréation du conteneur, par exemple après un changement d’image ou de variable, l’identifiant change. RabbitMQ cherche alors un répertoire `rabbit@<nouvel identifiant>`, ne le trouve pas, et repart d’une base vide. L’ancien répertoire reste dans le volume, sans être relu.

Le volume ne protégeait donc rien : les files et leurs messages auraient été perdus à la première recréation, sans aucune erreur.

### La correction

`hostname: rabbitmq` fixe le nom de machine. Le répertoire porte désormais un nom stable :

```bash
docker exec rabbitmq ls /var/lib/rabbitmq/mnesia
```

```text
rabbit@rabbitmq
rabbit@rabbitmq-feature_flags
rabbit@rabbitmq-plugins-expand
rabbit@rabbitmq.pid
```

Ce problème est propre à RabbitMQ : PostgreSQL et Redis écrivent leurs données dans un répertoire dont le nom ne dépend pas de la machine.

## 5. Les ports

| Port | Rôle | Publié sur le poste |
|---|---|---|
| `5672` | Protocole AMQP, utilisé par les services | Non |
| `15672` | Interface d’administration web | Oui, sur `127.0.0.1` seulement |

Les services joindront RabbitMQ par le réseau Docker, comme PostgreSQL et Redis. Le port `5672` n’a donc pas à être publié.

L’interface d’administration est différente : c’est une page web, destinée à une personne qui l’ouvre depuis son navigateur. La publier a un sens, mais pas sur toutes les interfaces du poste. La forme `"127.0.0.1:15672:15672"` n’ouvre le port que sur l’adresse locale : seul le poste lui-même peut l’atteindre.

L’interface s’ouvre depuis le navigateur de Windows, à l’adresse `http://localhost:15672`. WSL2 transmet à Windows les ports ouverts sur son adresse locale. La connexion se fait avec l’utilisateur et le mot de passe du fichier `docker/.env`.

## 6. Les identifiants

`docker/.env.example`, versionné, contient désormais :

```text
# ======================
# RABBITMQ
# ======================
RABBITMQ_USER=eshop_rabbit
RABBITMQ_PASSWORD=changez-moi
```

Les mêmes variables sont ajoutées à `docker/.env`, avec les valeurs réelles.

Comme pour PostgreSQL, ces variables ne servent qu’au **premier** démarrage, sur un volume vide. Changer le mot de passe dans `.env` n’a ensuite aucun effet : il faut le changer dans RabbitMQ, ou supprimer le volume.

L’utilisateur créé reçoit l’étiquette `administrator` et tous les droits sur l’hôte virtuel `/`. Tous les services utiliseront ce compte.

## 7. Le contrôle de santé

| Réglage | Valeur | Signification |
|---|---|---|
| `test` | `rabbitmq-diagnostics -q check_port_connectivity` | Réussit quand RabbitMQ accepte les connexions sur ses ports |
| `interval` | `10s` | Délai entre deux contrôles |
| `timeout` | `10s` | Durée au-delà de laquelle un contrôle est compté comme échoué |
| `retries` | `5` | Nombre d’échecs consécutifs avant l’état `unhealthy` |

`-q` supprime les messages d’information : seul le code de sortie compte.

### Pourquoi pas `ping`

La première version utilisait `rabbitmq-diagnostics ping`. Cette commande vérifie seulement que le nœud RabbitMQ tourne. Or le nœud démarre plusieurs secondes avant d’ouvrir le port `5672` : le journal du démarrage montre l’ouverture des ports en toute fin de séquence.

Pendant cet intervalle, `ping` répond « en bonne santé » alors qu’aucun service ne peut encore se connecter. C’est précisément l’état que les services surveilleront pour savoir s’ils peuvent démarrer. `check_port_connectivity` ne réussit qu’une fois les ports ouverts.

Ce contrôle n’utilise pas le mot de passe : `rabbitmq-diagnostics` s’adresse au nœud par un canal interne, réservé aux outils d’administration.

## 8. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

### Démarrer

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d
docker compose -f docker/docker-compose.yaml ps
```

Résultat vérifié le 14 octobre 2026 :

```text
NAME       IMAGE                    ...   STATUS                    PORTS
postgres   ankane/pgvector:latest   ...   Up 32 minutes (healthy)   5432/tcp
rabbitmq   rabbitmq:4-management    ...   Up 16 seconds (healthy)   4369/tcp, 5671-5672/tcp, ..., 127.0.0.1:15672->15672/tcp
redis      redis:7                  ...   Up 22 minutes (healthy)   6379/tcp
```

Seul le port `15672` porte une adresse, `127.0.0.1` : c’est le seul publié.

### Les ports ouverts sur le poste

```bash
ss -ltn | grep -E ':(5672|15672) '
```

Résultat vérifié :

```text
LISTEN 0      4096        127.0.0.1:15672      0.0.0.0:*
```

Une seule ligne. Avant correction, la commande en affichait deux, `0.0.0.0:15672` et `[::]:15672` : le même port, ouvert en IPv4 et en IPv6 sur toutes les interfaces.

| Accès à l’interface d’administration | Résultat |
|---|---|
| Navigateur ou `curl` sous Windows, `http://localhost:15672` | HTTP 200 |
| Depuis WSL2, `http://127.0.0.1:15672` | HTTP 200 |
| Par l’adresse réseau de WSL2 | Aucune réponse |

### Le mot de passe est exigé

```bash
docker exec rabbitmq rabbitmqctl authenticate_user eshop_rabbit faux
```

```text
user 'eshop_rabbit' - invalid credentials
```

Le bon mot de passe est accepté. Il a été testé en le lisant dans les variables du conteneur, sans l’afficher :

```bash
docker exec rabbitmq sh -c \
  'rabbitmqctl -q authenticate_user "$RABBITMQ_DEFAULT_USER" "$RABBITMQ_DEFAULT_PASS" >/dev/null && echo accepté'
```

Les guillemets simples empêchent le terminal de remplacer les variables : elles sont lues dans le conteneur.

### Les données survivent à la recréation

```bash
docker compose -f docker/docker-compose.yaml up -d --force-recreate rabbitmq
docker exec rabbitmq rabbitmqctl -q list_users
```

```text
user          tags
eshop_rabbit  [administrator]
```

Ce résultat seul ne suffit pas : sur une base vide, RabbitMQ recrée cet utilisateur à partir des variables, et la liste serait identique. La preuve se lit dans le journal du nouveau conteneur :

```bash
docker logs rabbitmq 2>&1 | grep -c -E 'Will seed default|Created user'
```

Résultat vérifié : `0`. Sur une base vide, RabbitMQ écrit `Will seed default virtual host and user`, puis `Created user 'eshop_rabbit'`. Ici, aucune de ces lignes : RabbitMQ a repris la base existante.

## 9. Les avertissements du journal

Au démarrage, le journal contient :

```text
[warning] Deprecated features: `management_metrics_collection`: Feature `management_metrics_collection` is deprecated.
```

RabbitMQ prévient que la collecte de statistiques utilisée par l’interface d’administration disparaîtra dans une version future. L’avertissement est présent en version 3.13 comme en 4.3. Il ne demande aucune action : l’interface fonctionne.

Au tout premier démarrage, sur un volume vide, le journal contient aussi `Classic peer discovery backend: list of nodes does not contain the local node`. Ce message concerne la formation d’un groupe de plusieurs nœuds RabbitMQ. Avec un seul nœud, il est sans objet.

## 10. Problèmes rencontrés pendant la mise au point

| Constat | Cause | Correction |
|---|---|---|
| Répertoire de données nommé d’après l’identifiant du conteneur | Aucun nom de machine fixé | `hostname: rabbitmq` |
| Version 3.13.7 démarrée | Image `rabbitmq:3-management`, dont la série n’est plus maintenue en version gratuite | Image `rabbitmq:4-management` |
| Port `5672` ouvert sur le poste | Bloc `ports:` | Port retiré |
| Port `15672` ouvert sur toutes les interfaces | Publication sans adresse | Publication sur `127.0.0.1` |
| Contrôle de santé positif avant l’ouverture des ports | `rabbitmq-diagnostics ping` | `check_port_connectivity` |

Le changement de version et de nom de machine a demandé de repartir d’un volume vide, qui contenait les données de la version 3.13 sous l’ancien nom de nœud. La suppression a visé RabbitMQ seul :

```bash
docker compose -f docker/docker-compose.yaml rm -sf rabbitmq
docker volume rm docker_rmq_data
docker compose -f docker/docker-compose.yaml up -d
```

`rm -sf` arrête puis supprime le conteneur, sans confirmation. PostgreSQL et Redis n’ont pas été touchés.

## 11. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Fichier Compose valide | Oui |
| PostgreSQL, Redis et RabbitMQ à l’état `healthy` | Oui |
| Version de RabbitMQ | `4.3.6` |
| Nom de nœud stable | `rabbit@rabbitmq` |
| Mot de passe faux refusé | Oui |
| Données reprises après recréation du conteneur | Oui |
| Port `5672` publié sur le poste | Non, volontairement |
| Interface d’administration | `http://localhost:15672`, depuis le poste seulement |
| Connexion des services par Compose | Non, guide suivant |

## 12. Points ouverts

1. **Un seul compte pour tous les services.** Le compte `eshop_rabbit` est administrateur. Un compte limité pour les services serait plus sûr ; ce n’est pas nécessaire pour l’apprentissage.
2. **L’image porte l’étiquette `rabbitmq:4-management`**, qui suit les nouvelles versions 4.x. Une étiquette complète, comme `rabbitmq:4.3.6-management`, figerait la version.

Depuis le 15 octobre 2026, RabbitMQ a un plafond de mémoire de 1 Gio, choisi pour que son seuil de blocage des publications, 40 % de la mémoire disponible, reste loin de sa consommation (guide 16, section 5).

## 13. Étape suivante

Les trois dépendances sont en place. L’étape suivante consiste à ajouter les neuf services au fichier Compose, avec la configuration relevée dans le guide 02, section 6, et à les faire attendre que leurs dépendances soient `healthy`. Les deux premiers sont traités dans [06 — Docker Compose : Identity.API](06-compose-identity.md) et [07 — Docker Compose : Catalog.API](07-compose-catalog.md).

Les services joindront RabbitMQ avec une chaîne de connexion de la forme :

```text
ConnectionStrings__eventbus=amqp://<utilisateur>:<mot-de-passe>@rabbitmq:5672
```

## 14. Commandes de référence

```bash
# Démarrer
docker compose -f docker/docker-compose.yaml up -d

# État des conteneurs
docker compose -f docker/docker-compose.yaml ps

# Journaux de RabbitMQ
docker compose -f docker/docker-compose.yaml logs rabbitmq

# Utilisateurs, files et consommateurs
docker exec rabbitmq rabbitmqctl -q list_users
docker exec rabbitmq rabbitmqctl -q list_queues name consumers

# État des connexions
docker exec rabbitmq rabbitmq-diagnostics -q check_port_connectivity && echo OK

# Recréer le conteneur en conservant les données
docker compose -f docker/docker-compose.yaml up -d --force-recreate rabbitmq
```

**Bilan :** RabbitMQ démarre avec Docker Compose, exige son mot de passe, conserve ses données grâce à un nom de nœud fixe, et n’expose sur le poste que son interface d’administration, en local. Les trois dépendances de l’application sont prêtes.
