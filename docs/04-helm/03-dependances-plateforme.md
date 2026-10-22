# 03 — Les charts des dépendances et de la plateforme

## 1. Objectif

PostgreSQL, Redis et RabbitMQ sont trop différents pour un chart commun : probes, arguments, ports et outils de diagnostic leur sont propres. Chacun a donc son chart. Un quatrième, `eshop-platform`, regroupe ce que partagent tous les services.

**État au 22 octobre 2026 :** quatre charts, `postgres`, `redis`, `rabbitmq` et `eshop-platform`, déploient les objets qui ne sont pas des services d'eShop. Leur reprise n'a recréé aucun pod et n'a touché aucun volume.

## 2. Pourquoi pas les charts publiés

Les charts Bitnami, longtemps la référence pour ces composants, ne sont plus librement utilisables depuis le changement de leur catalogue en 2025. En entreprise, ces bases sont d'ailleurs souvent des services gérés (Amazon RDS, ElastiCache, Amazon MQ) ou confiées à des opérateurs ([docs/03-kubernetes/02-stockage.md](../03-kubernetes/02-stockage.md), section 3). Les charts du projet reprennent donc ses manifestes, déjà vérifiés.

## 3. Les règles des charts de dépendances

| Règle | Raison |
|---|---|
| Les noms sont écrits en dur : `postgres`, `postgres-credentials`… | Tous les services les désignent par ces noms, dans leurs chaînes de connexion chiffrées. Un nom tiré de la release les casserait au moindre écart |
| `volumeClaimTemplates` reproduit à l'identique, sans étiquette | Champ non modifiable d'un `StatefulSet`. Une différence ferait échouer la mise à jour |
| `selector` et `serviceName` inchangés | Non modifiables, eux aussi |
| Les étiquettes du chart sur les objets seulement | Comme pour `eshop-service` |
| La taille et la classe du volume en valeurs, avec un avertissement | Les changer demande de supprimer le `StatefulSet` ; ses données restent, grâce à `whenDeleted: Retain` |
| Les valeurs chiffrées dans `helm/values/<chart>.yaml` | Même place que pour les services ; le modèle échoue si elles manquent (`required`) |

## 4. Le chart de PostgreSQL

```text
helm/postgres/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl
    ├── service.yaml
    ├── statefulset.yaml
    └── sealedsecret.yaml
```

### `values.yaml`

```yaml
image: pgvector/pgvector:0.8.7-pg15

# Modèle du volume : non modifiable après la création du StatefulSet.
# Changer ces valeurs demande de supprimer le StatefulSet (les données restent, whenDeleted: Retain).
storage:
  size: 2Gi
  storageClassName: local-path

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 512Mi

# Valeurs chiffrées par kubeseal pour le secret postgres-credentials
encryptedData: {}
```

### Le `StatefulSet` : ce qui est variable, ce qui ne l'est pas

Le modèle reprend le manifeste du [guide 03-kubernetes/03](../03-kubernetes/03-postgres.md). Seuls l'image, les ressources et le modèle de volume viennent des valeurs :

```yaml
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
  # Non modifiable : reproduit à l'identique, sans étiquette
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: {{ .Values.storage.storageClassName }}
        resources:
          requests:
            storage: {{ .Values.storage.size }}
```

### Le `SealedSecret`

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  # Le nom fait partie du chiffrement, et figure dans les chaînes de connexion des services
  name: postgres-credentials
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "postgres.labels" . | nindent 4 }}
spec:
  encryptedData:
    {{- required "encryptedData est obligatoire (helm/values/postgres.yaml)" .Values.encryptedData | toYaml | nindent 4 }}
  template:
    metadata:
      name: postgres-credentials
      namespace: {{ .Release.Namespace }}
```

## 5. Redis et RabbitMQ

Même structure. Les fichiers `_helpers.tpl` et `sealedsecret.yaml` ont été produits depuis ceux de PostgreSQL :

```bash
for d in redis rabbitmq; do
  mkdir -p helm/$d/templates
  sed "s/postgres/$d/g" helm/postgres/templates/_helpers.tpl > helm/$d/templates/_helpers.tpl
  sed "s/postgres/$d/g" helm/postgres/templates/sealedsecret.yaml > helm/$d/templates/sealedsecret.yaml
done
grep -rn 'postgres' helm/redis helm/rabbitmq
```

Le `grep` final ne doit rien trouver : vérifié.

| Chart | Particularités |
|---|---|
| `redis` | Les arguments de `redis-server`, dont `$(REDIS_PASSWORD)`, écrit tel quel : Helm ne remplace que les `{{ }}`, Kubernetes remplace la variable au démarrage. Deux variables issues du secret. Plafond de mémoire de 1280 Mio |
| `rabbitmq` | Deux ports nommés, `amqp` et `management` ; probes par `rabbitmq-diagnostics` ; plafond de 1 Gio |

## 6. La plateforme : `eshop-platform`

| Objet | Dans le chart | Raison |
|---|---|---|
| `Gateway` et `EnvoyProxy` `eshop` | Oui | Le point d'entrée, commun aux services ([docs/03-kubernetes/14-point-entree.md](../03-kubernetes/14-point-entree.md)) |
| `SealedSecret` `ghcr-pull` | Oui | Le jeton de lecture du registre, commun aux services |
| L'espace de noms `eshop` | **Non** | Une release vit dans un espace de noms, qui doit exister avant elle. Il est créé par `helm ... --create-namespace`, à l'installation du premier chart ; Argo CD fera de même avec son option `CreateNamespace` |

Ses valeurs :

```yaml
gateway:
  # Adresse figée : les noms du fichier hosts de Windows y pointent
  address: 192.168.57.20
  # Nom fixe du Service du proxy : CoreDNS y renvoie les noms du laboratoire (rôle lab_dns)
  serviceName: eshop-gateway
  hostname: "*.eshop.lab"

ghcrPull:
  # Jeton de lecture du registre, chiffré par kubeseal pour le secret ghcr-pull
  encryptedData: {}
```

Le `SealedSecret` `ghcr-pull` conserve son **type** dans son modèle :

```yaml
  template:
    metadata:
      name: ghcr-pull
      namespace: {{ .Release.Namespace }}
    # Identifiants de registre : sans ce type, le cluster ne s'en servirait pas pour télécharger les images
    type: kubernetes.io/dockerconfigjson
```

## 7. Les fichiers de valeurs

Les valeurs chiffrées ont été recopiées des `SealedSecret` de `kubernetes/`, sans déchiffrement :

```bash
for d in redis rabbitmq; do
  {
    echo "# $d : recopiées de kubernetes/$d/sealedsecret-$d-credentials.yaml, chiffrées pour $d-credentials"
    echo "encryptedData:"
    sed -n '/encryptedData:/,/template:/p' kubernetes/$d/sealedsecret-$d-credentials.yaml | sed '1d;$d' | sed 's/^    /  /'
  } > helm/values/$d.yaml
done
```

Résultat vérifié : une valeur pour Redis (`REDIS_PASSWORD`), deux pour RabbitMQ, une pour la plateforme (`.dockerconfigjson`), deux pour PostgreSQL.

## 8. Vérifier, puis reprendre

Pour ces charts, le `diff` est affiché sans filtre :

```bash
helm template postgres helm/postgres -n eshop -f helm/values/postgres.yaml | kubectl diff -f - 2>&1 \
  | grep -E '^[+-]' | grep -v -E '^(\+\+\+|---) '
```

Résultats vérifiés le 22 octobre 2026 : uniquement des étiquettes, et les `targetPort` numériques devenus des noms ; aucune ligne `generation`, rien dans les pods ni dans les volumes. La reprise est décrite dans [02-reprise.md](02-reprise.md), section 5.

Une commande de vérification a échoué au passage, à cause du sélecteur `-l 'app in (redis,rabbitmq)'` : par la fonction `kubectl` qui passe par SSH, les guillemets ont disparu, et le shell de `kube-control` a buté sur la parenthèse. Deux sélecteurs simples, `-l app=redis` et `-l app=rabbitmq`, ne demandent aucune protection.

## 9. Étape suivante

Déployer les 13 releases sur un cluster neuf, sans reprise : [04 — Le déploiement par Helm](04-deploiement.md).

**Bilan :** quatre charts décrivent les bases, la messagerie et le point d'entrée, avec les noms et les modèles de volume des objets existants. Leur reprise n'a recréé aucun pod et n'a touché aucune donnée.
