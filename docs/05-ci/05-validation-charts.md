# 05 — La validation des charts Helm

## 1. Objectif

Les tests vérifient le code ([guide 03](03-tests.md)), Trivy vérifie les images ([guide 04](04-analyse-images.md)). Rien ne vérifiait encore **ce qui décrit le déploiement** : les charts de `helm/` et leurs fichiers de valeurs. Une erreur y était découverte seulement par Argo CD, sur le cluster :

| Erreur | Ce qu'on voyait sur le cluster |
|---|---|
| Erreur de rendu : un `required` non rempli, une faute dans un modèle, un `fail` déclenché | L'application en `ComparisonError` : plus rien ne se synchronise |
| Objet refusé par Kubernetes : champ mal orthographié, mauvais type | L'application `Degraded` ou bloquée en synchronisation |
| Valeur acceptée par tous mais fausse | Visible seulement quand les pods tournent, comme l'étiquette `3045452` lue comme un nombre ([guide 03, section 5](03-tests.md)) |

Ce guide ajoute un contrôle des charts **avant** qu'Argo CD ne les lise.

**État au 28 novembre 2026 :** les 13 releases passent `helm lint` et `helm template` en local. Dans le workflow `images.yml`, le rendu des 9 services est vérifié après l'écriture des étiquettes par le robot et avant son commit ; le blocage a été prouvé en simulant la panne du 26 novembre. Le workflow dédié aux modifications faites à la main dans `helm/` reste à écrire (section 7).

## 2. Les trois niveaux de contrôle

| Niveau | Outil | Ce qu'il vérifie | Ce qu'il ne voit pas |
|---|---|---|---|
| 1. Structure | `helm lint` | `Chart.yaml`, la syntaxe des modèles, un rendu possible avec les valeurs données, des bonnes pratiques | Les valeurs réelles d'une release, si on ne les lui donne pas |
| 2. Rendu | `helm template` | Le rendu **exact** d'une release, avec son nom et son fichier de valeurs : `required`, `fail`, erreurs de modèle, YAML produit invalide | Si les objets produits sont acceptés par Kubernetes |
| 3. Schéma | `kubeconform` | Chaque objet rendu contre le schéma de l'API Kubernetes : champ inconnu, mauvais type, champ obligatoire absent | Ce qui dépend du cluster : un Secret absent, une image inexistante, un webhook d'admission |

Un quatrième niveau, `kubectl apply --dry-run=server`, ferait valider les objets par le vrai serveur d'API, CRD comprises. Il est impossible ici : le cluster est sur un poste personnel, GitHub ne peut pas le joindre.

### Une précision sur la panne `3.045452e+06`

Aucun de ces trois niveaux n'aurait arrêté la panne **d'origine** : le rendu était valide, et `ghcr.io/…:3.045452e+06` est une chaîne correcte pour un schéma. Seul Kubernetes, en créant le pod, a refusé le `+`. C'est le garde-fou ajouté ensuite dans le modèle (`kindIs "string"` puis `fail`, [guide 01 de Helm](../04-helm/01-chart-commun.md)) qui transforme ce cas en **erreur de rendu**. Le contrôle de ce guide sert à déclencher ce garde-fou avant le cluster.

## 3. Rendre comme Argo CD

Un contrôle n'a de valeur que s'il rend les charts **avec les mêmes entrées qu'Argo CD**. L'ApplicationSet ([argocd/eshop.yaml](../../argocd/eshop.yaml)) rend chaque release ainsi :

```text
chart    : helm/<chart>
release  : <release>                    (les noms des objets en dépendent)
valeurs  : helm/values/<release>.yaml
namespace: eshop
```

Il y a 13 releases pour 5 charts, dont 9 avec `eshop-service`. `helm lint helm/eshop-service` sans fichier de valeurs ne vérifierait que les valeurs par défaut (`tag: ""`), pas ce qui est déployé : il faut rendre **13 fois**.

## 4. La base locale

Dans WSL2, à la racine du dépôt, le 27 novembre 2026 :

```bash
helm version --short
for r in eshop-platform:eshop-platform postgres:postgres redis:redis rabbitmq:rabbitmq \
         identity-api:eshop-service catalog-api:eshop-service basket-api:eshop-service \
         ordering-api:eshop-service order-processor:eshop-service payment-processor:eshop-service \
         webhooks-api:eshop-service webapp:eshop-service webhook-client:eshop-service; do
  release=${r%%:*}; chart=${r##*:}
  echo "===== $release ($chart)"
  helm lint "helm/$chart" -f "helm/values/$release.yaml" 2>&1 | tail -n 3
  helm template "$release" "helm/$chart" -f "helm/values/$release.yaml" -n eshop > /dev/null \
    && echo "rendu : OK"
done
```

| Élément | Rôle |
|---|---|
| `${r%%:*}` et `${r##*:}` | Découpent `basket-api:eshop-service` en release et chart, comme l'ApplicationSet |
| `tail -n 3` | Garde la fin de `helm lint` : les messages et le bilan |
| `> /dev/null` | Le rendu n'est pas affiché : on veut seulement savoir s'il réussit |

| Contrôle | Résultat |
|---|---|
| Version | `v4.3.1+gc0d08d0` |
| `helm lint` | 13 fois `1 chart(s) linted, 0 chart(s) failed` |
| `helm template` | 13 fois `rendu : OK` |
| Messages | `[INFO] Chart.yaml: icon is recommended` sur chacun des 5 charts |

Le message `icon is recommended` est **accepté** : c'est une information, pas un avertissement, et il ne fait pas échouer le lint. Une icône sert à présenter un chart dans un catalogue public comme Artifact Hub ; ces charts n'y sont pas publiés.

## 5. Le contrôle des étiquettes écrites par le robot

### Le piège du déclencheur

Le fichier de `helm/` le plus souvent modifié, c'est `helm/values/<service>.yaml`, **par le robot**, à chaque exécution. Or un push fait avec le `GITHUB_TOKEN` ne déclenche aucun workflow ([guide 02](02-etiquettes-helm.md)). Un workflow déclenché « sur push dans `helm/**` » ne verrait donc **jamais** les commits du robot, alors que la panne du 26 novembre venait d'eux.

Le contrôle des valeurs du robot est donc placé **dans son propre job**, `update-values`, entre l'écriture des étiquettes et le commit :

```text
sed (écrit les étiquettes) → Installer Helm → Vérifier le rendu → Commiter et pousser → Argo CD
                                                     │
                                                 en échec : rien n'est commité, Argo CD ne voit rien
```

### Les deux étapes

Le fichier complet : [.github/workflows/images.yml](../../.github/workflows/images.yml).

```yaml
      # Helm épinglé : même version qu'en local, archive vérifiée par sa somme SHA-256
      - name: Installer Helm
        env:
          HELM_VERSION: v4.3.1
          HELM_SHA256: 0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b
        run: |
          cd "$RUNNER_TEMP"
          curl -fsSLo helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
          echo "${HELM_SHA256}  helm.tgz" | sha256sum -c -
          tar -xzf helm.tgz linux-amd64/helm
          echo "$RUNNER_TEMP/linux-amd64" >> "$GITHUB_PATH"

      # Rendu des neuf services avec les étiquettes qui viennent d'être écrites, comme Argo CD le fera.
      # Un échec arrête le job avant le commit : Argo CD ne voit jamais des valeurs qui ne se rendent pas
      - name: Vérifier le rendu des charts
        run: |
          helm version --short
          for s in identity-api catalog-api basket-api ordering-api order-processor \
                   payment-processor webhooks-api webapp webhook-client; do
            echo "== $s"
            helm template "$s" helm/eshop-service -f "helm/values/${s}.yaml" -n eshop > /dev/null
          done
```

| Choix | Raison |
|---|---|
| Helm téléchargé, pas celui du runner | `ubuntu-latest` fournit un Helm dont la version change sans prévenir. Ici, c'est la même version qu'en local |
| Somme SHA-256 écrite dans le workflow | Relevée le 27 novembre 2026 avec `curl -fsSL https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz.sha256sum`. Si l'archive change sur le serveur, `sha256sum -c` échoue avant que le binaire soit utilisé |
| `cd "$RUNNER_TEMP"` | L'archive est téléchargée hors du dépôt : elle ne peut pas être commitée par erreur |
| Seulement `eshop-service` | Le robot ne modifie que les valeurs des 9 services |
| Pas de `set -e` | GitHub lance `run` avec `bash -e` : le premier rendu en échec arrête la boucle et le job |

## 6. Vérifier

### Le cas normal

Exécution n°12, commit `9e33b3a`, le 27 novembre 2026. Heures en UTC, relevées par l'API de GitHub :

| Contrôle | Résultat |
|---|---|
| Durée totale | 2 min 12 |
| `Étiquettes dans helm/values` | Vert en 7 s : les deux nouvelles étapes coûtent 1 s |
| `Installer Helm` | `helm.tgz: OK` : la somme correspond |
| `Vérifier le rendu des charts` | `v4.3.1+gc0d08d0`, puis les 9 lignes `== <service>` sans erreur |
| Commit du robot | `741902f`, « CI : images 9e33b3a dans helm/values » |
| Cluster | 13 applications `Synced Healthy` sur `741902f`, les 9 images en `:9e33b3a` |

### La preuve du blocage

La panne du 26 novembre ne se reproduit pas à la demande : il faudrait un commit dont l'empreinte ne contient que des chiffres. Elle a donc été **simulée** : dans le commit `48b6fd9`, le `sed` du robot écrit une étiquette en chiffres, sans guillemets.

```bash
            sed -i -E "s/^(  tag: )\"?[0-9a-f]+\"?/\11234567/" "helm/values/${s}.yaml"
```

`\11234567` se lit `\1` puis `1234567` : `sed` ne connaît que les références `\1` à `\9`.

La ligne a d'abord été essayée en local, sur une copie d'un fichier de valeurs :

```bash
s=identity-api
tmp=$(mktemp --suffix=.yaml)
cp "helm/values/$s.yaml" "$tmp"
sed -i -E "s/^(  tag: )\"?[0-9a-f]+\"?/\11234567/" "$tmp"
grep -n '^  tag:' "helm/values/$s.yaml" "$tmp"
helm template "$s" helm/eshop-service -f "$tmp" -n eshop > /dev/null; echo "code de sortie : $?"
rm "$tmp"
```

```text
/tmp/tmp.….yaml:4:  tag: 1234567
Error: execution error at (eshop-service/templates/deployment.yaml:33:10): image.tag doit être une chaîne : mettre l'étiquette entre guillemets
code de sortie : 1
```

Puis en CI, exécution n°13 du 28 novembre 2026 :

| Contrôle | Résultat |
|---|---|
| `Tests unitaires` | Vert, 1 min 01 |
| Les 9 constructions, avec Trivy | Vertes, de 43 s à 54 s |
| `Étiquettes dans helm/values` | **Rouge** en 6 s |
| `Vérifier le rendu des charts` | `== identity-api`, puis le même message qu'en local, à `deployment.yaml:33:10`, puis `exit code 1` |
| `Commiter et pousser` | Ignoré |
| Dépôt | Aucun commit du robot après `48b6fd9` |
| Images `:48b6fd9` | Publiées sur ghcr.io, jamais désignées par un fichier de valeurs |
| Cluster | Argo CD n'a rien reçu de nouveau : il reste sur `741902f`, les images en `:9e33b3a` |
| Durée totale | 2 min 8 |

La simulation a été annulée dans le commit `c5705d5` ; `git diff 9e33b3a -- .github/workflows/images.yml` ne montre plus aucune différence. L'exécution n°14 qui a suivi est verte en 2 min 19 : les 9 rendus passent et le robot commite `c618b35` avec l'étiquette `c5705d5`. Le cluster l'a suivi : les 9 images en `:c5705d5`.

**Leçon :** un garde-fou dans un modèle ne protège que si quelque chose le déclenche avant le cluster. Le 26 novembre, il n'existait pas ; aujourd'hui, il existe et il est exécuté entre la modification automatique et le déploiement automatique.

## 7. Les limites

| Limite | Conséquence |
|---|---|
| Les modifications faites à la main dans `helm/` et `argocd/` ne sont pas encore contrôlées | Un chart cassé poussé seul n'est vu qu'au déploiement. Un workflow dédié, déclenché sur ces chemins, avec `helm lint`, le rendu des 13 releases et `kubeconform`, reste à écrire |
| Le rendu ne valide pas les objets | Un champ mal orthographié dans un `Deployment` passe `helm template`. C'est le rôle de `kubeconform`, prévu dans le workflow dédié |
| La somme SHA-256 vient du même serveur que l'archive | Elle garantit que le binaire reste celui publié le 27 novembre 2026, pas qu'il est authentique. La signature GPG (`.asc`), vérifiée avec la clé des mainteneurs de Helm, le prouverait |
| La liste des 9 services est écrite trois fois dans `images.yml` | La matrice, le `sed` et le rendu. Un service ajouté doit l'être aux trois endroits |
| Les valeurs elles-mêmes ne sont pas décrites | Un fichier `values.schema.json` dans le chart ferait refuser par Helm, et donc par Argo CD, une étiquette qui n'est pas une chaîne de 7 caractères hexadécimaux. Il remplacerait le garde-fou `kindIs` |
