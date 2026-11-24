# 03 — La synchronisation automatique, et la boucle complète du commit au cluster

## 1. Objectif

Après la reprise, Argo CD gère les 13 applications, mais il attend toujours qu'on lui dise de synchroniser ([guide 02](02-applicationset.md)). Helm, de son côté, garde l'historique de ses releases et pourrait encore les modifier. Deux outils pour un même cluster, et un geste manuel restant.

Ce guide :

- confie la synchronisation à Argo CD : ce qui est dans `main` est appliqué, ce qui est modifié à la main est annulé ;
- retire Helm de la boucle ;
- prouve la chaîne complète : un push de code, puis plus aucune commande, jusqu'à la nouvelle version en ligne.

**État au 2 novembre 2026 :** un commit poussé sur `main` est construit par GitHub Actions, son étiquette écrite dans `helm/values/`, puis déployé par Argo CD sur les neuf services, sans aucune intervention. Une modification manuelle du cluster est annulée en quelques secondes.

## 2. La synchronisation automatique

Dans le modèle d'`Application` d'[argocd/eshop.yaml](../../argocd/eshop.yaml) (commit `a0eb793`, 30 octobre 2026) :

```yaml
      # Synchronisation automatique, une fois la reprise vérifiée :
      # le cluster suit main, une modification manuelle est annulée, un objet retiré du dépôt est supprimé
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - ServerSideApply=true
          # Sur un cluster neuf, l'espace de noms eshop n'existe pas encore (deploy.sh le créait)
          - CreateNamespace=true
```

| Réglage | Effet | Sans lui |
|---|---|---|
| `automated` | Argo CD synchronise dès qu'il voit un nouveau commit sur `main` | Il signale `OutOfSync` et attend un clic |
| `selfHeal: true` | Il synchronise aussi quand c'est **le cluster** qui a changé : une modification faite à la main est annulée | Une modification manuelle reste en place jusqu'au commit suivant |
| `prune: true` | Un objet retiré du chart est supprimé du cluster | Il reste, orphelin, marqué à supprimer dans l'interface |
| `CreateNamespace=true` | L'espace de noms `eshop` est créé s'il manque | Sur un cluster neuf, la première synchronisation échoue : `deploy.sh` le créait (`--create-namespace`) |

Argo CD lit le dépôt de lui-même, par défaut toutes les 120 secondes avec un décalage aléatoire allant jusqu'à 60 secondes. Un commit est donc vu en 3 minutes au plus, sans webhook de GitHub vers le cluster : le laboratoire n'est pas joignable depuis Internet.

L'`ApplicationSet` modifié est appliqué comme au guide 02 :

```bash
kubectl apply -f - < argocd/eshop.yaml
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,AUTO:.spec.syncPolicy.automated.selfHeal,SYNC:.status.sync.status
```

Résultat vérifié le 30 octobre 2026 : `applicationset.argoproj.io/eshop configured`, et les 13 applications avec `AUTO` à `true`, toutes `Synced`.

## 3. Helm retiré de la boucle

### Pourquoi

Helm garde l'historique de chaque release dans des secrets de l'espace de noms : `sh.helm.release.v1.<release>.v<révision>`. Tant qu'ils existent, `helm upgrade` ou `helm rollback` peuvent modifier les objets qu'Argo CD gère. Argo CD annulerait aussitôt le changement : deux outils se disputeraient le cluster.

Argo CD n'utilise pas ces secrets. Il rend les charts par `helm template`, sans installer de release : `helm list` ne voit pas ses déploiements.

### Comment

```bash
kubectl -n eshop get secret -l owner=helm --no-headers | wc -l
kubectl -n eshop delete secret -l owner=helm
helm list -n eshop
kubectl -n eshop get pods
```

`owner=helm` est l'étiquette que Helm pose sur ses secrets d'historique : la sélection ne touche aucun autre secret.

Résultats vérifiés le 30 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Secrets d'historique | 26 supprimés : les révisions 1 et 2 de chacune des 13 releases |
| `helm list -n eshop` | Vide : Helm a oublié les releases |
| Pods | Les 12 inchangés : même âge, aucun redémarrage. Supprimer l'historique ne supprime aucun objet |

Les objets gardent l'étiquette `app.kubernetes.io/managed-by: Helm`. Elle ne vient pas de l'historique mais des modèles des charts, qu'Argo CD rend toujours par Helm : elle est donc attendue, et ne crée aucun écart.

**Conséquence :** revenir à une version précédente ne passe plus par `helm rollback`, mais par Git. `git revert` du commit fautif, puis push : Argo CD applique l'état précédent.

### `helm/deploy.sh` conservé comme trace

Le script n'est pas supprimé : il montre l'étape Helm du projet. Lancé sur un cluster géré par Argo CD, il recréerait des releases en concurrence avec lui. Il refuse donc désormais de s'exécuter, sauf demande explicite :

```bash
# Historique depuis le 25 octobre 2026 : le déploiement est confié à Argo CD (argocd/eshop.yaml).
# Lancé sur un cluster géré par Argo CD, ce script entrerait en concurrence avec lui.
# Conservé comme trace de l'étape Helm (docs/04-helm/04-deploiement.md).
if [ "${ESHOP_HELM_DEPLOY:-}" != "1" ]; then
  echo "Déploiement confié à Argo CD : ce script est conservé comme trace." >&2
  echo "Pour l'utiliser malgré tout, sur un cluster sans Argo CD : ESHOP_HELM_DEPLOY=1 bash helm/deploy.sh" >&2
  exit 1
fi
```

Vérifié : `bash helm/deploy.sh` affiche les deux lignes et se termine avec le code 1, sans rien déployer.

## 4. Vérifier `selfHeal` : une modification manuelle annulée

Une modification faite directement sur le cluster, sans passer par le dépôt :

```bash
kubectl -n eshop scale deployment catalog-api --replicas=2
kubectl -n eshop get deployment catalog-api -w
```

`-w` suit les changements de l'objet en direct (Ctrl+C pour arrêter).

Résultat vérifié le 30 octobre 2026 : `UP-TO-DATE` passe à 2, puis revient à 1, alors que `READY` est resté à `1/1`. Argo CD a remis une seule copie, celle du chart, avant même que la seconde soit prête.

**Leçon :** sur un cluster géré par Argo CD, une correction urgente faite avec `kubectl` est annulée. Elle doit passer par un commit.

## 5. La boucle complète

### Le test

Une modification sans effet sur le fonctionnement, mais qui déclenche la CI : un commentaire en tête de `docker/src/Catalog.API/Dockerfile`. Puis commit, push, et **aucune autre commande** jusqu'à la vérification.

### Ce qui s'est passé, le 2 novembre 2026

| Étape | Acteur | Preuve |
|---|---|---|
| Push du commit `f9bbdda` | Le développeur | `main` sur GitHub |
| Construction et publication des 9 images | GitHub Actions, exécution n° 4 | Succès en **1 min 42** : de 54 s à 1 min 27 par image, en parallèle |
| Étiquette `f9bbdda` écrite dans les 9 fichiers de valeurs | Le job « Étiquettes dans helm/values », 8 s | Commit `1b1a927` de `github-actions[bot]` |
| Synchronisation des 9 services | Argo CD | Les 13 applications `Synced Healthy` sur `1b1a927` |

Puis, dans WSL2 :

```bash
git pull
grep -h 'tag:' helm/values/*.yaml | sort | uniq -c
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision
kubectl -n eshop get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
kubectl -n eshop get pods
```

| Contrôle | Résultat |
|---|---|
| Étiquettes | Les 9 à `f9bbdda` |
| Applications | Les 13 `Synced Healthy`, sur `1b1a927` |
| Images | Les 9 `Deployment` en `ghcr.io/josuekabangu/<service>:f9bbdda` |
| Services | 9 pods récents (de 5 à 7 minutes au moment du relevé), 0 redémarrage |
| Dépendances | `postgres-0`, `redis-0` et `rabbitmq-0` intacts : 11 jours d'âge |

Argo CD suit le commit du robot, `1b1a927`, et non celui du développeur : c'est lui qui contient les nouvelles étiquettes. Les trois dépendances n'ont pas bougé : leurs charts et leurs valeurs n'avaient pas changé.

La durée exacte n'a pas été mesurée ce jour-là : les captures et les commandes n'ont pas été prises au même moment.

### La durée, mesurée le 24 novembre 2026

Le même test, rejoué avec l'heure du push notée en UTC, comme les horodatages d'Argo CD :

```bash
date -u +%H:%M:%S; git push
```

Puis, une fois les 13 applications `Synced Healthy` :

```bash
git pull
TZ=UTC git log -2 --format='%h %cd %an' --date=format-local:'%H:%M:%S'
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,DEBUT:.status.operationState.startedAt,FIN:.status.operationState.finishedAt
kubectl -n eshop get pods -o custom-columns='NAME:.metadata.name,CREE:.metadata.creationTimestamp,PRET:.status.conditions[?(@.type=="Ready")].lastTransitionTime'
```

`TZ=UTC` fait afficher à `git log` l'heure UTC ; sans lui, il affiche l'heure locale, UTC+1 en novembre.

| Étape | Heure (UTC) | Depuis le push |
|---|---|---|
| Push du commit `0f0c6cc` | 14:06:44 | 0 |
| Commit du robot `7cafe55` : fin de la CI | 14:08:56 | 2 min 12 |
| Première synchronisation par Argo CD (`webapp`) | 14:09:27 | 2 min 43 |
| Dernière synchronisation (`payment-processor`) | 14:11:32 | 4 min 48 |
| Dernier service prêt | 14:11:37 | **4 min 53** |

Chaque service est prêt 5 à 11 s après la création de son pod. Ce qui allonge la boucle est l'étalement des synchronisations : 2 min 05 entre la première et la dernière. Argo CD vérifie chaque application à son propre rythme, avec un décalage aléatoire, et non les 13 au même instant. Les quatre applications sans changement, `eshop-platform` et les trois dépendances, n'ont pas été synchronisées.
## 6. Les limites

| Limite | Conséquence |
|---|---|
| Pas de webhook de GitHub vers Argo CD | Jusqu'à 3 minutes entre le commit du robot et la synchronisation de chaque application, et des services synchronisés l'un après l'autre : 2 min 05 d'étalement le 24 novembre 2026. Le laboratoire n'étant pas joignable depuis Internet, c'est le seul mode possible ici |
| Le robot écrit directement sur `main` | Aucune relecture entre la CI et le cluster : une image qui compile part en production. Les tests et l'analyse des images dans la CI restent à ajouter ([docs/05-ci/01-construction-images.md](../05-ci/01-construction-images.md), section 6) |
| Les neuf services sont redéployés à chaque construction | Même si un seul a changé : les neuf images sont reconstruites, donc les neuf étiquettes changent |
| `prune` n'a pas été mis à l'épreuve | Aucun objet n'a encore été retiré d'un chart |

## 7. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Synchronisation automatique active sur les 13 applications
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,AUTO:.spec.syncPolicy.automated.selfHeal,SYNC:.status.sync.status

# Dernière synchronisation de chaque application, en UTC
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,DEBUT:.status.operationState.startedAt,FIN:.status.operationState.finishedAt

# Revenir à la version précédente : par Git, plus par Helm
git revert <commit>
git push
```

## 8. Étape suivante

Faire installer l'`ApplicationSet` par Ansible, pour qu'un cluster reconstruit se remplisse seul depuis GitHub : [04-amorcage.md](04-amorcage.md).
