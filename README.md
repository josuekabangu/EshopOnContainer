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

| Domaine                | Technologies prévues ou utilisées |
| ---------------------- | --------------------------------- |
| Virtualisation         | VMware Workstation                |
| Provisionnement local  | Vagrant                           |
| Configuration système  | Ansible                           |
| Conteneurs             | Docker et containerd              |
| Orchestration          | Kubernetes                        |
| Réseau Kubernetes      | Calico                            |
| Déploiement applicatif | Helm                              |
| CI/CD                  | GitHub Actions                    |
| GitOps                 | Argo CD                           |
| Observabilité          | Prometheus, Grafana et Loki       |
| Sécurité               | Trivy et SonarQube                |
| Infrastructure as Code | Terraform                         |
| Cloud                  | AWS, dans une phase ultérieure    |

Les technologies prévues ne signifient pas que tous les composants sont déjà intégrés ou opérationnels.

## État d’avancement

Le premier objectif est de construire un laboratoire Kubernetes local reproductible.

* [x] Création des machines virtuelles avec Vagrant et VMware.
* [x] Automatisation de la configuration avec Ansible.
* [x] Préparation des nœuds pour Kubernetes.
* [x] Initialisation du Control Plane.
* [x] Configuration du réseau des pods avec Calico.
* [x] Intégration du Worker au cluster.
* [ ] Amélioration de la portabilité de l’inventaire Ansible.
* [ ] Finalisation de la documentation et des tests d’acceptation.
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
│       ├── 03-wsl2.md
│       ├── 04-ansible.md
│       ├── 05-inventory.md
│       ├── 06-roles.md
│       └── ...
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

* [Documentation du laboratoire local](lab-local/README.md)
* [Architecture du laboratoire](docs/01-lab-local/01-architecture.md)
* [Configuration Vagrant](docs/01-lab-local/02-vagrant.md)
* [Environnement WSL2](docs/01-lab-local/03-wsl2.md)
* [Configuration Ansible](docs/01-lab-local/04-ansible.md)
* [Inventaire Ansible](docs/01-lab-local/05-inventory.md)
* [Organisation des rôles Ansible](docs/01-lab-local/06-roles.md)

## Feuille de route

1. **Fondations :** finaliser et fiabiliser le laboratoire Kubernetes local.
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
