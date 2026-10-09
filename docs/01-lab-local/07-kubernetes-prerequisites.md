# 07 — Prérequis Kubernetes

## 1. Objectif

Ce document décrit la préparation système nécessaire au fonctionnement des nœuds Kubernetes du laboratoire local EshopOnContainer.

La préparation est automatisée avec Ansible à travers le rôle `common`.

Le rôle est appliqué aux groupes `control_plane` et `workers`, regroupés dans le groupe logique `k8s_cluster`.

L'objectif est de préparer les systèmes Linux avant l'installation de `kubeadm`, `kubelet` et `kubectl`.

Les opérations d'initialisation du cluster ne font pas partie de cette étape.

---

## 2. Périmètre

La préparation concerne actuellement les deux machines virtuelles suivantes :

| Nœud           | Rôle          | OS                 | Architecture |
| -------------- | ------------- | ------------------ | ------------ |
| `kube-control` | Control Plane | Ubuntu 22.04.3 LTS | `x86_64`     |
| `kube-worker`  | Worker        | Ubuntu 22.04.3 LTS | `x86_64`     |

La version du système est celle fournie par la box Vagrant décrite dans `02-vagrant.md`. Elle a été vérifiée sur les deux nœuds le 8 octobre 2026.

Les adresses et le réseau des machines sont définis dans `01-architecture.md`.

---

## 3. Rôle Ansible utilisé

La préparation est implémentée dans :

```text
lab-local/
└── ansible/
    └── roles/
        └── common/
            └── tasks/
                └── main.yml
```

Le rôle est appelé par le playbook principal :

```yaml
---
- name: Préparer les noeuds du cluster Kubernetes
  hosts: k8s_cluster
  become: true

  roles:
    - common
    - containerd
    - kubernetes
```

Le rôle `common` est exécuté en premier, afin de préparer le système avant la configuration du runtime de conteneurs.

Les rôles `containerd` et `kubernetes` sont exécutés par le même playbook, mais ils sont documentés séparément dans `08-containerd.md` et `09-kubernetes.md`.

---

## 4. Paquets système nécessaires

Le rôle `common` installe les paquets suivants :

```yaml
- ca-certificates
- curl
- gpg
- apt-transport-https
```

Ces paquets fournissent notamment les outils et certificats nécessaires à la récupération et à la vérification de ressources provenant de dépôts HTTPS.

L'installation est réalisée avec le module Ansible `ansible.builtin.apt`.

La tâche utilise :

```yaml
update_cache: true
cache_valid_time: 3600
```

Cela permet de mettre à jour l'index APT tout en évitant une actualisation inutile lorsque le cache est encore considéré comme valide.

---

## 5. Modules du noyau Linux

Kubernetes et les composants réseau utilisés par les conteneurs nécessitent certains modules du noyau Linux.

Le rôle charge :

```text
overlay
br_netfilter
```

La tâche utilisée est :

```yaml
- name: Charger les modules kernel nécessaires à Kubernetes
  community.general.modprobe:
    name: "{{ item }}"
    state: present
  loop:
    - overlay
    - br_netfilter
```

### `overlay`

`overlay` fournit le support du système de fichiers OverlayFS.

Il est notamment utilisé par les runtimes de conteneurs pour gérer efficacement les différentes couches des images de conteneurs.

### `br_netfilter`

`br_netfilter` permet au trafic traversant des bridges Linux d'être traité par les mécanismes de filtrage réseau du noyau.

Il est nécessaire pour le fonctionnement attendu de certaines règles réseau Kubernetes.

---

## 6. Persistance des modules

Le chargement des modules avec `modprobe` ne suffit pas à garantir leur chargement après un redémarrage.

Le rôle crée donc :

```text
/etc/modules-load.d/kubernetes.conf
```

avec :

```text
overlay
br_netfilter
```

La configuration est ainsi persistante.

La tâche Ansible utilisée est :

```yaml
- name: Rendre les modules kernel persistants
  ansible.builtin.copy:
    dest: /etc/modules-load.d/kubernetes.conf
    content: |
      overlay
      br_netfilter
    owner: root
    group: root
    mode: '0644'
```

---

## 7. Paramètres réseau du noyau

Le rôle configure les paramètres `sysctl` nécessaires à Kubernetes :

```text
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
```

La configuration est persistante dans :

```text
/etc/sysctl.d/99-kubernetes.conf
```

### `net.bridge.bridge-nf-call-iptables`

Permet au trafic traversant les bridges réseau d'être traité par les règles iptables.

### `net.bridge.bridge-nf-call-ip6tables`

Fournit le même comportement pour le trafic IPv6.

### `net.ipv4.ip_forward`

Active le routage IPv4 au niveau du noyau.

Ce comportement est nécessaire pour permettre au nœud de transférer du trafic entre différentes interfaces ou réseaux, notamment dans le contexte réseau d'un cluster Kubernetes.

La tâche utilise :

```yaml
- name: Configurer les paramètres réseau nécessaires à Kubernetes
  ansible.builtin.sysctl:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    state: present
    reload: true
    sysctl_file: /etc/sysctl.d/99-kubernetes.conf
  loop:
    - name: net.bridge.bridge-nf-call-iptables
      value: "1"
    - name: net.bridge.bridge-nf-call-ip6tables
      value: "1"
    - name: net.ipv4.ip_forward
      value: "1"
```

---

## 8. Swap

### 8.1 Pourquoi désactiver le swap ?

Par défaut, `kubelet` refuse de démarrer sur un nœud dont le swap est actif (paramètre `failSwapOn`). La procédure d'installation de `kubeadm` demande donc de le désactiver.

Le laboratoire conserve ce comportement par défaut : le swap est désactivé sur les deux machines avant l'initialisation du cluster.

### 8.2 État constaté avant correction

Avec la première box utilisée par le laboratoire (`ubuntu/jammy64`), les machines démarraient sans swap et aucune tâche Ansible n'était nécessaire.

Ce n'est plus le cas depuis le changement de box décrit dans `02-vagrant.md`. La box `bento/ubuntu-22.04` crée un fichier de swap de 2 Go.

```bash
ansible all -m shell -a 'swapon --show'
```

Cette commande liste les zones de swap actives. Une sortie vide signifie que le swap est désactivé.

Résultat constaté le 8 octobre 2026, avant correction, sur les deux nœuds :

```text
NAME      TYPE SIZE USED PRIO
/swap.img file   2G   0B   -2
```

Le fichier `/etc/fstab` contenait la ligne qui réactive ce swap à chaque démarrage :

```text
/swap.img	none	swap	sw	0	0
```

### 8.3 Désactivation avec Ansible

Deux tâches ont été ajoutées au rôle `common`. Elles répondent à deux besoins distincts : l'état immédiat et la persistance.

```yaml
- name: Désactiver le swap immédiatement
  ansible.builtin.command: swapoff -a
  when: ansible_swaptotal_mb > 0
  changed_when: true
```

Cette tâche désactive le swap sur le système en cours d'exécution.

La condition `when` utilise un fait collecté par Ansible : la tâche n'est exécutée que si du swap est présent. Sur un système déjà corrigé, elle est ignorée, ce qui préserve l'idempotence.

```yaml
- name: Désactiver le swap au démarrage
  ansible.builtin.replace:
    path: /etc/fstab
    regexp: '^([^#].*\sswap\s.*)$'
    replace: '# \1'
```

Cette tâche commente dans `/etc/fstab` toute ligne de swap qui ne l'est pas déjà. Sans elle, le swap reviendrait au prochain redémarrage.

### 8.4 Vérification

État immédiat :

```bash
ansible all -m shell -a 'swapon --show'
ansible all -m shell -a 'free -h'
```

La commande `free -h` affiche l'utilisation de la mémoire. La ligne `Swap` doit indiquer un total nul.

Résultat vérifié sur les deux nœuds :

```text
Swap:             0B          0B          0B
```

La commande `swapon --show` ne retourne plus aucune sortie.

Persistance :

```bash
ansible all -m shell -a 'grep swap /etc/fstab'
```

Cette commande affiche les lignes de `/etc/fstab` qui concernent le swap. Elles doivent commencer par `#`.

Résultat vérifié sur les deux nœuds :

```text
# /swap.img     none    swap    sw      0       0
```

Le fait que le swap ait été détecté par une vérification, et non par une panne, est consigné dans `13-troubleshooting.md` (problème 7).

---

## 9. Validation des modules

Après exécution du rôle, les modules ont été vérifiés sur les deux nœuds.

Commande utilisée :

```bash
ansible k8s_cluster -m shell -a 'lsmod | grep -E "overlay|br_netfilter"'
```

Les modules suivants sont présents :

```text
overlay
br_netfilter
```

La persistance a également été vérifiée :

```bash
ansible k8s_cluster -m shell -a 'cat /etc/modules-load.d/kubernetes.conf'
```

Résultat attendu :

```text
overlay
br_netfilter
```

---

## 10. Validation des paramètres réseau

Les fichiers de configuration ont été vérifiés :

```bash
ansible k8s_cluster -m shell -a 'cat /etc/sysctl.d/99-kubernetes.conf'
```

Les valeurs attendues sont :

```text
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
```

Les valeurs actives du noyau ont également été vérifiées.

Les trois paramètres retournent :

```text
1
```

sur les deux nœuds.

---

## 11. Idempotence

Le playbook a été exécuté plusieurs fois le 8 octobre 2026.

Après la configuration, une nouvelle exécution retourne :

```text
kube-control : ok=17   changed=0    unreachable=0    failed=0    skipped=1
kube-worker  : ok=17   changed=0    unreachable=0    failed=0    skipped=1
```

Ce résultat porte sur l'ensemble du playbook, c'est-à-dire sur les trois rôles.

L'absence de changement confirme que les tâches convergent vers l'état souhaité sans modifier inutilement les systèmes déjà configurés.

La tâche ignorée (`skipped=1`) est « Désactiver le swap immédiatement » : sa condition n'est plus remplie puisque le swap est déjà désactivé.

```text
TASK [common : Désactiver le swap immédiatement]
skipping: [kube-control]
skipping: [kube-worker]
```

---

## 12. État obtenu

À l'issue de cette étape, les deux nœuds disposent des prérequis système nécessaires à la poursuite de l'installation.

```text
kube-control
    ├── paquets système installés
    ├── overlay chargé
    ├── br_netfilter chargé
    ├── modules persistants
    ├── IPv4 forwarding activé
    ├── paramètres bridge/netfilter configurés
    ├── swap désactivé
    └── swap commenté dans /etc/fstab

kube-worker
    ├── paquets système installés
    ├── overlay chargé
    ├── br_netfilter chargé
    ├── modules persistants
    ├── IPv4 forwarding activé
    ├── paramètres bridge/netfilter configurés
    ├── swap désactivé
    └── swap commenté dans /etc/fstab
```

La préparation système est donc considérée comme validée.

---

## 13. Limites de cette étape

Cette étape ne réalise pas :

* l'installation de `kubeadm` ;
* l'installation de `kubelet` ;
* l'installation de `kubectl` ;
* l'initialisation du Control Plane ;
* la création du cluster ;
* l'installation du CNI ;
* la jonction du Worker au cluster.

Ces opérations sont réalisées dans les étapes suivantes, de `08-containerd.md` à `12-worker.md`.

---

## 14. Étape suivante

La prochaine étape consiste à installer et configurer le runtime de conteneurs `containerd`.

Cette configuration est documentée dans :

```text
docs/01-lab-local/08-containerd.md
```

Le rôle Ansible correspondant est :

```text
lab-local/ansible/
└── roles/
    └── containerd/
```

Les composants Kubernetes ne sont installés qu'après le runtime de conteneurs : dans le playbook, le rôle `containerd` précède le rôle `kubernetes`.
