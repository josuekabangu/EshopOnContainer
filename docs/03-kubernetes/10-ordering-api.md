# 10 — Ordering.API sur le cluster

## 1. Objectif

`Ordering.API` enregistre les commandes des utilisateurs. Il range ses tables dans la base `orderingdb`, qu'il partagera avec `OrderProcessor`, échange des événements par RabbitMQ, et réserve son API aux utilisateurs connectés.

Ce guide le déploie sur le modèle de `Catalog.API` ([guide 08](08-catalog-api.md)), avec l'adresse d'`Identity.API` en plus, comme `Basket.API` ([guide 09](09-basket-api.md)). Les objectifs sont de :

- vérifier qu'il crée ses tables et s'abonne à RabbitMQ ;
- vérifier son **contrôle d'accès** : un appel sans jeton, ou avec un jeton qu'`Identity.API` n'a pas signé, doit être refusé.

**État au 20 octobre 2026 :** `Ordering.API` tourne sur `kube-worker`. Ses tables sont créées dans le schéma `ordering`, il est abonné à RabbitMQ, et il refuse les appels sans jeton valide. C'est le premier contrôle d'accès vérifié sur le cluster.

## 2. Les choix

| Question | Choix |
|---|---|
| Type d'objet | `Deployment`, image `ghcr.io/josuekabangu/ordering-api:87e28f8`, avec `ghcr-pull` |
| Port | `8080`, par défaut, dans le conteneur et dans le `Service` |
| Chaînes de connexion | `SealedSecret` `ordering-api-secrets` : `ConnectionStrings__orderingdb` et `ConnectionStrings__eventbus` |
| Adresse d'`Identity.API` | `Identity__Url: http://identity-api:5223`, dans `env` ; `http://identity.eshop.lab` depuis le 21 octobre 2026 ([guide 14](14-point-entree.md), section 6) |
| Probes | `/alive` pour le démarrage et la vivacité, `/health` pour la disponibilité |

Le `Deployment` ne diffère de celui de `Catalog.API` que par son nom, son image, son secret et la variable `Identity__Url`.

`Ordering.API` applique ses migrations avant d'accepter des requêtes. Sa probe de disponibilité ne réussit donc qu'une fois ses tables créées : `OrderProcessor` pourra s'appuyer sur cet état, comme il attendait l'état `healthy` du conteneur avec Compose ([guide 02-docker/15](../02-docker/15-controles-de-sante.md), section 7).

## 3. Le secret

Les trois valeurs nécessaires sont lues dans les secrets du cluster, sans saisie, comme pour `Catalog.API` :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

mkdir -p kubernetes/ordering-api
PG_PASS=$(kubectl -n eshop get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
RMQ_USER=$(kubectl -n eshop get secret rabbitmq-credentials -o jsonpath='{.data.RABBITMQ_DEFAULT_USER}' | base64 -d)
RMQ_PASS=$(kubectl -n eshop get secret rabbitmq-credentials -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d)
printf 'ConnectionStrings__orderingdb=Host=postgres;Port=5432;Database=orderingdb;Username=postgres;Password=%s\nConnectionStrings__eventbus=amqp://%s:%s@rabbitmq:5672/\n' \
    "$PG_PASS" "$RMQ_USER" "$RMQ_PASS" \
  | kubectl -n eshop create secret generic ordering-api-secrets \
      --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/ordering-api/sealedsecret-ordering-api.yaml
unset PG_PASS RMQ_USER RMQ_PASS
grep -E '^    [A-Za-z_]+:' kubernetes/ordering-api/sealedsecret-ordering-api.yaml | cut -c1-40
grep -c -E 'Password|amqp' kubernetes/ordering-api/sealedsecret-ordering-api.yaml
```

Résultat vérifié le 20 octobre 2026 : deux clés chiffrées, et `0` valeur en clair.

## 4. Les manifestes

```text
kubernetes/ordering-api/
├── deployment-ordering-api.yaml
├── sealedsecret-ordering-api.yaml
└── service-ordering-api.yaml
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ordering-api
  namespace: eshop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ordering-api
  template:
    metadata:
      labels:
        app: ordering-api
    spec:
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: ordering-api
          image: ghcr.io/josuekabangu/ordering-api:87e28f8
          envFrom:
            - secretRef:
                name: ordering-api-secrets
          env:
            - name: Identity__Url
              value: http://identity-api:5223
            # Routes /health et /alive, hors environnement Development (adaptation ae2f77b)
            - name: HealthChecks__Expose
              value: "true"
          ports:
            - name: http
              containerPort: 8080
          startupProbe:
            httpGet:
              path: /alive
              port: http
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            httpGet:
              path: /alive
              port: http
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
```

Le `Service` `ordering-api` expose le port 8080, sous le nom `http`.

## 5. Appliquer

```bash
for f in kubernetes/ordering-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status deployment/ordering-api --timeout=300s
kubectl -n eshop get pods -l app=ordering-api -o wide
```

Résultat vérifié le 20 octobre 2026 :

```text
NAME                           READY   STATUS    RESTARTS   AGE   IP              NODE
ordering-api-bfb4689f5-h94k2   1/1     Running   0          11s   10.244.73.145   kube-worker
```

L'image n'avait jamais été téléchargée par ce cluster. Son téléchargement a confirmé que le jeton du secret `ghcr-pull` était toujours valide, après la révocation, le même jour, d'un autre jeton GitHub exposé par erreur : le jeton d'écriture.

## 6. Vérifier

### Les tables

`Ordering.API` range ses tables dans le schéma `ordering`, un espace de noms à l'intérieur de la base :

```bash
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d orderingdb -At <<'SQL'
select schemaname || '.' || tablename from pg_tables where schemaname not in ('pg_catalog','information_schema') order by 1;
select "Name" from ordering.cardtypes order by "Id";
SQL
```

Résultat vérifié le 20 octobre 2026 :

```text
ordering.IntegrationEventLog
ordering.buyers
ordering.cardtypes
ordering.orderItems
ordering.orders
ordering.paymentmethods
ordering.requests
public.__EFMigrationsHistory
Amex
Visa
MasterCard
```

Sept tables dans le schéma `ordering`, et les trois types de carte de paiement, comme avec Compose ([guide 02-docker/09](../02-docker/09-compose-ordering.md), section 4).

Une première version de la seconde requête, `select name from ordering.cardtypes order by id`, a échoué sur `column "name" does not exist`. Les colonnes créées par le service portent des majuscules (`Name`, `Id`), et PostgreSQL ramène en minuscules tout nom qui n'est pas entre guillemets doubles.

### L'abonnement à RabbitMQ

```bash
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
SH
```

Résultat vérifié : `Ordering 1`, à côté de `Catalog 1` et `Basket 1`.

### Le contrôle d'accès, par le `Service`

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: ordtest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: ordtest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
Y
kubectl -n eshop wait --for=condition=Ready pod/ordtest --timeout=120s
kubectl -n eshop exec -i ordtest -- sh <<'SH'
b=http://ordering-api:8080
echo "health : $(curl -s -m 10 -w ' %{http_code}' $b/health)"
echo "commandes sans jeton : $(curl -s -m 10 -o /dev/null -w '%{http_code}' "$b/api/orders?api-version=1.0")"
echo "commandes avec un faux jeton : $(curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer faux' "$b/api/orders?api-version=1.0")"
SH
kubectl -n eshop delete pod ordtest
```

Résultat vérifié le 20 octobre 2026 :

| Requête | Résultat | Signification |
|---|---|---|
| `/health` | `Healthy 200` | Le service, sa base et RabbitMQ répondent |
| Liste des commandes, sans jeton | `401` | L'API exige une authentification |
| Liste des commandes, avec un jeton inventé | `401` | Un jeton qu'`Identity.API` n'a pas signé est refusé |

L'acceptation d'un **vrai** jeton attend la connexion d'un utilisateur, avec `WebApp`.

### Le journal

```bash
kubectl -n eshop logs deployment/ordering-api | grep -E '^(fail|crit):|^Error:' | sort | uniq -c
kubectl -n eshop logs deployment/ordering-api | grep -A1 -E '^warn:'
```

Résultat vérifié :

| Message | Explication |
|---|---|
| `Error: libgssapi_krb5.so.2` et `fail: ...Connection[20004]`, une fois chacun | Les deux messages attendus d'un service qui crée sa base PostgreSQL ([guide 07](07-identity-api.md), section 6) |
| `warn: LuckyPennySoftware.MediatR.License` | Pas de licence pour la bibliothèque MediatR : autorisé en développement et en test. Déjà vu avec Compose |
| `warn:` sur les clés de protection des données | Sans conséquence : `Ordering.API` n'émet pas de cookie, comme `Basket.API` |

## 7. Tableau de validation

| Contrôle | Résultat au 20 octobre 2026 |
|---|---|
| Deux chaînes de connexion chiffrées, sans valeur en clair | Oui |
| Image téléchargée avec `ghcr-pull` | Oui |
| Pod | `1/1 Running`, aucun redémarrage |
| Tables du schéma `ordering` | 7, et 3 types de carte |
| File `Ordering` dans RabbitMQ | 1 consommateur |
| `/health` par le `Service` | `Healthy` 200 |
| Appel sans jeton, ou avec un jeton inventé | Refusé, `401` |
| Journal | Les deux messages attendus, et la licence MediatR |

## 8. Étape suivante

Déployer `OrderProcessor`, la tâche de fond qui partage les tables d'`Ordering.API` ([guide 02-docker/10](../02-docker/10-compose-order-processor.md)) : [11 — OrderProcessor sur le cluster](11-order-processor.md).

## 9. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes d'Ordering.API
for f in kubernetes/ordering-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# État
kubectl -n eshop get pods -l app=ordering-api -o wide

# Commandes enregistrées
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d orderingdb -At <<'SQL'
select count(*) from ordering.orders;
SQL

# Journal, niveaux de gravité seulement
kubectl -n eshop logs deployment/ordering-api | grep -E '^(fail|crit|warn):'
```

**Bilan :** `Ordering.API` tourne sur le cluster, avec ses tables et son abonnement à RabbitMQ. Il refuse tout appel sans jeton valide : c'est le premier contrôle d'accès vérifié sur le cluster. L'acceptation d'un vrai jeton attend la connexion d'un utilisateur.
