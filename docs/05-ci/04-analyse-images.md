# 04 — L'analyse des images par Trivy

## 1. Objectif

Les tests unitaires vérifient le code d'eShop ([guide 03](03-tests.md)). Mais une image contient beaucoup plus que ce code :

| Couche de l'image | Origine | Exemples |
|---|---|---|
| Le système de base | Ubuntu 24.04, via `mcr.microsoft.com/dotnet/aspnet:10.0` | `libc6`, `gnutls`, `tar`, `util-linux` |
| Le runtime | Microsoft | ASP.NET Core et .NET 10.0.15 |
| Les dépendances | Les auteurs des paquets NuGet | `Npgsql`, `RabbitMQ.Client`, Duende IdentityServer |
| Le code de l'application | eShop | `Basket.API.dll` |

Une faille connue dans l'une des trois premières couches passe tous les tests, puisque le code fonctionne. Elle serait pourtant déployée.

Ce guide ajoute une analyse de chaque image par **Trivy** dans le job `build`. Une faille grave qui a un correctif fait échouer le job : l'étiquette n'est pas écrite dans `helm/values/`, et l'image n'est jamais déployée.

**État au 27 novembre 2026 :** les 9 images sont analysées à chaque exécution, en 17 à 26 s par image. Elles ont 24 failles chacune, toutes dans les paquets Ubuntu, de sévérité `LOW` ou `MEDIUM`, et aucune n'a de correctif : aucune n'est bloquante. Le blocage a été prouvé avec une règle durcie volontairement.

## 2. Les notions

| Notion | Définition |
|---|---|
| **CVE** | L'identifiant public d'une faille connue, par exemple `CVE-2026-76642`. Elle concerne certaines versions d'un paquet |
| **Sévérité** | `CRITICAL`, `HIGH`, `MEDIUM`, `LOW` ou `UNKNOWN`, dérivée du score CVSS (0 à 10) : la gravité *théorique* de la faille |
| **Version corrigée** | La version du paquet qui supprime la faille. S'il y en a une, il existe une action possible : mettre à jour. Sinon, on ne peut qu'attendre ou accepter le risque |
| **Statut** | `fixed` : un correctif existe. `affected` : le paquet est touché, sans correctif publié |

### Comment Trivy travaille

Trivy ne lit pas le code. Il fait un **inventaire suivi d'une comparaison** :

1. il télécharge sa base de vulnérabilités, `trivy-db`, construite à partir des bulletins d'Ubuntu, de GitHub, de NVD…, et mise à jour plusieurs fois par jour ;
2. il fait l'inventaire de l'image : les paquets système (97 ici, lus dans la base de `dpkg`) et les dépendances .NET, lues dans les fichiers `*.deps.json` ;
3. il compare chaque paquet et sa version à la base.

Deux conséquences :

- **le résultat change sans que l'image change** : une image propre aujourd'hui peut avoir une faille critique demain, le jour où celle-ci est publiée ;
- **un binaire copié à la main** dans l'image, sans gestionnaire de paquets ni `deps.json`, est invisible pour Trivy.

## 3. La base locale

Avant d'écrire le workflow, les images ont été analysées en local, avec la même version de Trivy, depuis WSL2 :

```bash
docker run --rm -v trivy-cache:/root/.cache/trivy aquasec/trivy:0.76.2 image \
  --severity CRITICAL,HIGH --table-mode summary \
  mcr.microsoft.com/dotnet/aspnet:10.0
```

| Option | Rôle |
|---|---|
| `-v trivy-cache:/root/.cache/trivy` | Un volume garde la base (138 Mo) entre deux analyses : sans lui, `--rm` l'efface |
| `--table-mode summary` | Un nombre de failles par cible, au lieu du détail de chaque faille |

Pour une image privée d'eShop, l'image est d'abord téléchargée par le Docker de WSL2, déjà connecté à ghcr.io. Trivy la lit ensuite par le socket de Docker, sans aucun identifiant :

```bash
docker pull ghcr.io/josuekabangu/basket-api:963c953
docker run --rm -v trivy-cache:/root/.cache/trivy \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:0.76.2 image --table-mode detailed --scanners vuln \
  ghcr.io/josuekabangu/basket-api:963c953
```

Résultats vérifiés le 27 novembre 2026 :

| Image | Ubuntu 24.04 | Runtime 10.0.15 | Paquets NuGet |
|---|---|---|---|
| `aspnet:10.0`, filtrée sur `CRITICAL,HIGH` | 0 | 0 | — |
| `basket-api:963c953`, toutes sévérités | **24** : 18 `MEDIUM`, 6 `LOW`, 0 `HIGH`, 0 `CRITICAL` | 0 | 0 |

Le détail des 24 failles de `basket-api` :

| Constat | Détail |
|---|---|
| Correctifs | **Aucun** : les 24 ont le statut `affected` |
| CVE distinctes | **15**. `CVE-2026-76642`, dans util-linux, est comptée 7 fois, une fois par paquet issu du même code source (`bsdutils`, `libblkid1`, `libmount1`, `libsmartcols1`, `libuuid1`, `mount`, `util-linux`). systemd et shadow ont le même effet |
| Paquets concernés | `mount`, `tar`, `dash`, `login`, `passwd`, `gpgv`, `gnutls`, `systemd`, `icu`… Des outils système que les services n'appellent pas ; .NET chiffre avec OpenSSL, pas avec gnutls |

**Leçon :** un nombre de CVE ne mesure pas le risque. Il faut regarder la sévérité, l'existence d'un correctif, et si le paquet sert réellement. Bloquer sur ces 24 failles ne mènerait à rien : on ne peut rien corriger avant qu'Ubuntu publie un correctif et que Microsoft reconstruise `aspnet:10.0`.

## 4. Les choix

| Question | Choix | Raison |
|---|---|---|
| Ce qui bloque | `CRITICAL` et `HIGH`, **seulement s'ils ont un correctif** (`--ignore-unfixed`) | Bloquer seulement quand une action est possible. Sinon, le workflow échoue sans solution et finit par être désactivé |
| Ce qui est affiché | Toutes les sévérités, dans le journal, sans bloquer | Le rapport complet reste consultable à chaque exécution |
| Où | Une étape à la fin du job `build`, sur l'image **publiée** | Une seule étape à ajouter. Si elle échoue, `update-values` ne part pas (`needs: build`), donc l'image n'est jamais déployée |
| Comment lancer Trivy | L'image `aquasec/trivy`, comme en local, et non l'action `aquasecurity/trivy-action` | La commande vérifiée en local, sans action tierce de plus dans la chaîne |
| Quelle version | `0.76.2`, désignée par son **empreinte** `sha256:8f6bb947…` | Même règle que pour les actions ([guide 01](01-construction-images.md#2-les-choix)) : une étiquette peut être déplacée, une empreinte non |
| Accès à l'image privée | `docker pull` puis lecture par le socket de Docker | `login-action` a déjà connecté Docker à ghcr.io plus haut dans le job : aucun jeton à transmettre à Trivy |
| Les secrets | `--scanners vuln` | Trivy cherche aussi par défaut des secrets écrits dans l'image. Cette recherche n'a rien trouvé en local et allonge l'analyse |

### L'autre option : analyser avant de publier

On aurait pu construire l'image en local dans le job (`load: true`), l'analyser, puis la publier seulement si elle passe. Une image vulnérable ne serait alors jamais publiée sur ghcr.io. Le prix : deux étapes de construction et la gestion du cache à revoir. Le but ici est que rien de vulnérable n'atteigne le cluster ; l'analyse après publication y suffit.

## 5. L'étape

Le fichier complet : [.github/workflows/images.yml](../../.github/workflows/images.yml). L'étape suit `Construire et publier` dans le job `build` :

```yaml
      # Analyse de l'image publiée. Une faille grave qui a un correctif fait échouer le job :
      # update-values ne part pas, et l'image n'est jamais déployée
      - name: Analyser l'image (Trivy)
        env:
          IMAGE: ghcr.io/${{ github.repository_owner }}/${{ matrix.service }}:${{ steps.tag.outputs.tag }}
          # Image de Trivy désignée par son empreinte, comme les actions : une étiquette peut être déplacée
          TRIVY: aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb
        run: |
          docker pull --quiet "$IMAGE"
          run_trivy() {
            docker run --rm -v trivy-cache:/root/.cache/trivy \
              -v /var/run/docker.sock:/var/run/docker.sock \
              "$TRIVY" image --scanners vuln --no-progress "$@" "$IMAGE"
          }
          echo "::group::Rapport complet, toutes sévérités"
          run_trivy
          echo "::endgroup::"
          # Blocage : seulement CRITICAL et HIGH, et seulement si un correctif existe
          run_trivy --skip-db-update --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1
```

| Élément | Rôle |
|---|---|
| Premier passage | Le **rapport** : toutes les sévérités, dans un bloc repliable du journal. Il ne bloque jamais sur une faille |
| Second passage | Le **blocage** : `--exit-code 1` fait échouer l'étape s'il reste une faille après les filtres |
| Volume `trivy-cache` | La base est téléchargée une fois par job, au premier passage, puis réutilisée (`--skip-db-update`) |
| `--no-progress` | Pas de barre de téléchargement, illisible dans un journal |
| `bash -e` | GitHub lance `run` avec `-e` : si le premier passage échoue lui-même, par exemple parce que la base ne se télécharge pas, l'étape échoue. En cas de doute, rien n'est déployé |

## 6. Vérifier

### Le cas normal

Exécution n°9, commit `db86720`, le 27 novembre 2026. Heures en UTC, relevées par l'API de GitHub :

| Contrôle | Résultat |
|---|---|
| `Tests unitaires` | Vert, 1 min 03 |
| Les 9 constructions | Vertes, de 33 s à 53 s ; l'étape Trivy de 17 s à 26 s |
| Rapport complet (`identity-api`, `webapp`) | `Total: 24 (UNKNOWN: 0, LOW: 6, MEDIUM: 18, HIGH: 0, CRITICAL: 0)` pour Ubuntu ; 0 pour `app/*.deps.json` et pour le runtime : le même rapport que `basket-api` en local |
| Second passage | 0 sur les 4 cibles |
| Image Trivy | `Digest: sha256:8f6bb947…`, l'empreinte épinglée |
| `Étiquettes dans helm/values` | Vert, commit du robot `454a95b` |
| Durée totale | **2 min 10**, contre 1 min 46 pour l'exécution n°8 sans Trivy |
| Cluster | 13 applications `Synced Healthy`, les 9 images en `:db86720` |

Les paquets NuGet d'`identity-api`, qui contient Duende IdentityServer, et de `webapp`, en Blazor, n'ont aucune faille connue, quelle que soit la sévérité.

### La preuve du blocage

Aucune faille grave n'a de correctif aujourd'hui : le cas réel ne peut pas être provoqué. La règle a donc été **durcie volontairement**, dans le commit `5553989`, pour bloquer sur les failles `MEDIUM` même sans correctif :

```bash
          run_trivy --skip-db-update --severity MEDIUM,HIGH,CRITICAL --exit-code 1
```

Résultat, exécution n°10 du 27 novembre 2026 :

| Contrôle | Résultat |
|---|---|
| `Tests unitaires` | Vert, 1 min 01 |
| Les 9 constructions | **Rouges** : `Construire et publier` réussie, puis `Analyser l'image (Trivy)` en échec |
| Second passage (`identity-api`) | `Total: 18 (MEDIUM: 18, HIGH: 0, CRITICAL: 0)` : les 18 `MEDIUM` attendues |
| `Étiquettes dans helm/values` | Ignoré |
| Dépôt | Aucun commit du robot après `5553989` |
| Images `:5553989` | Publiées sur ghcr.io, puisque l'analyse suit la publication : le compromis de la section 4 |
| Cluster | Inchangé : 13 `Synced Healthy`, les 9 images toujours en `:db86720` |
| Durée totale | 2 min 02 |

La règle durcie a ensuite été annulée par `git revert` (commit `1b0ad73`). L'exécution n°11 qui a suivi est verte en 2 min 21 : étape Trivy de 17 s à 30 s, puis commit du robot `84fd9ed` avec l'étiquette `1b0ad73`.

## 7. Les limites

| Limite | Conséquence |
|---|---|
| L'analyse suit la publication | Une image refusée existe quand même sur ghcr.io, sans être désignée par aucun fichier de valeurs. Elle pourrait être déployée à la main |
| Seulement au moment de la construction | Une faille publiée après la construction n'est pas vue tant qu'aucun push ne relance le workflow. Une analyse programmée (`schedule`) des images déployées reste à ajouter |
| Le bruit de l'image de base | 24 failles sans correctif dans chaque image. Les images *chiseled* de Microsoft (`aspnet:10.0-noble-chiseled`), sans shell ni outils système, en supprimeraient la plupart, au prix de `kubectl exec … sh` et des contrôles de santé de Compose écrits en `bash` |
| L'image Trivy vient de Docker Hub | 9 téléchargements par exécution. Docker Hub limite les téléchargements anonymes : sans conséquence à ce rythme |
| Aucune exception possible pour l'instant | Si une faille grave corrigeable ne peut pas être corrigée tout de suite, il faudra un fichier `.trivyignore`, une CVE par ligne avec sa raison écrite : c'est une décision de risque, elle doit être tracée |
| Pas de rapport dans l'onglet *Security* de GitHub | Le format SARIF permettrait de suivre les failles comme des alertes, au lieu de les lire dans le journal |
| Les dépendances PostgreSQL, Redis et RabbitMQ | Leurs images publiques (`pgvector/pgvector`, `redis`, `rabbitmq`) ne sont pas construites par ce workflow, donc pas analysées |
