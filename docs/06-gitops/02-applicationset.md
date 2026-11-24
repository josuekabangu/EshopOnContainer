# 02 — Les 13 releases déclarées à Argo CD, et la reprise des objets de Helm

## 1. Objectif

Argo CD est installé, mais il ne sait rien d'eShop ([guide 01](01-installation.md)). Il faut lui décrire l'application : où sont les charts, avec quelles valeurs, dans quel espace de noms. Ces objets tournent déjà, déployés par `helm/deploy.sh` ([docs/04-helm/04-deploiement.md](../04-helm/04-deploiement.md)) : Argo CD doit les **reprendre**, sans les recréer et sans coupure.

**État au 25 octobre 2026 :** les 13 releases sont déclarées par un seul objet, l'`ApplicationSet` `eshop`. Après deux corrections des charts et une synchronisation lancée à la main, les 13 applications sont `Synced Healthy` sur le commit `5633b96`. Les dépendances n'ont pas été redémarrées, les services tournent sur les images de la CI.

## 2. Une `Application` par release

Argo CD décrit ce qu'il déploie par des objets `Application` : une source (dépôt, chemin, valeurs) et une destination (cluster, espace de noms). Les 13 releases Helm deviennent 13 `Application`, du même nom. Ainsi, chaque service se synchronise, s'inspecte et se dépanne séparément, comme chaque release Helm le permettait.

Trois façons de créer ces 13 objets :

| Façon | Retenue ? | Raison |
|---|---|---|
| 13 fichiers `Application` | Non | 13 fichiers presque identiques : une correction se fait 13 fois, la duplication que le chart commun avait supprimée ([docs/04-helm/01-chart-commun.md](../04-helm/01-chart-commun.md)) |
| Une `Application` « parente » qui déploie les 13 autres (*app of apps*) | Non | Garde les 13 fichiers, en ajoutant un niveau |
| **Un `ApplicationSet`** | **Oui** | Un modèle d'`Application` et une liste de 13 entrées. Le contrôleur des `ApplicationSet`, installé avec Argo CD, génère une `Application` par entrée |

## 3. Le fichier : `argocd/eshop.yaml`

Le fichier complet : [argocd/eshop.yaml](../../argocd/eshop.yaml). Il est rangé à la racine du dépôt, dans son propre dossier : il ne fait partie ni d'un chart ni du laboratoire.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: eshop
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - list:
        elements:
          - {release: eshop-platform, chart: eshop-platform}
          - {release: postgres, chart: postgres}
          - {release: redis, chart: redis}
          - {release: rabbitmq, chart: rabbitmq}
          - {release: identity-api, chart: eshop-service}
          # ... les huit autres services, tous sur eshop-service
  # Supprimer l'ApplicationSet ne supprime pas les objets déployés (PostgreSQL et ses données compris)
  syncPolicy:
    preserveResourcesOnDeletion: true
  template:
    metadata:
      name: '{{.release}}'
      labels:
        app.kubernetes.io/part-of: eshop
    spec:
      project: default
      source:
        repoURL: https://github.com/josuekabangu/EshopOnContainer.git
        targetRevision: main
        path: 'helm/{{.chart}}'
        helm:
          releaseName: '{{.release}}'
          # Chemin relatif au chart : les fichiers de valeurs sont dans helm/values/
          valueFiles:
            - '../values/{{.release}}.yaml'
      destination:
        server: https://kubernetes.default.svc
        namespace: eshop
      syncPolicy:
        syncOptions:
          - ServerSideApply=true
```

Ceci est la version du 23 octobre 2026. Sa `syncPolicy` n'a pas de section `automated` : Argo CD compare, mais ne modifie rien sans qu'on le lui demande. La synchronisation automatique et l'option `CreateNamespace=true` ont été ajoutées une fois la reprise vérifiée ([guide 03](03-synchronisation-automatique.md)).

| Ligne | Rôle |
|---|---|
| `goTemplate: true`, `missingkey=error` | Les modèles `{{.release}}` suivent la syntaxe de Go, comme Helm. Une clé mal orthographiée fait échouer la génération au lieu de produire un nom vide |
| `releaseName: '{{.release}}'` | Argo CD rend le chart par `helm template` avec ce nom de release. Les charts nomment leurs objets avec `.Release.Name` : sans cette ligne, le nom serait celui de l'`Application`, ici le même, mais la dépendance resterait implicite |
| `valueFiles: ['../values/{{.release}}.yaml']` | Le chemin est relatif au dossier du chart, d'où le `../` : les fichiers de valeurs sont dans `helm/values/`, à côté des charts |
| `targetRevision: main` | Argo CD suit la branche principale, où le robot de la CI écrit les étiquettes |
| `ServerSideApply=true` | Helm 4 appliquait déjà les objets côté serveur ([docs/04-helm/02-reprise.md](../04-helm/02-reprise.md)). Argo CD fait de même : chaque outil n'est propriétaire que des champs qu'il écrit |
| `preserveResourcesOnDeletion: true` | Sans elle, supprimer l'`ApplicationSet` supprimerait les 13 `Application`, puis tous leurs objets. Le volume de PostgreSQL survivrait (`whenDeleted: Retain`), mais l'application serait coupée |

## 4. La première comparaison

Dans WSL2, à la racine du dépôt :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }
kubectl apply -f - < argocd/eshop.yaml
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision
```

`kubectl` s'exécute sur `kube-control` : le fichier lui est envoyé par l'entrée standard (`-f -` et `<`), puisqu'il est sur le poste et non sur la VM. Le chemin est relatif à la racine du dépôt : lancée depuis `lab-local/ansible`, la commande répond `No such file or directory`.

Résultats vérifiés le 23 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| `ApplicationSet` | Créé à 14:30 UTC, conditions `ParametersGenerated` et `ResourcesUpToDate` à `True` |
| `Application` | Les 13, toutes `OutOfSync Healthy`, sur le commit `b9ead53` |
| Objets | **Tous** `OutOfSync`, dans les 13 applications |

`Healthy` dit que les objets fonctionnent. `OutOfSync` dit qu'ils diffèrent de ce que le dépôt produit. Le détail des écarts, dans l'interface (*Diff* de chaque application), en montre trois sortes :

| Écart | Objets concernés | Nature |
|---|---|---|
| L'annotation `argocd.argoproj.io/tracking-id` manque | Tous | Attendu : c'est par elle qu'Argo CD reconnaît les objets qu'il gère. Les objets créés par Helm ne l'ont pas ; la synchronisation l'ajoute |
| L'étiquette de l'image : `b59f061` dans le cluster, `5abbd6a` dans le dépôt | Les 9 `Deployment` | Attendu : la CI a écrit `5abbd6a` après le dernier `deploy.sh` ([docs/05-ci/02-etiquettes-helm.md](../05-ci/02-etiquettes-helm.md), section 5) |
| Des champs présents dans le cluster, absents du chart | Les `StatefulSet` et les `HTTPRoute` | **Permanent** : voir la section suivante |

## 5. Les deux écarts permanents

### La cause commune

À l'enregistrement d'un objet, le serveur d'API de Kubernetes **complète** certains champs laissés vides par leur valeur par défaut. L'objet stocké contient donc plus que ce que le chart a envoyé. Argo CD compare ce que produit le chart avec ce qui est stocké : un champ ajouté par le serveur apparaît comme un écart, que la synchronisation ne fait pas disparaître, puisque le serveur le rajoute à chaque fois.

La correction retenue : **écrire ces valeurs par défaut dans les charts**. L'objet envoyé est alors identique à l'objet stocké. C'est le serveur qui fixe ces valeurs : les écrire ne change rien au fonctionnement.

### Les `volumeClaimTemplates` des trois `StatefulSet`

Le serveur ajoute `apiVersion: v1` et `kind: PersistentVolumeClaim` à chaque modèle de volume. Dans les charts `postgres`, `redis` et `rabbitmq` (commit `18d5653`) :

```yaml
  # Non modifiable : reproduit à l'identique, sans étiquette.
  # apiVersion et kind sont ajoutés par Kubernetes à l'enregistrement ; les écrire évite
  # un écart permanent avec Argo CD
  volumeClaimTemplates:
    - apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: data
```

`volumeClaimTemplates` est un champ non modifiable ([docs/04-helm/03-dependances-plateforme.md](../04-helm/03-dependances-plateforme.md)). Il fallait donc s'assurer que l'objet envoyé reste **identique** à celui du cluster, ce que vérifie la commande donnée plus bas.

La version des charts est restée `0.1.0` : la changer aurait modifié l'étiquette `helm.sh/chart` dans le modèle de pod, et redémarré les trois dépendances sans raison.

### Les `HTTPRoute` des trois services exposés

Celui-ci n'est apparu qu'**après** la première synchronisation : `identity-api`, `webapp` et `webhook-client`, les trois services qui ont une `HTTPRoute`, restaient `OutOfSync`. Le schéma de Gateway API complète la référence au `Gateway`, la règle de chemin et la référence au `Service`. Dans le modèle `helm/eshop-service/templates/httproute.yaml` (commit `5633b96`) :

```yaml
# Les valeurs par défaut du schéma de Gateway API sont écrites : Kubernetes les ajoute
# à l'enregistrement, et Argo CD verrait sinon un écart permanent
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: eshop
  hostnames:
    - {{ required "route.hostname est obligatoire quand route.enabled vaut true" .Values.route.hostname }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: {{ .Release.Name }}
          port: {{ .Values.port }}
          weight: 1
```

### Vérifier qu'une correction ne change rien au cluster

Avant chaque commit, dans WSL2, à la racine du dépôt :

```bash
for d in postgres redis rabbitmq; do
  echo "== $d"
  helm template "$d" "helm/$d" -n eshop -f "helm/values/$d.yaml" \
    | kubectl diff --server-side --force-conflicts -f -
done
```

`helm template` produit les objets du chart, sans rien envoyer. `kubectl diff --server-side` demande au serveur ce que deviendraient les objets s'ils étaient appliqués, valeurs par défaut comprises, et le compare à l'existant. **Une sortie vide signifie que la correction ne modifierait aucun objet du cluster.**

| Correction | Résultat de `kubectl diff`, 25 octobre 2026 |
|---|---|
| `volumeClaimTemplates` | Vide pour `postgres`, `redis` et `rabbitmq` |
| `HTTPRoute` | Vide pour `identity-api`, `webapp` et `webhook-client` |

**Leçon :** un écart qui ne disparaît pas après une synchronisation n'est pas une panne d'Argo CD. C'est presque toujours une valeur ajoutée par le serveur. Le *Diff* de l'interface montre laquelle.

## 6. La reprise : une synchronisation à la main

La synchronisation a été lancée depuis l'interface (bouton *Sync* de chaque application), le 25 octobre 2026, en deux temps :

1. `eshop-platform`, `postgres`, `redis` et `rabbitmq`. Pour elles, le seul écart restant était l'annotation de suivi : rien ne devait redémarrer ;
2. les neuf services, qui passent aux images `5abbd6a`.

Puis, dans WSL2 :

```bash
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n eshop get pods
kubectl -n eshop get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
SH
```

Résultats vérifiés le 25 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Applications | 10 `Synced Healthy` ; `identity-api`, `webapp` et `webhook-client` `OutOfSync Healthy`, à cause des `HTTPRoute` |
| Dépendances | `postgres-0`, `redis-0` et `rabbitmq-0` non redémarrés : 2 jours et 18 heures d'âge |
| Services | Les 9 recréés, sur `ghcr.io/josuekabangu/<service>:5abbd6a`, 0 redémarrage |
| Files RabbitMQ | Les 7, avec 1 consommateur chacune |

Après le commit `5633b96` des `HTTPRoute`, les 13 applications sont passées `Synced Healthy` sur ce commit, **sans nouvelle synchronisation** : l'objet du cluster était déjà celui que produisait le chart corrigé, seule la comparaison a changé.

Le 30 octobre 2026, cinq jours après un redémarrage de Windows et des deux machines virtuelles, l'état était le même, sans aucune commande entre les deux : les 13 applications `Synced Healthy`, les 12 pods `Running` avec exactement un redémarrage chacun (celui des machines), les 7 files RabbitMQ avec leur consommateur.

## 7. Les limites

| Limite | Conséquence |
|---|---|
| Le projet Argo CD `default` | Il autorise n'importe quel dépôt et n'importe quelle destination. En équipe, un `AppProject` limite chaque application à son dépôt et à son espace de noms |
| Le dépôt est lu sans authentification | Possible parce qu'il est public. Un dépôt privé demanderait un secret d'accès, chiffré comme les autres |
| La liste des 13 releases est écrite deux fois | Dans `argocd/eshop.yaml` et dans `helm/deploy.sh`. Ce dernier est conservé comme trace seulement ([guide 03](03-synchronisation-automatique.md)) |

## 8. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# État des 13 applications et commit suivi
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision

# État de chaque objet d'une application
kubectl -n argocd get application webapp -o 'jsonpath={range .status.resources[*]}{.kind}/{.name} {.status}{"\n"}{end}'

# Ce que changerait un chart, comparé au cluster (sortie vide : rien)
helm template webapp helm/eshop-service -n eshop -f helm/values/webapp.yaml \
  | kubectl diff --server-side --force-conflicts -f -
```

## 9. Étape suivante

Confier la synchronisation à Argo CD, retirer Helm de la boucle, et prouver la chaîne complète du commit au cluster : [03-synchronisation-automatique.md](03-synchronisation-automatique.md).
