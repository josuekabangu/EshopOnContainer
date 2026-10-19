# EshopOnContainer

**Projet DevOps — Automatisation, conteneurisation et orchestration d’une application e-commerce.**

## Présentation

EshopOnContainer est un projet de mise en pratique des pratiques DevOps autour d’une application e-commerce basée sur une architecture microservices.

L’objectif est de construire progressivement une plateforme reproductible, automatisée et observable, depuis la préparation de l’infrastructure jusqu’au déploiement et à l’exploitation des services applicatifs.

Le projet privilégie une approche progressive : chaque brique technique est configurée, testée et documentée avant de passer à la suivante.

## Objectifs

* Automatiser le provisionnement et la configuration de l’infrastructure.
* Déployer un cluster Kubernetes multi-nœuds.
* Conteneuriser les services de l’application e-commerce.
* Automatiser les tests et la construction des images avec GitHub Actions.
* Déployer les applications avec Helm et mettre en place une approche GitOps avec Argo CD.
* Superviser les applications et l’infrastructure.
* Intégrer progressivement les pratiques de sécurité.
* Étudier le déploiement sur une infrastructure cloud avec Terraform.

## Architecture du projet

Le projet est organisé autour de trois domaines principaux :

| Domaine                  | Responsabilité                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------ |
| Laboratoire local        | Préparer l’environnement Kubernetes et automatiser la configuration des machines.    |
| Application e-commerce   | Héberger les services applicatifs et leurs dépendances.                              |
| Industrialisation DevOps | Mettre en place le déploiement, la CI/CD, le GitOps, l’observabilité et la sécurité. |

### Technologies

| Domaine                 | Technologie                 | État    |
| ----------------------- | --------------------------- | ------- |
| Virtualisation          | VMware Workstation          | Utilisé |
| Provisionnement local   | Vagrant                     | Utilisé |
| Poste de contrôle       | WSL2 Ubuntu                 | Utilisé |
| Configuration système   | Ansible                     | Utilisé |
| Runtime de conteneurs   | containerd                  | Utilisé |
| Orchestration           | Kubernetes (kubeadm)        | Utilisé |
| Réseau Kubernetes       | Calico                      | Utilisé |
| Construction des images | Docker et Docker Compose    | Utilisé |
| Secrets du cluster      | Sealed Secrets (laboratoire) ; External Secrets et AWS Secrets Manager (EKS) | Utilisé au laboratoire |
| Déploiement applicatif  | Helm                        | Prévu   |
| CI/CD                   | GitHub Actions              | Prévu   |
| GitOps                  | Argo CD                     | Prévu   |
| Observabilité           | Prometheus, Grafana et Loki | Prévu   |
| Sécurité                | Trivy et SonarQube          | Prévu   |
| Infrastructure as Code  | Terraform                   | Prévu   |
| Cloud                   | AWS : EKS, stockage EBS CSI | Prévu   |

« Utilisé » signifie que la technologie est en place, testée et documentée dans ce dépôt. « En cours » signifie qu'elle est partiellement en place. « Prévu » signifie qu'elle fait partie de la feuille de route, sans être encore intégrée.

## État d’avancement

Le premier objectif était de construire un laboratoire Kubernetes local reproductible. Il est atteint : le cluster se reconstruit à partir de machines neuves en une seule commande, le script `lab-local/scripts/rebuild.ps1`, en un peu plus de cinq minutes. Voir la [documentation du laboratoire local](lab-local/README.md).

### Laboratoire local

* [x] Création des machines virtuelles avec Vagrant et VMware.
* [x] Automatisation de la configuration avec Ansible.
* [x] Préparation des nœuds pour Kubernetes.
* [x] Initialisation du Control Plane, automatisée avec Ansible.
* [x] Configuration du réseau des pods avec Calico, automatisée avec Ansible.
* [x] Intégration du Worker au cluster, automatisée avec Ansible.
* [x] Reconstruction complète du cluster validée à partir de machines neuves.
* [x] Tests du réseau du cluster : Pod à Pod entre nœuds, Service et DNS.
* [x] Documentation du laboratoire, en quinze guides.
* [x] Fournisseur de volumes `local-path-provisioner`, installé par Ansible, persistance des données vérifiée.
* [x] Contrôleur Sealed Secrets, installé par Ansible, avec une clé qui survit aux reconstructions.
* [x] Inventaire Ansible portable, sans chemin lié à un compte utilisateur.
* [x] Enchaînement de la reconstruction en une seule commande.

### Application et conteneurisation

* [x] Import des sources de l’application eShop dans le dépôt, à une version identifiée.
* [x] Image Docker du service `Catalog.API` construite et testée avec PostgreSQL et RabbitMQ.
* [x] Images Docker des huit autres services construites et testées.
* [x] PostgreSQL démarré avec Docker Compose.
* [x] Redis démarré avec Docker Compose.
* [x] RabbitMQ démarré avec Docker Compose.
* [x] Identity.API et Catalog.API démarrés avec Docker Compose.
* [x] Basket.API démarré avec Docker Compose.
* [x] Ordering.API démarré avec Docker Compose.
* [x] OrderProcessor démarré avec Docker Compose, rétablissement vérifié s'il démarre avant les tables.
* [x] PaymentProcessor démarré avec Docker Compose, échange de messages vérifié avec Ordering.API.
* [x] Webhooks.API démarré avec Docker Compose.
* [x] WebApp démarrée avec Docker Compose : connexion d'un utilisateur et commande menée jusqu'au paiement depuis le navigateur.
* [x] WebhookClient démarré avec Docker Compose : abonnement et notification vérifiés.
* [x] Démarrage de l’ensemble des services avec Docker Compose : 9 services et 3 dépendances.
* [x] Contrôles de santé sur les 12 conteneurs, démarrage ordonné par l'état `healthy` des dépendances.
* [x] Redémarrage automatique, rotation des journaux, plafonds de mémoire, image PostgreSQL officielle à version figée.

### Déploiement sur Kubernetes

* [x] Images publiées sur un registre privé (`ghcr.io`), étiquetées par l'identifiant du commit, téléchargées par le cluster.
* [x] Fournisseur de volumes pour les données persistantes : `local-path` au laboratoire, EBS CSI prévu sur AWS.
* [x] PostgreSQL déployé sur le cluster, données conservées après suppression du pod et du `StatefulSet`.
* [x] Secrets versionnés dans le dépôt, chiffrés : un cluster neuf retrouve tout depuis les fichiers, sans ressaisie.
* [x] Redis déployé sur le cluster : mot de passe exigé et invisible, données conservées après suppression du pod.
* [x] RabbitMQ déployé sur le cluster : version figée, nom de nœud stable, mot de passe exigé, données conservées après suppression du pod.
* [ ] Services d'eShop déployés, avec leurs probes.
* [ ] Point d'entrée unique et connexion d'un utilisateur.

### Suite du projet

* [ ] Validation de l’application e-commerce complète.
* [ ] Déploiement applicatif avec Helm.
* [ ] Mise en place de GitHub Actions et d’Argo CD.
* [ ] Intégration de l’observabilité et des contrôles de sécurité.
* [ ] Étude du déploiement cloud avec Terraform.

## Structure du dépôt

```text
EshopOnContainer/
├── application/
│   ├── README.md
│   └── eShop/
│
├── docker/
│   ├── docker-compose.yaml
│   ├── .env.example
│   ├── scripts/
│   └── src/
│       ├── Catalog.API/
│       ├── ...
│       └── Webhooks.API/
│
├── docs/
│   ├── 01-lab-local/
│   │   ├── 01-architecture.md
│   │   ├── ...
│   │   ├── 14-local-path.md
│   │   └── 15-sealed-secrets.md
│   ├── 02-docker/
│   │   ├── 01-catalog-api.md
│   │   ├── 02-autres-services.md
│   │   ├── 03-compose-postgres.md
│   │   ├── 04-compose-redis.md
│   │   ├── 05-compose-rabbitmq.md
│   │   ├── 06-compose-identity.md
│   │   ├── 07-compose-catalog.md
│   │   ├── 08-compose-basket.md
│   │   ├── 09-compose-ordering.md
│   │   ├── 10-compose-order-processor.md
│   │   ├── 11-compose-payment-processor.md
│   │   ├── 12-compose-webhooks.md
│   │   ├── 13-compose-webapp.md
│   │   ├── 14-compose-webhook-client.md
│   │   ├── 15-controles-de-sante.md
│   │   └── 16-robustesse-compose.md
│   └── 03-kubernetes/
│       ├── 01-registre-images.md
│       ├── 02-stockage.md
│       ├── 03-postgres.md
│       ├── 04-secrets.md
│       ├── 05-redis.md
│       └── 06-rabbitmq.md
│
├── lab-local/
│   ├── README.md
│   ├── vagrant/
│   ├── ansible/
│   ├── scripts/
│   └── tests/
│
├── kubernetes/
│   ├── README.md
│   ├── sealed-secrets-cert.pem
│   ├── namespace-eshop.yaml
│   ├── sealedsecret-ghcr-pull.yaml
│   ├── postgres/
│   ├── rabbitmq/
│   └── redis/
│
└── README.md
```

Cette structure évoluera avec l’intégration de l’application et des composants de la chaîne DevOps.

## Documentation

Pour démarrer : [guide du laboratoire local](lab-local/README.md).

Les guides techniques se lisent dans l'ordre de construction du laboratoire :

| Guide | Sujet |
| ----- | ----- |
| [01 — Architecture](docs/01-lab-local/01-architecture.md) | Machines, réseaux, état du laboratoire |
| [02 — Vagrant](docs/01-lab-local/02-vagrant.md) | Création et gestion des machines |
| [03 — WSL2](docs/01-lab-local/03-wsl.md) | Poste de contrôle |
| [04 — Ansible](docs/01-lab-local/04-ansible.md) | Installation et configuration |
| [05 — Inventaire](docs/01-lab-local/05-inventory.md) | Inventaire et accès SSH |
| [06 — Rôles](docs/01-lab-local/06-roles.md) | Rôles, playbook et validation |
| [07 — Prérequis Kubernetes](docs/01-lab-local/07-kubernetes-prerequisites.md) | Préparation des systèmes |
| [08 — containerd](docs/01-lab-local/08-containerd.md) | Runtime de conteneurs |
| [09 — Kubernetes](docs/01-lab-local/09-kubernetes.md) | Installation des composants |
| [10 — Control Plane](docs/01-lab-local/10-control-plane.md) | Initialisation du cluster |
| [11 — Calico](docs/01-lab-local/11-calico.md) | Réseau des Pods |
| [12 — Worker](docs/01-lab-local/12-worker.md) | Jonction du Worker et tests réseau |
| [13 — Dépannage](docs/01-lab-local/13-troubleshooting.md) | Problèmes rencontrés et corrections |
| [14 — Volumes](docs/01-lab-local/14-local-path.md) | Fournisseur de volumes `local-path`, test de persistance |
| [15 — Sealed Secrets](docs/01-lab-local/15-sealed-secrets.md) | Contrôleur qui déchiffre les secrets, sauvegarde et restauration de sa clé |

Conteneurisation de l'application :

| Guide | Sujet |
| ----- | ----- |
| [Application eShop](application/README.md) | Provenance et version du code source |
| [01 — Catalog.API](docs/02-docker/01-catalog-api.md) | Image Docker du premier service, test avec ses dépendances |
| [02 — Autres services](docs/02-docker/02-autres-services.md) | Images des huit autres services, test de démarrage, configuration attendue |
| [03 — Compose : PostgreSQL](docs/02-docker/03-compose-postgres.md) | Base de données décrite dans Docker Compose, identifiants hors du dépôt |
| [04 — Compose : Redis](docs/02-docker/04-compose-redis.md) | Stockage des paniers, mot de passe et persistance |
| [05 — Compose : RabbitMQ](docs/02-docker/05-compose-rabbitmq.md) | Messagerie entre services, nom de nœud fixe, interface d'administration locale |
| [06 — Compose : Identity.API](docs/02-docker/06-compose-identity.md) | Premier service, construction de l'image par Compose, attente de PostgreSQL |
| [07 — Compose : Catalog.API](docs/02-docker/07-compose-catalog.md) | Catalogue, connexion à RabbitMQ, attente de la réponse du service |
| [08 — Compose : Basket.API](docs/02-docker/08-compose-basket.md) | Panier, Redis, gRPC en HTTP/2, dépendance à Identity.API |
| [09 — Compose : Ordering.API](docs/02-docker/09-compose-ordering.md) | Commandes, tables partagées avec OrderProcessor, contrôle d'accès |
| [10 — Compose : OrderProcessor](docs/02-docker/10-compose-order-processor.md) | Tâche de fond, vérification sans API, démarrage avant les tables |
| [11 — Compose : PaymentProcessor](docs/02-docker/11-compose-payment-processor.md) | Paiement simulé, liaisons RabbitMQ, événement de test à travers le bus |
| [12 — Compose : Webhooks.API](docs/02-docker/12-compose-webhooks.md) | Abonnements des applications extérieures, valeur d'origine remplacée, trois événements |
| [13 — Compose : WebApp](docs/02-docker/13-compose-webapp.md) | Boutique, adresse unique d'Identity.API, fichier `hosts`, parcours de commande de bout en bout |
| [14 — Compose : WebhookClient](docs/02-docker/14-compose-webhook-client.md) | Site de démonstration des webhooks, adresse vue du réseau Docker, notification reçue |
| [15 — Les contrôles de santé](docs/02-docker/15-controles-de-sante.md) | Routes `/health` et `/alive` activables, contrôle sans `curl`, démarrage par vagues |
| [16 — Robustesse du fichier Compose](docs/02-docker/16-robustesse-compose.md) | Redémarrage, journaux, plafonds de mémoire, image PostgreSQL, revue extérieure |

Déploiement sur Kubernetes :

| Guide | Sujet |
| ----- | ----- |
| [Manifestes Kubernetes](kubernetes/README.md) | Cible du déploiement, règles, contenu du répertoire `kubernetes/` |
| [01 — Le registre d'images](docs/03-kubernetes/01-registre-images.md) | Images privées sur `ghcr.io`, étiquette du commit, jetons, secret d'accès du cluster |
| [02 — Le stockage](docs/03-kubernetes/02-stockage.md) | Options de stockage, usage en entreprise, choix du laboratoire et d'AWS |
| [03 — PostgreSQL](docs/03-kubernetes/03-postgres.md) | `StatefulSet`, probes, conservation des données vérifiée |
| [04 — Les secrets](docs/03-kubernetes/04-secrets.md) | Secrets chiffrés dans le dépôt avec `kubeseal`, options d'entreprise, cluster neuf sans ressaisie, changement de mot de passe |
| [05 — Redis](docs/03-kubernetes/05-redis.md) | Version figée, mot de passe exigé et absent des arguments du processus, persistance vérifiée |
| [06 — RabbitMQ](docs/03-kubernetes/06-rabbitmq.md) | Version figée, nom de nœud stable fourni par le `StatefulSet`, mot de passe exigé, persistance vérifiée |

## Feuille de route

1. **Fondations :** construire un laboratoire Kubernetes local reproductible. Étape réalisée.
2. **Application :** intégrer et valider l’application e-commerce.
3. **Déploiement :** conteneuriser les services et préparer les charts Helm.
4. **Automatisation :** construire la chaîne CI/CD avec GitHub Actions.
5. **GitOps :** automatiser la synchronisation des déploiements avec Argo CD.
6. **Exploitation :** ajouter l’observabilité, les contrôles de sécurité et les procédures de maintenance.
7. **Cloud :** étudier l’industrialisation de l’infrastructure avec Terraform, sur AWS. Le cluster y sera un cluster **EKS**, géré par AWS, avec le stockage EBS CSI : c’est l’usage courant en entreprise. Décision du 16 octobre 2026. Conséquence : Ansible ne sert qu’à construire le laboratoire local, et reste donc dans `lab-local/ansible/`.

## Philosophie du projet

Le projet suit quelques principes fondamentaux :

* Automatiser les opérations répétitives.
* Séparer les responsabilités entre les composants.
* Favoriser la reproductibilité et l’idempotence.
* Documenter les choix techniques et les procédures.
* Valider chaque étape avant d’ajouter de la complexité.
* Ne déclarer un composant opérationnel qu’après l’avoir testé.

## Objectif final

Disposer d’un projet DevOps documenté et démontrable, illustrant le cycle de vie d’une application e-commerce : infrastructure, automatisation, conteneurisation, orchestration, déploiement continu, observabilité et sécurité.
