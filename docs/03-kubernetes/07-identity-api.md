# 07 — Identity.API sur le cluster

## 1. Objectif

`Identity.API` gère les comptes des utilisateurs et délivre les jetons que présentent les autres services, selon le protocole OpenID Connect. C'est le premier service d'eShop déployé sur le cluster : tous les autres dépendent de lui.

Les objectifs sont de :

- déployer le service depuis l'image privée du registre, avec une chaîne de connexion chiffrée dans le dépôt ;
- vérifier qu'il crée sa base et répond par son `Service` ;
- comprendre où il garde ses clés, et ce que cela implique sur Kubernetes.

**État au 19 octobre 2026 :** `Identity.API` tourne sur `kube-worker`. Il a créé sa base `identitydb` avec ses deux utilisateurs de démonstration, ses routes de santé répondent `Healthy`, et son émetteur est `http://identity-api:5223`, comme avec Compose.

L'accès depuis un navigateur n'est pas encore traité : il dépend du point d'entrée du cluster, à mettre en place avec `WebApp`.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Type d'objet | **`Deployment`** | Le service ne garde aucune donnée locale utile : ses données sont dans PostgreSQL. Ses pods sont interchangeables, contrairement à ceux d'un `StatefulSet` |
| Nombre de copies | **1, obligatoirement** | Voir section 7 |
| Image | `ghcr.io/josuekabangu/identity-api:87e28f8`, avec `imagePullSecrets: ghcr-pull` | L'image privée, liée au commit ([guide 01](01-registre-images.md)). Elle contient les deux adaptations du code, `ae2f77b` et `72ee8fa`, antérieures à `87e28f8` |
| Port | `5223` dans le conteneur et dans le `Service` | Comme avec Compose : l'adresse interne reste `http://identity-api:5223` |
| Chaîne de connexion | `SealedSecret` `identity-api-secrets`, clé `ConnectionStrings__identitydb` | Elle contient le mot de passe de PostgreSQL |
| Probes | `startupProbe` et `livenessProbe` sur `/alive`, `readinessProbe` sur `/health` | `/alive` vérifie que le processus répond ; `/health` vérifie aussi PostgreSQL. Un pod privé de sa base est retiré du `Service`, sans être redémarré |
| Adresses des clients (`WebAppClient`, `WebhooksWebClient`) | **Non définies pour l'instant** | `Identity.API` les lit dans sa configuration au démarrage, et les garde en mémoire (`AddInMemoryClients`). Elles seront ajoutées avec le point d'entrée, au prix d'un redémarrage |

Les routes `/health` et `/alive` n'existent hors de l'environnement `Development` que grâce à l'adaptation `ae2f77b`, activée par `HealthChecks__Expose` ([guide 02-docker/15](../02-docker/15-controles-de-sante.md)).

## 3. Le secret

La chaîne de connexion reprend celle de Compose. Le mot de passe de PostgreSQL n'est pas saisi : il est lu dans le secret `postgres-credentials` du cluster, puis assemblé et chiffré dans un tuyau. Aucune faute de frappe n'est possible, et rien ne s'affiche :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

mkdir -p kubernetes/identity-api
PG_PASS=$(kubectl -n eshop get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
printf 'Host=postgres;Port=5432;Database=identitydb;Username=postgres;Password=%s' "$PG_PASS" \
  | kubectl -n eshop create secret generic identity-api-secrets \
      --from-file=ConnectionStrings__identitydb=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/identity-api/sealedsecret-identity-api.yaml
unset PG_PASS
grep -c 'Password' kubernetes/identity-api/sealedsecret-identity-api.yaml
```

Résultat vérifié le 19 octobre 2026 : `0`, le mot `Password` n'apparaît pas en clair.

Le mot de passe de PostgreSQL figure désormais dans deux secrets. S'il change ([guide 04](04-secrets.md), section 9), ce secret doit être recréé par la même commande, puis le service redémarré.

## 4. Les manifestes

```text
kubernetes/identity-api/
├── deployment-identity-api.yaml
├── sealedsecret-identity-api.yaml
└── service-identity-api.yaml
```

Le `Service` `identity-api` expose le port 5223, sous le nom `http`.

### Le `Deployment`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-api
  namespace: eshop
spec:
  # Une seule copie : les clés de protection des données (cookies) sont propres à chaque pod
  replicas: 1
  selector:
    matchLabels:
      app: identity-api
  template:
    metadata:
      labels:
        app: identity-api
    spec:
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: identity-api
          image: ghcr.io/josuekabangu/identity-api:87e28f8
          envFrom:
            - secretRef:
                name: identity-api-secrets
          env:
            - name: ASPNETCORE_HTTP_PORTS
              value: "5223"
            # Routes /health et /alive, hors environnement Development (adaptation ae2f77b)
            - name: HealthChecks__Expose
              value: "true"
          ports:
            - name: http
              containerPort: 5223
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

| Élément | Rôle |
|---|---|
| `imagePullSecrets` | Le secret présenté au registre privé pour télécharger l'image |
| `envFrom` | Transmet la chaîne de connexion sous le nom `ConnectionStrings__identitydb` ; .NET lit `__` comme le séparateur `:` de sa configuration |
| `"5223"`, `"true"` | Entre guillemets : une variable d'environnement est une chaîne |
| `port: http` | Les probes désignent le port par son nom : un changement de numéro ne les oublierait pas |
| `limits.memory` | 512 Mio, le plafond commun des services dans Compose |

## 5. Appliquer et vérifier

```bash
for f in kubernetes/identity-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status deployment/identity-api --timeout=300s
kubectl -n eshop get pods -o wide
```

Résultat vérifié le 19 octobre 2026 :

```text
deployment.apps/identity-api created
sealedsecret.bitnami.com/identity-api-secrets created
service/identity-api created
deployment "identity-api" successfully rolled out

NAME                           READY   STATUS    RESTARTS   AGE   IP              NODE
identity-api-9cb78db89-5crh4   1/1     Running   0          16s   10.244.73.137   kube-worker
postgres-0                     1/1     Running   0          52m   10.244.73.134   kube-worker
rabbitmq-0                     1/1     Running   0          52m   10.244.73.136   kube-worker
redis-0                        1/1     Running   0          52m   10.244.73.135   kube-worker
```

Le nom du pod se compose du nom du `Deployment`, d'un suffixe propre à sa version (`9cb78db89`) et d'un suffixe aléatoire : contrairement à `postgres-0`, il change à chaque recréation.

### La base

```bash
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -At <<'SQL'
select datname from pg_database order by 1;
SQL
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d identitydb -At <<'SQL'
select count(*) from "AspNetUsers";
SQL
```

Résultat vérifié : `identitydb` dans la liste des bases, et `2` utilisateurs, ceux de démonstration créés au premier démarrage.

### Le service, par son `Service`

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: idtest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: idtest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
Y
kubectl -n eshop wait --for=condition=Ready pod/idtest --timeout=120s
kubectl -n eshop exec -i idtest -- sh <<'SH'
echo "alive : $(curl -s -w ' %{http_code}' http://identity-api:5223/alive)"
echo "health : $(curl -s -w ' %{http_code}' http://identity-api:5223/health)"
echo "issuer : $(curl -s http://identity-api:5223/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"')"
SH
kubectl -n eshop delete pod idtest
```

Résultat vérifié le 19 octobre 2026 :

```text
alive : Healthy 200
health : Healthy 200
issuer : "issuer":"http://identity-api:5223"
```

`/health` à `Healthy` prouve aussi que la chaîne de connexion déchiffrée est la bonne. L'émetteur est celui de Compose : les autres services le verront ainsi.

## 6. Le journal

Un premier filtre, `grep -i -E 'fail|error|exception'`, a remonté des dizaines de requêtes SQL : la colonne `AccessFailedCount` contient `fail`. Le filtre retenu ne garde que les lignes qui commencent par un niveau de gravité :

```bash
kubectl -n eshop logs deployment/identity-api | grep -E '^(fail|crit):|^Error:' | sort | uniq -c
kubectl -n eshop logs deployment/identity-api | grep -A1 -E '^warn:'
```

Résultat vérifié le 19 octobre 2026 :

| Message | Explication |
|---|---|
| `Error: libgssapi_krb5.so.2: cannot open shared object file` | Le pilote PostgreSQL cherche la bibliothèque Kerberos, pour une authentification inutilisée. Déjà vu avec Compose ([guide 02-docker/01](../02-docker/01-catalog-api.md)) |
| `fail: Microsoft.EntityFrameworkCore.Database.Connection[20004]` | Premier démarrage : la base n'existe pas encore, le service la crée. Déjà vu avec Compose ([guide 02-docker/02](../02-docker/02-autres-services.md), section 7) |
| `warn: Duende.IdentityServer.License` | Pas de licence Duende : autorisé en développement et en test, obligatoire en production |
| `warn: ...FileSystemXmlRepository` : `Storing keys in a directory '/home/app/.aspnet/DataProtection-Keys' that may not be persisted` | Les clés de protection des données vivent dans le conteneur. Voir section 7 |
| `warn: ...XmlKeyManager` : `No XML encryptor configured` | Ces mêmes clés sont stockées sans chiffrement |

Le pod n'a connu aucun redémarrage.

## 7. Les clés d'Identity.API

Le service manipule deux jeux de clés. Leur emplacement a été vérifié dans le pod, par l'entrée standard :

```bash
kubectl -n eshop exec -i deployment/identity-api -- sh <<'SH'
pwd
ls -l tempkey.jwk
ls -l /home/app/.aspnet/DataProtection-Keys
SH
```

```text
/app
-rw-r--r-- 1 root root 2018 Oct 12 12:31 tempkey.jwk
total 4
-rw------- 1 app app 1001 Oct 19 14:44 key-e2e25068-917b-4a33-b44d-9f3e55b16500.xml
```

Une première tentative, `kubectl ... exec deployment/identity-api -- sh -c 'pwd; ls -l tempkey.jwk; ...'`, avait donné un résultat faux : SSH avait recollé la commande, et seul `pwd` avait tourné dans le pod, les `ls` sur `kube-control`. Avec la fonction `kubectl` par SSH, tout ce qui contient du shell passe par l'entrée standard.

### La clé de signature des jetons : publique

`Program.cs` d'`Identity.API` désactive la gestion automatique des clés de Duende, et utilise une clé de développement :

```csharp
options.KeyManagement.Enabled = false;          // TODO: Remove this line in production.
...
.AddDeveloperSigningCredential();               // TODO: Not recommended for production
```

`AddDeveloperSigningCredential` relit le fichier `tempkey.jwk` s'il existe, et n'en crée un que s'il est absent. Or le fichier du pod appartient à `root` et date du 12 octobre : il vient de l'image. Il est **versionné dans le projet d'origine**, dotnet/eShop, au commit importé comme sur sa branche principale, avec la même empreinte que dans ce dépôt. Le Dockerfile copie tout `src/`, donc la clé avec.

| Conséquence | Évaluation |
|---|---|
| La clé est la même pour tous les pods et après chaque redémarrage | Les jetons survivent à un redémarrage |
| La clé privée est **publique** : n'importe qui peut fabriquer un jeton que les services accepteraient | Acceptable pour un laboratoire joignable seulement depuis le poste. **Inacceptable** au-delà |

La correction ne demande pas de modifier le code : fournir un `tempkey.jwk` propre au projet, par un `SealedSecret` monté à `/app/tempkey.jwk`. Le service relirait cette clé au lieu de celle de l'image. C'est le premier point ouvert de la section 9.

### Les clés de protection des données : propres à chaque pod

ASP.NET chiffre avec elles les cookies de session et les jetons anti-falsification des formulaires. Elles sont créées au démarrage, dans le conteneur, au nom du compte `app`.

| Conséquence | Évaluation |
|---|---|
| Un redémarrage du pod crée de nouvelles clés | Les utilisateurs doivent se reconnecter, comme après une recréation du conteneur avec Compose |
| Deux pods auraient chacun leurs clés | Un cookie émis par l'un serait illisible pour l'autre : d'où `replicas: 1`, commenté dans le manifeste |

En entreprise, ces clés sont rangées dans un stockage partagé, Redis ou une base, ce qui demande une modification du code.

## 8. Tableau de validation

| Contrôle | Résultat au 19 octobre 2026 |
|---|---|
| Chaîne de connexion chiffrée, sans valeur en clair | Oui |
| Image privée téléchargée par le cluster | Oui |
| Pod | `1/1 Running` sur `kube-worker`, aucun redémarrage |
| Base `identitydb` et utilisateurs de démonstration | Créés, 2 utilisateurs |
| `/alive` et `/health` par le `Service` | `Healthy`, 200 |
| Émetteur | `http://identity-api:5223` |
| Erreurs du journal | Les deux attendues, une fois chacune |
| Clé de signature | Celle de l'image, publique |
| Clés de protection des données | Dans le conteneur, perdues au redémarrage |

## 9. Points ouverts

1. **Remplacer la clé de signature publique** par une clé propre au projet, fournie par un `SealedSecret` monté à `/app/tempkey.jwk`. Prioritaire avant toute exposition hors du poste.
2. **Le point d'entrée et l'adresse publique.** Le navigateur et les pods doivent joindre `Identity.API` par la même adresse, sans quoi l'émetteur des jetons ne correspond pas ([guide 02-docker/13](../02-docker/13-compose-webapp.md), section 3). À trancher avec `WebApp`, qui ajoutera aussi `WebAppClient` à la configuration.
3. **Un compte PostgreSQL propre au service**, plutôt que le compte administrateur partagé.
4. **Les clés de protection des données** dans un stockage partagé, pour permettre plusieurs copies.

## 10. Étape suivante

Déployer les API qui s'appuient sur `Identity.API` et sur les dépendances, en commençant par `Catalog.API`, qui ne demande aucune authentification pour la lecture du catalogue : [08 — Catalog.API sur le cluster](08-catalog-api.md).

## 11. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes d'Identity.API
for f in kubernetes/identity-api/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# État
kubectl -n eshop get pods -l app=identity-api -o wide

# Redémarrer (les utilisateurs devront se reconnecter)
kubectl -n eshop rollout restart deployment/identity-api

# Journal, niveaux de gravité seulement
kubectl -n eshop logs deployment/identity-api | grep -E '^(fail|crit|warn):'
```

**Bilan :** `Identity.API` tourne sur le cluster depuis son image privée, avec une chaîne de connexion chiffrée dans le dépôt. Il a créé sa base et répond par son `Service`, avec l'émetteur de Compose. L'examen de ses clés a révélé une clé de signature publique, héritée du projet d'origine, et des clés de session propres au pod : la première est à remplacer avant toute exposition, les secondes imposent une seule copie.
