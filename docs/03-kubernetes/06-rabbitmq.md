# 06 — RabbitMQ sur le cluster

## 1. Objectif

RabbitMQ transporte les événements échangés par les services d'eShop : commande créée, stock confirmé, paiement accepté. Ce guide le déploie dans l'espace de noms `eshop`, sur le modèle de PostgreSQL et de Redis ([guides 03](03-postgres.md) et [05](05-redis.md)).

Les objectifs sont de :

- déployer RabbitMQ à une version figée, avec des identifiants chiffrés dans le dépôt ;
- vérifier que son répertoire de données porte un nom stable, le problème rencontré avec Docker Compose ;
- vérifier que le mot de passe est exigé, par le `Service` ;
- vérifier que les données survivent au pod.

**État au 19 octobre 2026 :** RabbitMQ 4.3.6 tourne sur `kube-worker`, sous le nom de nœud `rabbit@rabbitmq-0`. Il refuse les connexions sans mot de passe ou avec un mot de passe faux, et un hôte virtuel créé a survécu à la suppression du pod.

Avec PostgreSQL, Redis et RabbitMQ, les trois dépendances de l'application sont en place.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Image | `rabbitmq:4.3.6-management` | La version qui tourne dans Compose, mais figée : Compose utilise `rabbitmq:4-management`, une étiquette qui suit chaque nouvelle version ([guide 02-docker/05](../02-docker/05-compose-rabbitmq.md), point ouvert 2). 4.3.6 est la dernière version 4.x au 19 octobre 2026. La variante `-management` inclut l'interface d'administration |
| Type d'objet | `StatefulSet`, volume de 2 Gio conservé à la suppression | Les files et leurs messages sont écrits sur disque |
| Nom du nœud | Aucun réglage | Voir section 3 |
| Identifiants | `SealedSecret` `rabbitmq-credentials` : `RABBITMQ_DEFAULT_USER` et `RABBITMQ_DEFAULT_PASS`, transmis par `envFrom` | Les noms de variables qu'attend l'image. Comme pour PostgreSQL, ils ne servent qu'au **premier** démarrage, sur un volume vide |
| Ports du `Service` | `5672`, AMQP, pour les services ; `15672`, interface et API d'administration | Un `Service` n'est joignable que depuis le cluster : rien n'est publié vers l'extérieur |
| Mémoire | Plafond de 1 Gio, réservation de 256 Mio | Comme dans Compose : RabbitMQ lit le plafond du conteneur, et bloque les publications à 40 %, soit environ 400 Mio ([guide 02-docker/16](../02-docker/16-robustesse-compose.md), section 5) |

## 3. Le nom du nœud

RabbitMQ range ses données dans un répertoire qui porte le nom de son nœud, `rabbit@<nom de machine>`. Avec Docker Compose, le nom de machine était l'identifiant du conteneur, tiré au hasard : à chaque recréation, RabbitMQ cherchait un autre répertoire et repartait d'une base vide. Il avait fallu fixer `hostname: rabbitmq`.

Un `StatefulSet` règle ce problème de lui-même : chaque pod reçoit un nom stable, formé du nom du `StatefulSet` et d'un numéro, et le garde d'une recréation à l'autre. Le nom de machine de `rabbitmq-0` est donc toujours `rabbitmq-0`, et le nœud `rabbit@rabbitmq-0`. La section 6 le vérifie, et la section 8 prouve que la base est bien reprise.

## 4. Le secret

Le mot de passe entrera dans l'adresse de connexion des services, `amqp://eshop_rabbit:<mot de passe>@rabbitmq:5672/`. Il est donc généré sans caractère spécial, et enregistré dans le gestionnaire de mots de passe avant d'être saisi :

```bash
openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; echo
```

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

mkdir -p kubernetes/rabbitmq
read -rs -p 'Mot de passe RabbitMQ : ' RMQ_PASS; echo
printf '%s' "$RMQ_PASS" \
  | kubectl -n eshop create secret generic rabbitmq-credentials \
      --from-literal=RABBITMQ_DEFAULT_USER=eshop_rabbit \
      --from-file=RABBITMQ_DEFAULT_PASS=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/rabbitmq/sealedsecret-rabbitmq-credentials.yaml
unset RMQ_PASS
```

Le nom d'utilisateur reprend celui de Compose, `eshop_rabbit`.

## 5. Les manifestes

```text
kubernetes/rabbitmq/
├── sealedsecret-rabbitmq-credentials.yaml
├── service-rabbitmq.yaml
└── statefulset-rabbitmq.yaml
```

### Le `Service`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
  namespace: eshop
  labels:
    app: rabbitmq
spec:
  selector:
    app: rabbitmq
  ports:
    - name: amqp
      port: 5672
      targetPort: 5672
    - name: management
      port: 15672
      targetPort: 15672
```

Un `Service` à plusieurs ports exige un nom pour chacun.

### Le `StatefulSet`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rabbitmq
  namespace: eshop
spec:
  serviceName: rabbitmq
  replicas: 1
  selector:
    matchLabels:
      app: rabbitmq
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      containers:
        - name: rabbitmq
          image: rabbitmq:4.3.6-management
          envFrom:
            - secretRef:
                name: rabbitmq-credentials
          env:
            - name: RABBITMQ_DEFAULT_VHOST
              value: /
          ports:
            - name: amqp
              containerPort: 5672
            - name: management
              containerPort: 15672
          volumeMounts:
            - name: data
              mountPath: /var/lib/rabbitmq
          # check_port_connectivity : ping répond avant l'ouverture du port 5672
          startupProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "check_port_connectivity"]
            periodSeconds: 10
            timeoutSeconds: 10
            failureThreshold: 30
          readinessProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "check_port_connectivity"]
            periodSeconds: 20
            timeoutSeconds: 10
          livenessProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "ping"]
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
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

### Les trois probes

| Probe | Commande | Raison |
|---|---|---|
| `startupProbe` | `check_port_connectivity` | Réussit seulement une fois les ports ouverts. `ping` répond plusieurs secondes plus tôt, dès que le nœud tourne : c'est la leçon de Compose ([guide 02-docker/05](../02-docker/05-compose-rabbitmq.md), section 7). Jusqu'à 300 s sont laissées au démarrage |
| `readinessProbe` | `check_port_connectivity` | Tant qu'elle échoue, le pod est retiré du `Service` : aucun service ne tente de s'y connecter |
| `livenessProbe` | `ping` | La question est seulement : le nœud tourne-t-il encore ? Un redémarrage n'intervient qu'après 6 échecs, soit 3 minutes |

Les outils `rabbitmq-diagnostics` démarrent une machine Erlang à chaque appel, ce qui prend une à deux secondes. D'où les délais de 10 s et des contrôles plus espacés que pour Redis.

Ces commandes n'utilisent pas le mot de passe : elles s'adressent au nœud par un canal interne, protégé par un jeton, le cookie Erlang, que RabbitMQ crée au premier démarrage dans son volume.

## 6. Appliquer et vérifier le nœud

```bash
for f in kubernetes/rabbitmq/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status statefulset/rabbitmq --timeout=300s
kubectl -n eshop get pods,pvc -o wide
```

Résultat vérifié le 19 octobre 2026 :

```text
sealedsecret.bitnami.com/rabbitmq-credentials created
service/rabbitmq created
statefulset.apps/rabbitmq created
partitioned roll out complete: 1 new pods have been updated...

NAME             READY   STATUS    RESTARTS   AGE    IP              NODE
pod/postgres-0   1/1     Running   0          145m   10.244.73.133   kube-worker
pod/rabbitmq-0   1/1     Running   0          27s    10.244.73.140   kube-worker
pod/redis-0      1/1     Running   0          47m    10.244.73.138   kube-worker

NAME                                    STATUS   VOLUME                                     CAPACITY   STORAGECLASS
persistentvolumeclaim/data-postgres-0   Bound    pvc-9b5c6f26-87e7-4aba-a8db-2053d42b1977   2Gi        local-path
persistentvolumeclaim/data-rabbitmq-0   Bound    pvc-40dd81f3-d3b1-40b7-97ad-3a7eaf9ea08d   2Gi        local-path
persistentvolumeclaim/data-redis-0      Bound    pvc-75ca87fb-c56d-45ee-a1fe-cbf0e3421c7e   2Gi        local-path
```

Les commandes suivantes sont envoyées par l'entrée standard, pour traverser SSH sans perdre leurs guillemets :

```bash
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
echo "version : $(rabbitmqctl -q version)"
echo "dossiers de données :"; ls /var/lib/rabbitmq/mnesia
rabbitmqctl -q list_users
SH
```

Résultat vérifié le 19 octobre 2026 :

```text
version : 4.3.6
dossiers de données :
rabbit@rabbitmq-0
rabbit@rabbitmq-0-feature_flags
rabbit@rabbitmq-0-plugins-expand
rabbit@rabbitmq-0.pid
user    tags
eshop_rabbit    [administrator]
```

Le répertoire porte le nom stable du pod. L'utilisateur a été créé à partir du secret, avec l'étiquette `administrator` et tous les droits sur l'hôte virtuel `/`.

## 7. Vérifier que le mot de passe est exigé

Le test passe par le `Service`, depuis un pod de test qui reçoit le secret comme le recevront les services. Il interroge l'API d'administration, `/api/whoami`, qui vérifie l'utilisateur et le mot de passe dans la même base que les connexions AMQP :

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: rmqtest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: rmqtest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
      envFrom: [ { secretRef: { name: rabbitmq-credentials } } ]
Y
kubectl -n eshop wait --for=condition=Ready pod/rmqtest --timeout=120s
kubectl -n eshop exec -i rmqtest -- sh <<'SH'
u=http://rabbitmq:15672/api/whoami
echo "sans mot de passe : $(curl -s -o /dev/null -w '%{http_code}' $u)"
echo "mot de passe faux : $(curl -s -o /dev/null -w '%{http_code}' -u "$RABBITMQ_DEFAULT_USER:faux" $u)"
echo "mot de passe du secret : $(curl -s -w ' %{http_code}' -u "$RABBITMQ_DEFAULT_USER:$RABBITMQ_DEFAULT_PASS" $u)"
SH
kubectl -n eshop delete pod rmqtest
```

Résultat vérifié le 19 octobre 2026 :

```text
sans mot de passe : 401
mot de passe faux : 401
mot de passe du secret : {"name":"eshop_rabbit","tags":["administrator"],"is_internal_user":true} 200
```

Le port AMQP `5672` n'est pas testé ici avec un mot de passe : il le sera quand les services d'eShop s'y connecteront. D'ici là, la probe `check_port_connectivity` vérifie qu'il est ouvert.

## 8. Vérifier que les données survivent

Un hôte virtuel de test est créé, le pod supprimé, puis l'hôte virtuel relu :

```bash
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q add_vhost test-persistance
kubectl -n eshop delete pod rabbitmq-0
kubectl -n eshop rollout status statefulset/rabbitmq --timeout=300s
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_vhosts
kubectl -n eshop logs rabbitmq-0 | grep -c -E 'Will seed default|Created user'
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q delete_vhost test-persistance
```

Résultat vérifié le 19 octobre 2026 :

```text
name
test-persistance
/
0
```

Le `0` est la preuve décisive, comme dans Compose : sur une base vide, RabbitMQ écrit `Will seed default virtual host and user`, puis `Created user`. Le pod recréé n'a écrit ni l'un ni l'autre : il a repris la base du volume.

## 9. Les limites

| Limite | Conséquence |
|---|---|
| Une seule copie | Une panne de `kube-worker` interrompt l'échange des événements. En entreprise : trois nœuds et des files répliquées (`quorum queues`), souvent avec le RabbitMQ Cluster Operator |
| Un seul compte, administrateur, pour tous les services | Comme dans Compose. Un compte limité par service serait plus sûr |
| Identifiants lus au premier démarrage seulement | Changer le secret ne change pas le mot de passe : même procédure que pour PostgreSQL ([guide 04](04-secrets.md), section 9), avec `rabbitmqctl change_password` |
| Interface d'administration joignable seulement dans le cluster | Pour l'ouvrir depuis le poste, il faudra un tunnel (`kubectl port-forward` et SSH) ou un point d'entrée |
| Supprimer l'espace de noms `eshop` | Supprime la demande de volume, donc les messages, malgré `whenDeleted: Retain` |

## 10. Tableau de validation

| Contrôle | Résultat au 19 octobre 2026 |
|---|---|
| `rabbitmq-0` | `1/1 Running` sur `kube-worker`, en 27 s |
| Demande de volume `data-rabbitmq-0` | `Bound`, 2 Gio, `local-path` |
| Version | 4.3.6 |
| Nom du nœud et du répertoire de données | `rabbit@rabbitmq-0`, stable |
| Utilisateur créé à partir du secret | `eshop_rabbit`, administrateur |
| Par le `Service`, sans mot de passe | Refusé, `401` |
| Mot de passe faux | Refusé, `401` |
| Mot de passe du secret | Accepté, `200` |
| Données reprises après suppression du pod | Oui, aucune réinitialisation |

## 11. Étape suivante

Les trois dépendances sont en place. Viennent ensuite les services d'eShop, en commençant par `Identity.API`, dont dépendent tous les autres. Chacun aura besoin de ses chaînes de connexion, qui contiennent les mots de passe de PostgreSQL, Redis ou RabbitMQ, et seront donc rangées dans des `SealedSecret`.

## 12. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes de RabbitMQ
for f in kubernetes/rabbitmq/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# État
kubectl -n eshop get pods,pvc -l app=rabbitmq -o wide

# Files, utilisateurs, hôtes virtuels
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_queues
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_users

# Mémoire et seuil de blocage
kubectl -n eshop exec rabbitmq-0 -- rabbitmq-diagnostics -q memory_breakdown

# Journal
kubectl -n eshop logs rabbitmq-0
```

**Bilan :** RabbitMQ tourne sur le cluster à une version figée, sous un nom de nœud stable que le `StatefulSet` fournit sans réglage. Son mot de passe est exigé par le `Service` et absent de tout fichier en clair, et ses données survivent au pod. Les trois dépendances d'eShop sont en place.
