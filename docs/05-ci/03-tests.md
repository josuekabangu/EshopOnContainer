# 03 — Les tests unitaires avant la construction des images

## 1. Objectif

Jusqu'ici, le workflow publiait toute image qui compile ([guide 01](01-construction-images.md#6-les-limites)). Depuis l'étape GitOps, une image publiée est **déployée sans intervention** : la CI écrit son étiquette dans `helm/values/` ([guide 02](02-etiquettes-helm.md)), puis Argo CD l'applique au cluster ([docs/06-gitops/03-synchronisation-automatique.md](../06-gitops/03-synchronisation-automatique.md)). Un code faux irait donc jusqu'au cluster.

Ce guide ajoute au workflow un premier job, `test`, qui lance les tests unitaires d'eShop. Les neuf constructions en dépendent : **si un test échoue, aucune image n'est construite**, aucune étiquette n'est écrite, et le cluster ne bouge pas.

**État au 26 novembre 2026 :** le job de tests passe en 1 min 8 à 1 min 10. Un test cassé volontairement a bloqué toute la suite de l'exécution. La mise en place a aussi révélé une panne indépendante des tests : une étiquette composée uniquement de chiffres, lue comme un nombre ([section 5](#5-leçon--létiquette-3045452-lue-comme-un-nombre)).

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Quels tests | Les quatre projets de tests unitaires : `Basket.UnitTests`, `Ordering.UnitTests`, `Application.UnitTests`, `eShop.AppHost.UnitTests` | Rapides et sans dépendance extérieure : ni base de données, ni Docker |
| `ClientApp.UnitTests` | Exclu | Il teste l'application mobile et demande l'outillage MAUI (`NETSDK1147`, *workload* `maui-tizen`), sans rapport avec les services déployés |
| Les tests fonctionnels | Pas encore | Ils démarrent PostgreSQL et RabbitMQ via Aspire et Docker : plus longs, à évaluer séparément |
| Où | Un job `test`, et `needs: test` sur le job `build` | Le blocage est garanti par GitHub : `build` ne démarre pas si `test` échoue, et `update-values` dépend déjà de `build` |
| Quel SDK | `actions/setup-dotnet` avec `global-json-file: application/eShop/global.json` | La version du SDK et le lanceur de tests sont ceux qu'eShop déclare, comme en local |
| La commande | `dotnet test --project <csproj>` | eShop utilise MSTest.Sdk avec Microsoft.Testing.Platform, déclaré dans `global.json` : `dotnet test` attend alors `--project` |
| Un projet en échec | La boucle lance quand même les suivants, puis échoue | Un seul passage montre l'état des quatre projets |
| Droits | `contents: read` pour ce job | Il ne publie rien |

## 3. Le job

Le fichier complet : [.github/workflows/images.yml](../../.github/workflows/images.yml).

```yaml
jobs:
  test:
    name: Tests unitaires
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
      - uses: actions/setup-dotnet@0f4a354dd5547a28c70b7853dbd95d5b67886e73  # v6.1.0
        with:
          global-json-file: application/eShop/global.json
      - name: Lancer les tests unitaires
        working-directory: application/eShop
        run: |
          status=0
          for p in Basket.UnitTests Ordering.UnitTests Application.UnitTests eShop.AppHost.UnitTests; do
            echo "::group::$p"
            dotnet test --project "tests/$p/$p.csproj" || status=1
            echo "::endgroup::"
          done
          exit $status

  build:
    name: ${{ matrix.service }}
    # Aucune image n'est construite si un test échoue
    needs: test
    # ... inchangé
```

| Élément | Rôle |
|---|---|
| `::group::` / `::endgroup::` | Chaque projet apparaît comme un bloc repliable dans le journal de GitHub Actions |
| `|| status=1` puis `exit $status` | Un échec est retenu sans interrompre la boucle, et le job échoue à la fin |
| L'empreinte de `setup-dotnet` | `0f4a354…` correspond à `v6.1.0`, vérifié par l'API de GitHub. Même règle que pour les autres actions ([guide 01](01-construction-images.md#2-les-choix)) |

## 4. Vérifier

### La base locale

Avant d'écrire le job, les tests ont été lancés en local dans le conteneur du SDK, sur le contenu du dernier commit uniquement, sans les fichiers de travail :

```bash
git archive HEAD application/eShop | docker run -i --rm mcr.microsoft.com/dotnet/sdk:10.0 sh -c '
  mkdir /w && tar -x -C /w && cd /w/application/eShop
  for p in Basket.UnitTests Ordering.UnitTests Application.UnitTests ClientApp.UnitTests eShop.AppHost.UnitTests; do
    echo "===== $p"
    dotnet test --project tests/$p/$p.csproj 2>&1 | tail -6
  done'
```

Résultats vérifiés le 24 novembre 2026 :

| Projet | Tests | Durée, compilation comprise |
|---|---|---|
| `Basket.UnitTests` | 8 réussis | 14 s |
| `Ordering.UnitTests` | 43 réussis | 9 s |
| `Application.UnitTests` | 13 réussis | 13 s |
| `eShop.AppHost.UnitTests` | 8 réussis | 17 s |
| `ClientApp.UnitTests` | Ne compile pas : `NETSDK1147`, *workload* MAUI manquant | — |

Au total, 72 tests réussis en 53 s environ.

### Le cas normal

Le push du workflow modifié, le commit `3045452`, a lancé l'exécution n°6. Durées relevées par l'API de GitHub, en heure UTC, le 26 novembre 2026 :

| Contrôle | Exécution n°6 (`3045452`) | Exécution n°8 (`963c953`) |
|---|---|---|
| `Tests unitaires` | Vert, 1 min 10 | Vert, 1 min 8 |
| Les 9 constructions | Démarrées **après** les tests (10:00:21 contre 10:00:19 pour la fin des tests), de 19 s à 2 min 25 | Démarrées après les tests, de 18 s à 26 s |
| `Étiquettes dans helm/values` | Vert, commit du robot `cf98894` | Vert, commit du robot `a2c3b95` |
| Durée totale | 3 min 49 | 1 min 46 |

À comparer aux 2 min 12 de l'exécution n°5 du 24 novembre, sans tests. Le job de tests ajoute environ 1 min 10 à chaque exécution, puisque les constructions l'attendent. L'exécution n°6 a été plus longue à cause de `basket-api`, construit en 2 min 25 contre moins d'une minute pour les autres : son cache n'a pas servi ce jour-là. La cause n'a pas été recherchée.

Les compteurs `Passed!` de chaque projet n'ont **pas été lus** dans le journal de la CI : GitHub n'affiche les journaux qu'aux utilisateurs connectés, et la capture a été faite sans connexion. Le job vert prouve qu'aucun test n'a échoué, pas qu'il y en a bien 72.

### La preuve du blocage

Un test de `Basket.UnitTests` a été faussé volontairement : la valeur attendue `42` est devenue `43`. Ce changement a été poussé seul, dans le commit `b84d4e1` :

```csharp
Assert.AreEqual(43, response.Items[0].ProductId);
```

Résultat, exécution n°7 du 26 novembre 2026 :

| Contrôle | Résultat |
|---|---|
| `Tests unitaires` | Rouge en 52 s, à l'étape `Lancer les tests unitaires`, 1 annotation d'erreur |
| Les 9 constructions | Jamais lancées : la liste des jobs de l'exécution ne montre que `Tests unitaires`. L'API les présente comme un seul job ignoré, nommé `matrix.service`, puisque la matrice n'a pas été développée |
| `Étiquettes dans helm/values` | Ignoré |
| Dépôt | Aucun commit du robot après `b84d4e1` |
| Durée totale | 55 s |

Le test cassé a ensuite été annulé par `git revert` (commit `ba9e8a0`), et poussé avec la correction de la section suivante.

## 5. Leçon : l'étiquette `3045452` lue comme un nombre

### Le symptôme

Après l'exécution n°6, le 26 novembre 2026, les neuf services n'avaient plus aucun pod prêt :

```text
NAME                          READY   STATUS             RESTARTS   AGE
basket-api-759f558757-9kpv4   0/1     InvalidImageName   0          142m
...
NOM          IMAGE
basket-api   ghcr.io/josuekabangu/basket-api:3.045452e+06
```

Argo CD affichait les neuf applications en `Synced Degraded`. PostgreSQL, Redis et RabbitMQ fonctionnaient.

### La cause

1. L'empreinte courte du commit, `3045452`, ne contient **que des chiffres**.
2. Le robot l'a écrite sans guillemets : `tag: 3045452`. YAML lit ce texte comme un **nombre entier**.
3. Helm range les nombres de ses valeurs en nombres à virgule. `{{ .Values.image.tag }}` les écrit alors en notation scientifique : `3.045452e+06`.
4. Le `+` est interdit dans un nom d'image : Kubernetes refuse le pod avec `InvalidImageName`, sans même essayer de télécharger l'image.

Les étiquettes précédentes, `0f0c6cc` ou `f9bbdda`, contenaient au moins une lettre et restaient donc du texte. Sept caractères hexadécimaux sont tous des chiffres environ une fois sur 27 : la panne était **latente depuis le premier commit du robot**. Une empreinte comme `1234e56` serait lue elle aussi comme un nombre, cette fois en notation scientifique.

Ni les tests ni Argo CD ne pouvaient la voir : le modèle se rendait sans erreur, et les objets étaient valides pour l'API de Kubernetes.

### La correction

Trois changements, poussés ensemble dans le commit `963c953` :

| Fichier | Changement |
|---|---|
| Les 9 fichiers `helm/values/<service>.yaml` | `tag: "3045452"`, entre guillemets |
| [.github/workflows/images.yml](../../.github/workflows/images.yml) | Le robot écrit toujours l'étiquette entre guillemets, et accepte l'ancienne forme sans guillemets |
| [helm/eshop-service/templates/deployment.yaml](../../helm/eshop-service/templates/deployment.yaml) | Le rendu échoue si l'étiquette n'est pas du texte |

La nouvelle ligne du workflow :

```bash
sed -i -E "s/^(  tag: )\"?[0-9a-f]+\"?/\1\"${TAG}\"/" "helm/values/${s}.yaml"
```

Le garde-fou dans le modèle :

```yaml
{{- if not (kindIs "string" .Values.image.tag) }}
{{- fail "image.tag doit être une chaîne : mettre l'étiquette entre guillemets" }}
{{- end }}
```

Avec ce garde-fou, une étiquette numérique fait échouer le rendu du chart. Argo CD affiche alors une erreur de synchronisation et **laisse en place** ce qui tourne, au lieu de déployer une image impossible.

`| quote` ou `| toString` dans le modèle n'auraient pas suffi : la valeur est déjà un nombre quand le modèle la reçoit, et `toString` produit lui aussi `3.045452e+06`.

### La validation

Vérifié le 26 novembre 2026 :

| Contrôle | Résultat |
|---|---|
| Garde-fou, valeurs encore sans guillemets | `helm template` échoue : `execution error at (eshop-service/templates/deployment.yaml:34:10): image.tag doit être une chaîne` |
| Rendu, valeurs entre guillemets | `image: "ghcr.io/josuekabangu/basket-api:3045452"` |
| Ligne du workflow, essai local | `tag: "3045452"` et `tag: 0f0c6cc` deviennent tous deux `tag: "1a2b3c4"` |
| Exécution n°8 | Verte ; commit du robot `a2c3b95` avec `tag: "963c953"`, entre guillemets |
| Cluster | Argo CD sur `a2c3b95` ; 13 applications `Synced Healthy` ; 9 Deployments en `:963c953` ; 12 pods `1/1 Running`, aucun redémarrage |

### Pourquoi le site était entièrement arrêté

Lors d'une mise à jour, un Deployment garde normalement l'ancien pod tant que le nouveau n'est pas prêt. Ici, `basket-api` n'avait que deux ReplicaSets : celui de `3.045452e+06`, âgé de 165 minutes comme `postgres-0`, et celui de `963c953`. **Aucun ReplicaSet de l'étiquette précédente, `0f0c6cc`, n'existait.** Les Deployments ont donc été créés directement avec la mauvaise étiquette, sur un cluster démarré après le commit du robot `cf98894` : il n'y avait aucun ancien pod à garder.

Sur un cluster déjà en service, la mise à jour aurait laissé les anciens pods en place. Ce cas n'a pas été vérifié.

**Leçon :** une valeur YAML sans guillemets n'est pas forcément du texte. Toute valeur qui *ressemble* à un nombre, comme une version, une étiquette ou un code, doit être écrite entre guillemets dès qu'un outil la génère.

## 6. Les limites

| Limite | Conséquence |
|---|---|
| Les compteurs de tests de la CI n'ont pas été lus | Le nombre de tests lancés par GitHub Actions n'est pas vérifié, seulement l'absence d'échec ([section 4](#le-cas-normal)) |
| `ClientApp.UnitTests` exclu | L'application mobile n'est pas testée. Elle n'est pas déployée par ce projet |
| Pas de tests fonctionnels | Les échanges avec PostgreSQL, RabbitMQ et les autres services ne sont testés que par le parcours dans le navigateur, à la main |
| Le job de tests précède les constructions | Environ 1 min 10 de plus à chaque exécution. Les lancer en parallèle publierait des images avant de connaître le résultat des tests |
| Le garde-fou ne couvre que `eshop-service` | Les charts `postgres`, `redis` et `rabbitmq` n'en ont pas besoin aujourd'hui : leur valeur `image` est le nom complet (`redis:7.4.11`), toujours du texte. Une étiquette seule comme `7.4` serait, elle, lue comme un nombre |
| Pas d'analyse des images | Une vulnérabilité connue dans une image n'est pas détectée. Trivy est l'étape suivante |
