# 01 — Architecture du laboratoire local

## 1. Objectif

Ce document présente l'architecture du laboratoire Kubernetes local du projet EshopOnContainer.

Il définit les machines virtuelles, leurs rôles, leurs ressources et leur réseau de communication.

Les procédures de création des machines sont détaillées dans `02-vagrant.md`.

## 2. Vue d'ensemble

Le laboratoire est hébergé sur un poste Windows. VirtualBox assure la virtualisation et Vagrant permet de définir et de gérer les machines virtuelles.

```text
                    Poste Windows
                         |
                  Vagrant / VirtualBox
                         |
              +----------+----------+
              |                     |
              v                     v
         kube-control          kube-worker
         192.168.57.10         192.168.57.11
         Control Plane         Worker Node
              |                     |
              +----------+----------+
                         |
                  Réseau privé
                  192.168.57.0/24
```

## 3. Machines virtuelles

| Propriété         | `kube-control`   | `kube-worker`    |
| ----------------- | ---------------- | ---------------- |
| Système           | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| Rôle cible        | Control Plane    | Worker Node      |
| Adresse IP privée | `192.168.57.10`  | `192.168.57.11`  |
| Mémoire vive      | 3 Go             | 2 Go             |
| CPU virtuels      | 2                | 2                |

### 3.1 Control Plane

La machine `kube-control` hébergera les composants de contrôle du cluster Kubernetes. Elle permettra notamment de gérer l'état du cluster et de coordonner les workloads.

### 3.2 Worker Node

La machine `kube-worker` hébergera les workloads déployés dans le cluster Kubernetes.

Les applications seront planifiées sur les nœuds en fonction de leurs ressources disponibles et des contraintes définies.

## 4. Architecture réseau

Chaque machine dispose d'une interface NAT et d'une interface associée au réseau privé du laboratoire.

### Interface NAT

L'interface NAT permet notamment aux machines virtuelles d'accéder à Internet.

Exemple d'adresse observée : `10.0.2.15`.

Cette adresse dépend de la configuration NAT de VirtualBox et ne doit pas être confondue avec l'adresse privée du laboratoire.

### Réseau privé

Le réseau privé permet aux machines virtuelles de communiquer directement entre elles.

| Machine        | Adresse privée     |
| -------------- | ------------------ |
| `kube-control` | `192.168.57.10/24` |
| `kube-worker`  | `192.168.57.11/24` |

Les communications entre les nœuds du cluster utiliseront ce réseau.

## 5. État du laboratoire

### Infrastructure

* [x] Machines virtuelles créées.
* [x] Ubuntu 22.04 LTS opérationnel.
* [x] Adresses IP privées configurées.
* [x] Accès SSH fonctionnel.
* [x] Communication entre les deux machines vérifiée.

### Cluster Kubernetes

* [ ] Préparation des systèmes avec Ansible.
* [ ] Installation de containerd.
* [ ] Installation des composants Kubernetes.
* [ ] Initialisation du Control Plane.
* [ ] Installation du plugin réseau CNI.
* [ ] Jonction du Worker.
* [ ] Validation du cluster.

Ces étapes constituent la cible de construction du laboratoire ; leur réalisation sera documentée dans les fichiers suivants.

## 6. Documentation associée

| Fichier                          | Responsabilité                                     |
| -------------------------------- | -------------------------------------------------- |
| `02-vagrant.md`                  | Création et gestion des machines virtuelles        |
| `03-ansible.md`                  | Automatisation de la configuration des systèmes    |
| `04-inventory.md`                | Déclaration des machines dans l'inventaire Ansible |
| `05-roles.md`                    | Organisation des rôles Ansible                     |
| `06-kubernetes-prerequisites.md` | Préparation des nœuds pour Kubernetes              |
| `07-containerd.md`               | Installation et configuration de containerd        |
| `08-kubernetes.md`               | Composants et fonctionnement de Kubernetes         |
| `09-control-plane.md`            | Initialisation du Control Plane                    |
| `10-calico.md`                   | Installation et validation du CNI Calico           |
| `11-worker.md`                   | Jonction et validation du Worker                   |
| `12-troubleshooting.md`          | Diagnostic des problèmes du laboratoire            |

Ce document constitue la référence architecturale du laboratoire local. Il ne décrit pas les procédures d'installation ou de configuration des composants.
