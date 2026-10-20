# 09 — Basket.API sur le cluster

## 1. Objectif

`Basket.API` gère les paniers des utilisateurs. Il les range dans Redis, vérifie les jetons émis par `Identity.API`, reçoit des événements par RabbitMQ, et expose son API en gRPC, un protocole qui repose sur HTTP/2.

Ce guide le déploie sur le modèle de `Catalog.API` ([guide 08](08-catalog-api.md)). Les objectifs sont de :

- reproduire les deux points d'écoute de Compose : HTTP/2 pour gRPC, HTTP/1.1 pour les probes ;
- transmettre les chaînes de connexion vers Redis et RabbitMQ, chiffrées dans le dépôt ;
- vérifier un véritable appel gRPC par le `Service` ;
- vérifier que le mot de passe Redis de la chaîne est accepté par Redis, ce que Compose n'avait pu faire qu'avec un utilisateur connecté.

**État au 20 octobre 2026 :** `Basket.API` tourne sur `kube-worker`. Il est abonné à RabbitMQ, répond à un appel gRPC par son `Service`, et le mot de passe Redis de sa chaîne est accepté par Redis. Son journal ne contient aucune erreur.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Type d'objet | `Deployment`, image `ghcr.io/josuekabangu/basket-api:87e28f8` | Aucune donnée locale : les paniers sont dans Redis |
| Points d'écoute | `8080` en HTTP/2 seul, pour gRPC ; `8081` en HTTP/1.1, pour les routes de santé | Comme avec Compose ([guide 02-docker/15](../02-docker/15-controles-de-sante.md)) : un port HTTP/2 seul refuse les requêtes HTTP/1.1, celles des probes de Kubernetes comprises |
| `Service` | Le port `8080` seul, avec `appProtocol: kubernetes.io/h2c` | Les autres services n'appellent que gRPC. Les probes visent `8081` directement sur le pod, sans passer par le `Service` |
| Chaînes de connexion | `SealedSecret` `basket-api-secrets` : `ConnectionStrings__redis` et `ConnectionStrings__eventbus` | Elles contiennent les mots de passe de Redis et de RabbitMQ |
| Adresse d'`Identity.API` | `Identity__Url: http://identity-api:5223`, dans `env` | Ce n'est pas un secret. C'est l'émetteur annoncé par `Identity.API` ([guide 07](07-identity-api.md)) : les jetons qu'il signe seront acceptés |

`appProtocol: kubernetes.io/h2c` déclare que le port parle HTTP/2 sans chiffrement (`h2c`). Kubernetes ne s'en sert pas lui-même : c'est une indication pour un futur point d'entrée, qui devra joindre le service dans ce protocole.

## 3. Le secret

Les trois valeurs nécessaires sont lues dans les secrets `redis-credentials` et `rabbitmq-credentials`, comme pour `Catalog.API` :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

mkdir -p kubernetes/basket-api
REDIS_PASS=$(kubectl -n eshop get secret redis-credentials -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)
RMQ_USER=$(kubectl -n eshop get secret rabbitmq-credentials -o jsonpath='{.data.RABBITMQ_DEFAULT_USER}' | base64 -d)
RMQ_PASS=$(kubectl -n eshop get secret rabbitmq-credentials -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d)
printf 'ConnectionStrings__redis=redis:6379,password=%s\nConnectionStrings__eventbus=amqp://%s:%s@rabbitmq:5672/\n' \
    "$REDIS_PASS" "$RMQ_USER" "$RMQ_PASS" \
  | kubectl -n eshop create secret generic basket-api-secrets \
      --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/basket-api/sealedsecret-basket-api.yaml
unset REDIS_PASS RMQ_USER RMQ_PASS
grep -E '^    [A-Za-z_]+:' kubernetes/basket-api/sealedsecret-basket-api.yaml | cut -c1-40
grep -c -E 'password=|amqp' kubernetes/basket-api/sealedsecret-basket-api.yaml
```

Résultat vérifié le 20 octobre 2026 : deux clés chiffrées, et `0` valeur en clair.

La ligne `unset` compte : sans elle, les trois mots de passe restent dans les variables du terminal jusqu'à sa fermeture. Lors du déroulement, elle n'apparaissait pas dans la sortie collée : elle est alors à lancer à part.

## 4. Les manifestes

```text
kubernetes/basket-api/
├── deployment-basket-api.yaml
├── sealedsecret-basket-api.yaml
└── service-basket-api.yaml
```

### Le `Service`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: basket-api
  namespace: eshop
  labels:
    app: basket-api
spec:
  selector:
    app: basket-api
  ports:
    - name: grpc
      port: 8080
      targetPort: grpc
      # HTTP/2 sans chiffrement : indication pour un futur point d'entrée
      appProtocol: kubernetes.io/h2c
```

`targetPort: grpc` désigne le port du conteneur par son nom.

### Le `Deployment`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: basket-api
  namespace: eshop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: basket-api
  template:
    metadata:
      labels:
        app: basket-api
    spec:
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: basket-api
          image: ghcr.io/josuekabangu/basket-api:87e28f8
          envFrom:
            - secretRef:
                name: basket-api-secrets
          env:
            - name: Identity__Url
              value: http://identity-api:5223
            # Routes /health et /alive, hors environnement Development (adaptation ae2f77b)
            - name: HealthChecks__Expose
              value: "true"
            # gRPC en HTTP/2 seul sur 8080 ; second port, en HTTP/1.1, réservé aux probes
            - name: Kestrel__Endpoints__grpc__Url
              value: http://+:8080
            - name: Kestrel__Endpoints__grpc__Protocols
              value: Http2
            - name: Kestrel__Endpoints__health__Url
              value: http://+:8081
            - name: Kestrel__Endpoints__health__Protocols
              value: Http1
          ports:
            - name: grpc
              containerPort: 8080
            - name: health
              containerPort: 8081
          startupProbe:
            httpGet:
              path: /alive
              port: health
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /health
              port: health
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            httpGet:
              path: /alive
              port: health
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

| Élément | Rôle |
|---|---|
| `Kestrel__Endpoints__grpc__...` et `...__health__...` | Deux points d'écoute nommés, `grpc` et `health`, avec leur adresse et leur protocole. Ils remplacent le point d'écoute par défaut de l'image |
| `port: health` dans les probes | Les probes visent `8081`, en HTTP/1.1 |

## 5. Appliquer

```bash
for f in kubernetes/basket-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status deployment/basket-api --timeout=300s
kubectl -n eshop get pods -l app=basket-api -o wide
```

Résultat vérifié le 20 octobre 2026 :

```text
NAME                          READY   STATUS    RESTARTS   AGE   IP              NODE
basket-api-5dd65596b6-l2xgz   1/1     Running   0          7s    10.244.73.142   kube-worker
```

Le pod est prêt en 7 secondes : les probes passent par le port `8081`.

## 6. Vérifier

### L'abonnement à RabbitMQ

```bash
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
SH
```

Résultat vérifié : `Catalog 1` et `Basket 1`. `Basket.API` a créé sa file et s'y est abonné.

### Le mot de passe Redis de la chaîne

`Basket.API` n'ouvre sa connexion à Redis qu'à la première lecture d'un panier, et un appel anonyme ne la déclenche pas ([guide 02-docker/08](../02-docker/08-compose-basket.md), section 5). Avec Compose, l'accès à Redis n'avait pu être prouvé qu'avec un utilisateur connecté.

Sur le cluster, un pod de test reçoit **le secret de `Basket.API`**, et essaie le mot de passe de sa chaîne :

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: baskettest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: baskettest
      image: redis:7.4.11
      command: ["sleep", "300"]
      envFrom: [ { secretRef: { name: basket-api-secrets } } ]
Y
kubectl -n eshop wait --for=condition=Ready pod/baskettest --timeout=120s
kubectl -n eshop exec -i baskettest -- sh <<'SH'
echo "redis avec le mot de passe de la chaîne : $(REDISCLI_AUTH="${ConnectionStrings__redis#*password=}" redis-cli -h redis ping 2>&1)"
SH
kubectl -n eshop delete pod baskettest
```

`${ConnectionStrings__redis#*password=}` retire de la chaîne tout ce qui précède `password=`, sans rien afficher.

Résultat vérifié le 20 octobre 2026 : `PONG`. Le mot de passe que reçoit `Basket.API` est accepté par Redis, à travers le `Service` `redis`.

### Un appel gRPC, par le `Service`

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: grpctest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: grpctest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
Y
kubectl -n eshop wait --for=condition=Ready pod/grpctest --timeout=120s
kubectl -n eshop exec -i grpctest -- sh <<'SH'
b=http://basket-api:8080
echo "HTTP/1.1 : $(curl -s -m 10 -o /dev/null -w '%{http_code}' $b/)"
echo "HTTP/2 : $(curl -s -m 10 -o /dev/null -w '%{http_code}' --http2-prior-knowledge $b/)"
printf '\0\0\0\0\0' | curl -s -m 10 --http2-prior-knowledge \
  -H 'content-type: application/grpc' -H 'te: trailers' \
  --data-binary @- -D - -o /dev/null $b/BasketApi.Basket/GetBasket | grep -i -E '^(HTTP|grpc-status)'
SH
kubectl -n eshop delete pod grpctest
```

L'appel gRPC est construit à la main, comme avec Compose : un message vide (`\0\0\0\0\0`) envoyé à la méthode `GetBasket` du service `BasketApi.Basket`.

Résultat vérifié le 20 octobre 2026 :

| Requête | Résultat | Signification |
|---|---|---|
| HTTP/1.1 | `400` | Le port `8080` refuse HTTP/1.1 |
| HTTP/2 | `404` | Il répond en HTTP/2, sans page à la racine |
| Appel gRPC `GetBasket` | `HTTP/2 200`, `grpc-status: 0` | L'API a traité l'appel avec succès |

L'appel est anonyme : le service renvoie un panier vide sans interroger Redis.

### Le journal

```bash
kubectl -n eshop logs deployment/basket-api | grep -E '^(fail|crit):|^Error:' | sort | uniq -c
kubectl -n eshop logs deployment/basket-api | grep -A1 -E '^warn:'
```

Aucune erreur : pas même `libgssapi`, puisque `Basket.API` n'utilise pas le pilote PostgreSQL. Trois avertissements :

| Avertissement | Explication |
|---|---|
| `Kestrel` : `Overriding address(es) 'http://*:8080'` | Les deux points d'écoute nommés remplacent l'adresse par défaut de l'image : c'est voulu ([guide 02-docker/15](../02-docker/15-controles-de-sante.md)) |
| `FileSystemXmlRepository` et `XmlKeyManager` | Les clés de protection des données vivent dans le conteneur, comme pour `Identity.API`. Mais `Basket.API` n'émet aucun cookie : ses appelants s'authentifient par jeton. Ces clés n'imposent ici aucune contrainte sur le nombre de copies |

## 7. Ce qui reste à vérifier

| Point | Quand |
|---|---|
| Lecture et écriture d'un panier dans Redis par le service lui-même | Avec un utilisateur connecté, une fois `WebApp` en place |
| Acceptation des jetons d'`Identity.API` | Même moment : les jetons viendront de la connexion d'un utilisateur |

## 8. Tableau de validation

| Contrôle | Résultat au 20 octobre 2026 |
|---|---|
| Deux chaînes de connexion chiffrées, sans valeur en clair | Oui |
| Pod | `1/1 Running`, probes sur le port `8081` |
| File `Basket` dans RabbitMQ | 1 consommateur |
| Mot de passe Redis de la chaîne | Accepté, `PONG` |
| HTTP/1.1 sur le port gRPC | Refusé, `400` |
| Appel gRPC par le `Service` | `HTTP/2 200`, `grpc-status: 0` |
| Erreurs du journal | Aucune |

## 9. Étape suivante

Déployer `Ordering.API`, qui partage ses tables avec `OrderProcessor` ([guide 02-docker/09](../02-docker/09-compose-ordering.md)).

## 10. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes de Basket.API
for f in kubernetes/basket-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# État
kubectl -n eshop get pods -l app=basket-api -o wide

# Journal, niveaux de gravité seulement
kubectl -n eshop logs deployment/basket-api | grep -E '^(fail|crit|warn):'
```

**Bilan :** `Basket.API` tourne sur le cluster avec ses deux points d'écoute, HTTP/2 pour gRPC et HTTP/1.1 pour les probes. Un appel gRPC réussit par le `Service`, le mot de passe Redis de sa chaîne est accepté par Redis, et il est abonné à RabbitMQ. L'accès réel aux paniers et la vérification des jetons attendent un utilisateur connecté.
