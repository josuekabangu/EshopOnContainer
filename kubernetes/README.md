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
| `rabbitmq/sealedsecret-rabbitmq-credentials.yaml` | `SealedSecret` `rabbitmq-credentials` : utilisateur et mot de passe de RabbitMQ, chiffrés | [docs/03-kubernetes/06-rabbitmq.md](../docs/03-kubernetes/06-rabbitmq.md) |
| `rabbitmq/service-rabbitmq.yaml` | `Service` `rabbitmq` : AMQP sur 5672, administration sur 15672 | Même guide |
| `rabbitmq/statefulset-rabbitmq.yaml` | `StatefulSet` `rabbitmq` : RabbitMQ 4.3.6 avec l'interface d'administration, nœud `rabbit@rabbitmq-0`, volume de 2 Gio conservé, trois probes | Même guide |
| `redis/sealedsecret-redis-credentials.yaml` | `SealedSecret` `redis-credentials` : mot de passe de Redis, chiffré | [docs/03-kubernetes/05-redis.md](../docs/03-kubernetes/05-redis.md) |
| `redis/service-redis.yaml` | `Service` `redis` : adresse stable de Redis, port 6379 | Même guide |
| `redis/statefulset-redis.yaml` | `StatefulSet` `redis` : Redis 7.4.11, mot de passe exigé, journal `appendonly`, volume de 2 Gio conservé, trois probes | Même guide |
| `basket-api/sealedsecret-basket-api.yaml` | `SealedSecret` `basket-api-secrets` : chaînes de connexion à Redis et à RabbitMQ, chiffrées | [docs/03-kubernetes/09-basket-api.md](../docs/03-kubernetes/09-basket-api.md) |
| `basket-api/service-basket-api.yaml` | `Service` `basket-api` : port 8080, gRPC en HTTP/2 (`appProtocol: kubernetes.io/h2c`) | Même guide |
| `basket-api/deployment-basket-api.yaml` | `Deployment` `basket-api` : image `87e28f8`, HTTP/2 sur 8080, probes sur 8081 en HTTP/1.1 | Même guide |
| `catalog-api/sealedsecret-catalog-api.yaml` | `SealedSecret` `catalog-api-secrets` : chaînes de connexion à `catalogdb` et à RabbitMQ, chiffrées | [docs/03-kubernetes/08-catalog-api.md](../docs/03-kubernetes/08-catalog-api.md) |
| `catalog-api/service-catalog-api.yaml` | `Service` `catalog-api` : port 8080 | Même guide |
| `catalog-api/deployment-catalog-api.yaml` | `Deployment` `catalog-api` : image `87e28f8`, probes sur `/alive` et `/health` | Même guide |
| `identity-api/sealedsecret-identity-api.yaml` | `SealedSecret` `identity-api-secrets` : chaîne de connexion à `identitydb`, chiffrée | [docs/03-kubernetes/07-identity-api.md](../docs/03-kubernetes/07-identity-api.md) |
| `identity-api/service-identity-api.yaml` | `Service` `identity-api` : port 5223 | Même guide |
| `identity-api/deployment-identity-api.yaml` | `Deployment` `identity-api` : image `87e28f8`, une seule copie, probes sur `/alive` et `/health` | Même guide |
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
for f in kubernetes/rabbitmq/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/identity-api/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/catalog-api/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/basket-api/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
```

Validé le 19 octobre 2026 avec les trois dépendances, sur un cluster reconstruit en 6 min 58 : les quatre secrets déchiffrés, les trois pods prêts, et chaque base refuse un mot de passe faux et accepte celui de son secret. Une première validation, avec PostgreSQL seul, date du 18 octobre. Les lignes d'`identity-api`, de `catalog-api` et de `basket-api`, ajoutées ensuite, n'ont pas encore été rejouées sur un cluster neuf sur un cluster neuf ([docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md), section 8).
