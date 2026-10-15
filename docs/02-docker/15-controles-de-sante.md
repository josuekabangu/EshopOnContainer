# 15 — Les contrôles de santé

## 1. Objectif

Les guides 06 à 14 ont ajouté les neuf services d’eShop au fichier Compose. Chacun signalait le même point ouvert : **aucun contrôle de santé**. Un service qui dépendait d’un autre ne pouvait attendre que son démarrage (`condition: service_started`), et non le moment où il fonctionne réellement.

Ce guide règle ce point pour tous les services à la fois. Il couvre :

- ce que le code d’eShop prévoit pour la santé, et pourquoi c’est inactif dans un conteneur ;
- l’adaptation du code qui rend les routes de santé disponibles sur demande ;
- le contrôle utilisé par Compose, alors que les images ne contiennent ni `curl` ni `wget` ;
- les deux cas particuliers, `Basket.API` et `Identity.API` ;
- l’ordre de démarrage qui en résulte, et les corrections apportées aux contrôles de PostgreSQL et de Redis après une revue.

**État au 15 octobre 2026 :** les douze conteneurs ont un contrôle de santé. Chaque service attend que ses dépendances soient `healthy`. L’ensemble démarre sur des volumes neufs en 34 secondes, sans erreur hors celles attendues au premier démarrage.

## 2. Ce que prévoit eShop

### Deux routes, deux questions

Le code commun aux neuf services, `application/eShop/src/eShop.ServiceDefaults/Extensions.cs`, déclare deux routes :

| Route | Contrôles exécutés | Question posée |
|---|---|---|
| `/alive` | Le seul contrôle `self`, qui répond toujours « sain » | Le processus répond-il ? |
| `/health` | Tous les contrôles enregistrés | Le service et ses dépendances fonctionnent-ils ? |

Les contrôles des dépendances ne sont pas écrits par eShop : ils sont ajoutés automatiquement par les bibliothèques Aspire qui connectent chaque service. Les bibliothèques présentes dans les images le montrent :

```bash
docker run --rm --entrypoint sh catalog-api:latest -c 'ls /app | grep -i healthcheck'
```

| Image | Bibliothèques de santé | Dépendances contrôlées par `/health` |
|---|---|---|
| `catalog-api` | `HealthChecks.Rabbitmq`, contrôle Entity Framework | PostgreSQL, RabbitMQ |
| `basket-api` | `HealthChecks.Rabbitmq`, `HealthChecks.Redis` | Redis, RabbitMQ |
| `ordering-api` | `HealthChecks.Rabbitmq`, contrôle Entity Framework | PostgreSQL, RabbitMQ |
| `identity-api` | Contrôle Entity Framework | PostgreSQL |
| `webapp` | `HealthChecks.Rabbitmq` | RabbitMQ |

### Des routes réservées au développement

Les deux routes ne sont déclarées qu’en environnement `Development` :

```csharp
// Adding health checks endpoints to applications in non-development environments has security implications.
if (app.Environment.IsDevelopment())
{
    app.MapHealthChecks("/health");
    app.MapHealthChecks("/alive", ...);
}
```

Les conteneurs tournent en `Production`. Les deux routes y répondent donc `404`, comme le guide 01 l’avait constaté.

## 3. Ce que fait réellement `/health`

Avant d’exposer ces routes, leur comportement a été vérifié sur des instances jetables de `Catalog.API`, démarrées en `Development` pour faire apparaître les routes :

| Situation | `/health` | `/alive` |
|---|---|---|
| Dépendances joignables | `Healthy`, HTTP 200 | `Healthy`, HTTP 200 |
| RabbitMQ injoignable | **Aucune réponse en 120 secondes** | `Healthy`, HTTP 200, en 14 ms |
| Base de données injoignable | Le service ne démarre pas | Idem |

Trois enseignements :

1. `/health` contrôle bien les dépendances, et `/alive` non.
2. **Quand RabbitMQ est injoignable, `/health` ne répond jamais `Unhealthy` : il reste bloqué.** Tout contrôle qui l’interroge doit donc avoir un délai d’attente court.
3. Sans base de données, le service s’arrête au démarrage, ses migrations ayant échoué. Aucune route n’existe alors. C’est la politique de redémarrage qui prend le relais (guide 16).

## 4. L’adaptation du code : `HealthChecks:Expose`

### La modification

Dans `application/eShop/src/eShop.ServiceDefaults/Extensions.cs`, la condition devient :

```csharp
// EshopOnContainer adaptation: health endpoints can also be exposed outside Development,
// when explicitly requested by configuration (HealthChecks__Expose=true).
var exposeHealthEndpoints = app.Environment.IsDevelopment()
    || app.Configuration.GetValue<bool>("HealthChecks:Expose");

if (exposeHealthEndpoints)
```

En haut du fichier, une ligne est ajoutée :

```csharp
using Microsoft.Extensions.Configuration;
```

Sans elle, la compilation échoue : `GetValue` est une méthode d’extension rangée dans cet espace de noms. Le projet `eShop.ServiceDefaults` utilise le SDK .NET de base, dont les `using` implicites ne l’incluent pas. La première version de la modification l’avait oublié ; l’erreur a été trouvée en construisant une image de test, avant toute modification du dépôt :

```text
error CS1061: 'IConfiguration' does not contain a definition for 'GetValue'
```

### Pourquoi activable plutôt que toujours active

| Critère | Supprimer la condition | La rendre activable |
|---|---|---|
| Comportement par défaut d’eShop | Modifié | Conservé |
| Décision visible dans le déploiement | Non | Oui, par la variable |
| Retour en arrière | Recompiler | Retirer la variable |

Le commentaire de Microsoft signale un risque à exposer ces routes. Il reste limité ici : elles ne répondent qu’un mot, `Healthy` ou `Unhealthy`, et les ports ne sont publiés que sur `127.0.0.1`.

### La règle du projet

La modification suit la règle de `application/README.md` : un commit dédié (`ae2f77b`), et une ligne dans le tableau des adaptations. Un seul fichier change, mais il vaut pour les neuf services, qui appellent tous `MapDefaultEndpoints`.

### Vérifier

Avec une image de test, en `Production` :

| Instance | `/health` | `/alive` | API |
|---|---|---|---|
| Sans `HealthChecks__Expose` | 404 | 404 | 200 |
| Avec `HealthChecks__Expose=true` | 200 | 200 | 200 |

Puis, une fois les neuf images reconstruites avec la modification et sans la variable, `/health` répondait toujours `404` : le comportement d’origine est conservé.

## 5. Le contrôle de Compose

### Le problème : ni `curl`, ni `wget`

Un contrôle de santé Compose est une commande exécutée **dans** le conteneur. Les images de base .NET sont réduites au minimum :

```bash
docker run --rm --entrypoint sh catalog-api:latest -c \
  'for t in bash curl wget nc perl python3; do printf "%s=%s " $t "$(command -v $t || echo -)"; done'
```

```text
bash=/usr/bin/bash curl=- wget=- nc=- perl=/usr/bin/perl python3=-
```

Ajouter `curl` aux images aurait alourdi les neuf Dockerfiles et élargi ce qu’un attaquant trouverait dans un conteneur. `bash` suffit.

### La requête HTTP écrite à la main

`bash` sait ouvrir une connexion réseau par un chemin spécial, `/dev/tcp/<adresse>/<port>`. Le contrôle y écrit une requête HTTP, puis lit la première ligne de la réponse :

```bash
exec 3<>/dev/tcp/127.0.0.1/8080 \
  && printf 'GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3 \
  && head -1 <&3 | grep -q ' 200 '
```

- `exec 3<>/dev/tcp/127.0.0.1/8080` ouvre une connexion vers le service, dans le conteneur, et lui attribue le numéro 3.
- `printf ... >&3` envoie la requête. `\r\n` termine chaque ligne, comme l’exige HTTP ; la ligne vide finale termine la requête.
- `head -1 <&3` lit la première ligne de la réponse, par exemple `HTTP/1.1 200 OK`.
- `grep -q ' 200 '` réussit seulement si le code est 200. Un `404` ou un `503` fait échouer le contrôle.

### Une définition, neuf services

Le contrôle est écrit une seule fois, en tête du fichier Compose :

```yaml
x-service-healthcheck: &service-healthcheck
  test:
    - CMD
    - bash
    - -c
    - >-
      exec 3<>/dev/tcp/127.0.0.1/$${HEALTHCHECK_PORT:-8080}
      && printf 'GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
      && head -1 <&3 | grep -q ' 200 '
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
  start_interval: 2s
```

| Élément | Rôle |
|---|---|
| `x-service-healthcheck` | Compose ignore les clés commençant par `x-` : elles servent à définir des blocs réutilisables |
| `&service-healthcheck` | Nom donné au bloc, rappelé dans chaque service par `healthcheck: *service-healthcheck` |
| `>-` | Bloc de texte YAML replié : les trois lignes forment une seule commande |
| `$${HEALTHCHECK_PORT:-8080}` | Le double `$` empêche Compose de remplacer la variable. C’est `bash`, dans le conteneur, qui la lit, avec `8080` par défaut |
| `timeout: 5s` | Interrompt le contrôle quand `/health` reste bloqué (section 3), et le compte comme un échec |
| `retries: 5` | Cinq échecs consécutifs avant l’état `unhealthy` |
| `start_period: 30s` | Les échecs des 30 premières secondes ne comptent pas, le temps des migrations |
| `start_interval: 2s` | Pendant `start_period`, un contrôle toutes les 2 secondes au lieu de 10 (Docker Engine 25 ou plus) |

Chaque service reçoit ensuite deux lignes :

```yaml
    environment:
      HealthChecks__Expose: "true"
    healthcheck: *service-healthcheck
```

### Le contrôle échoue bien quand il le faut

Le contrôle a été essayé dans un projet Compose jetable, sur le réseau du projet :

| Conteneur de test | Configuration | Résultat |
|---|---|---|
| `t-catalog` | `HealthChecks__Expose=true` | `healthy` |
| `t-nohc` | Sans la variable | Échec à chaque contrôle, jamais `healthy` |

Le second conteneur prouve que le contrôle ne se contente pas de constater qu’un service tourne : il échoue tant que `/health` ne répond pas `200`.

## 6. Deux services à part

### Identity.API : un autre port

`Identity.API` écoute sur le port `5223` dans son conteneur (guide 13, section 5). Il reçoit :

```yaml
      HEALTHCHECK_PORT: "5223"
```

### Basket.API : HTTP/2 seul

`Basket.API` n’accepte que HTTP/2 sur son port, pour gRPC (guide 08). Une requête HTTP/1.1, comme celle du contrôle, y reçoit `400`. Deux solutions ont été essayées :

| Solution | Résultat |
|---|---|
| Accepter HTTP/1.1 et HTTP/2 sur le même port : `Kestrel__EndpointDefaults__Protocols=Http1AndHttp2` | **gRPC cassé.** Sans chiffrement TLS, Kestrel ne peut pas choisir le protocole, et désactive HTTP/2 : `HTTP/2 is not enabled for [::]:8080. ... TLS is not enabled` |
| Un second port, en HTTP/1.1, réservé aux contrôles | Contrôle réussi, gRPC intact |

La seconde solution se configure par variables d’environnement, sans toucher au code :

```yaml
      HEALTHCHECK_PORT: "8081"
      Kestrel__Endpoints__grpc__Url: "http://+:8080"
      Kestrel__Endpoints__grpc__Protocols: "Http2"
      Kestrel__Endpoints__health__Url: "http://+:8081"
      Kestrel__Endpoints__health__Protocols: "Http1"
```

Kestrel, le serveur web de .NET, ouvre alors deux points d’écoute, chacun avec son protocole. Le journal le confirme :

```text
warn: Overriding address(es) 'http://*:8080'. Binding to endpoints defined via IConfiguration ...
Now listening on: http://[::]:8080
Now listening on: http://[::]:8081
```

L’avertissement est attendu : la variable `ASPNETCORE_HTTP_PORTS` du Dockerfile est remplacée par ces deux points d’écoute.

| Contrôle | Résultat |
|---|---|
| `/alive` et `/health` sur `8081`, en HTTP/1.1 | 200 |
| Appel gRPC `GetBasket` sur `8080` | `grpc-status: 0` |
| Port `8081` publié sur le poste | Non : seul le contrôle, dans le conteneur, l’utilise |

### Les deux services sans page

`OrderProcessor` et `PaymentProcessor` ne servent aucune page (guide 02, section 7), mais ils appellent eux aussi `MapDefaultEndpoints`. Avec `HealthChecks__Expose=true`, leurs routes `/health` et `/alive` existent, et le contrôle commun s’applique sans changement.

## 7. Attendre la santé plutôt que le démarrage

Tous les `depends_on` des services passent de `service_started` à `service_healthy`. Un service ne démarre plus qu’une fois ses dépendances réellement prêtes.

Le code d’eShop rend ce changement particulièrement utile pour `OrderProcessor`. `Ordering.API` applique ses migrations dans la méthode `StartAsync` d’un service d’arrière-plan (`Shared/MigrateDbContextExtensions.cs`). L’application n’accepte aucune requête avant leur fin. Un `/health` à `200` garantit donc que les tables de `orderingdb` existent.

Le guide 10 avait montré qu’`OrderProcessor`, démarré avant ces tables, écrivait une erreur toutes les 30 secondes jusqu’à leur création. Cette fenêtre a disparu : lors des deux démarrages à froid décrits plus bas, son journal ne contenait **aucune** ligne `fail`.

## 8. Les contrôles de PostgreSQL et de Redis, corrigés

Une revue extérieure du fichier Compose a relevé plusieurs défauts. Chaque affirmation a été vérifiée avant d’être retenue ou écartée ; le guide 16 traite les autres points.

### PostgreSQL : prêt trop tôt pendant l’initialisation

L’ancien contrôle était `pg_isready -U postgres`. Sans l’option `-h`, `pg_isready` interroge le serveur par son socket local. Or pendant l’exécution des scripts d’initialisation, comme `init-db.sh`, l’image fait tourner un serveur **temporaire**, joignable seulement par ce socket.

Le cas a été reproduit avec une base jetable et un script d’initialisation de 25 secondes :

| Moment | `pg_isready` par le socket | `pg_isready -h 127.0.0.1`, par TCP |
|---|---|---|
| Pendant l’initialisation | « accepting connections » | Pas de réponse |
| Après l’initialisation | Prêt | Prêt |

Le contrôle déclarait donc la base prête alors que les services, qui passent par TCP, ne pouvaient pas encore s’y connecter. Ce cas ne se produit qu’à la création du volume.

Le contrôle devient :

```yaml
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U $${POSTGRES_USER} -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
      start_interval: 2s
```

`-U $${POSTGRES_USER}` suit en plus la variable du fichier `.env`, au lieu d’écrire l’utilisateur en dur (point ouvert du guide 03).

Lors du démarrage sur volumes neufs (section 9), l’historique du contrôle montre l’effet :

| Heure (UTC) | Événement |
|---|---|
| 11:24:04 | Début de `init-db.sh` |
| 11:24:05 | Contrôle : **échec**, code 2, pas de réponse par TCP |
| 11:24:05 | Les quatre bases créées |
| 11:24:06 | Fin de l’initialisation, le vrai serveur écoute en TCP |
| 11:24:07 | Contrôle : succès |

### Redis : le mot de passe dans la commande

L’ancien contrôle était `redis-cli -a ${REDIS_PASSWORD} ping`. Compose remplaçait la variable : le mot de passe figurait en clair dans la définition du contrôle, et `redis-cli` affichait un avertissement à chaque exécution.

```yaml
    environment:
      REDISCLI_AUTH: ${REDIS_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
```

- `REDISCLI_AUTH` est la variable que `redis-cli` lit nativement pour s’authentifier.
- `grep -q PONG` corrige un défaut relevé dans le guide 04 : `redis-cli` sort avec le code `0` même quand Redis refuse la commande. Seule la réponse `PONG` fait maintenant réussir le contrôle.

Le mot de passe reste visible par `docker inspect`, dans les variables du conteneur, comme tous ceux du projet (guide 04, section 6). Mais il n’apparaît plus dans la commande du contrôle, et l’avertissement a disparu du journal.

## 9. Les démarrages à froid

### Sur des volumes existants

Après un `docker compose down` puis `up -d`, les images ayant été reconstruites :

| Après | Conteneurs `healthy` |
|---|---|
| 43 s | `postgres`, `rabbitmq`, `redis` (délai qui inclut la reconstruction des neuf images) |
| 48 s | `catalog-api`, `identity-api`, `payment-processor` |
| 53 s | `basket-api`, `ordering-api` |
| 55 s | `webhooks-api` |
| 60 s | `order-processor`, `webapp`, `webhook-client` |

### Sur des volumes neufs

Après `docker compose down -v`, avec toutes les corrections du guide et `start_interval` :

| Après | Conteneurs `healthy` |
|---|---|
| 20 s | `postgres` |
| 26 s | `identity-api`, `rabbitmq`, `redis` |
| 29-30 s | `payment-processor`, `webhooks-api`, `basket-api` |
| 32 s | `catalog-api`, `ordering-api`, `webhook-client` |
| 34 s | `order-processor`, `webapp` |

Les services démarrent par vagues, dans l’ordre de leurs dépendances, sans aucune intervention.

> **Attention :** `down -v` supprime les volumes, donc toutes les données : commandes, abonnements, paniers. Les bases sont recréées vides puis réinitialisées au démarrage (catalogue, utilisateurs `alice` et `bob`).

| Contrôle après le démarrage sur volumes neufs | Résultat |
|---|---|
| Bases | `catalogdb`, `identitydb`, `orderingdb`, `webhooksdb` |
| Articles, utilisateurs | 101 ; `alice`, `bob` |
| Lignes `fail` | Une dans `identity-api`, `catalog-api`, `ordering-api` et `webhooks-api`, sur `__EFMigrationsHistory`, attendues sur une base neuve (guide 02, section 7) |
| Lignes `fail` dans `order-processor` | 0 |
| Boutique | 10 articles |

## 10. Pour Kubernetes

Les deux routes correspondent aux deux types de contrôle de Kubernetes :

| Probe | Question | Route |
|---|---|---|
| `livenessProbe` | Faut-il redémarrer le conteneur ? | `/alive` |
| `readinessProbe` | Peut-on lui envoyer du trafic ? | `/health` |

Sous Compose, `/health` sert aux deux usages, car Compose ne redémarre jamais un conteneur `unhealthy`. Sous Kubernetes, utiliser `/health` pour la *liveness* serait une erreur : une coupure de RabbitMQ ferait redémarrer tous les services en même temps, sans rien résoudre. Les probes devront aussi avoir un délai d’attente court, pour la raison donnée en section 3.

## 11. Points ouverts

1. **`/health` reste bloqué quand RabbitMQ est injoignable.** Le délai d’attente des contrôles compense, mais le comportement vient du code d’eShop.
2. **Les routes de santé sont joignables depuis le poste**, sur les ports publiés, par exemple `http://127.0.0.1:5102/health`. Elles ne répondent qu’un mot, et seulement sur `127.0.0.1`.

## 12. Tableau de validation

| Contrôle | Résultat au 15 octobre 2026 |
|---|---|
| Adaptation `HealthChecks:Expose`, commit dédié | `ae2f77b`, inscrite dans `application/README.md` |
| Comportement par défaut conservé | `/health` en 404 sans la variable |
| Contrôle sans `curl`, par `bash` | Fonctionne, échoue sur 404 |
| `Basket.API`, second port en HTTP/1.1 | Contrôle réussi, gRPC intact |
| Douze conteneurs `healthy` | Oui |
| `depends_on` en `service_healthy` | Tous |
| Contrôle PostgreSQL pendant l’initialisation | Échoue tant que le serveur définitif n’écoute pas en TCP |
| Mot de passe Redis hors de la commande du contrôle | Oui |
| Démarrage sur volumes neufs | 34 s, sans erreur inattendue |

## 13. Commandes de référence

```bash
# État de santé de tous les conteneurs
docker compose -f docker/docker-compose.yaml ps --format '{{.Name}}|{{.Status}}'

# Historique des contrôles d'un conteneur (code de sortie de chaque contrôle)
docker inspect catalog-api --format '{{range .State.Health.Log}}{{.Start}} rc={{.ExitCode}}{{"\n"}}{{end}}'

# Interroger une route de santé depuis le poste
curl -s -w ' (%{http_code})\n' http://127.0.0.1:5102/health

# Exécuter le contrôle à la main, dans le conteneur
docker exec catalog-api bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080 && printf "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3 && head -1 <&3'
```

**Bilan :** les neuf services d’eShop exposent leurs routes de santé sur demande, grâce à une adaptation de huit lignes. Compose les interroge sans outil supplémentaire, attend que chaque dépendance soit réellement prête, et démarre l’application complète par vagues, sur des volumes neufs, en 34 secondes.
