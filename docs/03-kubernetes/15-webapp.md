# 15 — WebApp sur le cluster : la boutique de bout en bout

## 1. Objectif

`WebApp` est la boutique : le site que l'utilisateur ouvre dans son navigateur. Il affiche le catalogue, confie la connexion à `Identity.API`, gère le panier par `Basket.API` et passe les commandes par `Ordering.API`.

Ce guide le déploie derrière le point d'entrée ([guide 14](14-point-entree.md)), puis mène une commande complète depuis le navigateur de Windows. C'est la validation de toute l'application sur le cluster.

**État au 21 octobre 2026 :** la boutique s'ouvre par `http://shop.eshop.lab`. L'utilisateur `alice` s'y est connecté, a rempli son panier, et trois commandes sont passées à l'état `Paid`.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Objet | `Deployment`, image `ghcr.io/josuekabangu/webapp:87e28f8`, port 8080 | — |
| Copies | **1, obligatoirement** | `WebApp` chiffre les cookies de session avec ses clés de protection des données, propres à chaque pod, comme `Identity.API` ([guide 07](07-identity-api.md), section 7) |
| Secret | `webapp-secrets` : `ConnectionStrings__eventbus` | `WebApp` s'abonne à RabbitMQ pour suivre l'état des commandes |
| `IdentityUrl`, `CallBackUrl` | `http://identity.eshop.lab`, `http://shop.eshop.lab` | Les adresses publiques, que suit le navigateur |
| `services__catalog-api__http__0` et les deux autres | Les `Service` du cluster, port 8080 | Les appels internes. Sans ces réglages, `WebApp` viserait le port 443 ([guide 02-docker/02](../02-docker/02-autres-services.md)) |
| `Authentication__AllowInsecureCookies` | `"true"` | Connexion en HTTP par un nom autre que `localhost` : le cas pour lequel l'adaptation `72ee8fa` a été écrite. Compose ne la définissait pas, la boutique y étant ouverte par `localhost` |
| Route | `shop.eshop.lab` vers `webapp:8080` | — |

## 3. Le secret

Comme pour `PaymentProcessor` ([guide 12](12-payment-processor.md), section 3), avec le nom `webapp-secrets`, rangé dans `kubernetes/webapp/sealedsecret-webapp.yaml`.

## 4. Les manifestes

```text
kubernetes/webapp/
├── deployment-webapp.yaml
├── httproute-webapp.yaml
├── sealedsecret-webapp.yaml
└── service-webapp.yaml
```

### La route

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: webapp
  namespace: eshop
spec:
  parentRefs:
    - name: eshop
  hostnames:
    - shop.eshop.lab
  rules:
    - backendRefs:
        - name: webapp
          port: 8080
```

### Le `Deployment` : la partie propre à WebApp

Le reste suit le modèle des autres services : `imagePullSecrets`, probes `/alive` et `/health`, ressources.

```yaml
spec:
  # Une seule copie : les clés de protection des données (cookies) sont propres à chaque pod
  replicas: 1
  ...
          env:
            # Adresses publiques, suivies par le navigateur
            - name: IdentityUrl
              value: http://identity.eshop.lab
            - name: CallBackUrl
              value: http://shop.eshop.lab
            # Appels internes, par les Service du cluster
            - name: services__catalog-api__http__0
              value: http://catalog-api:8080
            - name: services__basket-api__http__0
              value: http://basket-api:8080
            - name: services__ordering-api__http__0
              value: http://ordering-api:8080
            # Connexion en HTTP par un nom autre que localhost (adaptation 72ee8fa)
            - name: Authentication__AllowInsecureCookies
              value: "true"
            # Routes /health et /alive, hors environnement Development (adaptation ae2f77b)
            - name: HealthChecks__Expose
              value: "true"
```

## 5. Appliquer

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

for f in kubernetes/webapp/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status deployment/webapp --timeout=300s
kubectl -n eshop get pods -l app=webapp
kubectl -n eshop get httproute
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
SH
```

Puis, depuis PowerShell :

```powershell
curl.exe -s -m 10 -o NUL -w "%{http_code}`n" http://shop.eshop.lab/
```

Résultats vérifiés le 21 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Pod | `1/1 Running`, prêt en 7 s |
| Routes | `identity-api` sur `identity.eshop.lab`, `webapp` sur `shop.eshop.lab` |
| RabbitMQ | Une septième file, `Ordering.webapp`, avec 1 consommateur : le nom d'abonnement de `WebApp` |
| Page d'accueil depuis Windows | `200` |

## 6. Le parcours dans le navigateur

Dans Edge, sous Windows :

1. ouvrir `http://shop.eshop.lab` : le catalogue s'affiche, « 101 products », avec ses images. La mention « Non sécurisé » est normale en HTTP ;
2. cliquer sur l'icône de personne, en haut à droite : le navigateur part vers `identity.eshop.lab` ;
3. se connecter avec `alice` ;
4. revenir sur la boutique, connecté ;
5. ajouter un article au panier, puis passer commande ;
6. dans « Mes commandes », attendre l'état `Paid`.

### Les preuves côté serveur

Le journal de `WebApp` montre l'ajout au panier :

```text
Start processing HTTP request POST http://basket-api/BasketApi.Basket/UpdateBasket
Received HTTP response headers after 33.6267ms - 200
```

`UpdateBasket` est réservé aux utilisateurs connectés : `Basket.API` a accepté le jeton d'`alice`, émis par `http://identity.eshop.lab` et vérifié à cette adresse.

```bash
kubectl -n eshop logs deployment/basket-api | grep -E 'Basket item persisted|OrderStartedIntegrationEventHandler' | tail -3
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d orderingdb -At <<'SQL'
select "Id", "OrderStatus" from ordering.orders order by "Id";
SQL
```

Résultats vérifiés le 21 octobre 2026 :

```text
info: eShop.Basket.API.IntegrationEvents.EventHandling.OrderStartedIntegrationEventHandler[0]
      Basket item persisted successfully.
info: eShop.Basket.API.IntegrationEvents.EventHandling.OrderStartedIntegrationEventHandler[0]
1|Paid
2|Paid
```

Une troisième commande, passée avec le test de `WebhookClient`, a suivi le même chemin ([guide 16](16-webhook-client.md)).

| Maillon | Preuve |
|---|---|
| Navigateur → point d'entrée → `WebApp` → `Catalog.API` | La boutique et ses 101 articles |
| Connexion par `identity.eshop.lab` | `UpdateBasket` accepté |
| Même émetteur pour le navigateur et les pods | Jeton accepté par `Basket.API`, puis par `Ordering.API` à la commande |
| Redis | `Basket item persisted successfully` |
| Création de la commande | `OrderStartedIntegrationEventHandler` : `Basket.API` vide le panier |
| `OrderProcessor`, `PaymentProcessor`, RabbitMQ | Commandes à l'état `Paid` |

### Deux erreurs de vérification

- Une première recherche de `persisted` dans le journal de `Basket.API` a remonté l'avertissement des clés de protection des données (`may not be persisted`), et non un panier : le filtre est désormais `Basket item persisted`.
- La recherche de `UserLoginSuccess` dans le journal d'`Identity.API` n'a rien donné, alors que la connexion avait réussi : Duende écrit ses événements sous un autre libellé, non vérifié. Les paniers et les commandes suffisent à prouver la connexion.

## 7. Le journal

```bash
kubectl -n eshop logs deployment/webapp --since=15m | grep -E '^(fail|crit|warn):' -A3
```

Aucune erreur. Trois avertissements :

| Avertissement | Explication |
|---|---|
| Clés de protection des données (deux lignes) | Propres au pod : d'où une seule copie |
| `Failed to determine the https port for redirect` | `WebApp` voudrait rediriger vers HTTPS, ne connaît aucun port HTTPS, et laisse passer la requête en HTTP |

## 8. Tableau de validation

| Contrôle | Résultat au 21 octobre 2026 |
|---|---|
| Pod | `1/1 Running` |
| Route `shop.eshop.lab` | Acceptée |
| File RabbitMQ de `WebApp` | `Ordering.webapp`, 1 consommateur |
| Boutique depuis le navigateur | Oui, 101 articles |
| Connexion d'`alice` | Oui |
| Panier dans Redis | Oui |
| Commandes menées à `Paid` | Oui, trois |

## 9. Étape suivante

Déployer `WebhookClient`, l'autre site ouvert depuis un navigateur : [16 — WebhookClient sur le cluster](16-webhook-client.md).

**Bilan :** la boutique fonctionne de bout en bout sur le cluster, depuis le navigateur de Windows : catalogue, connexion, panier, commande et paiement. Le point d'entrée, les noms communs et l'émetteur partagé tiennent ensemble.
