# 13 — Docker Compose : WebApp

## 1. Objectif

Les guides [06](06-compose-identity.md) à [12](12-compose-webhooks.md) ont placé dans le fichier Compose les sept services sans interface d’eShop. Ce guide y ajoute `WebApp`, la boutique en ligne : la première page qu’un utilisateur ouvre dans son navigateur.

Avec elle apparaît la question laissée ouverte depuis le guide 06 : **la connexion d’un utilisateur**. Elle met en jeu le navigateur, sous Windows, et plusieurs conteneurs. Tous doivent joindre `Identity.API` à une seule et même adresse. Ce guide explique pourquoi, puis comment.

Les objectifs sont de :

- donner à `Identity.API` une adresse identique pour le navigateur et pour les conteneurs ;
- ajouter `WebApp` avec sa configuration ;
- vérifier le parcours complet d’un utilisateur : connexion, panier, commande, jusqu’au paiement.

**Périmètre :** `WebApp`, et les changements que la connexion impose à `Identity.API` et aux trois API. `WebhookClient`, l’autre site web d’eShop, sera traité ensuite.

**État au 15 octobre 2026 :** un utilisateur se connecte depuis le navigateur, remplit son panier et passe une commande. La commande traverse six services et arrive à l’état « payée », sans erreur.

## 2. Ce qui se passe quand un utilisateur se connecte

`WebApp` ne vérifie pas elle-même les mots de passe : elle confie la connexion à `Identity.API`, selon le protocole OpenID Connect. Le parcours compte trois acteurs :

```text
Navigateur (Windows)            WebApp (conteneur)            Identity.API (conteneur)
       │  1. « Se connecter »          │                                │
       │ ─────────────────────────────>│  2. Prépare la demande         │
       │                               │ ──────────────────────────────>│
       │  3. Redirection vers la page de connexion d’Identity.API       │
       │ <─────────────────────────────│                                │
       │  4. Identifiant et mot de passe                                │
       │ ──────────────────────────────────────────────────────────────>│
       │  5. Retour vers WebApp, avec un code                           │
       │ <──────────────────────────────────────────────────────────────│
       │ ─────────────────────────────>│  6. Échange le code            │
       │                               │     contre des jetons          │
       │                               │ ──────────────────────────────>│
```

`Identity.API` est donc joint par **deux acteurs différents** : le navigateur, aux étapes 3 et 4, et le conteneur `WebApp`, aux étapes 2 et 6. Plus tard, les API joindront aussi `Identity.API`, pour vérifier les jetons qu’on leur présente.

## 3. Le problème : une seule adresse pour tous

### Deux adresses différentes

Avant ce guide, `Identity.API` était joint de deux façons :

| Qui | Adresse |
|---|---|
| Le navigateur, sous Windows | `http://localhost:5223`, le port publié |
| Les conteneurs | `http://identity-api:8080`, le nom du service et son port interne |

Deux mécanismes rendent cette situation impossible.

**L’émetteur des jetons.** `Identity.API` inscrit dans chaque jeton son adresse, appelée « émetteur » (`issuer`). Il la déduit de l’adresse par laquelle on l’a joint. Le guide 06 l’avait constaté :

| Joint par | `issuer` annoncé |
|---|---|
| `http://127.0.0.1:5223` | `http://127.0.0.1:5223` |
| `http://identity-api:8080` | `http://identity-api:8080` |

Une API n’accepte un jeton que si son émetteur correspond à l’adresse qu’elle connaît pour `Identity.API`. Selon le chemin emprunté, les deux ne coïncideraient pas.

**La redirection du navigateur.** À l’étape 2, `WebApp` lit la configuration d’`Identity.API` en le joignant par le réseau Docker. Cette configuration contient l’adresse de la page de connexion, construite à partir de l’adresse utilisée : `http://identity-api:8080/...`. C’est vers elle que `WebApp` redirige le navigateur, à l’étape 3. Or Windows ne connaît pas le nom `identity-api`.

### La solution retenue : `http://identity-api:5223` pour tous

Il faut une adresse que le navigateur et les conteneurs comprennent de la même façon. Le projet utilise `http://identity-api:5223`, et règle chaque côté :

| Côté | Comment il joint `http://identity-api:5223` |
|---|---|
| Conteneurs | Le réseau Docker associe le nom `identity-api` au conteneur. `Identity.API` écoute sur le port `5223` dans le conteneur. |
| Navigateur | Le fichier `hosts` de Windows associe le nom `identity-api` à `127.0.0.1`. Le port `5223` est publié sur cette adresse. |

Cette solution ne modifie pas le code d’eShop. Elle demande une préparation du poste, une seule fois : la ligne du fichier `hosts`, décrite en section 4.

### Les solutions écartées

| Solution | Raison de l’écarter |
|---|---|
| Modifier le code d’`Identity.API` pour imposer l’émetteur, comme dans la première version du projet | Règle les jetons, mais pas la redirection du navigateur. Introduit un écart avec le code d’origine. |
| Utiliser l’adresse IP de WSL2, joignable de partout | Change à chaque redémarrage de WSL2, et oblige à publier les ports sur le réseau. |
| Utiliser un nom en `.localhost`, que les navigateurs dirigent vers `127.0.0.1` sans fichier `hosts` | Certains outils appliquent la même règle dans les conteneurs, où `127.0.0.1` désigne le conteneur lui-même. Non vérifié pour .NET 10. |

### Les limites de cette solution

- **La préparation est à refaire sur chaque poste**, comme la copie du fichier `.env`.
- **Le navigateur doit tourner sur le même poste que Docker.** Les ports sont publiés sur `127.0.0.1` et ne sont pas joignables depuis le réseau. L’accès depuis une autre machine relève du déploiement sur Kubernetes, avec un point d’entrée unique.

## 4. Préparer le poste : le fichier `hosts`

### Les scripts

Deux scripts ajoutent la ligne `127.0.0.1 identity-api` au fichier `hosts` du poste :

| Poste | Script | Lancement |
|---|---|---|
| Windows, avec Docker dans WSL2 | `docker/scripts/windows/add-hosts-entry.ps1` | PowerShell **en administrateur** |
| Linux | `docker/scripts/linux/add-hosts-entry.sh` | `sudo` |

Dans WSL2, il faut utiliser le script **Windows**. Le fichier `/etc/hosts` de WSL2 est régénéré à partir de celui de Windows à chaque démarrage, et c’est le navigateur de Windows qui doit connaître le nom. Le script Linux détecte WSL2 et s’arrête avec un message qui le rappelle.

### Ce que font les scripts

| Situation | Comportement |
|---|---|
| Lancé sans droits d’administrateur | Refusé |
| Ligne absente | Ajoutée, avec la marque `# EshopOnContainer`, puis vérifiée par une résolution du nom |
| Nom déjà déclaré vers `127.0.0.1` | Rien n’est modifié : le script peut être relancé sans risque |
| Nom déjà déclaré vers une autre adresse | Arrêt avec un message, sans rien écraser |
| Option `-Remove` (Windows) ou `--remove` (Linux) | Retire seulement les lignes marquées `# EshopOnContainer`, après une copie du fichier dans `hosts.bak` |

La marque protège les lignes écrites à la main. Une ligne `127.0.0.1 localhost identity-api`, par exemple, n’est jamais retirée par le script : la première version, qui retirait toute ligne contenant le nom, aurait aussi fait disparaître `localhost`.

Le script Windows tient compte de deux particularités, constatées pendant la mise au point :

- **L’attribut « lecture seule ».** Le fichier `hosts` de ce poste le portait. Même un administrateur ne peut pas écrire dans un tel fichier : le premier essai a échoué avec `L’accès au chemin d’accès ... est refusé`. Le script retire l’attribut le temps de l’écriture, puis le remet, y compris en cas d’erreur.
- **L’encodage.** Le fichier `hosts` est écrit en UTF-8 sans BOM, par les fonctions .NET. Avec `-Encoding ascii`, la première version transformait les caractères accentués des commentaires en `?`.

Le script PowerShell lui-même doit être enregistré en **UTF-8 avec BOM**. Sans cela, Windows PowerShell 5.1 affiche mal ses messages accentués.

### Lancer le script Windows

Un PowerShell ouvert en administrateur démarre dans `C:\WINDOWS\system32`. Il faut d’abord se placer à la racine du dépôt :

```powershell
cd /chemin/absolu/vers/EshopOnContainer
powershell -ExecutionPolicy Bypass -File .\docker\scripts\windows\add-hosts-entry.ps1
```

`-ExecutionPolicy Bypass` autorise ce script pour cette commande seulement, sans changer la configuration du poste.

Résultat vérifié le 15 octobre 2026 :

```text
Ajouté : 127.0.0.1	identity-api	# EshopOnContainer
Vérifié : identity-api -> 127.0.0.1
```

Vérifier ensuite que WSL2 connaît le nom :

```bash
getent hosts identity-api
```

```text
127.0.0.1       identity-api
```

Si la commande n’affiche rien, WSL2 n’a pas relu le fichier : lancer `wsl --shutdown` dans PowerShell, puis rouvrir le terminal. Cette commande arrête aussi Docker et les conteneurs.

### Les tests des scripts

| Script | Méthode | Cas vérifiés |
|---|---|---|
| Linux | Exécution dans un conteneur Debian jetable | Ajout, second lancement, retrait, retrait sans ligne, ligne à plusieurs noms conservée, autre adresse refusée, refus sans root, refus dans WSL2, fichier sans saut de ligne final |
| Windows | Exécution d’une copie sur un faux fichier `hosts`, sous PowerShell 7 et 5.1 | Les mêmes cas, plus un fichier en lecture seule, et l’absence de BOM après écriture |
| Windows | Exécution réelle, en administrateur | Ajout, attribut lecture seule remis, autres lignes intactes |

## 5. Les changements du fichier Compose

### Identity.API : une seule adresse, et l’adresse de la boutique

```yaml
  identity-api:
    # image, pull_policy, build et container_name inchangés
    environment:
      ConnectionStrings__identitydb: "Host=postgres;Port=5432;Database=identitydb;Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}"
      ASPNETCORE_HTTP_PORTS: "5223"
      WebAppClient: "http://localhost:5045"
    ports:
      - "127.0.0.1:5223:5223"
```

- `ASPNETCORE_HTTP_PORTS: "5223"` fait écouter `Identity.API` sur le port `5223` dans le conteneur. Cette variable remplace, pour ce seul service, la valeur `8080` fixée par le Dockerfile.
- `127.0.0.1:5223:5223` publie ce port sous le même numéro sur le poste.
- `WebAppClient` est l’adresse de la boutique, telle que le navigateur la voit. `Identity.API` ne renvoie un utilisateur, après sa connexion, que vers `WebAppClient` suivi de `/signin-oidc`.

### Les trois API : la nouvelle adresse

Dans `basket-api`, `ordering-api` et `webhooks-api` :

```yaml
      Identity__Url: "http://identity-api:5223"
```

### Le service WebApp

```yaml
  # =====================================================================
  # WEBAPP
  # =====================================================================
  webapp:
    image: webapp
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/WebApp/Dockerfile
    container_name: webapp
    environment:
      IdentityUrl: "http://identity-api:5223"
      CallBackUrl: "http://localhost:5045"
      ConnectionStrings__eventbus: "amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/"
      services__catalog-api__http__0: "http://catalog-api:8080"
      services__basket-api__http__0: "http://basket-api:8080"
      services__ordering-api__http__0: "http://ordering-api:8080"
    ports:
      - "127.0.0.1:5045:8080"
    depends_on:
      rabbitmq:
        condition: service_healthy
      identity-api:
        condition: service_started
      catalog-api:
        condition: service_started
      basket-api:
        condition: service_started
      ordering-api:
        condition: service_started
    networks:
      - eshop-network
```

| Réglage | Rôle |
|---|---|
| `IdentityUrl` | Adresse d’`Identity.API`. Sans tiret bas : c’est le nom que lit `WebApp`, alors que les API lisent `Identity__Url` (guide 02, section 6) |
| `CallBackUrl` | Adresse de la boutique, où l’utilisateur revient après sa déconnexion |
| `ConnectionStrings__eventbus` | RabbitMQ : `WebApp` reçoit les changements d’état des commandes, pour les afficher |
| `services__<nom>__http__0` | Adresse et port de chaque service appelé. Le code les désigne sans port, par exemple `http://catalog-api` ; sans ces variables, `WebApp` viserait le port `443` et afficherait une boutique vide (guide 02, section 7) |
| Port `5045` | Celui qu’eShop utilise en développement |
| `depends_on` | Les quatre services appelés par `WebApp`, et RabbitMQ |

Le Dockerfile de `WebApp` remplace un fichier source pour assouplir les cookies de connexion (guide 02, section 8). Ici, ce remplacement n’est pas nécessaire : la boutique est ouverte par `localhost`, que les navigateurs traitent comme une adresse sûre.

Aucune variable nouvelle n’est à ajouter au fichier `.env`.

## 6. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d
```

Sans nom de service, `up -d` recrée les conteneurs dont la configuration a changé : ici `identity-api`, les trois API et `webapp`. Les autres continuent de tourner.

### Le même émetteur, vu des deux côtés

C’est la vérification essentielle de ce guide :

```bash
curl -s http://identity-api:5223/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
docker run --rm --network docker_eshop-network curlimages/curl:latest \
  -s http://identity-api:5223/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
```

La première commande passe par le poste et le fichier `hosts`, comme le navigateur. La seconde passe par le réseau Docker, comme `WebApp` et les API.

Résultat vérifié le 15 octobre 2026 :

```text
"issuer":"http://identity-api:5223"
"issuer":"http://identity-api:5223"
```

Les deux commandes sont nécessaires. Lors d’un premier essai, seul le service `webapp` avait été ajouté : `Identity.API` écoutait encore sur `8080`. La première commande affichait pourtant le bon émetteur, parce que Docker redirigeait le port `5223` du poste vers le port `8080` du conteneur. La seconde n’affichait rien : depuis le réseau Docker, rien ne répondait sur `identity-api:5223`. Seule la comparaison des deux révèle une configuration incomplète.

### La boutique affiche le catalogue

```bash
until curl -s -o /dev/null http://127.0.0.1:5045/; do sleep 1; done
curl -s http://127.0.0.1:5045/ | grep -c 'catalog-item'
```

Résultat vérifié : `10` articles sur la page d’accueil.

### La redirection vers la page de connexion

```bash
curl -s -D - -o /dev/null http://localhost:5045/user/login | grep -i '^location'
```

Résultat vérifié, abrégé :

```text
location: http://identity-api:5223/connect/authorize?client_id=webapp&request_uri=urn:ietf:params:oauth:request_uri:...
```

`WebApp` a préparé la demande auprès d’`Identity.API` par le réseau Docker, puis renvoie le navigateur vers `identity-api:5223`, une adresse que le poste sait joindre. En suivant cette redirection, la page de connexion répond `200`.

### `localhost`, et non `127.0.0.1`

La boutique doit être ouverte par **`http://localhost:5045`**. Un essai par `http://127.0.0.1:5045` a échoué, avec dans le journal d’`Identity.API` :

```text
Invalid redirect_uri: http://127.0.0.1:5045/signin-oidc
  "AllowedRedirectUris": [ "http://localhost:5045/signin-oidc" ]
```

`WebApp` construit l’adresse de retour à partir de l’adresse saisie dans le navigateur. `Identity.API` la compare, caractère par caractère, à celle déclarée par `WebAppClient`. `127.0.0.1` et `localhost` désignent la même machine, mais ne s’écrivent pas de la même façon.

### Le parcours complet dans le navigateur

Le 15 octobre 2026, dans le navigateur de Windows :

1. ouverture de `http://localhost:5045` ;
2. clic sur l’icône utilisateur : redirection vers `http://identity-api:5223/Account/Login` ;
3. connexion avec l’utilisateur de démonstration `alice`, dont le mot de passe est défini dans `application/eShop/src/Identity.API/UsersSeed.cs` ;
4. retour sur la boutique, connecté ;
5. ajout d’un article au panier, puis passage de la commande.

Le journal d’`Identity.API` contient `User Login Success`, puis `Token Issued Success`.

La commande a ensuite été suivie à travers les journaux des services, par les événements qu’ils publient et reçoivent :

```bash
for c in ordering-api order-processor payment-processor catalog-api basket-api webapp webhooks-api; do
  docker logs -t --since 60m $c 2>&1 | grep -E '(Handling|Publishing) integration event' | sed "s/^/$c /"
done | sort -k2
```

Résultat vérifié, résumé :

| Heure (UTC) | Service | Événement | État de la commande |
|---|---|---|---|
| 23:14:35 | `ordering-api` | Commande créée, `OrderStarted` publié | `Submitted` |
| 23:14:35 | `basket-api` | `OrderStarted` reçu : le panier est vidé | |
| 23:15:58 | `order-processor` | Délai de grâce écoulé, `GracePeriodConfirmed` publié | `AwaitingValidation` |
| 23:15:58 | `catalog-api` | Stock vérifié, `OrderStockConfirmed` publié | |
| 23:16:08 | `ordering-api` | `OrderStatusChangedToStockConfirmed` publié | `StockConfirmed` |
| 23:16:08 | `payment-processor` | Paiement simulé, `OrderPaymentSucceeded` publié | |
| 23:16:18 | `ordering-api` | `OrderStatusChangedToPaid` publié | **`Paid`** |
| 23:16:19 | `webhooks-api` | Événement « payée » reçu, 0 abonnement à prévenir | |
| Tout du long | `webapp` | Chaque changement d’état reçu, pour l’afficher au client | |

En base :

```bash
docker exec postgres psql -U postgres -d orderingdb -c 'select "Id", "OrderStatus" from ordering.orders'
```

```text
 Id | OrderStatus
----+-------------
  1 | Paid
```

| Contrôle | Résultat |
|---|---|
| Erreurs dans les journaux des six services, pendant le parcours | Aucune |
| Messages en attente dans les sept files RabbitMQ | Aucun |
| Clés restantes dans Redis | `0` : le panier a été vidé à la commande |

Deux observations :

- **Dix secondes séparent `StockConfirmed` de `Paid`.** Ce n’est pas une lenteur : eShop simule un temps de validation du paiement, codé en dur dans `Ordering.API/Application/Commands/SetPaidOrderStatusCommandHandler.cs` (`await Task.Delay(10000)`).
- **83 secondes séparent la création de la commande de sa validation.** C’est le délai de grâce d’une minute, plus l’attente du passage suivant d’`OrderProcessor`, qui cherche toutes les 30 secondes (guide 10).

### Ce que ce parcours vérifie

C’est la première vérification de bout en bout du projet. Il confirme aussi plusieurs points restés ouverts dans les guides précédents :

| Point | Guide | Vérifié par |
|---|---|---|
| Accès de `Basket.API` à Redis | 08 | `Basket item persisted successfully`, puis panier vidé |
| Jetons acceptés par les API | 06, 08 | Requêtes d’`alice` acceptées par `Basket.API` et `Ordering.API` |
| Création d’une commande | 09 | Commande n° 1 |
| Traitement par `OrderProcessor` | 10 | `GracePeriodConfirmed` publié |
| Réception des événements par `Webhooks.API` | 12 | Événement « payée » reçu |

## 7. Points ouverts

1. **`WebhookClient` reste à ajouter**, avec la variable `WebhooksWebClient` d’`Identity.API`.
2. **Les services n’ont pas de contrôle de santé.** `WebApp` ne peut attendre que le démarrage des services qu’il appelle.
3. **Les ports de `Catalog.API`, `Basket.API`, `Ordering.API` et `Webhooks.API` ne sont plus utiles qu’aux tests.** `WebApp` les joint par le réseau Docker.
4. **Le fichier `hosts` est à préparer sur chaque poste**, voir section 4.
5. **Le journal de `WebApp` contient l’avertissement `Failed to determine the https port for redirect`.** Le code d’eShop demande une redirection vers HTTPS, qui n’est pas configuré ici. Sans conséquence : la boutique fonctionne en HTTP.

## 8. Tableau de validation

| Contrôle | Résultat au 15 octobre 2026 |
|---|---|
| Ligne `identity-api` dans le fichier `hosts` | Ajoutée par le script, résolue par Windows et par WSL2 |
| Émetteur vu du poste | `http://identity-api:5223` |
| Émetteur vu du réseau Docker | `http://identity-api:5223` |
| Image `webapp:latest` | Construite par Compose, 370 Mo |
| Page d’accueil | 10 articles |
| Redirection vers la page de connexion | Vers `http://identity-api:5223`, page en `200` |
| Connexion d’`alice` dans le navigateur | Réussie |
| Panier enregistré dans Redis | Oui |
| Commande passée et suivie | N° 1, de `Submitted` à `Paid` |
| Erreurs pendant le parcours | Aucune |
| Ports publiés | `127.0.0.1` seulement |

## 9. Étape suivante

Ajouter `WebhookClient`, le dernier service d’eShop. Ce site de démonstration permet d’enregistrer un abonnement auprès de `Webhooks.API`, puis de recevoir ses notifications.

## 10. Commandes de référence

```bash
# Vérifier que le poste connaît le nom d'Identity.API
getent hosts identity-api

# Comparer l'émetteur vu du poste et vu du réseau Docker
curl -s http://identity-api:5223/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
docker run --rm --network docker_eshop-network curlimages/curl:latest \
  -s http://identity-api:5223/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'

# Connexions réussies
docker logs identity-api 2>&1 | grep -E '"Name": "(User Login Success|Token Issued Success)"'

# État des commandes
docker exec postgres psql -U postgres -d orderingdb -c 'select "Id", "OrderStatus" from ordering.orders'
```

```powershell
# Retirer la ligne du fichier hosts, en administrateur
powershell -ExecutionPolicy Bypass -File .\docker\scripts\windows\add-hosts-entry.ps1 -Remove
```

**Bilan :** la boutique fonctionne de bout en bout. Une adresse unique pour `Identity.API`, `http://identity-api:5223`, permet au navigateur et aux conteneurs de s’accorder sur l’émetteur des jetons, sans modifier le code d’eShop. Un utilisateur s’est connecté, a rempli son panier et a passé une commande, menée jusqu’au paiement par six services.
