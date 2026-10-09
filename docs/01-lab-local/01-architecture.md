# 01 — Architecture du laboratoire local

## 1. Objectif

Ce document présente l'architecture du laboratoire Kubernetes local du projet **EshopOnContainer**.

Il définit :

* les composants du laboratoire ;
* les machines virtuelles ;
* leurs rôles ;
* les ressources allouées ;
* le réseau utilisé ;
* les relations entre les différents composants.

Les procédures de création et de gestion des machines virtuelles sont détaillées dans `02-vagrant.md`.

La configuration de l'environnement de contrôle WSL2 est présentée dans `03-wsl.md`.

---

## 2. Vue d'ensemble

Le laboratoire est hébergé sur un poste Windows.

**VMware Workstation** fournit la virtualisation des machines virtuelles et **Vagrant** permet de déclarer et de gérer leur configuration.

**WSL2** fournit l'environnement Linux utilisé comme poste de contrôle pour l'administration du laboratoire.

**Ansible** est utilisé depuis WSL2 afin de préparer et configurer les machines virtuelles.

### Pourquoi VMware Workstation et non VirtualBox ?

Le laboratoire a d'abord été construit sous VirtualBox. Il a été migré vers VMware Workstation le 8 octobre 2026.

WSL2 impose que l'hyperviseur Hyper-V reste actif sur le poste Windows. Dans cette situation, VirtualBox ne dispose plus de la virtualisation matérielle et les machines virtuelles se figent au démarrage. VMware Workstation fonctionne avec Hyper-V actif, ce qui permet d'utiliser les machines virtuelles et WSL2 en même temps.

Le diagnostic complet est consigné dans `13-troubleshooting.md` (problème 1).

```text
                              Poste Windows
                                   |
                    +--------------+--------------+
                    |                             |
           VMware Workstation                    WSL2
                    |                             |
              Vagrant                         Ansible
                    |                             |
          +---------+---------+                  |
          |                   |                  |
          v                   v                  |
   kube-control         kube-worker             |
   192.168.57.10        192.168.57.11           |
   Control Plane         Worker Node             |
          |                   |                  |
          +---------+---------+                  |
                    |                             |
                    +-----------------------------+
                         Réseau privé
                       192.168.57.0/24
```

---

## 3. Composants du laboratoire

Le laboratoire repose sur six composants principaux.

| Composant          | Rôle                                          |
| ------------------ | --------------------------------------------- |
| Windows            | Système hôte                                  |
| VMware Workstation | Hyperviseur                                   |
| Vagrant            | Gestion et définition des machines virtuelles |
| WSL2 / Ubuntu      | Environnement Linux de contrôle               |
| Ansible            | Automatisation de la configuration            |
| Kubernetes         | Orchestration des workloads                   |

La séparation des responsabilités permet de distinguer clairement :

* la création de l'infrastructure ;
* l'administration des systèmes ;
* l'orchestration des applications.

---

## 4. Machines virtuelles

Le laboratoire comporte actuellement deux machines virtuelles.

| Propriété         | `kube-control`   | `kube-worker`    |
| ----------------- | ---------------- | ---------------- |
| Système           | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| Rôle              | Control Plane    | Worker Node      |
| Adresse IP privée | `192.168.57.10`  | `192.168.57.11`  |
| Mémoire           | 3 Go             | 6 Go             |
| CPU virtuels      | 2                | 2                |

Le Worker reçoit davantage de mémoire que le Control Plane, car c'est lui qui exécutera les Pods applicatifs d'eShop.

### 4.1 `kube-control`

La machine `kube-control` constitue le **Control Plane** du cluster Kubernetes.

Elle héberge les composants permettant de :

* gérer l'état du cluster ;
* recevoir les demandes d'administration ;
* planifier les workloads ;
* coordonner les différents nœuds.

Son adresse privée est :

```text
192.168.57.10
```

### 4.2 `kube-worker`

La machine `kube-worker` constitue le **Worker Node**.

Elle est chargée d'exécuter les workloads Kubernetes, notamment les Pods applicatifs.

Son adresse privée est :

```text
192.168.57.11
```

---

## 5. Architecture réseau

Chaque machine virtuelle possède deux interfaces réseau.

| Interface | Réseau             | Réseau VMware        | Adressage | Usage                                      |
| --------- | ------------------ | -------------------- | --------- | ------------------------------------------ |
| `eth0`    | `192.168.200.0/24` | `VMnet8` (NAT)       | DHCP      | Accès à Internet                           |
| `eth1`    | `192.168.57.0/24`  | `VMnet6` (host-only) | Statique  | Communication entre nœuds et administration |

### 5.1 Réseau NAT

Le réseau NAT permet aux machines virtuelles d'accéder aux ressources externes, notamment Internet.

Les adresses sont attribuées par le service DHCP de VMware. Celles observées le 8 octobre 2026 sont :

```text
kube-control → 192.168.200.129
kube-worker  → 192.168.200.130
```

Ces adresses changent d'une création à l'autre. Après la reconstruction des machines le 9 octobre 2026, elles valaient :

```text
kube-control → 192.168.200.140
kube-worker  → 192.168.200.141
```

Elles ne doivent donc pas être utilisées comme adresses de communication entre les nœuds Kubernetes.

La route par défaut de chaque machine passe par cette interface :

```text
default via 192.168.200.2 dev eth0
```

Cette particularité impose de désigner explicitement l'adresse du réseau privé à Kubernetes, qui retiendrait sinon celle du réseau NAT. Ce point est traité dans `10-control-plane.md` (section 4).

### 5.2 Réseau privé

Le laboratoire utilise le réseau privé :

```text
192.168.57.0/24
```

Les adresses sont attribuées statiquement :

| Équipement              | Adresse            |
| ----------------------- | ------------------ |
| Poste Windows (`VMnet6`) | `192.168.57.1/24`  |
| `kube-control`          | `192.168.57.10/24` |
| `kube-worker`           | `192.168.57.11/24` |

Ce réseau est utilisé pour l'administration depuis WSL2 et pour les communications entre les nœuds du cluster.

L'adresse `192.168.57.1` du poste Windows est indispensable : sans elle, ni Windows ni WSL2 ne peuvent joindre les machines virtuelles. Sa mise en place est décrite dans `02-vagrant.md`.

---

## 6. Environnement de contrôle

WSL2 est utilisé comme environnement Linux de contrôle.

Depuis WSL2, l'administrateur peut :

* utiliser SSH ;
* exécuter Ansible ;
* administrer les machines virtuelles ;
* exécuter les commandes Kubernetes, à travers une session SSH sur `kube-control`, seule machine où `kubectl` est configuré.

La connectivité réseau entre WSL2 et les machines virtuelles a été vérifiée.

Tests réalisés :

```bash
ping -c 3 192.168.57.10
ping -c 3 192.168.57.11
```

Les deux machines répondent correctement.

La validation de l'accès **SSH depuis WSL2** constitue une étape distincte, documentée dans `05-inventory.md`.

---

## 7. Flux d'administration

Le flux d'administration est le suivant :

```text
Administrateur
      |
      v
   Windows
      |
      v
    WSL2
      |
      v
   Ansible
      |
      | SSH
      |
      +--------------------+
      |                    |
      v                    v
kube-control          kube-worker
192.168.57.10         192.168.57.11
```

Ansible n'est donc pas exécuté depuis les machines Kubernetes elles-mêmes.

Le poste de contrôle est WSL2.

---

## 8. État du laboratoire

### Infrastructure

* [x] Machines virtuelles créées.
* [x] Ubuntu 22.04 LTS installé.
* [x] Adresses IP privées configurées.
* [x] Connectivité WSL2 → `kube-control` vérifiée.
* [x] Connectivité WSL2 → `kube-worker` vérifiée.
* [x] Accès SSH depuis WSL2 validé.
* [x] Inventaire Ansible validé.

### Préparation Kubernetes

* [x] Préparation des systèmes avec Ansible.
* [x] Installation de containerd.
* [x] Installation des composants Kubernetes.
* [x] Initialisation du Control Plane.
* [x] Installation du plugin réseau CNI.
* [x] Jonction du Worker.
* [x] Validation du cluster.

### Automatisation

* [x] Préparation des systèmes, `containerd` et composants Kubernetes automatisés avec Ansible.
* [x] Initialisation du Control Plane automatisée avec Ansible.
* [x] Installation du plugin réseau automatisée avec Ansible.
* [x] Jonction du Worker automatisée avec Ansible.
* [x] Reconstruction complète du cluster validée à partir de machines neuves.
* [x] Remise en place des accès SSH regroupée dans un script.
* [ ] Enchaînement de la création des machines, des accès SSH et d'Ansible en une seule commande.

Le laboratoire a d'abord été construit à la main le 8 octobre 2026, puis automatisé le 9 octobre 2026. Les éléments cochés ont été vérifiés le 9 octobre 2026 sur le cluster reconstruit par Ansible, dont le résultat est présenté dans `06-roles.md` (section 8.3).

La validation du cluster comprend trois tests fonctionnels du réseau (Pod à Pod entre nœuds, Service, DNS). Ils ont été rejoués avec succès le 9 octobre 2026 sur le cluster reconstruit, comme décrit dans `12-worker.md` (section 7).

---

## 9. Documentation associée

| Fichier                          | Responsabilité                              |
| -------------------------------- | ------------------------------------------- |
| `01-architecture.md`             | Architecture générale du laboratoire        |
| `02-vagrant.md`                  | Création et gestion des machines virtuelles |
| `03-wsl.md`                      | Configuration de l'environnement WSL2       |
| `04-ansible.md`                  | Installation et configuration d'Ansible     |
| `05-inventory.md`                | Inventaire Ansible et accès SSH             |
| `06-roles.md`                    | Organisation des rôles Ansible              |
| `07-kubernetes-prerequisites.md` | Préparation des nœuds Kubernetes            |
| `08-containerd.md`               | Installation et configuration de containerd |
| `09-kubernetes.md`               | Installation des composants Kubernetes      |
| `10-control-plane.md`            | Initialisation du Control Plane             |
| `11-calico.md`                   | Installation et validation du CNI Calico    |
| `12-worker.md`                   | Jonction et validation du Worker            |
| `13-troubleshooting.md`          | Diagnostic des problèmes                    |

---

## 10. Principe d'organisation

Le laboratoire suit une séparation claire des responsabilités :

```text
Vagrant
  ↓
Création des VMs

WSL2
  ↓
Environnement de contrôle

Ansible
  ↓
Configuration des systèmes

Kubernetes
  ↓
Orchestration des workloads
```

Cette organisation permet de reproduire une approche proche d'un environnement professionnel dans lequel :

* l'infrastructure est définie séparément ;
* la configuration est automatisée ;
* les nœuds sont administrés à distance ;
* Kubernetes est utilisé comme couche d'orchestration.

Ce document constitue la référence architecturale du laboratoire local. Il ne décrit pas les procédures détaillées d'installation ou de configuration des composants.

---

## 11. Étape suivante

La prochaine étape consiste à créer les machines virtuelles décrites dans ce document.

Elle est documentée dans `02-vagrant.md`.
