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
| Construction des images | Docker                      | Prévu   |
| Déploiement applicatif  | Helm                        | Prévu   |
| CI/CD                   | GitHub Actions              | Prévu   |
| GitOps                  | Argo CD                     | Prévu   |
| Observabilité           | Prometheus, Grafana et Loki | Prévu   |
| Sécurité                | Trivy et SonarQube          | Prévu   |
| Infrastructure as Code  | Terraform                   | Prévu   |
| Cloud                   | AWS                         | Prévu   |

« Utilisé » signifie que la technologie est en place, testée et documentée dans ce dépôt. « Prévu » signifie qu'elle fait partie de la feuille de route, sans être encore intégrée.

## État d’avancement

Le premier objectif était de construire un laboratoire Kubernetes local reproductible. Il est atteint : le cluster se reconstruit à partir de machines neuves avec trois commandes, décrites dans la [documentation du laboratoire local](lab-local/README.md).

### Laboratoire local

* [x] Création des machines virtuelles avec Vagrant et VMware.
* [x] Automatisation de la configuration avec Ansible.
* [x] Préparation des nœuds pour Kubernetes.
* [x] Initialisation du Control Plane, automatisée avec Ansible.
* [x] Configuration du réseau des pods avec Calico, automatisée avec Ansible.
* [x] Intégration du Worker au cluster, automatisée avec Ansible.
* [x] Reconstruction complète du cluster validée à partir de machines neuves.
* [x] Tests du réseau du cluster : Pod à Pod entre nœuds, Service et DNS.
* [x] Documentation du laboratoire, en treize guides.
* [x] Inventaire Ansible portable, sans chemin lié à un compte utilisateur.
* [ ] Enchaînement de la reconstruction en une seule commande.

### Suite du projet

* [ ] Intégration et validation de l’application e-commerce.
* [ ] Déploiement applicatif avec Helm.
* [ ] Mise en place de GitHub Actions et d’Argo CD.
* [ ] Intégration de l’observabilité et des contrôles de sécurité.
* [ ] Étude du déploiement cloud avec Terraform.

## Structure du dépôt

```text
EshopOnContainer/
├── docs/
│   └── 01-lab-local/
│       ├── 01-architecture.md
│       ├── 02-vagrant.md
│       ├── 03-wsl.md
│       ├── 04-ansible.md
│       ├── 05-inventory.md
│       ├── 06-roles.md
│       ├── ...
│       └── 13-troubleshooting.md
│
├── lab-local/
│   ├── README.md
│   ├── vagrant/
│   ├── ansible/
│   └── scripts/
│
├── kubernetes/
│   └── tests/
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

## Feuille de route

1. **Fondations :** construire un laboratoire Kubernetes local reproductible. Étape réalisée.
2. **Application :** intégrer et valider l’application e-commerce.
3. **Déploiement :** conteneuriser les services et préparer les charts Helm.
4. **Automatisation :** construire la chaîne CI/CD avec GitHub Actions.
5. **GitOps :** automatiser la synchronisation des déploiements avec Argo CD.
6. **Exploitation :** ajouter l’observabilité, les contrôles de sécurité et les procédures de maintenance.
7. **Cloud :** étudier l’industrialisation de l’infrastructure avec Terraform.

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
