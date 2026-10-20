# 11 — OrderProcessor sur le cluster

## 1. Objectif

`OrderProcessor` est une tâche de fond. Toutes les 30 secondes, il cherche dans les tables d'`Ordering.API` les commandes dont le délai de grâce est écoulé, et publie pour chacune un événement sur RabbitMQ. Personne ne l'appelle : il n'expose aucune API métier.

Ce guide le déploie sur le cluster. Les objectifs sont de :

- décider ce qu'il faut à un service que personne n'appelle : probes, `Service`, nombre de copies ;
- prouver que la tâche de fond tourne, sans API à interroger.

**État au 20 octobre 2026 :** `OrderProcessor` tourne sur `kube-worker`, abonné à RabbitMQ. Sa recherche dans `ordering.orders` a été observée dans PostgreSQL. Son journal ne contient que le message attendu sur la bibliothèque Kerberos.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Probes | HTTP, sur `/alive` et `/health`, port 8080 | Le service n'a pas d'API métier, mais son `Program.cs` crée une `WebApplication` et appelle `MapDefaultEndpoints()` : les routes de santé existent dès que `HealthChecks__Expose` vaut `true` ([guide 02-docker/10](../02-docker/10-compose-order-processor.md), point ouvert 1) |
| `Service` | **Aucun** | Personne n'appelle le service. Les probes, envoyées par `kubelet`, joignent le pod directement |
| Nombre de copies | **1, obligatoirement** | La recherche des commandes n'est protégée par aucun verrou. Deux copies trouveraient les mêmes commandes et publieraient chaque événement deux fois |
| Chaînes de connexion | `SealedSecret` `order-processor-secrets` : `orderingdb` et `eventbus` | Les mêmes valeurs que pour `Ordering.API`, mais un secret propre au service : chacun peut évoluer sans toucher à l'autre |
| Ordre de démarrage | Aucune précaution | Kubernetes n'a pas d'équivalent de `depends_on`. Le service tolère l'absence des tables : il écrit une erreur toutes les 30 secondes, puis reprend seul dès qu'elles existent ([guide 02-docker/10](../02-docker/10-compose-order-processor.md), section 4) |

`Program.cs` d'`OrderProcessor` :

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.AddBasicServiceDefaults();
builder.AddApplicationServices();

var app = builder.Build();

app.MapDefaultEndpoints();

await app.RunAsync();
```

## 3. Le secret

Comme pour `Ordering.API` ([guide 10](10-ordering-api.md), section 3), sous le nom `order-processor-secrets`, rangé dans `kubernetes/order-processor/sealedsecret-order-processor.yaml`.

Résultat vérifié le 20 octobre 2026 : deux clés chiffrées, `ConnectionStrings__orderingdb` et `ConnectionStrings__eventbus`, et `0` valeur en clair.

## 4. Le manifeste

Un seul fichier, en plus du secret : pas de `Service`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-processor
  namespace: eshop
spec:
  # Une seule copie : deux instances traiteraient les mêmes commandes en double
  replicas: 1
  selector:
    matchLabels:
      app: order-processor
  template:
    metadata:
      labels:
        app: order-processor
    spec:
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: order-processor
          image: ghcr.io/josuekabangu/order-processor:87e28f8
          envFrom:
            - secretRef:
                name: order-processor-secrets
          env:
            # Routes /health et /alive, hors environnement Development (adaptation ae2f77b)
            - name: HealthChecks__Expose
              value: "true"
          ports:
            # Sert seulement aux probes : aucun Service ne l'expose
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

Sans `Service`, la `readinessProbe` ne retire le pod d'aucun équilibrage. Elle garde son utilité : l'état `Ready` du pod dit si le service atteint sa base et RabbitMQ, et `kubectl rollout status` l'attend.

## 5. Appliquer

```bash
for f in kubernetes/order-processor/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status deployment/order-processor --timeout=300s
kubectl -n eshop get pods -l app=order-processor -o wide
```

Résultat vérifié le 20 octobre 2026 :

```text
NAME                               READY   STATUS    RESTARTS   AGE   IP              NODE
order-processor-76b5c69d7d-zwklk   1/1     Running   0          7s    10.244.73.147   kube-worker
```

## 6. Vérifier

### L'abonnement à RabbitMQ

```bash
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
SH
```

Résultat vérifié : `OrderProcessor 1`, à côté d'`Ordering 1`, `Catalog 1` et `Basket 1`.

### Le travail de la tâche de fond

Un service sans API ne se teste pas par une requête. Avec Compose, la preuve se lisait dans la vue `pg_stat_activity` de PostgreSQL, qui donne la dernière requête de chaque connexion ([guide 02-docker/10](../02-docker/10-compose-order-processor.md), section 3).

Un premier relevé, sur le cluster, n'a montré que `SELECT 1` :

```bash
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -At <<'SQL'
select client_addr, state, left(query, 45) from pg_stat_activity where datname = 'orderingdb';
SQL
```

```text
10.244.73.145|idle|SELECT 1
10.244.73.147|idle|SELECT 1
```

`SELECT 1` est la requête du contrôle de santé de PostgreSQL, interrogé par `/health`. La `readinessProbe` appelle `/health` toutes les 10 secondes, la tâche de fond ne cherche que toutes les 30 secondes : la dernière requête de la connexion est presque toujours celle du contrôle. Avec Compose, le 14 octobre, le conteneur n'avait pas encore de contrôle de santé, et la recherche apparaissait seule.

Le journal ne peut pas prendre le relais : la tâche n'y écrit qu'au niveau `Debug`, désactivé par défaut. La vue a donc été relevée une fois par seconde pendant 40 secondes, pour la seule adresse du pod `order-processor` :

```bash
kubectl -n eshop exec -i postgres-0 -- sh <<'SH'
for i in $(seq 1 40); do
  psql -U postgres -At -c "select left(query, 45) from pg_stat_activity where datname = 'orderingdb' and client_addr = '10.244.73.147'"
  sleep 1
done | sort | uniq -c
SH
```

Résultat vérifié le 20 octobre 2026 :

```text
      4 FROM ordering.orders
     36 SELECT 1
      4 SELECT "Id"
      4 WHERE CURREN
```

La requête de la tâche de fond s'écrit sur plusieurs lignes : ses 45 premiers caractères en couvrent trois, que `uniq -c` compte séparément. Les trois morceaux, vus 4 fois chacun, forment une seule requête vue 4 fois :

```sql
SELECT "Id"
FROM ordering.orders
WHERE CURRENT_TIMESTAMP - "OrderDate" >= @GracePeriodTime AND "OrderStatus" = 'Submitted'
```

C'est la requête de `GracePeriodOrdersRepository.cs` : les commandes encore à l'état `Submitted` dont le délai de grâce est écoulé. La tâche de fond tourne et lit les tables d'`Ordering.API`.

### Le journal

```bash
kubectl -n eshop logs deployment/order-processor | grep -E '^(fail|crit):|^Error:' | sort | uniq -c
kubectl -n eshop logs deployment/order-processor | grep -A1 -E '^warn:'
```

Résultat vérifié : `Error: libgssapi_krb5.so.2`, une fois, et aucun avertissement. Pas de `Connection[20004]`, puisque le service ne crée aucune base, et pas d'erreur `42P01`, puisque les tables existaient déjà.

## 7. Ce qui reste à vérifier

La publication d'un événement `GracePeriodConfirmed` demande une commande réelle, donc un utilisateur connecté par `WebApp`. Avec Compose, elle avait été observée 83 secondes après la création de la commande ([guide 02-docker/10](../02-docker/10-compose-order-processor.md), point ouvert 2).

## 8. Tableau de validation

| Contrôle | Résultat au 20 octobre 2026 |
|---|---|
| Deux chaînes de connexion chiffrées, sans valeur en clair | Oui |
| Pod | `1/1 Running`, probes HTTP sur le port 8080 |
| `Service` | Aucun, volontairement |
| File `OrderProcessor` dans RabbitMQ | 1 consommateur |
| Recherche dans `ordering.orders` | Observée 4 fois sur 40 relevés d'une seconde |
| Journal | `libgssapi` seulement, aucun avertissement |

## 9. Étape suivante

Déployer `PaymentProcessor`, l'autre tâche de fond, qui simule le paiement des commandes ([guide 02-docker/11](../02-docker/11-compose-payment-processor.md)) : [12 — PaymentProcessor sur le cluster](12-payment-processor.md).

## 10. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes d'OrderProcessor
for f in kubernetes/order-processor/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# État
kubectl -n eshop get pods -l app=order-processor -o wide

# Dernières requêtes des connexions à orderingdb
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -At <<'SQL'
select client_addr, state, left(query, 45) from pg_stat_activity where datname = 'orderingdb';
SQL

# Journal, niveaux de gravité seulement
kubectl -n eshop logs deployment/order-processor | grep -E '^(fail|crit|warn):'
```

**Bilan :** `OrderProcessor` tourne sur le cluster, sans `Service` et en une seule copie. Ses probes HTTP fonctionnent grâce aux routes de santé que crée son code. Sa recherche périodique a été observée dans PostgreSQL, en relevant la vue `pg_stat_activity` plus souvent que la probe ne la recouvre.
