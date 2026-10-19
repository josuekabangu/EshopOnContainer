# 05 — Redis sur le cluster

## 1. Objectif

Redis conserve les paniers des utilisateurs, pour `Basket.API`. Ce guide le déploie dans l'espace de noms `eshop`, sur le modèle de PostgreSQL ([guide 03](03-postgres.md)), avec un mot de passe chiffré dans le dépôt ([guide 04](04-secrets.md)).

Les objectifs sont de :

- déployer Redis à une version figée, protégé par un mot de passe qui n'apparaît dans aucun fichier en clair ;
- vérifier que ce mot de passe est **exigé**, et pas seulement accepté ;
- vérifier qu'il n'apparaît ni dans la définition du pod, ni dans les arguments du processus ;
- vérifier que les données survivent au pod.

**État au 19 octobre 2026 :** Redis 7.4.11 tourne sur `kube-worker`. Il refuse les connexions sans mot de passe ou avec un mot de passe faux, et une donnée écrite a survécu à la suppression du pod.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Image | `redis:7.4.11` | Compose utilise `redis:7`, une étiquette qui suit chaque nouvelle version. La règle de [kubernetes/README.md](../../kubernetes/README.md) impose une version fixe. 7.4.11 est la dernière version 7.x au 19 octobre 2026 |
| Type d'objet | `StatefulSet`, volume de 2 Gio conservé à la suppression | Comme PostgreSQL : les paniers sont écrits sur disque (`appendonly`) |
| Réglages de Redis | Ceux de Compose ([guide 02-docker/04](../02-docker/04-compose-redis.md)) | `maxmemory 1gb` avec `noeviction` : Redis refuse d'écrire plutôt que d'effacer des paniers. `appendonly` avec `everysec` : au plus une seconde d'écritures perdue |
| Plafond de mémoire du conteneur | 1280 Mio | Au-dessus de `maxmemory` : Redis refuse les écritures avant que le noyau ne l'arrête |
| Mot de passe | `SealedSecret` `redis-credentials`, une clé `REDIS_PASSWORD` | Transmise deux fois au conteneur : à `redis-server`, et à `redis-cli` sous le nom `REDISCLI_AUTH` |

## 3. Le secret

Le mot de passe est généré sans caractère spécial, puisqu'il entrera dans la chaîne de connexion de `Basket.API`. Il est enregistré dans le gestionnaire de mots de passe avant d'être saisi :

```bash
openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; echo
```

Puis chiffré, sans toucher le disque en clair, depuis la racine du dépôt :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

mkdir -p kubernetes/redis
read -rs -p 'Mot de passe Redis : ' REDIS_PASS; echo
printf '%s' "$REDIS_PASS" \
  | kubectl -n eshop create secret generic redis-credentials \
      --from-file=REDIS_PASSWORD=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/redis/sealedsecret-redis-credentials.yaml
unset REDIS_PASS
```

## 4. Les manifestes

```text
kubernetes/redis/
├── sealedsecret-redis-credentials.yaml
├── service-redis.yaml
└── statefulset-redis.yaml
```

Le `Service` `redis`, port 6379, suit le modèle de celui de PostgreSQL. Les chaînes de connexion gardent ainsi `redis:6379`, comme dans Compose.

### Le `StatefulSet`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: eshop
spec:
  serviceName: redis
  replicas: 1
  selector:
    matchLabels:
      app: redis
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7.4.11
          args:
            - redis-server
            - --requirepass
            - $(REDIS_PASSWORD)
            - --maxmemory
            - 1gb
            - --maxmemory-policy
            - noeviction
            - --appendonly
            - "yes"
            - --appendfsync
            - everysec
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-credentials
                  key: REDIS_PASSWORD
            # Lu par redis-cli : le mot de passe n'apparaît pas dans la commande des probes
            - name: REDISCLI_AUTH
              valueFrom:
                secretKeyRef:
                  name: redis-credentials
                  key: REDIS_PASSWORD
          ports:
            - name: redis
              containerPort: 6379
          volumeMounts:
            - name: data
              mountPath: /data
          # grep PONG : redis-cli sort avec le code 0 même quand l'authentification échoue
          startupProbe:
            exec:
              command: ["sh", "-c", "redis-cli ping | grep -q PONG"]
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            exec:
              command: ["sh", "-c", "redis-cli ping | grep -q PONG"]
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            exec:
              command: ["sh", "-c", "redis-cli ping | grep -q PONG"]
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 6
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 1280Mi
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
| `$(REDIS_PASSWORD)` dans `args` | Kubernetes remplace la variable par sa valeur au démarrage du conteneur. La définition du pod, lisible par `kubectl get pod -o yaml`, ne contient que `$(REDIS_PASSWORD)` |
| `args` et non `command` | Le point d'entrée de l'image est conservé : il donne `/data` à l'utilisateur `redis`, puis lance Redis sans les droits root. Remplacer `command` le contournerait, et Redis tournerait en root |
| `"yes"` entre guillemets | Sans eux, YAML lirait le booléen `true`, refusé dans une liste de chaînes |
| `REDISCLI_AUTH` | `redis-cli` lit le mot de passe dans cette variable : il n'apparaît pas dans la commande des probes |
| `startupProbe` | Au démarrage, Redis recharge son journal `appendonly` et répond `LOADING` au lieu de `PONG`. Jusqu'à 150 s lui sont laissées |
| `grep -q PONG` | `redis-cli` se termine avec le code 0 même quand l'authentification échoue ([guide 02-docker/15](../02-docker/15-controles-de-sante.md)) |

Contrairement à PostgreSQL, Redis exige le mot de passe **sur toutes les connexions**, y compris celles de l'intérieur du conteneur. Une probe qui réussit prouve donc déjà que le secret est accepté. Pour PostgreSQL, la connexion par `127.0.0.1` ne vérifiait rien ([guide 04](04-secrets.md), section 7).

## 5. Appliquer

```bash
for f in kubernetes/redis/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status statefulset/redis --timeout=180s
kubectl -n eshop get pods,pvc -o wide
```

Résultat vérifié le 19 octobre 2026 :

```text
sealedsecret.bitnami.com/redis-credentials created
service/redis created
statefulset.apps/redis created
partitioned roll out complete: 1 new pods have been updated...

NAME             READY   STATUS    RESTARTS   AGE   IP              NODE
pod/postgres-0   1/1     Running   0          89m   10.244.73.133   kube-worker
pod/redis-0      1/1     Running   0          15s   10.244.73.136   kube-worker

NAME                                    STATUS   VOLUME                                     CAPACITY   STORAGECLASS
persistentvolumeclaim/data-postgres-0   Bound    pvc-9b5c6f26-87e7-4aba-a8db-2053d42b1977   2Gi        local-path
persistentvolumeclaim/data-redis-0      Bound    pvc-75ca87fb-c56d-45ee-a1fe-cbf0e3421c7e   2Gi        local-path
```

## 6. Vérifier que le mot de passe est exigé

Le test passe par le `Service`, depuis un pod de test qui reçoit le secret comme le recevra `Basket.API` :

```bash
kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: redistest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: redistest
      image: redis:7.4.11
      command: ["sleep", "300"]
      env:
        - name: REDIS_PASSWORD
          valueFrom: { secretKeyRef: { name: redis-credentials, key: REDIS_PASSWORD } }
Y
kubectl -n eshop wait --for=condition=Ready pod/redistest --timeout=120s
kubectl -n eshop exec -i redistest -- sh <<'SH'
echo "sans mot de passe : $(redis-cli -h redis ping 2>&1)"
echo "mot de passe faux : $(REDISCLI_AUTH=faux redis-cli -h redis ping 2>&1)"
echo "mot de passe du secret : $(REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -h redis ping 2>&1)"
SH
kubectl -n eshop delete pod redistest
```

Résultat vérifié le 19 octobre 2026 :

```text
sans mot de passe : NOAUTH Authentication required.
mot de passe faux : AUTH failed: WRONGPASS invalid username-password pair or user is disabled.
NOAUTH Authentication required.
mot de passe du secret : PONG
```

Avec le mot de passe faux, `redis-cli` signale l'échec de l'authentification, puis envoie quand même le `ping`, sans être authentifié : d'où le second `NOAUTH`.

## 7. Vérifier que le mot de passe n'est pas visible

Dans la définition du pod :

```bash
kubectl -n eshop get pod redis-0 -o yaml | grep -A1 requirepass
```

```text
    - --requirepass
    - $(REDIS_PASSWORD)
```

Dans les arguments du processus, lisibles par `ps` ou `/proc` sur le nœud. La commande passe par l'entrée standard : en argument de SSH, les guillemets autour de `'\0'` disparaîtraient, comme pour les requêtes SQL du [guide 03](03-postgres.md), section 6.

```bash
kubectl -n eshop exec -i redis-0 -- sh <<'SH'
echo "processus 1 : $(tr '\0' ' ' < /proc/1/cmdline)"
echo "utilisateur : $(stat -c %U /proc/1)"
echo "mot de passe dans la ligne de commande : $(tr '\0' '\n' < /proc/1/cmdline | grep -cxF "$REDIS_PASSWORD")"
SH
```

Résultat vérifié le 19 octobre 2026 :

```text
processus 1 : redis-server *:6379
utilisateur : redis
mot de passe dans la ligne de commande : 0
```

Redis réécrit le titre de son processus au démarrage, ce qui efface ses arguments. Le mot de passe ne reste visible qu'aux processus qui peuvent lire l'environnement du conteneur.

La première tentative de ce contrôle, `kubectl ... exec redis-0 -- sh -c 'tr "\0" " " < /proc/1/cmdline'`, a échoué sur `tr: missing operand` : SSH avait recollé les arguments et perdu les guillemets.

## 8. Vérifier que les données survivent

```bash
kubectl -n eshop exec redis-0 -- redis-cli set test:persistance avant-suppression
kubectl -n eshop delete pod redis-0
kubectl -n eshop rollout status statefulset/redis --timeout=180s
kubectl -n eshop exec redis-0 -- redis-cli get test:persistance
kubectl -n eshop exec redis-0 -- redis-cli del test:persistance
```

La valeur est choisie sans espace ni accent, pour traverser SSH intacte. `kubectl exec` hérite des variables du conteneur : `redis-cli` y trouve `REDISCLI_AUTH`.

Résultat vérifié le 19 octobre 2026 : `OK`, puis `avant-suppression` après recréation du pod, puis `1`.

Le volume contient le journal `appendonly`, dans `appendonlydir/`, et un instantané `dump.rdb` : Redis garde ses instantanés périodiques par défaut, comme dans Compose.

## 9. Les limites

| Limite | Conséquence |
|---|---|
| Une seule copie | Une panne de `kube-worker` rend les paniers indisponibles |
| `appendfsync everysec` | Au plus une seconde d'écritures perdue en cas d'arrêt brutal |
| `noeviction` à 1 Gio | Au-delà, Redis refuse les nouveaux paniers au lieu d'effacer les anciens |
| Mot de passe dans l'environnement du conteneur | Lisible par qui peut faire `kubectl exec` dans `eshop`. Les droits d'accès du cluster protègent le secret, pas Sealed Secrets |
| Supprimer l'espace de noms `eshop` | Supprime la demande de volume, donc les paniers, malgré `whenDeleted: Retain` |

## 10. Tableau de validation

| Contrôle | Résultat au 19 octobre 2026 |
|---|---|
| `redis-0` | `1/1 Running` sur `kube-worker`, utilisateur `redis` |
| Demande de volume `data-redis-0` | `Bound`, 2 Gio, `local-path` |
| Version et réglages | 7.4.11, `appendonly yes`, `maxmemory` 1 Gio |
| Connexion sans mot de passe, par le `Service` | Refusée, `NOAUTH` |
| Mot de passe faux | Refusé, `WRONGPASS` |
| Mot de passe du secret | Accepté, `PONG` |
| Mot de passe dans la définition du pod | Absent, `$(REDIS_PASSWORD)` |
| Mot de passe dans les arguments du processus | Absent |
| Donnée conservée après suppression du pod | Oui |

## 11. Étape suivante

Déployer RabbitMQ sur le même modèle. `Basket.API` aura ensuite besoin du mot de passe de Redis dans sa chaîne de connexion, `redis:6379,password=...`, qui sera rangée dans son propre secret.

## 12. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Appliquer les manifestes de Redis
for f in kubernetes/redis/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -

# État
kubectl -n eshop get pods,pvc -l app=redis -o wide

# Commande Redis
kubectl -n eshop exec redis-0 -- redis-cli info memory

# Journal
kubectl -n eshop logs redis-0
```

**Bilan :** Redis tourne sur le cluster à une version figée, sans les droits root, avec un mot de passe exigé par toutes les connexions et absent de tout fichier en clair, de la définition du pod et des arguments du processus. Ses données survivent au pod.
