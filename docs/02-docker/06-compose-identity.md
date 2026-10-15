# 06 — Docker Compose : Identity.API

## 1. Objectif

Les guides [03](03-compose-postgres.md), [04](04-compose-redis.md) et [05](05-compose-rabbitmq.md) ont placé les trois dépendances de l’application dans `docker/docker-compose.yaml`. Ce guide y ajoute le premier service d’eShop : `Identity.API`, qui authentifie les utilisateurs.

Il est choisi en premier parce qu’il ne dépend d’aucun autre service de l’application, seulement de PostgreSQL. Les autres services, eux, auront besoin de lui pour vérifier l’identité des utilisateurs.

Les objectifs sont de :

- faire construire l’image par Compose, sous le nom fixé par la convention du projet ;
- transmettre au service sa chaîne de connexion, à partir du fichier `.env` ;
- le faire attendre que PostgreSQL soit prêt ;
- vérifier qu’il répond et qu’il initialise sa base.

**Périmètre :** `Identity.API` seul. La connexion d’un utilisateur depuis un navigateur demande `WebApp` et sera traitée plus tard.

**État au 14 octobre 2026 :** `Identity.API` démarre avec Docker Compose, répond depuis le poste et a initialisé sa base.

## 2. Le service dans le fichier Compose

```yaml
  # =====================================================================
  # IDENTITY.API
  # =====================================================================
  identity-api:
    image: identity-api
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/Identity.API/Dockerfile
    container_name: identity-api
    environment:
      ConnectionStrings__identitydb: "Host=postgres;Port=5432;Database=identitydb;Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}"
      ASPNETCORE_HTTP_PORTS: "5223"
      WebAppClient: "http://localhost:5045"
    ports:
      - "127.0.0.1:5223:5223"
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - eshop-network
```

Aucune variable nouvelle n’est à ajouter au fichier `.env` : le service réutilise celles de PostgreSQL.

> **Mise à jour du 15 octobre 2026.** Ce bloc est la version actuelle. La première version publiait le port `"127.0.0.1:5223:8080"` et ne contenait ni `ASPNETCORE_HTTP_PORTS` ni `WebAppClient`. Les deux lignes ont été ajoutées pour la connexion des utilisateurs, avec l’ajout de `WebApp` : voir [13 — Docker Compose : WebApp](13-compose-webapp.md), section 3. Les sections 3 à 5 de ce guide restent valables.

## 3. La construction de l’image par Compose

C’est le premier service dont Compose construit lui-même l’image. Les réglages décrits ici valent pour tous les services suivants.

### `build`

```yaml
    build:
      context: ..
      dockerfile: docker/src/Identity.API/Dockerfile
```

- `context: ..` : le contexte de construction est la racine du dépôt. Le chemin est relatif au fichier Compose, qui se trouve dans `docker/` ; `..` remonte donc d’un niveau. C’est le même contexte que celui des commandes `docker build` des guides 01 et 02, et le même fichier `.dockerignore` s’applique.
- `dockerfile` : le chemin du Dockerfile, relatif au contexte.

### `image` et `pull_policy`

```yaml
    image: identity-api
    pull_policy: build
```

- `image` donne son nom à l’image construite. Sans cette ligne, Compose la nomme d’après le projet et le service, ici `docker-identity-api`. Le nom suit la convention du projet, décrite dans le guide 02, section 4. Sans étiquette, Docker ajoute `latest` : l’image s’appelle `identity-api:latest`.
- `pull_policy: build` fait construire l’image à chaque `docker compose up`, sans jamais la télécharger.

Ce second réglage corrige deux comportements constatés pendant la mise au point :

| Sans `pull_policy: build` | Conséquence |
|---|---|
| Compose tente d’abord de télécharger `identity-api` depuis Docker Hub ; la sortie affiche `Image identity-api Pulling` | Une image publiée un jour sous ce nom serait téléchargée et exécutée à la place de celle du projet |
| Si l’image existe déjà sur le poste, Compose la réutilise sans reconstruire | Une modification du code ne serait pas prise en compte |

Grâce au cache de construction, une reconstruction sans changement ne prend que quelques secondes : toutes les étapes affichent `CACHED`.

## 4. La configuration du service

### La chaîne de connexion

```yaml
      ConnectionStrings__identitydb: "Host=postgres;Port=5432;Database=identitydb;Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}"
```

- `identitydb` est le nom que le code d’`Identity.API` attend, relevé dans le guide 02, section 6.
- `Host=postgres` désigne le service `postgres` du fichier Compose. Le réseau `eshop-network` fait correspondre ce nom au conteneur.
- Compose remplace `${POSTGRES_USER}` et `${POSTGRES_PASSWORD}` par les valeurs du fichier `docker/.env`. Aucun mot de passe n’est écrit dans le fichier Compose.

Dans cette chaîne, le caractère `;` sépare les paramètres. Il ne doit pas figurer dans le mot de passe.

### L’ordre de démarrage : `depends_on`

```yaml
    depends_on:
      postgres:
        condition: service_healthy
```

Compose ne démarre `Identity.API` qu’une fois PostgreSQL à l’état `healthy`, grâce au contrôle de santé défini dans le guide 03. Sans cette condition, le service pourrait démarrer avant que la base accepte les connexions, et échouer à sa première migration.

La sortie de `docker compose up` montre cette attente :

```text
 ✔ Container postgres           Healthy
 ✔ Container identity-api       Started
```

### Le port

```yaml
      ASPNETCORE_HTTP_PORTS: "5223"
    ports:
      - "127.0.0.1:5223:5223"
```

Le port est publié parce que le navigateur doit joindre `Identity.API` : pendant la connexion, l’utilisateur est redirigé vers sa page d’identification. Il n’est ouvert que sur l’adresse locale, pour la raison donnée dans le guide 05, section 5.

`5223` est le port qu’eShop utilise en développement, dans `Identity.API/Properties/launchSettings.json`. Contrairement aux autres services, `Identity.API` écoute aussi sur ce port **dans** le conteneur : `ASPNETCORE_HTTP_PORTS` remplace, pour ce seul service, la valeur `8080` fixée par le Dockerfile. Le navigateur et les conteneurs le joignent ainsi à la même adresse, `http://identity-api:5223`. Le guide 13, section 3, explique pourquoi c’est indispensable.

`WebAppClient` est l’adresse de la boutique, telle que le navigateur la voit. `Identity.API` ne renvoie un utilisateur, après sa connexion, que vers une adresse déclarée.

## 5. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d identity-api
docker compose -f docker/docker-compose.yaml ps identity-api
```

`up -d identity-api` construit l’image, démarre PostgreSQL s’il ne tourne pas déjà, attend son état `healthy`, puis démarre le service.

Résultat vérifié le 14 octobre 2026 :

```text
NAME           IMAGE          ...   STATUS         PORTS
identity-api   identity-api   ...   Up 8 seconds   127.0.0.1:5223->8080/tcp
```

Depuis le 15 octobre 2026, la colonne `PORTS` affiche `127.0.0.1:5223->5223/tcp, 8080/tcp`. Le port `8080` reste annoncé par l’instruction `EXPOSE` du Dockerfile, mais plus rien n’y écoute.

Le service n’affiche pas d’état de santé : il n’a pas de contrôle de santé, voir section 6.

### Le service répond

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5223/.well-known/openid-configuration
```

Cette adresse publie la configuration du fournisseur d’identité : ses adresses de connexion et ses clés de signature. Résultat vérifié : `200`.

### La base est initialisée

```bash
docker exec postgres psql -U postgres -d identitydb -Atc 'select "UserName" from "AspNetUsers" order by 1'
```

Résultat vérifié :

```text
alice
bob
```

Au premier démarrage, `Identity.API` crée ses tables, puis deux utilisateurs de démonstration prévus par eShop. Le journal contient alors une ligne `fail` sur la table `__EFMigrationsHistory` : elle est normale, pour la raison donnée dans le guide 02, section 7.

### Le port et le compte d’exécution

```bash
ss -ltn | grep ':5223 '
docker exec identity-api sh -c 'grep ^Uid: /proc/1/status'
```

Résultats vérifiés : une seule ligne, `127.0.0.1:5223`, puis le compte `1654`, non privilégié.

## 6. Points ouverts

1. ~~Le service n’a pas de contrôle de santé~~ : réglé le 15 octobre 2026. Le service reçoit `HealthChecks__Expose: "true"`, `HEALTHCHECK_PORT: "5223"` et le contrôle commun ; les services qui en dépendent attendent son état `healthy`. Voir le guide 15.
2. **L’adresse d’émission des jetons dépend de l’adresse d’appel.** `Identity.API` signe chaque jeton avec son adresse, appelée « émetteur » (`issuer`), qu’il déduit de l’adresse utilisée pour le joindre. Avec la première version de ce guide, l’émetteur différait selon l’appelant :

   | Joint par | `issuer` annoncé |
   |---|---|
   | Le navigateur, `http://127.0.0.1:5223` | `http://127.0.0.1:5223` |
   | Un conteneur, `http://identity-api:8080` | `http://identity-api:8080` |

   **Résolu le 15 octobre 2026** : tous les acteurs joignent désormais `http://identity-api:5223`, et l’émetteur est le même pour tous. Voir le guide 13, section 3.
3. **Le service ne connaît pas encore toutes les adresses de ses clients.** `WebAppClient` est défini depuis l’ajout de `WebApp`. `WebhooksWebClient`, `BasketApiClient`, `OrderingApiClient` et `WebhooksApiClient` restent à transmettre ; les trois derniers ne servent qu’aux pages de documentation des API, absentes hors développement.

## 7. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Image construite par Compose | `identity-api:latest`, 399 Mo |
| Aucune tentative de téléchargement | Oui, grâce à `pull_policy: build` |
| Attente de PostgreSQL `healthy` | Oui |
| Configuration OpenID | HTTP 200 |
| Utilisateurs de démonstration | 2, `alice` et `bob` |
| Port publié | `127.0.0.1:5223` seulement |
| Compte d’exécution | `1654` |
| Contrôle de santé | Absent ; ajouté le 15 octobre 2026 (guide 15) |
| Connexion d’un utilisateur depuis un navigateur | Non testée |

## 8. Étape suivante

Ajouter `Catalog.API`, le second service sans dépendance applicative, et le premier relié à RabbitMQ : voir [07 — Docker Compose : Catalog.API](07-compose-catalog.md).

## 9. Commandes de référence

```bash
# Construire l'image et démarrer le service
docker compose -f docker/docker-compose.yaml up -d identity-api

# Journaux du service
docker compose -f docker/docker-compose.yaml logs identity-api

# Configuration OpenID
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5223/.well-known/openid-configuration

# Utilisateurs en base
docker exec postgres psql -U postgres -d identitydb -Atc 'select "UserName" from "AspNetUsers"'
```

**Bilan :** `Identity.API` démarre avec Docker Compose, attend PostgreSQL, crée sa base et ses utilisateurs de démonstration, et n’est joignable que depuis le poste. Restent à régler, avant la connexion d’un utilisateur, l’absence de contrôle de santé et l’adresse d’émission des jetons.
