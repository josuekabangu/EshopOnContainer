# 01 — Le registre d’images

## 1. Objectif

La phase Docker a construit les neuf images d’eShop dans le Docker de WSL2. Elles n’existent que là : les nœuds du cluster, `kube-control` et `kube-worker`, ne peuvent pas les télécharger.

Ce guide ouvre la phase de déploiement sur Kubernetes. Il rend les images disponibles au cluster, par un registre d’images : un serveur qui les stocke et les distribue.

Les objectifs sont de :

- publier les neuf images sur un registre, sous un nom et une version qui identifient le code exact qu’elles contiennent ;
- garder ces images privées ;
- donner au cluster, et à lui seul, un accès en lecture ;
- vérifier, depuis un nœud, que l’accès fonctionne avec ce droit et qu’il est refusé sans.

**État au 16 octobre 2026 :** les neuf images sont publiées sur `ghcr.io/josuekabangu`, en privé, avec l’étiquette `87e28f8`. Le cluster les télécharge grâce au secret `ghcr-pull`, dans l’espace de noms `eshop`.

## 2. Les choix

### Le registre : GitHub Container Registry

| Option | Avantage | Contrepartie |
|---|---|---|
| **GitHub Container Registry** (`ghcr.io`), retenue | La chaîne d’intégration continue, prévue avec GitHub Actions, y publiera les images : rien à refaire plus tard | Les nœuds doivent joindre Internet ; il faut des jetons d’accès GitHub |
| Registre installé dans le laboratoire | Tout reste sur le poste | Une brique de plus à installer et à rendre joignable, abandonnée au passage à la CI |
| Copie directe des images sur chaque nœud | Aucun registre | Manuel, à refaire sur chaque nœud et à chaque reconstruction |

### Des images privées

Les images sont **privées** : seul un détenteur d’un jeton autorisé peut les télécharger. En contrepartie, chaque `Deployment` du cluster devra désigner un secret d’accès.

Une image poussée sur `ghcr.io` est privée par défaut, même si le dépôt du projet est public. Aucune action n’est donc nécessaire pour la rendre privée.

### L’étiquette : l’identifiant du commit

Chaque image porte comme étiquette l’identifiant court du commit dont elle provient, par exemple `catalog-api:87e28f8`.

| Étiquette | Pourquoi l’écarter ou la retenir |
|---|---|
| `latest` | Écartée : elle désigne une image différente à chaque publication. Sur un cluster, il faut savoir exactement quelle version tourne et pouvoir revenir à la précédente |
| Numéro de version, comme `0.1.0` | Écartée pour l’instant : à incrémenter à la main, et rien ne garantit qu’il corresponde au code |
| Identifiant du commit, retenue | Relie chaque image au code exact qui l’a produite. C’est aussi ce que fera GitHub Actions |

Le nom complet d’une image devient :

```text
ghcr.io/josuekabangu/<service>:<identifiant du commit>
```

La convention du guide 02 de la phase Docker, `<service>:latest`, reste celle des images construites sur le poste. Elle avait annoncé ce passage : sur un cluster, une image doit avoir un préfixe de registre et une étiquette de version.

## 3. Deux jetons d’accès

L’accès au registre passe par des jetons GitHub. Le projet en utilise deux, aux droits différents :

| Jeton | Droit | Utilisé par | Où il est conservé |
|---|---|---|---|
| Jeton de publication | `write:packages` | La personne qui publie les images, depuis WSL2 | Saisi au clavier ; gardé par `docker login` le temps de la publication |
| Jeton de lecture | `read:packages` **seulement** | Le cluster, pour télécharger les images | Dans le secret `ghcr-pull` de l’espace de noms `eshop` |

Le jeton du cluster peut être lu par quiconque administre le cluster. Avec le seul droit de lecture, une fuite ne permettrait pas de remplacer les images par d’autres.

### Créer les jetons

Sur GitHub : *Settings* → *Developer settings* → *Personal access tokens* → **Tokens (classic)** → *Generate new token (classic)*.

- Le jeton doit être de type **classic** : les jetons *fine-grained* ne permettent pas d’accéder au registre `ghcr.io`.
- Une date d’expiration est fixée, par exemple 90 jours.
- La valeur n’est affichée qu’une fois : elle est conservée dans un gestionnaire de mots de passe, jamais dans un fichier du projet.

## 4. Publier les images

Les commandes sont lancées dans WSL2, depuis la racine du dépôt.

### Se connecter au registre

```bash
read -rs -p 'Jeton GitHub (write:packages) : ' GHCR_TOKEN; echo
echo "$GHCR_TOKEN" | docker login ghcr.io -u josuekabangu --password-stdin
unset GHCR_TOKEN
```

- `read -rs` lit le jeton sans l’afficher.
- `--password-stdin` le transmet par l’entrée standard : il n’apparaît ni dans la liste des processus, ni dans l’historique des commandes.
- `unset` l’efface du terminal.

Résultat attendu : `Login Succeeded`.

`docker login` enregistre ensuite le jeton dans `~/.docker/config.json`, encodé mais **non chiffré**. Docker le signale par un avertissement. La déconnexion, en fin de publication, l’en retire.

### Vérifier que le code est commité

```bash
git status --short
TAG=$(git rev-parse --short HEAD); echo "$TAG"
```

`git status` ne doit rien afficher. Sinon, l’image contiendrait des modifications absentes du commit dont elle porte le nom.

Résultat vérifié le 16 octobre 2026 : aucune modification en cours, `TAG` vaut `87e28f8`.

### Construire, étiqueter, publier

```bash
docker compose -f docker/docker-compose.yaml build

for svc in catalog-api identity-api basket-api ordering-api order-processor \
           payment-processor webhooks-api webapp webhook-client; do
  docker tag "$svc:latest" "ghcr.io/josuekabangu/$svc:$TAG" \
    && docker push "ghcr.io/josuekabangu/$svc:$TAG" | tail -1 \
    || { echo "Échec : $svc"; break; }
done
```

- `docker compose build` reconstruit les neuf images à partir du code du commit. Grâce au cache, toutes les étapes de compilation sont réutilisées : 15 secondes pour les neuf.
- `docker tag` donne un second nom à l’image, sans la copier.
- `docker push` l’envoie au registre. `| tail -1` n’affiche que la dernière ligne, qui donne l’empreinte de l’image publiée.
- `|| { ...; break; }` arrête la boucle à la première erreur, en nommant le service.

Résultat vérifié le 16 octobre 2026, extrait :

```text
87e28f8: digest: sha256:eaa4a2a1e166b9deb71f82fe6a2b47c6e203e4d5980662ab327fac0480a3fb77 size: 856
87e28f8: digest: sha256:5258949edcca97b5cc314f1c6b5bb7a385422a9d792a092ffb6130d34929f24b size: 856
...
```

L’empreinte (`digest`) identifie le contenu exact de l’image. Chacune correspond à celle annoncée par la construction juste avant : `exporting manifest list sha256:eaa4a2a1...` pour `identity-api`, par exemple.

Lors d’une nouvelle publication, une couche déjà présente sur le registre n’est pas renvoyée : la sortie affiche `Layer already exists`. C’est normal, le registre ne stocke chaque couche qu’une fois.

Une reconstruction peut changer l’empreinte globale d’une image sans en changer le contenu : Docker ajoute à chaque construction une attestation horodatée. Une image déjà publiée avec la même étiquette reste valable.

### Se déconnecter

```bash
docker logout ghcr.io
```

## 5. Vérifier que les images sont privées

Une demande d’accès sans identifiants, depuis n’importe quel poste :

```bash
curl -s "https://ghcr.io/token?scope=repository:josuekabangu/catalog-api:pull"
```

Résultat vérifié :

```text
{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}
```

Le registre refuse de délivrer un jeton anonyme : l’image est privée.

## 6. Donner au cluster l’accès en lecture

### L’espace de noms et le secret

> **Mise à jour du 18 octobre 2026.** L’espace de noms et le secret ne se créent plus par commande. Ils sont décrits par `kubernetes/namespace-eshop.yaml` et `kubernetes/sealedsecret-ghcr-pull.yaml`, ce dernier chiffré par Sealed Secrets : voir [04 — Les secrets dans le dépôt, chiffrés](04-secrets.md). Les commandes ci-dessous restent celles du 16 octobre ; la mise en forme du secret est la même, `kubeseal` y ajoute le chiffrement.

Les ressources de l’application seront rangées dans un espace de noms (*namespace*) dédié, `eshop`. Le secret d’accès y est créé.

```bash
CP="ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10"
$CP kubectl create namespace eshop

read -rs -p 'Jeton GitHub (read:packages) : ' GHCR_READ; echo
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$(printf 'josuekabangu:%s' "$GHCR_READ" | base64 -w0)" \
  | $CP kubectl -n eshop create secret generic ghcr-pull \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin
unset GHCR_READ
```

- `CP` est une variable du terminal qui raccourcit la connexion SSH vers `kube-control`, où `kubectl` est configuré.
- Le secret contient un petit document JSON, au format qu’attend Kubernetes pour un registre : pour `ghcr.io`, l’utilisateur et le jeton, encodés ensemble en base64.
- Le document est assemblé dans un tuyau, envoyé par SSH, puis lu par `kubectl` sur son entrée (`/dev/stdin`). Le jeton n’apparaît ainsi ni en argument d’une commande, ni dans un fichier, ni dans l’historique.
- `--type=kubernetes.io/dockerconfigjson` indique à Kubernetes qu’il s’agit d’identifiants de registre.

La commande `kubectl create secret docker-registry --docker-password=...` produirait le même secret, mais le jeton y figurerait en argument, visible dans la liste des processus de `kube-control` et dans l’historique.

Vérification :

```bash
$CP kubectl -n eshop get secret ghcr-pull
```

```text
NAME        TYPE                             DATA   AGE
ghcr-pull   kubernetes.io/dockerconfigjson   1      2m51s
```

### Le double test

Deux pods de test sont créés sur `kube-worker`, avec la même image, l’un avec le secret, l’autre sans :

```bash
$CP kubectl -n eshop apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pull-avec-secret
spec:
  nodeSelector: { kubernetes.io/hostname: kube-worker }
  imagePullSecrets: [ { name: ghcr-pull } ]
  restartPolicy: Never
  containers:
    - name: test
      image: ghcr.io/josuekabangu/catalog-api:87e28f8
      command: ["sleep", "60"]
---
apiVersion: v1
kind: Pod
metadata:
  name: pull-sans-secret
spec:
  nodeSelector: { kubernetes.io/hostname: kube-worker }
  restartPolicy: Never
  containers:
    - name: test
      image: ghcr.io/josuekabangu/catalog-api:87e28f8
      command: ["sleep", "60"]
EOF
```

| Réglage | Rôle |
|---|---|
| `nodeSelector` | Place le pod sur `kube-worker`, le nœud qui exécutera les services |
| `imagePullSecrets` | Désigne le secret à présenter au registre. C’est la seule différence entre les deux pods |
| `restartPolicy: Never` | Le pod n’est pas relancé à la fin de la commande |
| `command: ["sleep", "60"]` | Remplace le démarrage de l’application : seul le téléchargement est testé, sans base de données |

Résultats vérifiés le 16 octobre 2026 :

```bash
$CP kubectl -n eshop get pods -o wide
```

```text
NAME               READY   STATUS             RESTARTS   AGE   IP              NODE
pull-avec-secret   1/1     Running            0          49s   10.244.73.130   kube-worker
pull-sans-secret   0/1     ImagePullBackOff   0          49s   10.244.73.129   kube-worker
```

| Pod | État | Événement |
|---|---|---|
| `pull-avec-secret` | `Running`, puis `Completed` | `Successfully pulled image "ghcr.io/josuekabangu/catalog-api:87e28f8" in 7.931s`, 108 Mo |
| `pull-sans-secret` | `ErrImagePull`, puis `ImagePullBackOff` | `failed to authorize: failed to fetch anonymous token` |

`ImagePullBackOff` signifie que Kubernetes réessaie le téléchargement à intervalles croissants, après un échec.

Le message de l’événement étant tronqué avant le code HTTP, un téléchargement sans identifiants a été reproduit directement sur `kube-worker`, avec l’outil du runtime de conteneurs :

```bash
ssh -i ~/.ssh/vagrant/kube-worker vagrant@192.168.57.11 \
  'sudo crictl pull ghcr.io/josuekabangu/catalog-api:87e28f8'
```

Le registre répond `401 Unauthorized`.

Les deux pods de test ont ensuite été supprimés :

```bash
$CP kubectl -n eshop delete pod pull-avec-secret pull-sans-secret
```

L’espace de noms et le secret sont conservés pour le déploiement.

## 7. Points ouverts

1. **Les jetons expirent.** À l’expiration du jeton de lecture, les nœuds ne pourront plus télécharger de nouvelle image. Il faudra chiffrer à nouveau le secret `ghcr-pull` avec un nouveau jeton.
2. ~~**La publication est manuelle.**~~ Réglé le 22 octobre 2026 : GitHub Actions construit et publie les neuf images à chaque push, avec le jeton de l'exécution ([docs/05-ci/01-construction-images.md](../05-ci/01-construction-images.md)).
3. ~~**Une reconstruction du cluster supprime l’espace de noms et le secret.**~~ Réglé le 18 octobre 2026 : les deux sont décrits par des fichiers du dépôt et se réappliquent sans saisie ([guide 04](04-secrets.md)).
4. ~~**Les images ne sont pas reliées au dépôt dans l’interface de GitHub.**~~ Réglé le 22 octobre 2026, pour les images publiées par GitHub Actions : le workflow leur ajoute l'étiquette `org.opencontainers.image.source`. Les paquets ont aussi dû autoriser le dépôt à y publier ([docs/05-ci/01-construction-images.md](../05-ci/01-construction-images.md#4-le-droit-de-publier-sur-des-paquets-déjà-existants)).

## 8. Tableau de validation

| Contrôle | Résultat au 16 octobre 2026 |
|---|---|
| Code commité avant publication | Oui |
| Neuf images publiées | `ghcr.io/josuekabangu/<service>:87e28f8` |
| Empreintes publiées identiques à celles construites | Oui |
| Accès anonyme au registre | Refusé, `authentication required` |
| Espace de noms `eshop` | Créé |
| Secret `ghcr-pull`, avec le jeton de lecture seulement | Créé, type `kubernetes.io/dockerconfigjson` |
| Téléchargement depuis `kube-worker` avec le secret | Réussi, 7,9 s |
| Téléchargement sans le secret | Refusé, `401 Unauthorized` |

## 9. Étape suivante

Les dépendances de l’application, PostgreSQL, Redis et RabbitMQ, doivent conserver leurs données. Or le cluster ne dispose d’aucun fournisseur de volumes (`StorageClass`). Le guide suivant en installe un.

## 10. Commandes de référence

```bash
# Publier une image
TAG=$(git rev-parse --short HEAD)
docker tag catalog-api:latest "ghcr.io/josuekabangu/catalog-api:$TAG"
docker push "ghcr.io/josuekabangu/catalog-api:$TAG"

# Vérifier qu'une image est privée
curl -s "https://ghcr.io/token?scope=repository:josuekabangu/catalog-api:pull"

# Vérifier le secret du cluster
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl -n eshop get secret ghcr-pull

# Événements de téléchargement d'un pod
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 \
  kubectl -n eshop get events --field-selector involvedObject.name=<pod>
```

**Bilan :** les neuf images d’eShop sont publiées sur un registre privé, chacune liée au commit qui l’a produite. Le cluster les télécharge avec un jeton limité à la lecture, et le registre refuse tout accès sans identifiants.
