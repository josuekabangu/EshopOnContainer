# 01 — Le chart commun des services : eshop-service

## 1. Objectif

Les manifestes de `kubernetes/` ont été écrits et vérifiés un par un ([série 03-kubernetes](../03-kubernetes/01-registre-images.md)). Ils restent dans le dépôt comme trace de cette étape. Mais ils répètent beaucoup : les neuf services .NET ont la même forme, et une correction, comme l'attente de RabbitMQ, a dû être faite sept fois.

Cette série les remplace par des charts Helm. Ce guide présente le chart commun des neuf services.

**État au 22 octobre 2026 :** les neuf services d'eShop sont déployés par un seul chart, `eshop-service`, et un fichier de valeurs par service.

## 2. Le choix de l'organisation

| Option | Principe | Évaluation |
|---|---|---|
| Un chart par service | Neuf charts presque identiques | Le choix de la première version du projet, dont le guide notait lui-même : « cette approche ne supprime pas la duplication ». Une correction se fait neuf fois |
| **Un chart commun** | Un chart, `eshop-service`, et un fichier de valeurs par service ; neuf releases du même chart | Retenu. La pratique courante en entreprise : un chart d'application partagé. Une correction se fait une fois. Il prépare Argo CD, avec une application par service sur le même chart |
| Un seul chart pour toute l'application | Une seule release | Un `helm upgrade` met tout à jour : impossible de déployer un service seul |

Les dépendances, PostgreSQL, Redis et RabbitMQ, ont chacune leur chart, trop différentes pour un chart commun ; ce qui est partagé par tous les services a le sien ([03-dependances-plateforme.md](03-dependances-plateforme.md)).

```text
helm/
├── deploy.sh                 # déploie les 13 releases (guide 04)
├── eshop-service/            # chart commun des neuf services
├── eshop-platform/           # point d'entrée et accès au registre
├── postgres/ redis/ rabbitmq/
└── values/                   # un fichier par release
    └── script_gen/generate.sh
```

Helm et `kubeseal` sont installés dans WSL2 par le rôle Ansible `workstation`, qui y recopie aussi le fichier d'accès au cluster ([01-lab-local/19-workstation.md](../01-lab-local/19-workstation.md)).

## 3. Deux contraintes héritées des objets existants

Le chart doit produire les objets déjà en place, aux mêmes noms.

| Contrainte | Conséquence |
|---|---|
| Un `SealedSecret` ne se déchiffre que sous son nom et dans son espace de noms | Le chart nomme le secret `<service>-secrets`, comme les manifestes : les huit secrets existants suivaient déjà cette règle |
| Le sélecteur d'un `Deployment` ne peut plus être modifié après sa création | Le sélecteur reste `app: <service>`. Les étiquettes usuelles d'un chart (`app.kubernetes.io/...`, `helm.sh/chart`) ne vont que sur les objets eux-mêmes, ni sur le sélecteur, ni sur les pods |

## 4. Le chart

```text
helm/eshop-service/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl
    ├── deployment.yaml
    ├── service.yaml
    ├── httproute.yaml
    └── sealedsecret.yaml
```

### Les valeurs communes : `values.yaml`

```yaml
image:
  repository: ""   # ghcr.io/josuekabangu/<service>
  tag: ""          # identifiant court du commit qui a produit l'image

imagePullSecrets:
  - ghcr-pull

replicas: 1

# Port de l'application, et son nom
port: 8080
portName: http

# Port réservé aux probes, si le port principal n'accepte pas HTTP/1.1 (Basket.API) ; 0 = aucun
probePort: 0

service:
  enabled: true
  appProtocol: ""

route:
  enabled: false
  hostname: ""

# Attente de RabbitMQ au démarrage (docs/03-kubernetes/17-ordre-de-demarrage.md)
waitForRabbitMQ: false

# Variables d'environnement propres au service, sous forme de liste name/value
env: []

# Valeurs chiffrées par kubeseal pour le secret <service>-secrets ; vide = aucun secret
encryptedData: {}

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 512Mi
```

### Ce que décident les valeurs

| Valeur | Objet produit |
|---|---|
| `encryptedData` non vide | Un `SealedSecret` `<service>-secrets`, et `envFrom` dans le conteneur |
| `service.enabled` | Un `Service` ; `false` pour les tâches de fond, que personne n'appelle |
| `route.enabled`, `route.hostname` | Une `HTTPRoute` vers le `Gateway` `eshop` ; le nom d'hôte est alors obligatoire (`required`) |
| `waitForRabbitMQ` | L'`initContainer` `wait-for-rabbitmq` |
| `probePort` | Un second port, `health`, que visent alors les trois probes |

### Le `Deployment`, extrait

```yaml
      containers:
        - name: {{ .Release.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          {{- if .Values.encryptedData }}
          envFrom:
            - secretRef:
                name: {{ .Release.Name }}-secrets
          {{- end }}
          env:
            # Routes /health et /alive, hors environnement Development (adaptation ae2f77b)
            - name: HealthChecks__Expose
              value: "true"
            {{- with .Values.env }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          ports:
            - name: {{ .Values.portName }}
              containerPort: {{ .Values.port }}
            {{- if .Values.probePort }}
            - name: health
              containerPort: {{ .Values.probePort }}
            {{- end }}
          {{- $probePort := ternary "health" .Values.portName (gt (int .Values.probePort) 0) }}
          startupProbe:
            httpGet:
              path: /alive
              port: {{ $probePort }}
```

`HealthChecks__Expose`, commun à tous les services, est écrit une fois dans le chart. Les variables propres à chacun suivent, depuis son fichier de valeurs.

Le `Service` désigne son port cible par son nom (`targetPort: http`), et non plus par son numéro : c'est l'une des différences relevées lors de la reprise ([02-reprise.md](02-reprise.md)).

## 5. Les fichiers de valeurs

Un fichier par service, dans `helm/values/`, ne contient que ce qui lui est propre. Celui de `catalog-api` :

```yaml
# Catalog.API (docs/03-kubernetes/08-catalog-api.md)
image:
  repository: ghcr.io/josuekabangu/catalog-api
  tag: 87e28f8

waitForRabbitMQ: true

# Recopiées de kubernetes/catalog-api/sealedsecret-catalog-api.yaml : chiffrées pour catalog-api-secrets
encryptedData:
  ConnectionStrings__catalogdb: AgBmsR...
  ConnectionStrings__eventbus: AgB4D5X...
```

| Service | Particularités de ses valeurs |
|---|---|
| `identity-api` | `port: 5223` et `ASPNETCORE_HTTP_PORTS`, route `identity.eshop.lab`, adresses des clients, pas d'attente de RabbitMQ |
| `basket-api` | `portName: grpc`, `probePort: 8081`, `appProtocol: kubernetes.io/h2c`, variables Kestrel |
| `ordering-api`, `webhooks-api` | `Identity__Url` |
| `order-processor`, `payment-processor` | `service.enabled: false` |
| `webapp` | Route `shop.eshop.lab`, adresses, appels internes, cookies |
| `webhook-client` | Image `a6647c9`, route `webhooks.eshop.lab`, aucun secret, pas d'attente de RabbitMQ |

Les valeurs chiffrées ont été recopiées des `SealedSecret` de `kubernetes/`, sans être déchiffrées : elles restent liées au nom `<service>-secrets`. Le script `helm/values/script_gen/generate.sh` a produit les huit fichiers à partir des manifestes, une fois, pour la migration ; il est conservé comme trace de la méthode.

## 6. Vérifier avant tout déploiement

```bash
helm lint helm/eshop-service -f helm/values/catalog-api.yaml
helm template catalog-api helm/eshop-service -n eshop -f helm/values/catalog-api.yaml | grep -E '^kind:'
```

Résultat vérifié le 22 octobre 2026 : `1 chart(s) linted, 0 chart(s) failed`, et trois objets, `Service`, `Deployment`, `SealedSecret`. La seule remarque de `helm lint`, l'absence d'icône, ne concerne que les charts publiés dans un catalogue.

## 7. Étape suivante

Les objets existaient déjà, créés par `kubectl apply` : leur reprise par Helm, sans coupure, fait l'objet de [02 — La reprise des objets existants](02-reprise.md).

**Bilan :** un chart, et neuf fichiers de valeurs courts, décrivent les neuf services d'eShop. Les noms des secrets et les sélecteurs, fixés par les objets existants, sont conservés.
