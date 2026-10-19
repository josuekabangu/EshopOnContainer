# 03 — PostgreSQL sur le cluster

## 1. Objectif

Les guides [01](01-registre-images.md) et [02](02-stockage.md) ont rendu les images disponibles au cluster et lui ont donné un fournisseur de volumes. Ce guide déploie la première ressource de l’application : PostgreSQL, qui porte les bases du catalogue, des utilisateurs, des commandes et des abonnements.

Les objectifs sont de :

- déployer PostgreSQL avec l’extension `vector`, sans écrire aucun mot de passe dans un fichier ;
- lui donner un volume qui survive au pod ;
- protéger ses données contre la suppression accidentelle de sa définition ;
- vérifier ces deux protections avec une donnée réelle.

**État au 16 octobre 2026 :** PostgreSQL 15.19 tourne sur `kube-worker`, dans l’espace de noms `eshop`. Une donnée écrite a survécu à la suppression du pod, puis à celle du `StatefulSet`.

> **Mise à jour du 18 octobre 2026.** Le secret `postgres-credentials` n’est plus créé par commande : il est décrit par `kubernetes/postgres/sealedsecret-postgres-credentials.yaml`, chiffré par Sealed Secrets, et s’applique avec les deux autres fichiers du dossier. Voir [04 — Les secrets dans le dépôt, chiffrés](04-secrets.md). La section 3 décrit la méthode du 16 octobre ; le changement de mot de passe est traité dans le guide 04, section 9.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Type d’objet | **`StatefulSet`** | Prévu pour les applications à données : pod au nom stable (`postgres-0`), et volume créé pour lui à partir d’un modèle, qui le suit d’un redémarrage à l’autre. Un `Deployment` traite ses pods comme interchangeables |
| Image | `pgvector/pgvector:0.8.7-pg15` | La même qu’avec Docker Compose ([guide 02-docker/16](../02-docker/16-robustesse-compose.md), section 6) |
| Nom du `Service` | `postgres` | Les chaînes de connexion des services gardent `Host=postgres`, comme dans Compose |
| Utilisateur et mot de passe | Un `Secret`, créé par commande | Règle de [kubernetes/README.md](../../kubernetes/README.md) : aucun secret dans un fichier du dépôt |
| Script de création des bases | **Non repris** | Chaque service crée sa base à son premier démarrage ([guide 02-docker/02](../02-docker/02-autres-services.md), section 7). `OrderProcessor`, qui ne crée pas la sienne, se rétablit seul quand elle apparaît ([guide 02-docker/10](../02-docker/10-compose-order-processor.md)) |
| Politique `Delete` de la classe `local-path` | Conservée, avec la protection du `StatefulSet` | Voir section 5 |

## 3. Préparer l’espace de noms et les secrets

L’espace de noms `eshop` et le secret du registre disparaissent à chaque reconstruction du cluster ([kubernetes/README.md](../../kubernetes/README.md)). Ils ont été recréés avec les commandes du [guide 01](01-registre-images.md), section 6, avant ce déploiement.

### Le mot de passe

Le mot de passe entrera dans des chaînes de connexion, où les caractères `;`, `@` et `:` posent problème ([guide 02-docker/07](../02-docker/07-compose-catalog.md), section 3). Il est donc choisi sans caractère spécial, par exemple généré ainsi :

```bash
openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; echo
```

Il est conservé dans un gestionnaire de mots de passe.

### Le secret `postgres-credentials`

Depuis WSL2, à la racine du dépôt :

```bash
CP="ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10"

read -rs -p 'Mot de passe PostgreSQL : ' PG_PASS; echo
printf '%s' "$PG_PASS" | $CP kubectl -n eshop create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER=postgres \
  --from-file=POSTGRES_PASSWORD=/dev/stdin
unset PG_PASS
```

- Le nom d’utilisateur n’est pas un secret : il passe en argument, avec `--from-literal`.
- Le mot de passe passe par l’entrée standard (`/dev/stdin`), comme le jeton du registre : il n’apparaît ni en argument, ni dans l’historique, ni dans un fichier.
- `printf '%s'` n’ajoute pas de saut de ligne, qui ferait sinon partie du mot de passe.

Les deux clés du secret portent les noms des variables qu’attend l’image PostgreSQL. Le `StatefulSet` les lui transmet toutes ensemble, par `envFrom`.

Vérification :

```bash
$CP kubectl -n eshop get secret
```

```text
NAME                   TYPE                             DATA   AGE
ghcr-pull              kubernetes.io/dockerconfigjson   1      47m
postgres-credentials   Opaque                           2      46m
```

## 4. Les manifestes

Les deux objets sont décrits dans deux fichiers, un objet par fichier :

```text
kubernetes/postgres/
├── service-postgres.yaml
└── statefulset-postgres.yaml
```

### Le `Service`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: eshop
  labels:
    app: postgres
spec:
  selector:
    app: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
```

Le `Service` donne à PostgreSQL une adresse stable, `postgres`, résolue par le DNS du cluster. Il envoie les connexions aux pods qui portent l’étiquette `app: postgres`, et seulement à ceux qui sont prêts, selon leur `readinessProbe`.

### Le `StatefulSet`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: eshop
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: pgvector/pgvector:0.8.7-pg15
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            - secretRef:
                name: postgres-credentials
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          startupProbe:
            exec:
              command: ["sh", "-c", "pg_isready -h 127.0.0.1 -U \"$POSTGRES_USER\" -d postgres"]
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -h 127.0.0.1 -U \"$POSTGRES_USER\" -d postgres"]
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -h 127.0.0.1 -U \"$POSTGRES_USER\" -d postgres"]
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 2Gi
```

| Élément | Rôle |
|---|---|
| `serviceName: postgres` | Le `Service` associé au `StatefulSet` |
| `replicas: 1` | Une seule copie : sans opérateur, PostgreSQL ne se réplique pas de lui-même |
| `persistentVolumeClaimRetentionPolicy` | Ce que deviennent les demandes de volume quand le `StatefulSet` est supprimé ou réduit : voir section 5 |
| `envFrom` / `secretRef` | Transmet au conteneur toutes les clés du secret, comme variables d’environnement |
| `PGDATA` | Les données dans un sous-dossier du volume, comme avec Compose ([guide 02-docker/03](../02-docker/03-compose-postgres.md), section 3) |
| `volumeClaimTemplates` | Modèle de demande de volume. Le `StatefulSet` en crée une par pod, nommée `data-postgres-0`, à la classe `local-path`, de 2 Gio |
| `resources.requests` | Ce que le planificateur réserve sur le nœud : 0,1 cœur et 128 Mio |
| `resources.limits.memory` | Le plafond, 512 Mio, le même qu’avec Compose |

### Les trois probes

Toutes interrogent le serveur par `pg_isready -h 127.0.0.1`, donc par TCP. Sans `-h`, elles déclareraient prêt le serveur temporaire qui tourne pendant l’initialisation, joignable par le seul socket local ([guide 02-docker/15](../02-docker/15-controles-de-sante.md), section 8).

| Probe | Question | Réglage |
|---|---|---|
| `startupProbe` | Le démarrage est-il terminé ? | Jusqu’à 150 s (30 × 5 s), le temps de l’initialisation au premier démarrage. Les deux autres probes n’entrent en jeu qu’après sa réussite |
| `readinessProbe` | Peut-on lui envoyer des connexions ? | Tant qu’elle échoue, le pod est retiré du `Service` |
| `livenessProbe` | Faut-il redémarrer le conteneur ? | Seulement après 6 échecs consécutifs, soit 2 minutes : une base ne doit pas être redémarrée pour un ralentissement passager |

`sh -c` est nécessaire pour que la variable `$POSTGRES_USER` soit remplacée : une probe `exec` lance la commande directement, sans shell.

### Appliquer deux fichiers en une commande

`kubectl` est configuré sur `kube-control`, et les fichiers du dépôt n’y sont pas. Un fichier s’envoie par `<` sur l’entrée de `kubectl`. Un dossier ne peut pas s’envoyer ainsi :

```text
$CP kubectl apply -f - < kubernetes/postgres/
error: no objects passed to apply
```

Les fichiers du dossier sont donc envoyés l’un après l’autre, séparés par `---` :

```bash
for f in kubernetes/postgres/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
```

La ligne `---` est indispensable : sans elle, la fin d’un fichier et le début du suivant formeraient un seul objet YAML.

## 5. Protéger les données contre une suppression

### Le risque

La classe `local-path` est en politique `Delete` : supprimer la demande de volume efface les données, sans confirmation ([guide 01-lab-local/14](../01-lab-local/14-local-path.md), section 6).

### Les deux protections possibles

| Protection | Principe | Retenue |
|---|---|---|
| Une seconde classe de stockage, en politique `Retain` | Le volume survit même à la suppression de sa demande | Non : une classe de plus à maintenir dans le rôle `local_path` |
| La politique de conservation du `StatefulSet` | `whenDeleted: Retain` : supprimer le `StatefulSet` **conserve** ses demandes de volume | **Oui** |

La seconde couvre l’erreur la plus courante : supprimer ou recréer le `StatefulSet`, par exemple pour corriger sa définition. Pour perdre les données, il faut supprimer explicitement la demande `data-postgres-0`, ou l’espace de noms `eshop` entier.

`whenScaled: Retain` applique la même règle si le nombre de copies est réduit.

## 6. Démarrer et vérifier

```bash
for f in kubernetes/postgres/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
$CP kubectl -n eshop rollout status statefulset/postgres --timeout=180s
$CP kubectl -n eshop get pods,pvc -o wide
```

Résultat vérifié le 16 octobre 2026 :

```text
service/postgres created
statefulset.apps/postgres created
partitioned roll out complete: 1 new pods have been updated...

NAME             READY   STATUS    RESTARTS   AGE   IP              NODE
pod/postgres-0   1/1     Running   0          31s   10.244.73.131   kube-worker

NAME                                    STATUS   VOLUME                                     CAPACITY   STORAGECLASS
persistentvolumeclaim/data-postgres-0   Bound    pvc-8c2f9a57-6f62-49d7-a731-60d54b625ae4   2Gi        local-path
```

### Envoyer une requête SQL par SSH

Une requête passée en argument d’une commande SSH perd ses guillemets :

```text
$CP kubectl -n eshop exec postgres-0 -- psql -U postgres -Atc "select version()"
bash: -c: line 1: syntax error near unexpected token `('
```

SSH ne transmet pas les arguments un par un : il les recolle en une seule ligne, que le shell de `kube-control` relit. Les guillemets doubles, consommés par le shell de WSL2 avant l’envoi, ont disparu, et les parenthèses sont lues comme du code shell.

La requête est donc envoyée par l’entrée standard :

```bash
$CP kubectl -n eshop exec -i postgres-0 -- psql -U postgres -At <<'SQL'
select version();
select default_version from pg_available_extensions where name = 'vector';
SQL
```

- `-i` transmet l’entrée de la commande au conteneur.
- `<<'SQL'` envoie le texte tel quel : les guillemets simples autour de `SQL` empêchent le shell de le modifier.
- `-At` demande à `psql` une sortie brute, sans en-tête ni mise en forme.

Résultat vérifié :

```text
PostgreSQL 15.19 (Debian 15.19-1.pgdg12+2) on x86_64-pc-linux-gnu ...
0.8.7
```

L’extension `vector` n’est pas encore installée dans une base : `Catalog.API` le fera à son premier démarrage, dans `catalogdb`.

## 7. Vérifier que les données survivent

Une donnée est écrite, puis relue après chacune des deux suppressions.

```bash
# 1. Écrire une donnée
$CP kubectl -n eshop exec -i postgres-0 -- psql -U postgres -At <<'SQL'
create table test_persistance (note text, cree_le timestamptz default now());
insert into test_persistance (note) values ('écrit avant les suppressions');
select * from test_persistance;
SQL

# 2. Supprimer le pod, relire
$CP kubectl -n eshop delete pod postgres-0
$CP kubectl -n eshop rollout status statefulset/postgres --timeout=180s
$CP kubectl -n eshop exec -i postgres-0 -- psql -U postgres -At <<'SQL'
select * from test_persistance;
SQL

# 3. Supprimer le StatefulSet, vérifier la demande, réappliquer, relire, nettoyer
$CP kubectl -n eshop delete statefulset postgres
$CP kubectl -n eshop get pvc
cat kubernetes/postgres/statefulset-postgres.yaml | $CP kubectl apply -f -
$CP kubectl -n eshop rollout status statefulset/postgres --timeout=180s
$CP kubectl -n eshop exec -i postgres-0 -- psql -U postgres -At <<'SQL'
select * from test_persistance;
drop table test_persistance;
SQL
```

Résultats vérifiés le 16 octobre 2026 :

| Étape | Résultat |
|---|---|
| 1. Donnée écrite | `écrit avant les suppressions|2026-10-16 16:33:25.252749+00` |
| 2. Après suppression et recréation du pod | La même ligne, la même heure |
| 3a. Juste après la suppression du `StatefulSet` | Plus aucun pod ; `data-postgres-0` toujours `Bound`, même volume `pvc-8c2f9a57-…` |
| 3b. Après réapplication du `StatefulSet` | La même ligne, la même heure |
| 3c. Nettoyage | `DROP TABLE` |

Le journal du pod recréé à l’étape 3 confirme que PostgreSQL a retrouvé sa base au lieu d’en créer une :

```bash
$CP kubectl -n eshop logs postgres-0 | grep -E 'Skipping initialization|database system was'
```

```text
PostgreSQL Database directory appears to contain a database; Skipping initialization
LOG:  database system was shut down at 2026-10-16 16:10:12 UTC
```

`was shut down` indique un arrêt propre : à la suppression du pod, Kubernetes envoie un signal d’arrêt et laisse au processus le temps de se terminer.

### Une première tentative incomplète

Lors d’un premier essai, l’étape 3 avait été lancée sans l’étape 1 : la table de test n’existait pas, et la relecture finale a échoué sur `relation "test_persistance" does not exist`. L’âge du pod au moment de la suppression, 51 minutes, montrait que l’étape 2 n’avait pas tourné non plus. Le test a été repris dans l’ordre. Les blocs se lancent un par un, chaque résultat étant vérifié avant le suivant.

## 8. Les limites

| Limite | Conséquence |
|---|---|
| Une seule copie, aucune réplication | Une panne de `kube-worker` interrompt toutes les bases ; une panne de son disque les perd |
| Supprimer l’espace de noms `eshop` | Supprime la demande de volume, donc les données, malgré `whenDeleted: Retain` |
| Aucune sauvegarde | Prévue dans la phase d’exploitation |
| Un seul compte, administrateur, pour tous les services | Comme avec Compose ([guide 02-docker/03](../02-docker/03-compose-postgres.md), section 10) |
| ~~Le secret disparaît avec le cluster~~ | Réglé le 18 octobre 2026 : le secret chiffré est dans le dépôt ([guide 04](04-secrets.md)) |

## 9. Tableau de validation

| Contrôle | Résultat au 16 octobre 2026 |
|---|---|
| Espace de noms `eshop` et secrets `ghcr-pull`, `postgres-credentials` | Créés |
| `postgres-0` | `1/1 Running` sur `kube-worker` |
| Demande de volume `data-postgres-0` | `Bound`, 2 Gio, `local-path` |
| Version de PostgreSQL et de `vector` | 15.19 et 0.8.7 |
| Politique de conservation du `StatefulSet` | `whenDeleted: Retain`, `whenScaled: Retain` |
| Donnée conservée après suppression du pod | Oui |
| Donnée conservée après suppression du `StatefulSet` | Oui |

## 10. Étape suivante

Ranger les secrets dans le dépôt, chiffrés, au lieu de les créer par commande : voir [04 — Les secrets dans le dépôt, chiffrés](04-secrets.md). Redis et RabbitMQ suivront ensuite le même modèle : un `StatefulSet` avec son volume, un `Service`, et un `SealedSecret`.

## 11. Commandes de référence

```bash
CP="ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10"

# Appliquer les manifestes de PostgreSQL
for f in kubernetes/postgres/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -

# État du pod et du volume
$CP kubectl -n eshop get pods,pvc -o wide

# Requête SQL
$CP kubectl -n eshop exec -i postgres-0 -- psql -U postgres -At <<'SQL'
select datname from pg_database order by 1;
SQL

# Journal
$CP kubectl -n eshop logs postgres-0
```

**Bilan :** PostgreSQL tourne sur le cluster, avec un mot de passe qui n’apparaît dans aucun fichier et un volume qui conserve ses données au-delà de son pod comme de son `StatefulSet`. Ses limites, une copie unique sans sauvegarde, sont connues avant le déploiement des services.
