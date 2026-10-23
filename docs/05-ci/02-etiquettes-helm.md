# 02 — Les étiquettes des images écrites dans `helm/values/`

## 1. Objectif

Le [guide 01](01-construction-images.md) publie les images, mais rien ne les utilise : les fichiers de valeurs de Helm pointent toujours vers les étiquettes publiées à la main. Pour qu'un outil GitOps, Argo CD à l'étape suivante, déploie ce que la CI produit, la nouvelle étiquette doit être **écrite dans le dépôt**. Le dépôt reste ainsi la seule description de ce qui doit tourner.

Ce guide ajoute au workflow un second job qui, après la publication des neuf images, remplace l'étiquette dans les neuf fichiers `helm/values/<service>.yaml` et pousse un commit sur `main`.

**État au 23 octobre 2026 :** chaque exécution réussie écrit son étiquette dans les neuf fichiers, par un commit de `github-actions[bot]`, sans relancer le workflow. Les images ainsi désignées, déployées par `helm/deploy.sh`, font fonctionner toute l'application.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Où | Un second job, `update-values`, avec `needs: build` | Il ne démarre que si **les neuf** constructions ont réussi : jamais une étiquette qui désigne une image absente |
| Comment | `sed` sur les neuf fichiers, puis commit et push sur `main` | Le plus simple pour apprendre le mécanisme |
| Droits | `contents: write`, pour ce job seulement | Les neuf constructions gardent `contents: read` |
| Auteur du commit | `github-actions[bot]`, adresse `41898282+github-actions[bot]@users.noreply.github.com` | L'identité officielle du robot de GitHub Actions : les commits s'affichent sous son nom et son avatar |

En entreprise, cette mise à jour passe souvent par une **demande de fusion** relue avant d'atteindre la branche principale, ou par un outil dédié comme Argo CD Image Updater. Le commit direct pourra être remplacé par une demande de fusion plus tard.

### Pas de boucle

Le commit du robot ne relance pas le workflow, pour deux raisons indépendantes :

1. un push fait avec le `GITHUB_TOKEN` ne déclenche **aucun** workflow : GitHub l'interdit précisément pour éviter les boucles ;
2. `helm/` ne fait pas partie des chemins surveillés par le workflow.

### Les fins de ligne

Les fichiers de `helm/values/` ont des fins de ligne CRLF. L'expression ne remplace que l'empreinte, `[0-9a-f]+`, et laisse le retour chariot en place : chaque fichier ne change que d'une ligne, sans devenir mixte.

## 3. Le job

```yaml
  update-values:
    name: Étiquettes dans helm/values
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1

      - name: Écrire la nouvelle étiquette dans les fichiers de valeurs
        run: |
          TAG="${GITHUB_SHA::7}"
          for s in identity-api catalog-api basket-api ordering-api order-processor \
                   payment-processor webhooks-api webapp webhook-client; do
            sed -i -E "s/^(  tag: )[0-9a-f]+/\1${TAG}/" "helm/values/${s}.yaml"
          done
          git diff --stat

      - name: Commiter et pousser
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add helm/values/
          if git diff --cached --quiet; then
            echo "Étiquettes déjà à jour"
          else
            git commit -m "CI : images ${GITHUB_SHA::7} dans helm/values"
            git pull --rebase origin main
            git push
          fi
```

| Ligne | Rôle |
|---|---|
| `git diff --cached --quiet` | Une relance de la même exécution n'a rien à commiter : le job réussit sans commit vide |
| `git pull --rebase origin main` | `main` a pu avancer pendant les constructions. Le commit du robot est replacé au-dessus, sinon le push serait refusé (*non-fast-forward*) |

`git pull --rebase` et `concurrency` ([guide 01](01-construction-images.md#3-le-workflow)) se complètent : le second empêche deux exécutions de pousser en même temps, le premier gère un push humain survenu pendant la construction.

## 4. Vérifier

### Le commit du robot

Après le push du commit `b59f061`, qui ajoutait ce job :

```bash
git pull
grep -h 'tag:' helm/values/*.yaml | sort | uniq -c
```

Résultat vérifié le 22 octobre 2026 :

```text
Updating b59f061..26a0ae8
Fast-forward
 helm/values/basket-api.yaml        | 2 +-
 ...
 helm/values/webhooks-api.yaml      | 2 +-
 9 files changed, 9 insertions(+), 9 deletions(-)
      9   tag: b59f061
```

| Contrôle | Résultat |
|---|---|
| Commit du robot | `26a0ae8`, une ligne par fichier : les fins de ligne sont intactes |
| Étiquettes | Les neuf à `b59f061`. Les anciennes, `87e28f8` et `a6647c9` pour `webhook-client`, ont disparu |
| Pas de boucle | Un second `git pull` répond `Already up to date` : aucune nouvelle exécution |

L'étiquette désigne le commit **construit**, `b59f061`, et non `26a0ae8`, le dernier commit de `main`. C'est attendu : le commit du robot ne modifie que des fichiers de valeurs, il n'y a aucune image à construire pour lui.

Le 23 octobre, l'exécution suivante (commit `5abbd6a`, ajout du `git pull --rebase`) a de même écrit `5abbd6a` dans les neuf fichiers.

### Les images de la CI sur le cluster

Les images précédentes avaient été construites dans WSL2. Il fallait prouver que celles de GitHub Actions fonctionnent aussi :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }
time bash helm/deploy.sh
kubectl -n eshop get pods
kubectl -n eshop get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
SH
```

Résultats vérifiés le 22 octobre 2026, sur les étiquettes `b59f061` :

| Contrôle | Résultat |
|---|---|
| Releases | 13 en `deployed`, révision 2, en 1 min 31 |
| Images | Les neuf `Deployment` en `ghcr.io/josuekabangu/<service>:b59f061` |
| Pods | 12 en `1/1 Running`, aucun redémarrage |
| Dépendances | `postgres-0`, `redis-0` et `rabbitmq-0` non recréés (138 min d'âge) |
| Files RabbitMQ | Les 7, avec 1 consommateur chacune |
| Parcours dans le navigateur | Connexion d'`alice`, commande jusqu'à `Paid`, webhook reçu : fonctionne |

Les quatre releases sans changement passent aussi en révision 2 : `helm upgrade` enregistre une révision à chaque lancement. Rien n'ayant changé dans leurs objets, Kubernetes n'a recréé aucun de leurs pods.

`webhook-client` tourne désormais sur la même étiquette que les autres services : l'image `b59f061` contient l'adaptation des cookies `a6647c9` ([docs/03-kubernetes/16-webhook-client.md](../03-kubernetes/16-webhook-client.md)), puisqu'elle est construite à partir d'un commit postérieur.

## 5. Les limites

| Limite | Conséquence |
|---|---|
| Le déploiement reste lancé à la main | Le cluster tourne en `b59f061` alors que le dépôt désigne `5abbd6a`. Argo CD, à l'étape suivante, rapprochera le cluster du dépôt sans intervention |
| Commit direct sur `main`, sans relecture | Acceptable pour un dépôt à une personne. En équipe, une demande de fusion |
| Le `git pull --rebase` n'a pas encore servi | Aucun push n'est survenu pendant une construction : le cas qu'il traite n'a pas été provoqué |
| Le nom des neuf services est écrit deux fois dans le workflow | Dans la matrice et dans la boucle du job `update-values`. Un service ajouté doit l'être aux deux endroits |
