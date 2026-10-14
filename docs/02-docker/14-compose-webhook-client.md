# 14 — Docker Compose : WebhookClient

## 1. Objectif

Le guide [13](13-compose-webapp.md) a ajouté `WebApp` et vérifié le parcours d’une commande de bout en bout. Ce guide ajoute le dernier service d’eShop : `WebhookClient`.

`WebhookClient` est un site de démonstration des *webhooks* (guide 12). Un utilisateur connecté y enregistre un abonnement à l’événement « commande payée ». Ensuite, à chaque commande payée, `Webhooks.API` appelle le site, qui affiche la notification reçue.

Ce service fait apparaître un sens de communication nouveau. Jusqu’ici, seuls le navigateur et les conteneurs appelaient des services. Ici, **un service, `Webhooks.API`, appelle un site web** : il doit pouvoir le joindre.

Les objectifs sont de :

- ajouter `WebhookClient` avec sa configuration ;
- lui faire déclarer une adresse que `Webhooks.API` peut joindre ;
- vérifier le parcours complet : connexion, abonnement, commande, notification reçue.

**État au 15 octobre 2026 :** les neuf services d’eShop et leurs trois dépendances tournent avec Docker Compose. Une commande payée a déclenché une notification, reçue par `WebhookClient`.

## 2. Le parcours d’un webhook

```text
1. Abonnement
   Navigateur ──> WebhookClient ──« abonnement »──> Webhooks.API
                                                        │ 2. Vérification
   WebhookClient <──── OPTIONS /check, avec un jeton ───┘
                 ────── réponse, avec le même jeton ───>  abonnement enregistré

3. Notification, à chaque commande payée
   Ordering.API ──« commande payée »──> RabbitMQ ──> Webhooks.API
                                                        │
   WebhookClient <──── POST /webhook-received ──────────┘
```

À l’étape 2, `Webhooks.API` vérifie que l’adresse fournie appartient bien au site qui s’abonne (`Webhooks.API/Services/GrantUrlTesterService.cs`). Il envoie une requête `OPTIONS` sur l’adresse `/check`, avec un jeton dans l’en-tête `X-eshop-whtoken`, et attend ce même jeton dans la réponse. Sans cette réponse, l’abonnement est refusé.

Aux étapes 2 et 3, c’est donc le conteneur `webhooks-api` qui appelle `WebhookClient`.

## 3. L’adresse que déclare WebhookClient

Les deux adresses, `/check` et `/webhook-received`, sont fournies par `WebhookClient` au moment de l’abonnement. Il les construit dans `WebhookClient/Components/Pages/AddWebhook.razor` :

```csharp
var baseUrl = !string.IsNullOrEmpty(options.Value.SelfUrl)
    ? options.Value.SelfUrl
    : Nav.BaseUri;
var granturl = $"{baseUrl}check";
var url = $"{baseUrl}webhook-received";
```

Sans réglage, `baseUrl` est l’adresse affichée dans le navigateur, `http://localhost:5062/`. Depuis le conteneur `webhooks-api`, `localhost` désigne `webhooks-api` lui-même : la vérification échouerait, et l’abonnement serait refusé.

Le code prévoit ce cas avec le réglage `WebhookClientOptions:SelfUrl`. Le fichier Compose lui donne l’adresse du site **vue du réseau Docker** :

```yaml
      WebhookClientOptions__SelfUrl: "http://webhook-client:8080/"
```

La barre oblique finale est indispensable : le code colle directement `check` et `webhook-received` à cette adresse.

C’est la situation inverse de celle d’`Identity.API` (guide 13, section 3). `Identity.API` doit être joint par le navigateur et par les conteneurs, d’où une adresse commune. Les adresses de `WebhookClient` ne sont jointes que par `Webhooks.API` : l’adresse du réseau Docker suffit.

## 4. Les changements du fichier Compose

### Identity.API : l’adresse du site

Dans le bloc `environment` d’`identity-api` :

```yaml
      WebhooksWebClient: "http://localhost:5062"
```

Comme `WebAppClient` pour la boutique, cette adresse est la seule vers laquelle `Identity.API` renverra un utilisateur après sa connexion au site.

### Le service WebhookClient

```yaml
  # =====================================================================
  # WEBHOOKCLIENT
  # =====================================================================
  webhook-client:
    image: webhook-client
    pull_policy: build
    build:
      context: ..
      dockerfile: docker/src/WebhookClient/Dockerfile
    container_name: webhook-client
    environment:
      IdentityUrl: "http://identity-api:5223"
      CallBackUrl: "http://localhost:5062"
      WebhookClientOptions__SelfUrl: "http://webhook-client:8080/"
      services__webhooks-api__http__0: "http://webhooks-api:8080"
    ports:
      - "127.0.0.1:5062:8080"
    depends_on:
      identity-api:
        condition: service_started
      webhooks-api:
        condition: service_started
    networks:
      - eshop-network
```

| Réglage | Rôle |
|---|---|
| `IdentityUrl`, `CallBackUrl` | Comme pour `WebApp` (guide 13, section 5) |
| `WebhookClientOptions__SelfUrl` | Adresse que `Webhooks.API` appellera, voir section 3 |
| `services__webhooks-api__http__0` | Le code désigne `Webhooks.API` par `http://webhooks-api`, sans port ; même mécanisme que pour `WebApp` |
| Port `5062` | Celui qu’eShop utilise en développement |
| `depends_on` | `Identity.API` pour la connexion, `Webhooks.API` pour les abonnements |

Le site n’utilise ni base de données ni RabbitMQ.

Le réglage `WebhookClientOptions:Token`, le jeton de vérification, garde sa valeur par défaut, définie dans `WebhookClient/appsettings.json`. Ce n’est pas un secret : il sert seulement à prouver que l’adresse déclarée répond bien pour ce site.

## 5. Démarrer et vérifier

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

```bash
docker compose -f docker/docker-compose.yaml config --quiet && echo OK
docker compose -f docker/docker-compose.yaml up -d
```

`identity-api` est recréé, à cause de sa nouvelle variable.

### La configuration reçue

```bash
docker exec identity-api printenv WebhooksWebClient
docker exec webhook-client printenv IdentityUrl CallBackUrl WebhookClientOptions__SelfUrl
```

Résultat vérifié le 15 octobre 2026 :

```text
http://localhost:5062
http://identity-api:5223
http://localhost:5062
http://webhook-client:8080/
```

### La redirection vers la page de connexion

La page d’accueil répond `200` sans connexion : elle affiche un contenu différent selon que l’utilisateur est connecté ou non. La connexion passe par `/login` :

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://localhost:5062/login
```

Résultat vérifié, abrégé :

```text
302 http://identity-api:5223/connect/authorize?client_id=webhooksclient&request_uri=...
```

### Le parcours complet dans le navigateur

Le 15 octobre 2026, dans le navigateur de Windows :

1. ouverture de `http://localhost:5062`, puis connexion avec `alice` ;
2. ajout d’un abonnement, sur la page `/add-webhook` ;
3. ouverture de la boutique, `http://localhost:5045`, et passage d’une nouvelle commande ;
4. retour sur `http://localhost:5062`, une fois la commande payée : la notification est affichée.

Chaque étape a été suivie dans les journaux et en base.

**La connexion.** Le journal d’`Identity.API` contient `User Login Success`, puis `Token Issued Success` pour le client `webhooksclient`.

**La vérification de l’adresse**, dans le journal de `webhooks-api` :

```text
23:36:45  Sending HTTP request OPTIONS http://webhook-client:8080/check
23:36:45  Received HTTP response headers after 5.4906ms - 200
23:36:45  Response code is OK for url http://webhook-client:8080/check and token in header was 6168DB8D-... (expected token was 6168DB8D-...)
```

**L’abonnement enregistré**, dans la base `webhooksdb` :

```bash
docker exec postgres psql -U postgres -d webhooksdb -c 'select "Id", "Type", "DestUrl" from "Subscriptions"'
```

```text
 Id | Type |                  DestUrl
----+------+--------------------------------------------
  1 |    3 | http://webhook-client:8080/webhook-received
```

L’adresse enregistrée est bien celle du réseau Docker, issue de `SelfUrl`.

**La commande n° 2**, passée à 23:37:43, a atteint l’état `Paid`.

**L’envoi de la notification**, dans le journal de `webhooks-api` :

```text
23:39:18  Received OrderStatusChangedToShippedIntegrationEvent and got 1 subscriptions to process
23:39:18  Sending HTTP request POST http://webhook-client:8080/webhook-received
23:39:18  Received HTTP response headers after 40.9293ms - 200
```

Le service a reçu l’événement « commande payée », trouvé un abonnement, et appelé l’adresse enregistrée. Le nom `...Shipped...` du message est une coquille du code d’eShop, déjà signalée dans le guide 12.

**La réception**, dans le journal de `webhook-client` :

```text
23:39:18  Received hook with token 6168DB8D-.... My token is 6168DB8D-.... Token validation is set to False
23:39:18  Received hook is going to be processed
23:39:18  Received hook was processed.
```

`Token validation is set to False` : le site compare le jeton reçu au sien, mais ne refuserait pas une notification dont le jeton diffère. Ce comportement dépend du réglage `WebhookClientOptions:ValidateToken`, qui vaut `false` par défaut.

### État de l’ensemble

| Contrôle | Résultat |
|---|---|
| Conteneurs en fonctionnement | 12 : 9 services et 3 dépendances |
| Messages en attente dans les files RabbitMQ | 0 |
| Image `webhook-client:latest` | 351 Mo, compte d’exécution `1654` |
| Erreurs dans les journaux des 9 services, sur 30 minutes | 4, toutes expliquées en section 6 |

## 6. Une interférence entre les deux sites

Pendant le parcours, `WebApp` et `WebhookClient` ont chacun écrit deux lignes `fail` :

```text
fail: Microsoft.AspNetCore.Antiforgery.DefaultAntiforgery[7]
      An exception was thrown while deserializing the token.
      Microsoft.AspNetCore.Antiforgery.AntiforgeryValidationException: The antiforgery token could not be decrypted.
       ---> System.Security.Cryptography.CryptographicException: The key {37a67a6e-...} was not found in the key ring.
```

### La cause

Les formulaires des deux sites sont protégés contre les requêtes forgées par un jeton « anti-falsification ». Ce jeton est conservé dans un cookie, chiffré avec une clé propre à chaque site.

Or un navigateur ne distingue pas les cookies selon le port : `localhost:5045` et `localhost:5062` partagent les mêmes cookies. Chaque site a donc reçu le cookie de l’autre, et n’a pas pu le déchiffrer.

Les clés de chaque site le confirment :

```bash
docker exec webapp ls /home/app/.aspnet/DataProtection-Keys
docker exec webhook-client ls /home/app/.aspnet/DataProtection-Keys
```

| Site | Sa propre clé | Clé introuvable dans son erreur |
|---|---|---|
| `webapp` | `37a67a6e-...` | `2ee3fe8a-...`, celle de `webhook-client` |
| `webhook-client` | `2ee3fe8a-...` | `37a67a6e-...`, celle de `webapp` |

Chaque site échoue sur la clé de l’autre.

### Les conséquences

Elles sont nulles pour le fonctionnement : le site ignore le cookie illisible et en crée un nouveau. Le parcours complet a réussi malgré ces lignes.

Les auteurs d’eShop connaissent ce problème pour le cookie de session. Le code de `WebhookClient` lui donne un nom distinct de celui de `WebApp`, avec ce commentaire :

```csharp
// Must be distinct from WebApp's cookie name, otherwise the two sites will interfere
// with each other when both are on localhost (yes, even when they are on different ports)
options.Cookie.Name = ".AspNetCore.WebHooksClientIdentity";
```

Le cookie anti-falsification, lui, n’a pas reçu ce traitement. Ces lignes `fail` réapparaîtront chaque fois qu’on passe d’un site à l’autre dans le même navigateur. Elles ne signalent pas une panne.

## 7. Points ouverts

1. **La validation du jeton des notifications est désactivée**, voir section 5. Le réglage `WebhookClientOptions__ValidateToken=true` l’activerait.
2. **Les deux sites partagent leurs cookies**, voir section 6. Seul un nom de domaine distinct par site supprimerait l’interférence.
3. **Les services n’ont pas de contrôle de santé**, comme tous les services d’eShop.

## 8. Tableau de validation

| Contrôle | Résultat au 15 octobre 2026 |
|---|---|
| `WebhooksWebClient` reçu par `Identity.API` | `http://localhost:5062` |
| `SelfUrl` reçu par `WebhookClient` | `http://webhook-client:8080/` |
| Redirection de `/login` | Vers `http://identity-api:5223`, client `webhooksclient` |
| Connexion d’`alice` dans le navigateur | Réussie |
| Vérification de l’adresse par `Webhooks.API` | `OPTIONS /check`, `200`, jeton identique |
| Abonnement enregistré | Destination `http://webhook-client:8080/webhook-received` |
| Commande n° 2 | `Paid` |
| Notification envoyée et reçue | `POST /webhook-received`, `200`, `Received hook was processed` |
| Port publié | `127.0.0.1:5062` seulement |
| Compte d’exécution | `1654` |

## 9. Étape suivante

Les neuf services d’eShop tournent avec Docker Compose, et les deux parcours de bout en bout ont réussi. Restent les points ouverts communs à tous les services, dont le principal : l’absence de contrôle de santé, à régler avant le déploiement sur Kubernetes.

## 10. Commandes de référence

```bash
# Construire et démarrer l'ensemble
docker compose -f docker/docker-compose.yaml up -d

# Abonnements enregistrés
docker exec postgres psql -U postgres -d webhooksdb -c 'select "Id", "Type", "DestUrl" from "Subscriptions"'

# Vérifications d'adresse et envois de notifications
docker logs webhooks-api 2>&1 | grep -E 'OPTIONS|subscriptions to process|webhook-received'

# Notifications reçues
docker logs webhook-client 2>&1 | grep 'Received hook'
```

**Bilan :** `WebhookClient` déclare une adresse que `Webhooks.API` peut joindre, grâce au réglage `SelfUrl`. Une commande payée dans la boutique a déclenché une notification, reçue par le site. Avec ce dernier service, l’application eShop complète tourne avec Docker Compose.
