# 08 — Docker Compose : Basket.API

## 1. Objectif

Les guides [06](06-compose-identity.md) et [07](07-compose-catalog.md) ont ajouté `Identity.API` et `Catalog.API` au fichier Compose. Ce guide y ajoute `Basket.API`, qui conserve le panier de chaque client.

Ce service apporte trois nouveautés :

| Nouveauté | Conséquence |
|---|---|
| Il utilise Redis | Premier service relié à la dépendance décrite dans le guide 04 |
| Il dépend d’`Identity.API` | Premier service qui dépend d’un autre service de l’application |
| Il ne parle qu’en HTTP/2, avec le protocole gRPC | Un `curl` ordinaire ne suffit pas à le tester |

Les objectifs sont de :

- transmettre au service ses chaînes de connexion vers Redis et RabbitMQ, ainsi que l’adresse d’`Identity.API` ;
- le faire attendre que ses dépendances soient prêtes ;
- vérifier qu’il répond à un véritable appel de son API.

**Périmètre :** `Basket.API` seul. La construction de l’image par Compose fonctionne comme pour `Identity.API` : voir le guide 06, section 3.

**État au 14 octobre 2026 :** `Basket.API` démarre avec Docker Compose, répond aux appels gRPC et est abonné à RabbitMQ. Son accès à Redis, invérifiable sans utilisateur connecté, a été vérifié le 15 octobre 2026 après l’ajout de `WebApp`, voir section 5.

## 2. Le service dans le fichier Compose

```yaml
  # =====================================================================
  # BASKET.API
  # =====================================================================
  basket-api:
    image: basket-api
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/Basket.API/Dockerfile
    container_name: basket-api
    environment:
      ConnectionStrings__redis: "redis:6379,password=${REDIS_PASSWORD}"
      ConnectionStrings__eventbus: "amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
      Identity__Url: "http://identity-api:5223"
    ports:
      - "127.0.0.1:5221:8080"
    depends_on:
      redis:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      identity-api:
        condition: service_started
    networks:
      - eshop-network
```

Aucune variable nouvelle n’est à ajouter au fichier `.env` : le service réutilise `REDIS_PASSWORD`, `RABBITMQ_USER` et `RABBITMQ_PASSWORD`.

## 3. La configuration du service

### La connexion à Redis

```yaml
      ConnectionStrings__redis: "redis:6379,password=${REDIS_PASSWORD}"
```

- `redis` est le nom que le code attend (`AddRedisClient("redis")`).
- La valeur n’est pas une adresse, contrairement à celle de RabbitMQ. C’est une liste d’options séparées par des virgules : d’abord l’hôte et le port, puis `password=`.

Les caractères à éviter dans le mot de passe Redis sont donc `,`, qui sépare les options, et `=`, qui sépare un nom d’option de sa valeur.

### La connexion à RabbitMQ

```yaml
      ConnectionStrings__eventbus: "amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
```

Identique à celle de `Catalog.API`, décrite dans le guide 07, section 3.

### L’adresse d’Identity.API

```yaml
      Identity__Url: "http://identity-api:5223"
```

`Basket.API` vérifie le jeton de chaque utilisateur. Pour cela, il télécharge les clés de signature publiées par `Identity.API`, à cette adresse.

Le service est joint par son nom sur le réseau Docker, `identity-api`, et par le port `5223`. C’est la même adresse que celle qu’utilise le navigateur : un jeton n’est accepté que si l’adresse de son émetteur correspond à celle-ci. Le guide 13, section 3, explique ce choix.

> **Mise à jour du 15 octobre 2026.** La première version de ce guide utilisait `http://identity-api:8080`. Elle permettait au service de démarrer, mais aurait fait refuser les jetons des utilisateurs. L’adresse a été changée dans les trois API avec l’ajout de `WebApp`.

Le nom de la variable compte. Les API lisent `Identity__Url`, alors que `WebApp` et `WebhookClient` lisent `IdentityUrl`, sans séparateur. Le guide 02, section 6, donne la liste complète.

### Les dépendances à attendre

```yaml
    depends_on:
      redis:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      identity-api:
        condition: service_started
```

Redis et RabbitMQ ont un contrôle de santé : Compose attend leur état `healthy`.

`Identity.API` n’en a pas, faute de route `/health` (guide 06, section 6). Compose ne peut donc attendre que son démarrage, avec `service_started`. Cette limite est sans conséquence ici : `Basket.API` ne contacte `Identity.API` qu’à la première requête d’un utilisateur connecté, et non à son propre démarrage.

La sortie de `docker compose up` montre l’attente :

```text
 ✔ Container identity-api Running
 ✔ Container postgres     Healthy
 ✔ Container redis        Healthy
 ✔ Container rabbitmq     Healthy
 ✔ Container basket-api   Started
```

PostgreSQL apparaît aussi : `Identity.API` en dépend, et Compose vérifie toute la chaîne.

### Le port

```yaml
    ports:
      - "127.0.0.1:5221:8080"
```

`5221` est le port qu’eShop utilise en développement. Aucun navigateur ne joint `Basket.API` : `WebApp` l’interrogera par le réseau Docker. Le port sert seulement aux tests, sur l’adresse locale. Il pourra être retiré une fois `WebApp` en place.

## 4. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d basket-api
docker compose -f docker/docker-compose.yaml ps basket-api
```

Résultat vérifié le 14 octobre 2026 :

```text
NAME         IMAGE        ...   STATUS                  PORTS
basket-api   basket-api   ...   Up Less than a second   127.0.0.1:5221->8080/tcp
```

Le service écoute environ 0,7 seconde après le démarrage du conteneur. Comme pour `Catalog.API`, une requête envoyée trop tôt reçoit le code `000` : voir le guide 07, section 4.

### Le service ne parle que HTTP/2

La configuration d’eShop impose le protocole HTTP/2 sur le port de `Basket.API` (`Kestrel:EndpointDefaults:Protocols`, dans `appsettings.json`). Le protocole gRPC repose sur HTTP/2.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5221/
curl -s -o /dev/null -w '%{http_code}\n' --http2-prior-knowledge http://127.0.0.1:5221/
```

Résultats vérifiés le 14 octobre 2026 :

| Requête | Code | Signification |
|---|---|---|
| HTTP/1.1, celle que `curl` envoie par défaut | `400` | Le service refuse ce protocole |
| HTTP/2, avec `--http2-prior-knowledge` | `404` | Le service répond, mais n’a pas de page à la racine |

`--http2-prior-knowledge` indique à `curl` de parler HTTP/2 d’emblée, sans chiffrement. Sans TLS, `curl` ne le fait pas de lui-même.

Le `404` est ici le bon résultat : il prouve que le service répond en HTTP/2.

### Un véritable appel gRPC

Un `404` ne prouve pas que l’API fonctionne. Un appel de la méthode `GetBasket` a donc été envoyé, construit à la main avec `curl` :

```bash
printf '\0\0\0\0\0' | curl -s --http2-prior-knowledge \
  -H 'content-type: application/grpc' -H 'te: trailers' \
  --data-binary @- -D - -o /dev/null \
  http://127.0.0.1:5221/BasketApi.Basket/GetBasket | grep -i -E '^(HTTP|grpc-status)'
```

- L’adresse `/BasketApi.Basket/GetBasket` vient du contrat de l’API, `Basket.API/Proto/basket.proto` : paquet `BasketApi`, service `Basket`, méthode `GetBasket`.
- `content-type: application/grpc` et `te: trailers` sont les en-têtes qu’un client gRPC envoie.
- `printf '\0\0\0\0\0'` produit un message gRPC vide : un octet indique que le message n’est pas compressé, quatre octets donnent sa longueur, ici zéro.
- `-D -` affiche les en-têtes de la réponse, où gRPC place son code de résultat.

Résultat vérifié le 14 octobre 2026 :

```text
HTTP/2 200
grpc-status: 0
```

`grpc-status: 0` signifie « succès ». Le service a traité un appel de son API.

### L’abonnement à RabbitMQ

```bash
docker exec rabbitmq rabbitmqctl -q list_queues name consumers
```

Résultat vérifié :

```text
name     consumers
Catalog  1
Basket   1
```

`Basket.API` a créé sa file et s’y est abonné, à côté de celle de `Catalog.API`.

### Journal, port et compte d’exécution

```bash
docker logs basket-api 2>&1 | grep -c -E '^(fail|crit)'
ss -ltn | grep ':5221 '
docker exec basket-api sh -c 'grep ^Uid: /proc/1/status'
```

Résultats vérifiés : `0` erreur, une seule ligne `127.0.0.1:5221`, et le compte `1654`.

## 5. Ce qui ne peut pas encore être vérifié : l’accès à Redis

`Basket.API` n’ouvre pas sa connexion à Redis au démarrage, mais à la première lecture d’un panier. La liste des clients connectés à Redis ne contient donc aucune connexion du service.

Un appel anonyme ne suffit pas à la déclencher. Le code de `GetBasket` renvoie un panier vide sans interroger Redis quand l’appelant n’est pas identifié :

```csharp
[AllowAnonymous]
public override async Task<CustomerBasketResponse> GetBasket(GetBasketRequest request, ServerCallContext context)
{
    var userId = context.GetUserIdentity();
    if (string.IsNullOrEmpty(userId))
    {
        return new();
    }
```

L’accès à Redis ne sera donc vérifiable qu’avec un utilisateur connecté, c’est-à-dire une fois `WebApp` en place.

En attendant, une vérification partielle a été faite : le mot de passe reçu par `basket-api` a été comparé à celui de Redis, sans afficher l’un ni l’autre. Ils sont identiques.

### Une erreur de vérification à éviter

Un premier contrôle consistait à lister les clients connectés à Redis, avec un mot de passe saisi au clavier :

```bash
read -rs -p 'Mot de passe Redis : ' REDISCLI_AUTH; echo
docker exec -e REDISCLI_AUTH="$REDISCLI_AUTH" redis redis-cli client list
```

Il a donné deux enseignements :

- **`WRONGPASS`** : la valeur saisie ne correspondait pas. `read -rs` masque la saisie, et une faute de frappe ne se voit pas. Le message ne mettait donc pas en cause `Basket.API`.
- **Avec le bon mot de passe, la liste ne contient que la commande elle-même**, pour la raison donnée ci-dessus. Ce contrôle ne pouvait pas réussir avant la connexion d’un utilisateur.

### Vérifié le 15 octobre 2026, avec un utilisateur connecté

Une fois `WebApp` en place, l’utilisateur `alice` s’est connecté, a ajouté un article à son panier, puis a passé commande (guide 13, section 6). Le journal de `Basket.API` contient alors :

```text
info: eShop.Basket.API.Repositories.RedisBasketRepository[0]
      Basket item persisted successfully.
info: eShop.Basket.API.IntegrationEvents.EventHandling.OrderStartedIntegrationEventHandler[0]
```

| Constat | Ce qu’il prouve |
|---|---|
| `Basket item persisted successfully` | Le panier a été écrit dans Redis : la connexion et le mot de passe fonctionnent |
| Connexions à Redis ouvertes depuis l’adresse de `basket-api` | La connexion est restée ouverte après la première écriture |
| `OrderStartedIntegrationEventHandler`, puis `0` clé dans Redis | À la commande, `Basket.API` a reçu l’événement d’`Ordering.API` et vidé le panier |
| Requêtes d’`alice` acceptées | Le jeton émis par `Identity.API` est reconnu par `Basket.API` |

## 6. Points ouverts

1. ~~L’accès à Redis n’est pas vérifié~~ : vérifié le 15 octobre 2026, voir section 5.
2. ~~Le service n’a pas de contrôle de santé~~ : réglé le 15 octobre 2026. Comme prévu, un contrôle HTTP/1.1 échouait sur le port gRPC. Le service écoute désormais sur deux ports : `8080` en HTTP/2 pour gRPC, `8081` en HTTP/1.1 pour le contrôle. Accepter les deux protocoles sur le même port cassait gRPC. Voir le guide 15, section 6. Depuis, `Identity.API` est attendu à l’état `healthy`, et non plus seulement démarré.
3. **Le port publié n’est utile qu’aux tests.**

## 7. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Image construite par Compose | `basket-api:latest`, 354 Mo |
| Attente de Redis et RabbitMQ `healthy`, et d’Identity.API démarré | Oui |
| Requête HTTP/1.1 | Refusée, `400` |
| Requête HTTP/2 | Acceptée |
| Appel gRPC `GetBasket` anonyme | `grpc-status: 0` |
| File RabbitMQ `Basket` | 1 consommateur |
| Erreurs dans le journal | 0 |
| Port publié | `127.0.0.1:5221` seulement |
| Compte d’exécution | `1654` |
| Mot de passe Redis transmis | Identique à celui de Redis |
| Connexion effective à Redis | Vérifiée le 15 octobre 2026 avec un utilisateur connecté : panier écrit, puis vidé à la commande |

## 8. Étape suivante

Ajouter les deux autres services qui dépendent d’`Identity.API` : `Ordering.API` et `Webhooks.API`. Le premier est traité dans [09 — Docker Compose : Ordering.API](09-compose-ordering.md).

## 9. Commandes de référence

```bash
# Construire l'image et démarrer le service
docker compose -f docker/docker-compose.yaml up -d basket-api

# Tester le protocole
curl -s -o /dev/null -w '%{http_code}\n' --http2-prior-knowledge http://127.0.0.1:5221/

# Appel gRPC anonyme
printf '\0\0\0\0\0' | curl -s --http2-prior-knowledge \
  -H 'content-type: application/grpc' -H 'te: trailers' \
  --data-binary @- -D - -o /dev/null \
  http://127.0.0.1:5221/BasketApi.Basket/GetBasket | grep -i grpc-status

# Journaux du service
docker compose -f docker/docker-compose.yaml logs basket-api
```

**Bilan :** `Basket.API` démarre avec Docker Compose, attend ses dépendances, répond aux appels gRPC et s’abonne au bus de messages. Son accès à Redis a été vérifié avec un utilisateur connecté, une fois `WebApp` en place.
