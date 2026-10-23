# 01 — La construction des images par GitHub Actions

## 1. Objectif

Jusqu'ici, les neuf images d'eShop étaient construites dans le Docker de WSL2, puis publiées à la main sur `ghcr.io` avec un jeton personnel ([docs/03-kubernetes/01-registre-images.md](../03-kubernetes/01-registre-images.md)). Ce guide confie ce travail à GitHub Actions :

- chaque push sur `main` qui touche au code ou aux `Dockerfile` reconstruit les neuf images ;
- elles sont publiées sur `ghcr.io`, étiquetées par le commit, sans jeton personnel ;
- l'image indique le dépôt et le commit dont elle provient.

**État au 22 octobre 2026 :** le workflow `.github/workflows/images.yml` construit et publie les neuf images en 2 min 7, et en 32 s quand le cache des couches est rempli. Il s'authentifie avec le seul jeton fourni par GitHub à chaque exécution.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Un workflow par service, ou un seul ? | **Un seul**, avec une matrice de neuf entrées | Les neuf constructions sont identiques à part le nom et le `Dockerfile`. Une correction se fait une fois |
| Quand ? | Push sur `main` touchant `application/`, `docker/src/`, `.dockerignore` ou le workflow, et lancement à la main (`workflow_dispatch`) | Une modification de la documentation ou de `helm/` ne reconstruit rien |
| Un service en échec | `fail-fast: false` : les huit autres continuent | Une erreur dans un service ne masque pas l'état des autres |
| L'étiquette | `${GITHUB_SHA::7}`, les sept premiers caractères du commit | La convention déjà en place : `87e28f8`, `a6647c9` ([01-registre-images.md](../03-kubernetes/01-registre-images.md)) |
| L'authentification | `GITHUB_TOKEN`, avec la permission `packages: write` | Jeton créé par GitHub pour l'exécution et expiré à sa fin : aucun secret à stocker ni à renouveler |
| Les actions utilisées | Désignées par l'**empreinte de leur commit**, la version en commentaire | Une étiquette comme `v7` peut être déplacée vers un autre code ; une empreinte, non. C'est la recommandation de GitHub pour les actions tierces |
| Le cache | `type=gha`, une portée par service | Les couches de .NET restaurées sont réutilisées ; sans portée distincte, les neuf services écraseraient le même cache |
| Les étiquettes OCI | `org.opencontainers.image.source` et `org.opencontainers.image.revision` | La première relie le paquet au dépôt sur GitHub ; la seconde donne le commit complet |

Les droits sont limités au strict nécessaire : `contents: read` pour lire le dépôt, `packages: write` pour publier. Le job décrit au [guide 02](02-etiquettes-helm.md) reçoit en plus, pour lui seul, `contents: write`.

## 3. Le workflow

Le fichier complet : [.github/workflows/images.yml](../../.github/workflows/images.yml). La partie construction :

```yaml
on:
  push:
    branches: [main]
    paths:
      - application/**
      - docker/src/**
      - .dockerignore
      - .github/workflows/images.yml
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build:
    name: ${{ matrix.service }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - service: identity-api
            dockerfile: docker/src/Identity.API/Dockerfile
          # ... les huit autres services
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
      - id: tag
        run: echo "tag=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069  # v4.4.1
      - uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f  # v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc  # v7.4.0
        with:
          context: .
          file: ${{ matrix.dockerfile }}
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/${{ matrix.service }}:${{ steps.tag.outputs.tag }}
          labels: |
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
          cache-from: type=gha,scope=${{ matrix.service }}
          cache-to: type=gha,mode=max,scope=${{ matrix.service }}
```

Le contexte de construction est la racine du dépôt, comme en local ([docs/02-docker/01-catalog-api.md](../02-docker/01-catalog-api.md)) : les `Dockerfile` n'ont pas changé.

Deux réglages en tête du fichier, ajoutés après le premier lancement :

| Réglage | Rôle |
|---|---|
| `concurrency: {group: images, cancel-in-progress: false}` | Deux exécutions ne tournent jamais en même temps : la seconde attend. Aucune n'est annulée, pour qu'aucune image publiée ne reste sans étiquette écrite ([guide 02](02-etiquettes-helm.md)) |
| `DOCKER_BUILD_RECORD_UPLOAD: false` | `docker/build-push-action` joint par défaut à chaque exécution un compte rendu de construction, affiché comme « Artifacts ». Il n'est pas utilisé ici |

## 4. Le droit de publier sur des paquets déjà existants

### L'erreur

Le premier lancement a échoué sur les neuf services, à la publication :

```text
denied: permission_denied: read_package
```

### La cause

Les neuf paquets `ghcr.io/josuekabangu/<service>` existaient déjà : ils avaient été créés par la publication manuelle, avec le jeton personnel. Un paquet créé ainsi n'est **relié à aucun dépôt**. Le `GITHUB_TOKEN` d'un workflow n'a de droits que sur les paquets reliés à son dépôt, ou que ce dépôt a été autorisé à utiliser : la permission `packages: write` du workflow ne suffit pas.

Un paquet créé par le workflow lui-même aurait été relié au dépôt automatiquement.

### La correction

Pour chacun des neuf paquets, sur GitHub : *Packages* → le paquet → *Package settings* → section **« Manage Actions access »** → *Add Repository* → `EshopOnContainer`, rôle **Write**.

Un premier essai avait ajouté le dépôt dans la section voisine, **« Manage Codespaces access »**, avec le rôle Read. Elle ne concerne que les environnements Codespaces, et l'erreur restait la même. Après la correction, « Re-run failed jobs » a réussi.

**Leçon :** la permission déclarée dans le workflow est un plafond, pas une autorisation. Le paquet doit aussi accepter le dépôt.

## 5. Vérifier

Dans l'onglet *Actions* du dépôt, l'exécution du commit `9065a63`, après correction des accès :

| Contrôle | Résultat, 22 octobre 2026 |
|---|---|
| Jobs | Les 9 verts |
| Durée totale | 2 min 7 ; de 1 min 7 (`webhooks-api`) à 1 min 58 (`catalog-api`) par job, en parallèle |
| Relance de la même exécution, cache rempli | 32 s au total ; de 17 s à 27 s par job |
| Images | `ghcr.io/josuekabangu/<service>:9065a63`, à côté des étiquettes `87e28f8` publiées à la main |

La liaison au dépôt se contrôle sur la page d'un paquet (« Connected to repository »), ou depuis WSL2 :

```bash
docker buildx imagetools inspect ghcr.io/josuekabangu/catalog-api:9065a63 \
  --format '{{json .Image.Config.Labels}}' | tr ',' '\n' | grep org.opencontainers
```

**Attendu :** `org.opencontainers.image.source` vaut l'adresse du dépôt, `org.opencontainers.image.revision` le commit complet.

## 6. Les limites

| Limite | Conséquence |
|---|---|
| Aucun test n'est lancé avant la construction | Une image qui compile est publiée, même si le code est faux. Les tests d'eShop et une analyse des images (Trivy) viendront s'ajouter avant la publication |
| Les charts ne sont pas validés par la CI | Une erreur dans `helm/` n'est découverte qu'au déploiement. Un contrôle `helm lint` et `helm template` reste à ajouter |
| Les neuf images sont reconstruites à chaque fois | Même si un seul service a changé. Le cache rend ce coût faible (32 s) ; construire seulement les services modifiés compliquerait le workflow pour un gain réduit |
| Le compte rendu de construction désactivé | Non vérifié : les captures disponibles montrent encore l'ancienne exécution, d'avant le réglage |

La publication manuelle décrite dans [01-registre-images.md](../03-kubernetes/01-registre-images.md) reste possible, par exemple si GitHub Actions est indisponible. Le jeton personnel `write:packages` n'est plus nécessaire au fonctionnement courant.
