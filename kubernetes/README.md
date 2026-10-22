# Manifestes Kubernetes

> **Depuis le 22 octobre 2026, l'application est déployée par Helm** : `bash helm/deploy.sh`, à partir des charts de `helm/` ([docs/04-helm/04-deploiement.md](../docs/04-helm/04-deploiement.md)). Les manifestes de ce répertoire sont **conservés comme trace pédagogique** de l'étape précédente : chaque objet y a été écrit et vérifié à la main, avant d'être factorisé en chart.
>
> **Ne plus les appliquer** à un cluster où l'application est déployée par Helm : leurs objets appartiennent aux releases Helm, et un `kubectl apply` créerait des conflits de propriété ([docs/04-helm/02-reprise.md](../docs/04-helm/02-reprise.md)).
>
> Un seul fichier sert encore : `sealed-secrets-cert.pem`, la clé publique avec laquelle `kubeseal` chiffre les secrets.

Ce répertoire contient les fichiers qui décrivaient ce que le projet déploie sur le cluster du laboratoire.

## Cible

| Élément | Valeur |
|---|---|
| Cluster | Laboratoire local, construit par `lab-local/` : `kube-control` (192.168.57.10) et `kube-worker` (192.168.57.11) |
| Version de Kubernetes | v1.36.5, installée par kubeadm |
| Espace de noms de l'application | `eshop` |
| Registre d'images | `ghcr.io/josuekabangu`, privé |
| Version des images | Identifiant court du commit qui les a produites ; `87e28f8` au 16 octobre 2026, sauf `webhook-client` en `a6647c9`, le commit de son adaptation |
| Point d'entrée | `Gateway` `eshop`, classe `eg` (Envoy Gateway), à l'adresse `192.168.57.20` ; noms `shop.eshop.lab`, `identity.eshop.lab`, `webhooks.eshop.lab` |
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
- **Un service qui utilise RabbitMQ l'attend au démarrage**, par l'`initContainer` `wait-for-rabbitmq` : sans lui, son abonnement aux événements est perdu définitivement ([docs/03-kubernetes/17-ordre-de-demarrage.md](../docs/03-kubernetes/17-ordre-de-demarrage.md)).
- **Tenir à jour les tableaux ci-dessous**, y compris celui des ressources créées par commande, qui n'ont pas de fichier.

## Contenu

| Fichier | Rôle | Guide |
|---|---|---|
| `sealed-secrets-cert.pem` | Clé publique du contrôleur Sealed Secrets : sert à chiffrer, ne permet pas de déchiffrer. Exception explicite au `*.pem` du `.gitignore` | [docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md) |
| `namespace-eshop.yaml` | Espace de noms `eshop`, à appliquer avant tout autre fichier | Même guide |
| `sealedsecret-ghcr-pull.yaml` | `SealedSecret` `ghcr-pull` : jeton de lecture du registre, chiffré. Commun à tous les services | Même guide ; [docs/03-kubernetes/01-registre-images.md](../docs/03-kubernetes/01-registre-images.md) |
| `gateway/envoyproxy-eshop.yaml` | `EnvoyProxy` `eshop` : `Service` du proxy nommé `eshop-gateway`, adresse figée sur `192.168.57.20`. À appliquer avant le `Gateway` | [docs/03-kubernetes/14-point-entree.md](../docs/03-kubernetes/14-point-entree.md) |
| `gateway/gateway-eshop.yaml` | `Gateway` `eshop` : le point d'entrée, HTTP sur le port 80, noms `*.eshop.lab`, routes de l'espace de noms `eshop` seulement | Même guide |
| `identity-api/httproute-identity-api.yaml` | `HTTPRoute` : `identity.eshop.lab` vers `identity-api:5223` | Même guide |
| `webapp/sealedsecret-webapp.yaml` | `SealedSecret` `webapp-secrets` : chaîne de connexion à RabbitMQ, chiffrée | [docs/03-kubernetes/15-webapp.md](../docs/03-kubernetes/15-webapp.md) |
| `webapp/service-webapp.yaml` | `Service` `webapp` : port 8080 | Même guide |
| `webapp/httproute-webapp.yaml` | `HTTPRoute` : `shop.eshop.lab` vers `webapp:8080` | Même guide |
| `webapp/deployment-webapp.yaml` | `Deployment` `webapp` : une seule copie, adresses publiques, cookies assouplis (`72ee8fa`) | Même guide |
| `webhook-client/service-webhook-client.yaml` | `Service` `webhook-client` : port 8080, aussi destination des notifications | [docs/03-kubernetes/16-webhook-client.md](../docs/03-kubernetes/16-webhook-client.md) |
| `webhook-client/httproute-webhook-client.yaml` | `HTTPRoute` : `webhooks.eshop.lab` vers `webhook-client:8080` | Même guide |
| `webhook-client/deployment-webhook-client.yaml` | `Deployment` `webhook-client` : image `a6647c9`, une seule copie, cookies assouplis | Même guide |
| `postgres/sealedsecret-postgres-credentials.yaml` | `SealedSecret` `postgres-credentials` : utilisateur et mot de passe de PostgreSQL, chiffrés | [docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md) |
| `rabbitmq/sealedsecret-rabbitmq-credentials.yaml` | `SealedSecret` `rabbitmq-credentials` : utilisateur et mot de passe de RabbitMQ, chiffrés | [docs/03-kubernetes/06-rabbitmq.md](../docs/03-kubernetes/06-rabbitmq.md) |
| `rabbitmq/service-rabbitmq.yaml` | `Service` `rabbitmq` : AMQP sur 5672, administration sur 15672 | Même guide |
| `rabbitmq/statefulset-rabbitmq.yaml` | `StatefulSet` `rabbitmq` : RabbitMQ 4.3.6 avec l'interface d'administration, nœud `rabbit@rabbitmq-0`, volume de 2 Gio conservé, trois probes | Même guide |
| `redis/sealedsecret-redis-credentials.yaml` | `SealedSecret` `redis-credentials` : mot de passe de Redis, chiffré | [docs/03-kubernetes/05-redis.md](../docs/03-kubernetes/05-redis.md) |
| `redis/service-redis.yaml` | `Service` `redis` : adresse stable de Redis, port 6379 | Même guide |
| `redis/statefulset-redis.yaml` | `StatefulSet` `redis` : Redis 7.4.11, mot de passe exigé, journal `appendonly`, volume de 2 Gio conservé, trois probes | Même guide |
| `webhooks-api/sealedsecret-webhooks-api.yaml` | `SealedSecret` `webhooks-api-secrets` : chaînes de connexion à `webhooksdb` et à RabbitMQ, chiffrées | [docs/03-kubernetes/13-webhooks-api.md](../docs/03-kubernetes/13-webhooks-api.md) |
| `webhooks-api/service-webhooks-api.yaml` | `Service` `webhooks-api` : port 8080 | Même guide |
| `webhooks-api/deployment-webhooks-api.yaml` | `Deployment` `webhooks-api` : celui d'`ordering-api`, renommé | Même guide |
| `payment-processor/sealedsecret-payment-processor.yaml` | `SealedSecret` `payment-processor-secrets` : chaîne de connexion à RabbitMQ, chiffrée | [docs/03-kubernetes/12-payment-processor.md](../docs/03-kubernetes/12-payment-processor.md) |
| `payment-processor/deployment-payment-processor.yaml` | `Deployment` `payment-processor` : tâche de fond, probes HTTP sur le port 8080, sans `Service` | Même guide |
| `order-processor/sealedsecret-order-processor.yaml` | `SealedSecret` `order-processor-secrets` : chaînes de connexion à `orderingdb` et à RabbitMQ, chiffrées | [docs/03-kubernetes/11-order-processor.md](../docs/03-kubernetes/11-order-processor.md) |
| `order-processor/deployment-order-processor.yaml` | `Deployment` `order-processor` : tâche de fond, une seule copie, probes HTTP sur le port 8080, sans `Service` | Même guide |
| `ordering-api/sealedsecret-ordering-api.yaml` | `SealedSecret` `ordering-api-secrets` : chaînes de connexion à `orderingdb` et à RabbitMQ, chiffrées | [docs/03-kubernetes/10-ordering-api.md](../docs/03-kubernetes/10-ordering-api.md) |
| `ordering-api/service-ordering-api.yaml` | `Service` `ordering-api` : port 8080 | Même guide |
| `ordering-api/deployment-ordering-api.yaml` | `Deployment` `ordering-api` : image `87e28f8`, adresse publique d'`Identity.API`, probes sur `/alive` et `/health` | Même guide |
| `basket-api/sealedsecret-basket-api.yaml` | `SealedSecret` `basket-api-secrets` : chaînes de connexion à Redis et à RabbitMQ, chiffrées | [docs/03-kubernetes/09-basket-api.md](../docs/03-kubernetes/09-basket-api.md) |
| `basket-api/service-basket-api.yaml` | `Service` `basket-api` : port 8080, gRPC en HTTP/2 (`appProtocol: kubernetes.io/h2c`) | Même guide |
| `basket-api/deployment-basket-api.yaml` | `Deployment` `basket-api` : image `87e28f8`, HTTP/2 sur 8080, probes sur 8081 en HTTP/1.1 | Même guide |
| `catalog-api/sealedsecret-catalog-api.yaml` | `SealedSecret` `catalog-api-secrets` : chaînes de connexion à `catalogdb` et à RabbitMQ, chiffrées | [docs/03-kubernetes/08-catalog-api.md](../docs/03-kubernetes/08-catalog-api.md) |
| `catalog-api/service-catalog-api.yaml` | `Service` `catalog-api` : port 8080 | Même guide |
| `catalog-api/deployment-catalog-api.yaml` | `Deployment` `catalog-api` : image `87e28f8`, probes sur `/alive` et `/health` | Même guide |
| `identity-api/sealedsecret-identity-api.yaml` | `SealedSecret` `identity-api-secrets` : chaîne de connexion à `identitydb`, chiffrée | [docs/03-kubernetes/07-identity-api.md](../docs/03-kubernetes/07-identity-api.md) |
| `identity-api/service-identity-api.yaml` | `Service` `identity-api` : port 5223 | Même guide |
| `identity-api/deployment-identity-api.yaml` | `Deployment` `identity-api` : image `87e28f8`, une seule copie, adresses publiques des clients, probes sur `/alive` et `/health` | Même guide |
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
for f in kubernetes/gateway/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/postgres/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/redis/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/rabbitmq/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/identity-api/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/catalog-api/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/basket-api/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/ordering-api/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/order-processor/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/payment-processor/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/webhooks-api/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/webapp/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
for f in kubernetes/webhook-client/*.yaml; do echo '---'; cat "$f"; done | $CP kubectl apply -f -
```

Le `Gateway` suppose les rôles Ansible `metallb`, `envoy_gateway` et `lab_dns`, appliqués par la reconstruction. Le navigateur suppose, sur le poste, la ligne du fichier `hosts` ajoutée par `lab-local/scripts/add-hosts-entries.ps1`.

**Validé le 21 octobre 2026 avec toute l'application**, sur un cluster reconstruit : les 12 pods `1/1 Running` sans redémarrage, le `Gateway` programmé à `192.168.57.20`, les 7 files RabbitMQ avec leur consommateur, et une commande passée depuis le navigateur menée jusqu'à `Paid`, avec sa notification livrée. Une première réapplication, avant l'ajout de l'`initContainer` `wait-for-rabbitmq`, avait laissé quatre services sans abonnement ([docs/03-kubernetes/17-ordre-de-demarrage.md](../docs/03-kubernetes/17-ordre-de-demarrage.md)). Validations précédentes : le 18 octobre avec PostgreSQL seul, le 19 avec les trois dépendances ([docs/03-kubernetes/04-secrets.md](../docs/03-kubernetes/04-secrets.md), section 8).
