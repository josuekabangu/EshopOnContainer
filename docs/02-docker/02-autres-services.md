# 02 — Images Docker des autres services

## 1. Objectif

Le guide [01 — Catalog.API](01-catalog-api.md) a construit et testé l’image d’un premier service. Cette étape applique la même méthode aux huit autres services de l’application eShop.

Les objectifs sont de :

- construire une image par service, à partir du même modèle de Dockerfile ;
- vérifier que chaque image s’exécute sans privilèges ;
- démarrer chaque service avec ses dépendances, pour connaître ce dont il a besoin ;
- relever ce qui distingue un service des autres.

**Périmètre :** ce guide porte sur les Dockerfiles et sur un test de démarrage de chaque image. Le démarrage de l’ensemble avec Docker Compose et la connexion d’un utilisateur depuis un navigateur sont des étapes distinctes.

**État au 14 octobre 2026 :** les huit images sont construites et validées. Celle de `WebApp` a demandé une correction de son Dockerfile, décrite en section 8.

## 2. Les services de l’application

L’application compte neuf services. Trois d’entre eux n’exposent aucune interface aux utilisateurs : ils traitent des messages reçus de RabbitMQ.

| Service | Rôle | Image | Dépendances |
|---|---|---|---|
| `Catalog.API` | Catalogue des articles | `catalog-api:latest` | PostgreSQL, RabbitMQ |
| `Identity.API` | Authentification des utilisateurs | `identity-api:latest` | PostgreSQL |
| `Basket.API` | Panier, en gRPC | `basket-api:latest` | Redis, RabbitMQ, Identity.API |
| `Ordering.API` | Commandes | `ordering-api:latest` | PostgreSQL, RabbitMQ, Identity.API |
| `OrderProcessor` | Traitement différé des commandes | `order-processor:latest` | PostgreSQL, RabbitMQ |
| `PaymentProcessor` | Simulation du paiement | `payment-processor:latest` | RabbitMQ |
| `Webhooks.API` | Abonnements aux notifications | `webhooks-api:latest` | PostgreSQL, RabbitMQ, Identity.API |
| `WebhookClient` | Site de démonstration des notifications | `webhook-client:latest` | Identity.API, Webhooks.API |
| `WebApp` | Boutique en ligne | `webapp:latest` | Identity.API, Catalog.API, Basket.API, Ordering.API, RabbitMQ |

Ces dépendances sont celles que déclare l’application elle-même, dans le fichier `application/eShop/src/eShop.AppHost/AppHost.cs`. Ce fichier décrit l’assemblage des services pour l’outil de développement de Microsoft, Aspire. Il n’est pas utilisé pour construire les images, mais il sert de référence : il indique quel service a besoin de quoi.

## 3. Un modèle de Dockerfile commun

Chaque service dispose de son Dockerfile, dans un répertoire à son nom :

```text
docker/src/
├── Basket.API/Dockerfile
├── Catalog.API/Dockerfile
├── Identity.API/Dockerfile
├── OrderProcessor/Dockerfile
├── Ordering.API/Dockerfile
├── PaymentProcessor/Dockerfile
├── WebApp/Dockerfile
├── WebhookClient/Dockerfile
└── Webhooks.API/Dockerfile
```

Les Dockerfiles reprennent celui de `Catalog.API`, expliqué instruction par instruction dans le guide 01, section 4. Seul le nom du projet change, à trois endroits :

```dockerfile
RUN dotnet restore src/Ordering.API/Ordering.API.csproj

RUN dotnet publish src/Ordering.API/Ordering.API.csproj \
    --configuration Release \
    --output /app/publish \
    --no-restore

ENTRYPOINT [ "dotnet", "Ordering.API.dll" ]
```

Le reste est identique d’un service à l’autre : les deux images de base, la copie des fichiers de configuration et des sources, le port `8080` et l’instruction `USER $APP_UID`.

Deux conséquences de ce modèle commun ont été vérifiées :

- **Le cache de construction est partagé.** Tous les Dockerfiles copient les mêmes sources avec les mêmes instructions. Docker réutilise donc ces couches d’une image à l’autre, et seules la restauration et la publication sont refaites pour chaque service.
- **Le fichier `.dockerignore` s’applique sans changement.** Il a été écrit pour l’ensemble des sources, et non pour un service.

Le Dockerfile de `WebApp` contient une instruction supplémentaire, qui remplace un fichier source. Elle est expliquée en section 8.

## 4. Construire les images

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
cd /chemin/absolu/vers/EshopOnContainer
```

Une boucle construit les images l’une après l’autre :

```bash
for pair in Basket.API:basket-api Identity.API:identity-api \
            OrderProcessor:order-processor Ordering.API:ordering-api \
            PaymentProcessor:payment-processor WebhookClient:webhook-client \
            Webhooks.API:webhooks-api WebApp:webapp; do
  docker build \
    -f "docker/src/${pair%%:*}/Dockerfile" \
    -t "${pair##*:}:latest" \
    . || break
done
```

Chaque élément de la liste associe le nom du répertoire au nom de l’image, séparés par deux-points. `${pair%%:*}` en extrait la partie gauche, `${pair##*:}` la partie droite. `|| break` arrête la boucle à la première construction en échec, pour que l’erreur reste visible à l’écran.

### Convention de nommage des images

Chaque image porte le nom du service en minuscules, avec un tiret, et l’étiquette `latest` : `catalog-api:latest`, `identity-api:latest`, `webapp:latest`. Le fichier Docker Compose reprend les mêmes noms.

Cette convention a été fixée le 14 octobre 2026. Les images avaient d’abord été construites sous la forme `eshop/<service>:dev`, qui figure dans les sorties de commande enregistrées avant cette date. Il s’agit des mêmes images : seul leur nom a changé. Pour renommer une image existante sans la reconstruire :

```bash
docker tag eshop/catalog-api:dev catalog-api:latest
docker rmi eshop/catalog-api:dev
```

`docker tag` ajoute un second nom à la même image ; `docker rmi` retire ensuite l’ancien nom, sans supprimer l’image tant qu’un autre nom la désigne.

Deux conséquences de ce choix sont à connaître :

- **Un nom sans préfixe désigne Docker Hub.** Pour Docker, `identity-api:latest` signifie `docker.io/library/identity-api:latest`, l’espace des images officielles. Si l’image n’existe pas sur le poste, Docker tente de la télécharger. Dans le fichier Compose, le réglage `pull_policy: build` l’en empêche : l’image est toujours construite, jamais téléchargée.
- **L’étiquette `latest` ne désigne pas une version.** Chaque construction remplace l’image précédente sous le même nom. Pour le travail sur le poste, c’est le comportement voulu. Pour le déploiement sur Kubernetes, les images devront être poussées vers un registre, avec un préfixe et une étiquette de version.

Vérifier ensuite les images :

```bash
docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E '^(basket-api|catalog-api|identity-api|order-processor|ordering-api|payment-processor|webapp|webhook-client|webhooks-api):'
```

Résultat vérifié le 13 octobre 2026 :

| Image | Construction | Taille |
|---|---|---|
| `basket-api:latest` | Réussie | 354 Mo |
| `catalog-api:latest` | Réussie (guide 01) | 381 Mo |
| `identity-api:latest` | Réussie | 399 Mo |
| `order-processor:latest` | Réussie | 352 Mo |
| `ordering-api:latest` | Réussie | 361 Mo |
| `payment-processor:latest` | Réussie | 350 Mo |
| `webhook-client:latest` | Réussie | 351 Mo |
| `webhooks-api:latest` | Réussie | 360 Mo |
| `webapp:latest` | Réussie le 14 octobre 2026, après correction (section 8) | 370 Mo |

Une fois les couches communes en cache, chaque construction a pris entre 8 et 29 secondes.

## 5. Vérifier le compte d’exécution

Le guide 01, section 8, explique pourquoi une image ne doit pas s’exécuter en `root`. Le contrôle est répété pour chaque image :

```bash
for tag in basket-api identity-api order-processor ordering-api \
           payment-processor webhook-client webhooks-api webapp; do
  printf '%s : ' "$tag"
  docker run --rm --entrypoint id "$tag:latest"
done
```

La commande `id` est lancée à la place de l’application. Elle affiche le compte sous lequel un conteneur de l’image s’exécute.

Résultat vérifié le 13 octobre 2026, et le 14 pour `WebApp`, identique pour les huit images :

```text
uid=1654(app) gid=1654(app) groups=1654(app)
```

## 6. Tester le démarrage de chaque service

Une image qui se construit n’est pas encore une image qui fonctionne. Chaque service a donc été démarré avec ses dépendances.

### Méthode

Le test a utilisé un réseau Docker séparé, `eshop-verify`, supprimé à la fin. Aucun port n’a été publié sur l’hôte : les requêtes ont été envoyées depuis un conteneur placé sur le même réseau. Les conteneurs du guide 01 n’ont pas été modifiés.

Trois dépendances ont été démarrées :

| Conteneur | Image | Rôle |
|---|---|---|
| `v-postgres` | `ankane/pgvector:latest` | PostgreSQL |
| `v-redis` | `redis:7-alpine` | Redis, pour le panier |
| `v-rabbit` | `rabbitmq:4-management` | RabbitMQ |

Le mot de passe est saisi sans être affiché, puis conservé dans une variable du terminal :

```bash
read -rs -p 'Mot de passe de test : ' PW; echo

docker network create eshop-verify

docker run -d --network eshop-verify --name v-postgres \
  -e POSTGRES_PASSWORD="$PW" ankane/pgvector:latest

docker run -d --network eshop-verify --name v-redis redis:7-alpine

docker run -d --network eshop-verify --name v-rabbit \
  -e RABBITMQ_DEFAULT_USER=eshop -e RABBITMQ_DEFAULT_PASS="$PW" \
  rabbitmq:4-management
```

`read -rs` lit la saisie sans l’afficher. Le mot de passe n’apparaît ainsi ni à l’écran, ni dans l’historique des commandes, ni dans un fichier du dépôt.

### Configuration attendue par chaque service

Un service reçoit sa configuration par des variables d’environnement. Les noms ci-dessous ont été relevés dans le code de chaque service, puis vérifiés par le test.

| Variable | Services | Valeur utilisée pour le test |
|---|---|---|
| `ConnectionStrings__identitydb` | Identity.API | `Host=v-postgres;Username=postgres;Password=<mot-de-passe>;Database=identitydb` |
| `ConnectionStrings__catalogdb` | Catalog.API | Même forme, base `catalogdb` |
| `ConnectionStrings__orderingdb` | Ordering.API, OrderProcessor | Même forme, base `orderingdb` |
| `ConnectionStrings__webhooksdb` | Webhooks.API | Même forme, base `webhooksdb` |
| `ConnectionStrings__eventbus` | Tous, sauf Identity.API et WebhookClient | `amqp://eshop:<mot-de-passe>@v-rabbit:5672` |
| `ConnectionStrings__redis` | Basket.API | `v-redis:6379` |
| `Identity__Url` | Basket.API, Ordering.API, Webhooks.API | `http://identity-api:8080` |
| `IdentityUrl` | WebApp, WebhookClient | `http://identity-api:8080` |
| `CallBackUrl` | WebApp, WebhookClient | Adresse du service lui-même, par exemple `http://webapp:8080` |
| `WebAppClient`, `WebhooksWebClient`, `BasketApiClient`, `OrderingApiClient`, `WebhooksApiClient` | Identity.API | Adresse de chaque client, par exemple `http://webapp:8080` |
| `services__catalog-api__http__0`, `services__basket-api__http__0`, `services__ordering-api__http__0` | WebApp | Adresse et port du service, par exemple `http://catalog-api:8080` |

Deux noms se ressemblent sans être interchangeables : les API lisent `Identity__Url`, alors que les deux sites web lisent `IdentityUrl`.

Exemple de démarrage, pour `Ordering.API` :

```bash
docker run -d --network eshop-verify --name ordering-api \
  -e "ConnectionStrings__orderingdb=Host=v-postgres;Username=postgres;Password=$PW;Database=orderingdb" \
  -e "ConnectionStrings__eventbus=amqp://eshop:$PW@v-rabbit:5672" \
  -e Identity__Url=http://identity-api:8080 \
  ordering-api:latest
```

Le nom donné au conteneur compte : c’est par ce nom que les autres services le joignent sur le réseau Docker.

Les requêtes de test sont envoyées par un conteneur temporaire, les images des services ne contenant ni `curl` ni `wget` :

```bash
docker run --rm --network eshop-verify curlimages/curl:latest \
  -s -o /dev/null -w '%{http_code}\n' \
  'http://ordering-api:8080/api/orders?api-version=1.0'
```

`-o /dev/null` écarte le corps de la réponse, et `-w '%{http_code}\n'` n’affiche que le code HTTP.

### Résultats

Résultats vérifiés le 13 octobre 2026 :

| Service | Conteneur en fonctionnement | Compte du processus | Contrôle | Résultat |
|---|---|---|---|---|
| Identity.API | Oui, aucun redémarrage | `1654` | `/.well-known/openid-configuration` | HTTP 200 |
| Catalog.API | Oui, aucun redémarrage | `1654` | `/api/catalog/catalogTypes` | HTTP 200 |
| Ordering.API | Oui, aucun redémarrage | `1654` | `/api/orders` sans jeton | HTTP 401 |
| Webhooks.API | Oui, aucun redémarrage | `1654` | `/api/webhooks` sans jeton | HTTP 401 |
| Basket.API | Oui, aucun redémarrage | `1654` | Requête HTTP/2 | Réponse reçue (404, aucune page à la racine) |
| OrderProcessor | Oui, aucun redémarrage | `1654` | File RabbitMQ `OrderProcessor` | 1 consommateur |
| PaymentProcessor | Oui, aucun redémarrage | `1654` | File RabbitMQ `PaymentProcessor` | 1 consommateur |
| WebhookClient | Oui, aucun redémarrage | `1654` | Page d’accueil | HTTP 200 |
| WebApp | Oui, aucun redémarrage | `1654` | Page d’accueil | HTTP 200, 10 articles affichés |

Un code `401` est ici le résultat attendu : ces deux API exigent un jeton d’authentification, et le refus prouve que l’application répond et applique son contrôle d’accès.

Côté RabbitMQ, les connexions ont été contrôlées sur le broker lui-même :

```bash
docker exec v-rabbit rabbitmqctl -q list_queues name consumers
```

```text
OrderProcessor      1
Ordering            1
Ordering.webapp     2
Catalog             1
Webhooks            1
Basket              1
PaymentProcessor    1
```

Chaque service concerné a créé sa file et s’y est abonné. Après le démarrage, les journaux des services ne contenaient aucune erreur.

## 7. Ce que le test a appris

### Les bases de données sont créées par les services

Seule l’instance PostgreSQL a été démarrée, sans aucune base. Après le démarrage des services :

```bash
docker exec v-postgres psql -U postgres -Atc \
  "select datname from pg_database where datname like '%db' order by 1"
```

```text
catalogdb
identitydb
orderingdb
webhooksdb
```

Chaque service crée sa base et ses tables à son premier démarrage. Le journal contient alors une erreur de connexion, suivie de la création :

```text
fail: Microsoft.EntityFrameworkCore.Database.Connection[20004]
      An error occurred using the connection to database 'identitydb' on server 'tcp://v-postgres:5432'.
```

Cette ligne est normale au premier démarrage : le service constate que la base n’existe pas, puis la crée.

`OrderProcessor` fait exception. Il utilise la base `orderingdb` sans la créer : c’est `Ordering.API` qui s’en charge. `Ordering.API` doit donc démarrer avant lui.

### Aucun service n’a besoin d’écrire dans son répertoire

Le guide 01 signalait un risque : un service exécuté sans privilèges ne peut pas écrire dans `/app`, qui appartient à `root`. Le test l’écarte pour les neuf services.

- **Identity.API** signe ses jetons avec une clé lue dans le fichier `/app/tempkey.jwk`. Ce fichier fait partie des sources d’eShop : il est déjà dans l’image, et le service se contente de le lire.
- **Les services web** enregistrent des clés de protection dans `/home/app/.aspnet/DataProtection-Keys`. Ce répertoire se trouve dans le dossier personnel du compte `app`, où il a le droit d’écrire.

Deux limites en découlent, sans conséquence pour un test :

- La clé de signature `tempkey.jwk` est publique, puisqu’elle figure dans le dépôt d’eShop. Elle ne convient qu’à un environnement d’apprentissage.
- Les clés de protection disparaissent avec le conteneur. Les sessions des utilisateurs ne survivent donc pas à sa recréation. Le journal le signale par un avertissement `Storing keys in a directory ... that may not be persisted outside of the container`.

### Basket.API ne parle que HTTP/2

`Basket.API` est un service gRPC. Sa configuration impose le protocole HTTP/2 sur son port :

| Requête | Résultat |
|---|---|
| HTTP/1.1, celle que `curl` envoie par défaut | HTTP 400 |
| HTTP/2, avec l’option `--http2-prior-knowledge` | Réponse du service |

Un contrôle de santé HTTP ordinaire échouerait donc sur ce service, même s’il fonctionne. Ce point sera à prendre en compte lors de l’écriture des contrôles de santé.

### Les deux services de traitement ne servent aucune page

`OrderProcessor` et `PaymentProcessor` écoutent sur le port `8080`, mais toute requête y reçoit un code `404`. Leur travail passe par RabbitMQ. Leur bon fonctionnement se vérifie donc sur le broker, par la présence d’un consommateur sur leur file, et non par une requête HTTP.

### WebApp doit connaître le port des autres services

Dans son code, `WebApp` désigne les autres services par un nom sans port, par exemple `http://catalog-api`. Avec Aspire, le port est fourni automatiquement. Dans un conteneur, il doit être donné par une variable d’environnement.

Le test a comparé les deux situations :

| Configuration | Page d’accueil | Articles affichés | Journal |
|---|---|---|---|
| Sans variable `services__...` | HTTP 200 | Aucun | `Connection refused (catalog-api:443)` |
| Avec `services__catalog-api__http__0=http://catalog-api:8080` | HTTP 200 | 10 | Aucune erreur |

Sans cette variable, `WebApp` cherche le catalogue sur le port `443`, où rien n’écoute. La page s’affiche tout de même, vide : le code `200` ne suffit donc pas à valider ce service, il faut contrôler son contenu.

### Les routes de santé sont absentes

`/health` et `/alive` ont répondu `404` sur `Identity.API`, comme sur `Catalog.API` dans le guide 01. La cause est la même pour tous les services : ces routes ne sont déclarées qu’en environnement de développement, dans un fichier commun. Le sujet reste ouvert.

## 8. WebApp : un fichier de remplacement

### Pourquoi

Pendant la connexion d’un utilisateur, `WebApp` dépose deux cookies dans le navigateur, puis vérifie qu’ils lui reviennent. Avec le code d’origine, ces cookies portent l’attribut `secure` : un navigateur ne les renvoie que sur une connexion HTTPS, avec une exception pour `localhost`.

Le laboratoire n’a pas encore de HTTPS. Sur une adresse autre que `localhost`, par exemple celle d’un nœud du cluster, la connexion échouerait donc. L’image de `WebApp` est construite avec une version modifiée d’un fichier source, qui retire cette contrainte.

### Quoi

Le fichier modifié est `docker/src/WebApp/Extensions.cs`. Il remplace, dans l’image seulement, le fichier `application/eShop/src/WebApp/Extensions/Extensions.cs`. Les sources d’eShop ne sont pas modifiées.

Il diffère du fichier d’origine par cinq lignes, dans la configuration de la connexion :

```csharp
options.ResponseMode = "query";
options.CorrelationCookie.SameSite = SameSiteMode.Lax;
options.NonceCookie.SameSite = SameSiteMode.Lax;
options.CorrelationCookie.SecurePolicy = CookieSecurePolicy.None;
options.NonceCookie.SecurePolicy = CookieSecurePolicy.None;
```

Les quatre dernières lignes retirent l’attribut `secure` des deux cookies et les passent en `samesite=lax`. La première fait revenir la réponse de connexion dans l’adresse de la page : un cookie `lax` n’est pas renvoyé avec un formulaire émis par un autre site, ce qui est le mode de retour par défaut.

### Comment

Deux fichiers sont concernés.

Le Dockerfile de `WebApp` copie le fichier modifié **après** les sources :

```dockerfile
# Sources et projets référencés
COPY application/eShop/src/ ./src/

# Patch OAuth2 SameSite/SecurePolicy pour fonctionner en HTTP (dev sans TLS)
COPY docker/src/WebApp/Extensions.cs src/WebApp/Extensions/Extensions.cs
```

Le fichier `.dockerignore` autorise ce fichier, et lui seul, à entrer dans le contexte de construction :

```text
# Fichier de remplacement appliqué par le Dockerfile de WebApp.
!docker/src/WebApp/Extensions.cs
```

Construire l’image :

```bash
docker build -f docker/src/WebApp/Dockerfile -t webapp:latest .
```

### Les trois défauts corrigés

La première version de l’instruction échouait avec l’erreur `"/src/WebApp/Extensions.cs": not found`. Trois défauts se cumulaient, et corriger le premier ne suffisait pas :

| Défaut | Explication | Correction |
|---|---|---|
| Chemin source faux | Le contexte de construction est la racine du dépôt. Le fichier s’y trouve sous `docker/src/WebApp/`, et non sous `src/WebApp/`. | Chemin complet depuis la racine |
| Fichier exclu du contexte | Le `.dockerignore` n’autorisait que `application/eShop`. | Ligne d’autorisation ajoutée |
| Ordre des instructions | L’instruction précédait la copie des sources, qui aurait écrasé le fichier modifié par le fichier d’origine. | Instruction déplacée après la copie des sources |

Le troisième défaut est le plus trompeur : la construction aurait réussi, sans erreur ni avertissement, et l’image n’aurait pas contenu la modification.

### Vérifier

Une construction réussie ne prouve donc pas que le remplacement a eu lieu. La preuve se lit dans les cookies que `WebApp` émet au début d’une connexion :

```bash
docker run --rm --network eshop-verify curlimages/curl:latest \
  -s -D - -o /dev/null http://webapp:8080/user/login | grep -i '^set-cookie'
```

`-D -` affiche les en-têtes de la réponse, où figurent les cookies.

Résultats vérifiés le 14 octobre 2026 :

| Image | Attributs des cookies de connexion |
|---|---|
| Sources d’origine, construite pour comparaison | `secure; samesite=none` |
| `webapp:latest`, avec le fichier de remplacement | `samesite=lax` |

| Contrôle sur `webapp:latest` | Résultat |
|---|---|
| Construction | Réussie, 370 Mo |
| Compte d’exécution | `uid=1654(app)` |
| Page d’accueil | HTTP 200, 10 articles affichés |
| Redirection de `/user/login` vers Identity.API | HTTP 302 |
| Erreurs dans le journal | Aucune |
| Contexte de construction des autres services | Inchangé |

La connexion complète d’un utilisateur depuis un navigateur n’a pas été testée.

### Limites de ce choix

- **La modification n’est pas dans les sources.** Elle n’apparaît donc pas dans le tableau des adaptations de [application/README.md](../../application/README.md), qui ne recense que les changements faits dans `application/eShop`. Ce guide en est la seule trace.
- **Le fichier est une copie complète.** Lors d’une mise à jour d’eShop, il remplacera la nouvelle version du fichier d’origine et masquera ses évolutions. Il devra être comparé au fichier d’origine à chaque mise à jour.
- **La sécurité des cookies est réduite sans condition.** Ils perdent l’attribut `secure` même si l’application est un jour servie en HTTPS. Le fichier de remplacement sera à retirer à ce moment-là.

Pour comparer les deux fichiers :

```bash
diff --strip-trailing-cr \
  application/eShop/src/WebApp/Extensions/Extensions.cs \
  docker/src/WebApp/Extensions.cs
```

`--strip-trailing-cr` ignore les différences de fin de ligne. Le résultat attendu se limite aux cinq lignes ci-dessus et à un caractère invisible en tête du fichier d’origine.

## 9. Tableau de validation

| Contrôle | Résultat au 14 octobre 2026 |
|---|---|
| Dockerfiles présents | 9 sur 9 |
| Images construites | 9 sur 9 |
| Images exécutées sans privilèges | 9 sur 9, `uid=1654(app)` |
| Services démarrés avec leurs dépendances | 9 sur 9 |
| Fichier de remplacement de `WebApp` présent dans l’image | Oui : cookies de connexion en `samesite=lax` |
| Erreurs de permission dans les journaux | Aucune |
| Redémarrages de conteneur | Aucun |
| Bases de données créées par les services | 4 sur 4 |
| Files RabbitMQ avec consommateur | 7 |
| Connexion d’un utilisateur depuis un navigateur | Non testée |
| Parcours d’achat complet | Non testé |
| Routes de santé `/health` et `/alive` | Absentes (HTTP 404) |

## 10. Points ouverts

1. **Retirer le fichier de remplacement de `WebApp`** lorsque l’application sera servie en HTTPS, et le comparer au fichier d’origine à chaque mise à jour d’eShop, voir section 8.
2. **Décider du traitement des routes de santé**, en tenant compte de `Basket.API`, qui ne répond qu’en HTTP/2, et des deux services de traitement, qui ne servent aucune page.
3. **Réduire la répétition.** Les neuf Dockerfiles ne diffèrent que par le nom du projet. Un Dockerfile unique, recevant ce nom en argument de construction, éviterait de reporter neuf fois chaque évolution. Le choix d’un fichier par service reste valable : il est plus simple à lire.
4. **Corriger le commentaire** « Restauration des référencés », repris dans les neuf fichiers : il s’agit de la restauration des dépendances.
5. **Clé de signature et clés de protection**, voir section 7 : à traiter avant tout usage autre que l’apprentissage.

## 11. Étape suivante

Les services se démarrent ici un par un, à la main, avec une douzaine de variables. L’étape suivante consiste à décrire cet ensemble dans `docker/docker-compose.yaml` : les dépendances, les neuf services, leur configuration et leur ordre de démarrage, notamment `Ordering.API` avant `OrderProcessor`.

Ce travail commence par PostgreSQL : voir [03 — Docker Compose : PostgreSQL](03-compose-postgres.md).

## 12. Commandes de référence

```bash
# Construire une image
docker build -f docker/src/Ordering.API/Dockerfile -t ordering-api:latest .

# Lister les images du projet
docker image ls --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E '^(basket-api|catalog-api|identity-api|order-processor|ordering-api|payment-processor|webapp|webhook-client|webhooks-api):'

# Vérifier le compte d'exécution d'une image
docker run --rm --entrypoint id ordering-api:latest

# Envoyer une requête depuis le réseau de test
docker run --rm --network eshop-verify curlimages/curl:latest \
  -s -o /dev/null -w '%{http_code}\n' http://identity-api:8080/.well-known/openid-configuration

# Contrôler les files RabbitMQ et leurs consommateurs
docker exec v-rabbit rabbitmqctl -q list_queues name consumers

# Supprimer l'environnement de test
docker rm -f v-postgres v-redis v-rabbit
docker network rm eshop-verify
```

La dernière commande ne supprime que les dépendances. Les conteneurs des services démarrés pour le test sont à supprimer de la même façon, par leur nom.

**Bilan :** les neuf images sont construites, s’exécutent sans privilèges et démarrent avec leurs dépendances. Le test a aussi fourni la liste des variables et l’ordre de démarrage dont le fichier Docker Compose aura besoin.
