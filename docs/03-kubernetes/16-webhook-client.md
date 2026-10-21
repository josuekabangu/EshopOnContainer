# 16 — WebhookClient sur le cluster

## 1. Objectif

`WebhookClient` est un site de démonstration : il joue l'application extérieure qui s'abonne aux événements de la boutique, et affiche les notifications que `Webhooks.API` lui livre ([guide 02-docker/14](../02-docker/14-compose-webhook-client.md)).

Ce guide le déploie derrière le point d'entrée, et vérifie qu'une commande payée produit une notification livrée. Il a demandé une troisième adaptation du code d'eShop.

**État au 21 octobre 2026 :** `WebhookClient` s'ouvre par `http://webhooks.eshop.lab`. `alice` s'y est connectée et abonnée ; au paiement de la commande `3`, `Webhooks.API` a livré trois notifications, une par abonnement, toutes traitées.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Objet | `Deployment`, image `ghcr.io/josuekabangu/webhook-client:a6647c9` | L'image de son adaptation, section 4 |
| Copies | 1, obligatoirement | Cookies de session, comme `WebApp` |
| Secret | Aucun | Sa configuration ne contient que des adresses |
| `IdentityUrl`, `CallBackUrl` | `http://identity.eshop.lab`, `http://webhooks.eshop.lab` | Les adresses publiques |
| `WebhookClientOptions__SelfUrl` | `http://webhook-client:8080/` | L'adresse où `Webhooks.API` livre les notifications : interne au cluster, sans passer par le point d'entrée |
| `services__webhooks-api__http__0` | `http://webhooks-api:8080` | Appel interne |
| `Authentication__AllowInsecureCookies` | `"true"` | Connexion en HTTP, section 4 |
| Route | `webhooks.eshop.lab` vers `webhook-client:8080` | — |

```text
kubernetes/webhook-client/
├── deployment-webhook-client.yaml
├── httproute-webhook-client.yaml
└── service-webhook-client.yaml
```

## 3. Premier essai : `Correlation failed`

Avec l'image `87e28f8`, la page s'affichait, mais la connexion échouait au retour d'`identity.eshop.lab` :

```bash
kubectl -n eshop logs deployment/webhook-client --since=10m | grep -E '^(fail|crit|warn):' -A4 | head -30
```

```text
warn: Microsoft.AspNetCore.Authentication.OpenIdConnect.OpenIdConnectHandler[15]
      '.AspNetCore.Correlation.L1TPgP9u...' cookie not found.
fail: Microsoft.AspNetCore.Server.Kestrel[13]
      Microsoft.AspNetCore.Authentication.AuthenticationFailureException: An error was encountered while handling the remote login.
       ---> Microsoft.AspNetCore.Authentication.AuthenticationFailureException: Correlation failed.
```

Avant de rediriger le navigateur, le site pose un cookie de corrélation, qui sert à reconnaître la réponse au retour. Le code d'origine le pose avec `SameSite=None`, qui exige l'attribut `Secure`, donc HTTPS. En HTTP, le navigateur ne le renvoie pas, et le site rejette la connexion.

`WebApp` avait le même défaut, réglé par l'adaptation `72ee8fa`. `WebhookClient` ne l'avait pas : avec Compose, il était ouvert par `localhost`, que les navigateurs traitent comme une adresse sûre. Le problème avait été annoncé avant le test.

Pour l'invoquer, `kubectl logs` demande le nom du pod, ou `deployment/<nom>` : `kubectl logs webhook-client` échoue, `webhook-client` étant le nom du `Deployment`.

## 4. L'adaptation `a6647c9`

### Les options

| Option | Coût | Retenue |
|---|---|---|
| La même adaptation que `WebApp`, activée par le même réglage | Un commit dans `application/`, une image pour ce seul service | **Oui** |
| HTTPS sur le point d'entrée | Une autorité de certification, cert-manager, la confiance sous Windows **et dans chaque pod**, les API joignant `Identity.API` par `https://identity.eshop.lab` | Point ouvert de la phase d'exploitation ; les deux adaptations deviendraient inutiles |

### Le code

Dans `application/eShop/src/WebhookClient/Extensions/Extensions.cs`, à la fin de `AddOpenIdConnect`, le bloc de `WebApp` à l'identique :

```csharp
            options.Scope.Add("webhooks");

            // EshopOnContainer adaptation: let the sign-in work over plain HTTP on a host other than
            // localhost, when explicitly requested by configuration (Authentication__AllowInsecureCookies=true).
            if (configuration.GetValue<bool>("Authentication:AllowInsecureCookies"))
            {
                options.ResponseMode = "query";
                options.CorrelationCookie.SameSite = SameSiteMode.Lax;
                options.NonceCookie.SameSite = SameSiteMode.Lax;
                options.CorrelationCookie.SecurePolicy = CookieSecurePolicy.None;
                options.NonceCookie.SecurePolicy = CookieSecurePolicy.None;
            }
        });
```

Sans le réglage, le comportement d'origine est conservé. La variable `configuration` existait déjà dans la méthode. La compilation a été vérifiée par une image de test, avant le commit.

L'adaptation est inscrite dans [application/README.md](../../application/README.md), selon la règle : une adaptation, un commit.

### L'image

La règle du [guide 01](01-registre-images.md) impose de commiter avant de publier : l'image porte l'identifiant du commit qui contient son code.

```bash
git add application/eShop/src/WebhookClient/Extensions/Extensions.cs
git commit -m "[App] - WebhookClient : assouplissement des cookies activable par Authentication:AllowInsecureCookies"

read -rs -p 'Jeton GitHub (write:packages) : ' GHCR_TOKEN; echo
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u josuekabangu --password-stdin
unset GHCR_TOKEN

TAG=$(git rev-parse --short HEAD)
docker build -f docker/src/WebhookClient/Dockerfile -t webhook-client:latest .
docker tag webhook-client:latest "ghcr.io/josuekabangu/webhook-client:$TAG"
docker push "ghcr.io/josuekabangu/webhook-client:$TAG"
```

Résultat vérifié le 21 octobre 2026 : commit `a6647c9`, image publiée sous `ghcr.io/josuekabangu/webhook-client:a6647c9`. La construction était entièrement en cache, celle de vérification ayant déjà compilé ce code ; une couche nouvelle a été publiée.

La connexion au registre a été refaite avec un nouveau jeton : l'ancien jeton d'écriture avait été révoqué le 20 octobre, après avoir été exposé par erreur.

`WebhookClient` porte désormais une étiquette différente des autres images, toujours en `87e28f8`.

### Le `Deployment`, et une étape manquée

Le `Deployment` reçoit la nouvelle image et le réglage :

```yaml
          image: ghcr.io/josuekabangu/webhook-client:a6647c9
          ...
            # Connexion en HTTP par un nom autre que localhost (adaptation de WebhookClient)
            - name: Authentication__AllowInsecureCookies
              value: "true"
```

Une première application n'avait ajouté que le réglage : la ligne `image:` était restée à `87e28f8`. Le pod avait redémarré avec l'ancien code, qui ignore le réglage, et la connexion échouait toujours. La vérification lisait l'image du **premier pod listé**, ce qui pouvait être l'ancien, encore en cours d'arrêt ; l'image du `Deployment` lui-même est la bonne référence :

```bash
kubectl -n eshop get deployment webhook-client -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

### Une seconde erreur, instructive

Le même journal contenait :

```text
The antiforgery token could not be decrypted.
The key {d3b72356-...} was not found in the key ring.
```

Le navigateur présentait un jeton anti-falsification chiffré par le premier pod, dont les clés de protection des données ont disparu avec lui. C'est, en conditions réelles, la limite décrite pour `Identity.API` ([guide 07](07-identity-api.md), section 7). Une fenêtre de navigation privée, sans les anciens cookies, l'évite pour le test.

## 5. Le test de bout en bout

Dans une fenêtre InPrivate d'Edge :

1. ouvrir `http://webhooks.eshop.lab`, et se connecter avec `alice` ;
2. s'abonner à l'événement « commande payée » ;
3. passer une commande sur `http://shop.eshop.lab` ;
4. attendre l'état `Paid`, puis recharger `WebhookClient`.

Après l'abonnement, la page affiche `alice` connectée, et la destination `http://webhook-client:8080/webhook-received` : l'adresse interne. L'enregistrement de l'abonnement est déjà une preuve : `WebhookClient` a appelé `Webhooks.API` avec le jeton d'`alice`, accepté avec `Identity__Url` à `http://identity.eshop.lab`.

### Les preuves côté serveur

```bash
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d webhooksdb -At <<'SQL'
select "Date", "DestUrl", "UserId" from "Subscriptions" order by "Date";
SQL
kubectl -n eshop logs deployment/webhooks-api --since=15m | grep 'subscriptions to process'
kubectl -n eshop logs deployment/webhooks-api --since=20m | grep -i -E 'webhook|sending|sent' | grep -v -i 'subscriptions to process' | tail -5
kubectl -n eshop logs deployment/webhook-client --since=20m | grep -i -E 'webhook-received|Received hook|POST' | tail -5
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d orderingdb -At <<'SQL'
select "Id", "OrderStatus" from ordering.orders order by "Id";
SQL
```

Résultats vérifiés le 21 octobre 2026, abrégés :

```text
2026-10-21 11:19:10|http://webhook-client:8080/webhook-received|b3eb639d-...
2026-10-21 11:22:58|http://webhook-client:8080/webhook-received|b3eb639d-...
2026-10-21 11:23:32|http://webhook-client:8080/webhook-received|b3eb639d-...

Received OrderStatusChangedToShippedIntegrationEvent and got 3 subscriptions to process

Sending HTTP request POST http://webhook-client:8080/webhook-received      (trois fois)

Received hook with token 6168DB8D-.... My token is 6168DB8D-.... Token validation is set to False
Received hook was processed.                                               (trois fois)

1|Paid
2|Paid
3|Paid
```

| Constat | Ce qu'il prouve |
|---|---|
| Trois abonnements d'un même utilisateur | Trois clics sur « Add webhook registration » |
| `3 subscriptions to process` | `Webhooks.API` a reçu l'événement « commande payée » de la commande `3`. Le nom `Shipped` est une coquille du code d'eShop ([guide 13](13-webhooks-api.md)) |
| Trois `POST` vers `webhook-client:8080` | Une livraison par abonnement, à l'intérieur du cluster |
| `Received hook was processed` | `WebhookClient` a reçu et traité les notifications |
| `Token validation is set to False` | Le jeton reçu correspond au sien, mais sa vérification est désactivée par défaut dans eShop |

## 6. Les limites

| Limite | Conséquence |
|---|---|
| Vérification du jeton désactivée | `WebhookClient` accepterait une notification de n'importe qui. Réglage d'origine d'eShop |
| Notifications gardées en mémoire | Elles disparaissent au redémarrage du pod |
| Adaptation des cookies | À retirer avec HTTPS |
| Une image à part | `a6647c9`, quand les autres sont en `87e28f8` |

## 7. Tableau de validation

| Contrôle | Résultat au 21 octobre 2026 |
|---|---|
| Adaptation `a6647c9`, compilée et publiée | Oui |
| Connexion d'`alice` en HTTP | Oui, après l'adaptation |
| Abonnement enregistré par `Webhooks.API` | Oui |
| Commande `3` à l'état `Paid` | Oui |
| Notifications livrées et traitées | Oui, trois |

## 8. Étape suivante

Toute l'application tourne sur le cluster. Une reconstruction complète, qui rejoue tout depuis le dépôt, a révélé un problème d'ordre de démarrage : [17 — L'ordre de démarrage](17-ordre-de-demarrage.md). Vient ensuite le passage aux charts Helm.

**Bilan :** `WebhookClient` fonctionne derrière le point d'entrée, grâce à une adaptation du code identique à celle de `WebApp`, publiée sous l'identifiant de son commit. Une commande payée sur la boutique a produit des notifications livrées à l'intérieur du cluster : la dernière chaîne d'eShop est vérifiée.
