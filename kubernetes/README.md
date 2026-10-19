# Manifestes Kubernetes

Ce répertoire contient les fichiers qui décrivent ce que le projet déploie sur le cluster du laboratoire.

## Cible

| Élément | Valeur |
|---|---|
| Cluster | Laboratoire local, construit par `lab-local/` : `kube-control` (192.168.57.10) et `kube-worker` (192.168.57.11) |
| Version de Kubernetes | v1.36.5, installée par kubeadm |
| Espace de noms de l'application | `eshop` |
| Registre d'images | `ghcr.io/josuekabangu`, privé |
| Version des images | Identifiant court du commit qui les a produites ; `87e28f8` au 16 octobre 2026 |
| Secret d'accès au registre | `ghcr-pull`, dans l'espace de noms `eshop` |
| Chiffrement des secrets | Sealed Secrets v0.40.0 : contrôleur installé par Ansible, clé publique dans `sealed-secrets-cert.pem` |

## Pourquoi des manifestes écrits à la main ?

Les ressources sont d'abord décrites en manifestes YAML, appliqués un par un et vérifiés à chaque étape, comme les services l'ont été un par un dans Docker Compose. Chaque objet Kubernetes est ainsi compris avant d'être factorisé.

Une fois l'application validée sur le cluster, ces manifestes serviront de base aux charts Helm du répertoire `helm/`.

## Règles

- **Aucun secret en clair dans un fichier.** Le dépôt est public. Un mot de passe ou un jeton n'y entre que chiffré, sous forme de `SealedSecret`, par `kubeseal` à partir d'une saisie masquée ([docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md)). Jamais d'objet `Secret`, dont les valeurs sont seulement encodées en base64. La clé privée qui déchiffre reste hors du dépôt.
- **Des images à version fixe.** Une image est toujours désignée par son nom complet et l'identifiant du commit, jamais par `latest`.
- **Un fichier, une responsabilité.** Chaque manifeste décrit un composant, ou un test.
- **Un manifeste n'entre ici qu'une fois vérifié.** Il a été appliqué au cluster, et son résultat est documenté dans un guide.
- **Tenir à jour les tableaux ci-dessous**, y compris celui des ressources créées par commande, qui n'ont pas de fichier.

## Contenu

| Fichier | Rôle | Guide |
|---|---|---|
| `sealed-secrets-cert.pem` | Clé publique du contrôleur Sealed Secrets : sert à chiffrer, ne permet pas de déchiffrer. Exception explicite au `*.pem` du `.gitignore` | [docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md) |
| `namespace-eshop.yaml` | Espace de noms `eshop`, à appliquer avant tout autre fichier | Même guide |
| `sealedsecret-ghcr-pull.yaml` | `SealedSecret` `ghcr-pull` : jeton de lecture du registre, chiffré. Commun à tous les services | Même guide ; [docs/03-kubernetes/01-registre-images.md](../docs/03-kubernetes/01-registre-images.md) |
| `postgres/sealedsecret-postgres-credentials.yaml` | `SealedSecret` `postgres-credentials` : utilisateur et mot de passe de PostgreSQL, chiffrés | [docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md) |
| `redis/sealedsecret-redis-credentials.yaml` | `SealedSecret` `redis-credentials` : mot de passe de Redis, chiffré | [docs/03-kubernetes/05-redis.md](../docs/03-kubernetes/05-redis.md) |
| `redis/service-redis.yaml` | `Service` `redis` : adresse stable de Redis, port 6379 | Même guide |
| `redis/statefulset-redis.yaml` | `StatefulSet` `redis` : Redis 7.4.11, mot de passe exigé, journal `appendonly`, volume de 2 Gio conservé, trois probes | Même guide |
| `postgres/service-postgres.yaml` | `Service` `postgres` : adresse stable de PostgreSQL dans le cluster, port 5432 | [docs/03-kubernetes/03-postgres.md](../docs/03-kubernetes/03-postgres.md) |
| `postgres/statefulset-postgres.yaml` | `StatefulSet` `postgres` : PostgreSQL 15 avec `vector`, volume de 2 Gio conservé à la suppression du `StatefulSet`, trois probes | Même guide |

Les fichiers d'un dossier s'appliquent ensemble ainsi :

```bash
for f in kubernetes/postgres/*.yaml; do echo '---'; cat "$f"; done \
  | ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl apply -f -
```

Le test du réseau du cluster, `network-test.yaml`, vérifie le laboratoire et non l'application. Il se trouve dans `lab-local/tests/`.

## Ressources créées par commande

Ces ressources existeraient sur le cluster sans fichier dans ce répertoire, et disparaîtraient à chaque reconstruction.

**Aucune au 18 octobre 2026.** L'espace de noms `eshop` et les secrets `ghcr-pull` et `postgres-credentials`, d'abord créés par commande, sont décrits par des fichiers depuis l'adoption de Sealed Secrets ([docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md)).

La clé privée de Sealed Secrets n'entre pas dans cette liste : ce n'est pas une ressource de l'application. Le rôle Ansible `sealed_secrets` la restaure à chaque reconstruction ([docs/01-lab-local/15-sealed-secrets.md](../docs/01-lab-local/15-sealed-secrets.md)).

## Appliquer un manifeste

`kubectl` est configuré sur `kube-control`, et les fichiers du dépôt n'y sont pas. Depuis WSL2, à la racine du dépôt, le fichier est donc envoyé par SSH sur l'entrée de `kubectl` :

```bash
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl apply -f - < kubernetes/<fichier>.yaml
```

`-f -` indique à `kubectl` de lire le manifeste sur son entrée. La redirection `<` y envoie le fichier local.

Pour supprimer les ressources d'un manifeste :

```bash
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl delete -f - < kubernetes/<fichier>.yaml
```

## Reconstruction du cluster

`lab-local/scripts/rebuild.ps1 -Rebuild` reconstruit le cluster à partir de machines neuves (voir [lab-local/README.md](../lab-local/README.md), section 8). Tout ce qui a été déployé disparaît alors, et se réapplique depuis ce répertoire, sans rien ressaisir, l'espace de noms en premier :

```bash
CP="ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10"
$CP kubectl apply -f - < kubernetes/namespace-eshop.yaml
$CP kubectl apply -f - < kubernetes/sealedsecret-ghcr-pull.yaml
for f in kubernetes/postgres/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/redis/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
```

Validé le 18 octobre 2026, avant l'ajout de Redis, sur un cluster neuf ([docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md), section 8).
