# 08 — Catalog.API sur le cluster

## 1. Objectif

`Catalog.API` sert le catalogue de la boutique : articles, marques, types et images. Il publie aussi un message sur RabbitMQ quand un article change, par exemple son prix. C'est le premier service du cluster à utiliser RabbitMQ.

Ce guide le déploie sur le modèle d'`Identity.API` ([guide 07](07-identity-api.md)). Les objectifs sont de :

- transmettre au service ses deux chaînes de connexion, vers PostgreSQL et vers RabbitMQ, chiffrées dans le dépôt ;
- vérifier qu'il crée sa base, ses 101 articles et l'extension `vector` ;
- vérifier sa connexion à RabbitMQ, la première par le protocole AMQP sur le cluster ;
- vérifier que son API répond par son `Service`.

**État au 20 octobre 2026 :** `Catalog.API` tourne sur `kube-worker`. Sa base contient 101 articles et l'extension `vector` 0.8.7, il est connecté à RabbitMQ et abonné à sa file, et son API répond par le `Service`. Son journal ne contient aucun avertissement.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Type d'objet | `Deployment` | Aucune donnée locale |
| Image | `ghcr.io/josuekabangu/catalog-api:87e28f8`, avec `ghcr-pull` | L'image privée, liée au commit |
| Port | `8080` dans le conteneur et dans le `Service` | Le port par défaut des images .NET, que Compose ne changeait pas pour ce service. Les autres services joignent `Catalog.API` par `http://catalog-api:8080`, comme avec Compose |
| Chaînes de connexion | `SealedSecret` `catalog-api-secrets`, deux clés : `ConnectionStrings__catalogdb` et `ConnectionStrings__eventbus` | Elles contiennent les mots de passe de PostgreSQL et de RabbitMQ |
| Probes | `/alive` pour le démarrage et la vivacité, `/health` pour la disponibilité | Comme `Identity.API` |
| Nombre de copies | 1 | Rien ne l'impose, contrairement à `Identity.API`. On ne change qu'une chose à la fois |

`/health` reste bloqué tant que RabbitMQ est injoignable, comme avec Compose. La probe de disponibilité échoue alors par expiration de son délai, et le pod est retiré du `Service` sans être redémarré : c'est le comportement voulu.

## 3. Le secret

Les trois valeurs nécessaires, le mot de passe de PostgreSQL et les identifiants de RabbitMQ, sont lues dans les secrets du cluster, puis assemblées au format `.env` et chiffrées dans un tuyau. Rien n'est saisi, rien ne s'affiche, et rien n'est écrit en clair sur le disque :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

mkdir -p kubernetes/catalog-api
PG_PASS=$(kubectl -n eshop get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
RMQ_USER=$(kubectl -n eshop get secret rabbitmq-credentials -o jsonpath='{.data.RABBITMQ_DEFAULT_USER}' | base64 -d)
RMQ_PASS=$(kubectl -n eshop get secret rabbitmq-credentials -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d)
printf 'ConnectionStrings__catalogdb=Host=postgres;Port=5432;Database=catalogdb;Username=postgres;Password=%s\nConnectionStrings__eventbus=amqp://%s:%s@rabbitmq:5672/\n' \
    "$PG_PASS" "$RMQ_USER" "$RMQ_PASS" \
  | kubectl -n eshop create secret generic catalog-api-secrets \
      --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/catalog-api/sealedsecret-catalog-api.yaml
unset PG_PASS RMQ_USER RMQ_PASS
grep -E '^    [A-Za-z_]+:' kubernetes/catalog-api/sealedsecret-catalog-api.yaml | cut -c1-40
grep -c -E 'Password|amqp' kubernetes/catalog-api/sealedsecret-catalog-api.yaml
```

- `--from-env-file=/dev/stdin` lit des lignes `CLE=valeur` sur l'entrée standard : une clé du secret par ligne. Seul le premier `=` sépare la clé de la valeur, si bien que les `=` de la chaîne PostgreSQL restent dans la valeur.
- Dans l'adresse `amqp://`, les caractères `@`, `:` et `/` ont un sens ([guide 02-docker/07](../02-docker/07-compose-catalog.md), section 3). Les mots de passe générés pour le projet n'en contiennent pas.

Résultat vérifié le 20 octobre 2026 : deux clés chiffrées, `ConnectionStrings__catalogdb` et `ConnectionStrings__eventbus`, et `0` occurrence de `Password` ou d'`amqp` en clair.

Les mots de passe de PostgreSQL et de RabbitMQ figurent désormais aussi dans ce secret. S'ils changent, il doit être recréé par la même commande, puis le service redémarré.

## 4. Les manifestes

```text
kubernetes/catalog-api/
├── deployment-catalog-api.yaml
├── sealedsecret-catalog-api.yaml
└── service-catalog-api.yaml
```

Le `Service` `catalog-api` expose le port 8080, sous le nom `http`.

Le `Deployment` reprend celui d'`Identity.API`, avec trois différences :

| Élément | `Identity.API` | `Catalog.API` |
|---|---|---|
| Image | `identity-api:87e28f8` | `catalog-api:87e28f8` |
| Secret | `identity-api-secrets` | `catalog-api-secrets` |
| Port | `5223`, fixé par `ASPNETCORE_HTTP_PORTS` | `8080`, par défaut : aucune variable `ASPNETCORE_HTTP_PORTS` |

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-api
  namespace: eshop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: catalog-api
  template:
    metadata:
      labels:
        app: catalog-api
    spec:
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: catalog-api
          image: ghcr.io/josuekabangu/catalog-api:87e28f8
          envFrom:
            - secretRef:
                name: catalog-api-secrets
          env:
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

## 5. Appliquer

```bash
for f in kubernetes/catalog-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status deployment/catalog-api --timeout=300s
kubectl -n eshop get pods -l app=catalog-api -o wide
```

Résultat vérifié le 20 octobre 2026 :

```text
NAME                           READY   STATUS    RESTARTS   AGE   IP              NODE
catalog-api-74ccd787fd-cbxr7   1/1     Running   0          10m   10.244.73.139   kube-worker
```

## 6. Vérifier

### La base, ses articles et l'extension `vector`

```bash
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d catalogdb -At <<'SQL'
select count(*) from "Catalog";
select extname, extversion from pg_extension where extname = 'vector';
SQL
```

Résultat vérifié : `101` articles, et `vector|0.8.7`. Le service installe lui-même l'extension à son premier démarrage. Avec Compose et l'ancienne image `ankane/pgvector`, la version était `0.5.1`.

### La connexion à RabbitMQ

```bash
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_connections user peer_host state
rabbitmqctl -q list_queues name consumers
SH
```

Résultat vérifié le 20 octobre 2026 :

```text
user          peer_host       state
eshop_rabbit  10.244.73.139   running
name     consumers
Catalog  1
```

La connexion vient de `10.244.73.139`, l'adresse du pod `catalog-api`. C'est la première connexion AMQP sur le cluster : elle prouve que le port `5672` est joignable par le `Service`, et que l'adresse `amqp://` déchiffrée, utilisateur et mot de passe compris, est acceptée. Le [guide 06](06-rabbitmq.md) avait reporté ce test.

La file `Catalog` porte le nom d'abonnement du service. Son consommateur est `Catalog.API` lui-même, qui reçoit les événements d'autres services, comme la confirmation d'une commande qui fait baisser le stock.

### L'API, par le `Service`

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: cattest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: cattest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
Y
kubectl -n eshop wait --for=condition=Ready pod/cattest --timeout=120s
kubectl -n eshop exec -i cattest -- sh <<'SH'
b=http://catalog-api:8080
echo "health : $(curl -s -m 10 -w ' %{http_code}' $b/health)"
echo "types : $(curl -s -m 10 -o /dev/null -w '%{http_code}' "$b/api/catalog/catalogTypes?api-version=1.0")"
echo "articles : $(curl -s -m 10 "$b/api/catalog/items?api-version=1.0&pageSize=1" | grep -o '"count":[0-9]*')"
echo "image : $(curl -s -m 10 -o /dev/null -w '%{http_code} %{content_type}' "$b/api/catalog/items/1/pic?api-version=1.0")"
SH
kubectl -n eshop delete pod cattest
```

`-m 10` limite chaque requête à 10 secondes : un `/health` bloqué ne bloque pas le test.

Résultat vérifié le 20 octobre 2026 :

```text
health : Healthy 200
types : 200
articles : "count":101
image : 200 image/webp
```

### Le journal

```bash
kubectl -n eshop logs deployment/catalog-api | grep -E '^(fail|crit):|^Error:' | sort | uniq -c
kubectl -n eshop logs deployment/catalog-api | grep -A1 -E '^warn:'
```

Résultat vérifié : `libgssapi_krb5.so.2` et `Connection[20004]`, une fois chacune, les deux messages attendus ([guide 07](07-identity-api.md), section 6). **Aucun avertissement** : `Catalog.API` n'utilise ni cookies, ni Duende IdentityServer, donc ni clés de protection des données, ni licence.

## 7. Les limites

| Limite | Conséquence |
|---|---|
| Le service utilise le compte administrateur de PostgreSQL et celui de RabbitMQ | Comme avec Compose. Un compte limité par service serait plus sûr |
| Trois secrets contiennent le mot de passe de PostgreSQL, deux celui de RabbitMQ | Un changement de mot de passe oblige à recréer chacun d'eux |
| Le catalogue n'est joignable que depuis le cluster | Le navigateur l'atteindra par `WebApp` et le point d'entrée |

## 8. Tableau de validation

| Contrôle | Résultat au 20 octobre 2026 |
|---|---|
| Deux chaînes de connexion chiffrées, sans valeur en clair | Oui |
| Pod | `1/1 Running`, aucun redémarrage |
| Articles dans `catalogdb` | 101 |
| Extension `vector` | 0.8.7 |
| Connexion AMQP à RabbitMQ | `running`, depuis le pod `catalog-api` |
| File `Catalog` | 1 consommateur |
| API par le `Service` : santé, types, articles, image | `Healthy` 200, 200, 101, 200 `image/webp` |
| Journal | Les deux messages attendus, aucun avertissement |

## 9. Étape suivante

Déployer `Basket.API`, qui ajoute Redis, l'authentification par les jetons d'`Identity.API`, et le protocole gRPC en HTTP/2 ([guide 02-docker/08](../02-docker/08-compose-basket.md)) : [09 — Basket.API sur le cluster](09-basket-api.md).

## 10. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes de Catalog.API
for f in kubernetes/catalog-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# État
kubectl -n eshop get pods -l app=catalog-api -o wide

# Connexions et files de RabbitMQ
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_connections user peer_host state
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_queues name consumers

# Journal, niveaux de gravité seulement
kubectl -n eshop logs deployment/catalog-api | grep -E '^(fail|crit|warn):'
```

**Bilan :** `Catalog.API` tourne sur le cluster avec deux chaînes de connexion chiffrées, assemblées à partir des secrets existants sans saisie. Il a créé sa base et son extension, s'est connecté à RabbitMQ par AMQP, et son API répond par le `Service`, sans aucun avertissement.
