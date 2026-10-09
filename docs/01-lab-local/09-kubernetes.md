# 09 — Installation des composants Kubernetes

## 1. Objectif

Cette étape consiste à installer les composants nécessaires à l'utilisation de Kubernetes sur les nœuds du laboratoire.

Les composants installés sont :

* `kubeadm` ;
* `kubelet` ;
* `kubectl`.

L'installation est automatisée avec le rôle Ansible `kubernetes`.

Cette étape prépare les machines au bootstrap du cluster, mais **ne crée pas le cluster Kubernetes**.

L'initialisation du Control Plane est traitée dans `10-control-plane.md`.

---

## 2. Prérequis

Avant cette étape, les nœuds ont été préparés avec :

* Ubuntu 22.04 LTS ;
* swap désactivé ;
* modules kernel nécessaires chargés ;
* paramètres `sysctl` configurés ;
* containerd installé ;
* containerd configuré avec `SystemdCgroup = true`.

Ces prérequis sont documentés dans `07-kubernetes-prerequisites.md` et `08-containerd.md`.

---

## 3. Rôle des composants

Les trois composants ont des responsabilités différentes.

### 3.1 kubeadm

`kubeadm` est l'outil utilisé pour réaliser le bootstrap du cluster Kubernetes.

Il permet notamment de :

* initialiser le Control Plane avec `kubeadm init` ;
* joindre un Worker au cluster avec `kubeadm join` ;
* effectuer certaines opérations de bootstrap du cluster.

Dans cette étape, `kubeadm` est uniquement installé.

Aucune initialisation ni jonction n'est effectuée par ce rôle. Elles sont réalisées par les rôles `control_plane` et `worker`.

---

### 3.2 kubelet

`kubelet` est l'agent Kubernetes exécuté sur chaque nœud.

Il assure notamment l'exécution des Pods demandés par le Control Plane et communique avec les composants Kubernetes nécessaires au fonctionnement du nœud.

Il est présent sur :

```text
kube-control
    |
    └── kubelet

kube-worker
    |
    └── kubelet
```

Dans cette étape, le paquet est installé et le service est activé par systemd.

Le service reste toutefois inactif tant que le nœud n'est pas initialisé ou joint à un cluster.

---

### 3.3 kubectl

`kubectl` est le client en ligne de commande permettant d'administrer Kubernetes.

Il est notamment utilisé pour :

```bash
kubectl get nodes
kubectl get pods
kubectl get namespaces
kubectl describe node
```

Dans cette étape, `kubectl` est uniquement installé.

Sa configuration pour communiquer avec le cluster est réalisée par le rôle `control_plane`, décrit dans `10-control-plane.md`.

---

## 4. Version Kubernetes

La version utilisée dans le laboratoire est définie dans :

```text
lab-local/ansible/group_vars/all.yml
```

Configuration :

```yaml
kubernetes_minor_version: "1.36"
kubernetes_version: "1.36.5-1.1"
```

La variable `kubernetes_minor_version` permet de définir le dépôt APT utilisé :

```text
https://pkgs.k8s.io/core:/stable:/v1.36/deb/
```

La variable `kubernetes_version` permet de verrouiller la version exacte des paquets installés.

Les trois composants utilisent donc la même version :

```text
kubeadm  → 1.36.5
kubelet  → 1.36.5
kubectl  → 1.36.5
```

Cette approche rend le laboratoire plus reproductible.

---

## 5. Configuration du dépôt APT

Le rôle Ansible configure le dépôt Kubernetes officiel.

La clé du dépôt est téléchargée dans :

```text
/etc/apt/keyrings/kubernetes-apt-keyring.asc
```

Puis convertie au format GPG :

```text
/etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

Le dépôt est ensuite déclaré dans :

```text
/etc/apt/sources.list.d/kubernetes.list
```

avec une configuration équivalente à :

```text
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /
```

Cette configuration permet à APT de vérifier les paquets provenant du dépôt Kubernetes.

---

## 6. Installation avec Ansible

L'installation est réalisée par le rôle :

```text
roles/kubernetes/
└── tasks/
    └── main.yml
```

La tâche utilisée est :

```yaml
- name: Installer les composants Kubernetes
  ansible.builtin.apt:
    name:
      - "kubeadm={{ kubernetes_version }}"
      - "kubelet={{ kubernetes_version }}"
      - "kubectl={{ kubernetes_version }}"
      - "cri-tools={{ crictl_version }}"
    state: present
    update_cache: true
```

Le paquet `cri-tools`, ajouté le 8 octobre 2026, fournit l'outil `crictl` décrit en section 6.2.

Les paquets sont installés sur l'ensemble du groupe :

```text
k8s_cluster
├── control_plane
│   └── kube-control
└── workers
    └── kube-worker
```

### 6.1 Gel des versions

L'installation d'une version précise ne suffit pas à la conserver. Une mise à jour du système (`apt upgrade`) pourrait installer une version plus récente de `kubelet` sans mettre à jour `kubeadm`, et rendre les composants incohérents entre eux.

Le rôle marque donc les paquets comme figés :

```yaml
- name: Figer les versions des composants Kubernetes
  ansible.builtin.dpkg_selections:
    name: "{{ item }}"
    selection: hold
  loop:
    - kubeadm
    - kubelet
    - kubectl
    - cri-tools
```

Le module `ansible.builtin.dpkg_selections` enregistre l'état `hold` pour chaque paquet. APT ne les met alors plus à jour automatiquement. Une montée de version devra être décidée et réalisée explicitement.

Vérification :

```bash
ansible all -m shell -a 'apt-mark showhold'
```

Cette commande liste les paquets figés sur chaque nœud.

Résultat vérifié le 8 octobre 2026 sur les deux nœuds :

```text
cri-tools
kubeadm
kubectl
kubelet
```

Le paquet `containerd` est figé par le rôle `containerd`, qui l'installe, comme décrit dans `08-containerd.md` (section 6).

### 6.2 crictl

#### Pourquoi crictl ?

`kubectl` interroge l'API du cluster. Il ne peut donc rien dire d'un nœud qui n'a pas encore rejoint le cluster, ni d'un nœud dont `kubelet` ne répond plus.

`crictl` interroge directement le runtime de conteneurs, à travers la même interface CRI que `kubelet`. Il permet de diagnostiquer un nœud indépendamment de l'état du cluster. Il a notamment servi à contrôler le Worker avant sa jonction, décrite dans `12-worker.md`.

#### Version

La version est définie dans `lab-local/ansible/group_vars/all.yml` :

```yaml
crictl_version: "1.36.0-1.1"
```

Le paquet `cri-tools` provient du même dépôt APT que les composants Kubernetes. Sa version suit la version mineure `1.36`, sans être identique à celle de `kubeadm`.

#### Configuration

Sans configuration, `crictl` ne sait pas quel runtime interroger. Le rôle dépose donc le fichier `/etc/crictl.yaml` :

```yaml
- name: Configurer crictl pour containerd
  ansible.builtin.copy:
    dest: /etc/crictl.yaml
    owner: root
    group: root
    mode: '0644'
    content: |
      runtime-endpoint: unix:///run/containerd/containerd.sock
      image-endpoint: unix:///run/containerd/containerd.sock
      timeout: 10
      debug: false
```

| Paramètre          | Rôle                                                        |
| ------------------ | ----------------------------------------------------------- |
| `runtime-endpoint` | Socket du runtime, celui de `containerd` (`08-containerd.md`) |
| `image-endpoint`   | Socket utilisé pour la gestion des images                   |
| `timeout`          | Délai maximal d'une requête, en secondes                    |
| `debug`            | Affichage détaillé, désactivé                               |

#### Vérification

```bash
crictl --version
```

Cette commande affiche la version de l'outil installé.

Résultat vérifié le 8 octobre 2026 sur les deux nœuds :

```text
crictl version v1.36.0
```

```bash
sudo crictl info | grep -E 'RuntimeReady|NetworkReady'
```

Cette commande interroge le runtime et affiche les conditions qui indiquent si le runtime et le réseau sont prêts. Elle nécessite `sudo`, car le socket de `containerd` appartient à `root`.

Résultat vérifié sur les deux nœuds : les conditions `RuntimeReady` et `NetworkReady` sont présentes, ce qui confirme que `crictl` communique avec `containerd`.

### 6.3 Adresse du nœud

#### Pourquoi fixer l'adresse dans ce rôle ?

Chaque machine possède deux interfaces. Sans indication, `kubelet` enregistre le nœud avec l'adresse de l'interface NAT au lieu de celle du réseau privé. Les deux adresses en jeu et leur rôle sont expliqués dans `10-control-plane.md` (section 4).

L'adresse doit être en place **avant** que le nœud ne soit initialisé ou joint au cluster. Elle est donc fixée ici, dans le rôle appliqué à tous les nœuds, et non dans les rôles qui créent le cluster. Lorsqu'elle était corrigée après coup, le nœud passait d'abord par l'adresse NAT : c'est le problème 9 de `13-troubleshooting.md`.

#### Variable

L'adresse de chaque nœud figure déjà dans l'inventaire. Elle est réutilisée au lieu d'être écrite une seconde fois, dans `lab-local/ansible/group_vars/all.yml` :

```yaml
node_ip: "{{ ansible_host }}"
```

#### Tâche

```yaml
- name: Fixer l'adresse du nœud utilisée par kubelet
  ansible.builtin.copy:
    dest: /etc/default/kubelet
    owner: root
    group: root
    mode: '0644'
    content: |
      KUBELET_EXTRA_ARGS=--node-ip={{ node_ip }}
  notify: Redémarrer kubelet
```

Le fichier `/etc/default/kubelet` est lu par le service `kubelet` au démarrage. L'option `--node-ip` lui impose l'adresse sous laquelle il enregistre le nœud.

#### Handler

Le rôle dispose d'un handler, dans `roles/kubernetes/handlers/main.yml` :

```yaml
---
- name: Redémarrer kubelet
  ansible.builtin.systemd_service:
    name: kubelet
    state: restarted
    daemon_reload: true
```

`kubelet` n'est redémarré que si le contenu du fichier change. Sur un nœud déjà configuré, la tâche répond `ok` et le service n'est pas touché.

Sur une machine neuve, ce redémarrage a lieu avant l'initialisation du cluster. `kubelet` ne dispose alors d'aucune configuration et redémarre en boucle jusqu'à ce que `kubeadm` la lui fournisse. Ce comportement est normal.

#### Vérification

```bash
ansible all -m shell -a 'cat /etc/default/kubelet'
```

Cette commande affiche le fichier d'options de `kubelet` sur chaque nœud.

Résultat vérifié le 9 octobre 2026 :

```text
kube-control | KUBELET_EXTRA_ARGS=--node-ip=192.168.57.10
kube-worker  | KUBELET_EXTRA_ARGS=--node-ip=192.168.57.11
```

La prise en compte par le processus et l'effet sur l'enregistrement du nœud sont vérifiés dans `10-control-plane.md` et `12-worker.md`.

Cette tâche a d'abord été appliquée sur le cluster existant, où les fichiers avaient été écrits à la main : elle a répondu `ok` sur les deux nœuds, ce qui confirme qu'elle reproduit exactement la configuration manuelle.

---

## 7. Pourquoi installer les composants sur les deux nœuds ?

Les nœuds du cluster doivent disposer de `kubelet` et de `kubeadm`.

Le laboratoire installe également `kubectl` sur les deux machines afin de faciliter les opérations d'administration et de diagnostic.

| Composant | Control Plane | Worker |
| --------- | :-----------: | :----: |
| kubeadm   |       ✅       |    ✅   |
| kubelet   |       ✅       |    ✅   |
| kubectl   |       ✅       |    ✅   |

Cette organisation simplifie notamment les exercices de diagnostic du laboratoire.

---

## 8. Validation de l'installation

L'installation a été vérifiée sur les deux nœuds.

Commande utilisée :

```bash
ansible k8s_cluster -m shell -a 'kubeadm version -o short && kubelet --version && kubectl version --client=true'
```

Résultat :

```text
v1.36.5
Kubernetes v1.36.5
Client Version: v1.36.5
Kustomize Version: v5.8.1
```

Les trois composants utilisent donc bien la version attendue.

---

## 9. État du service kubelet

Le service `kubelet` est activé par systemd.

Vérification :

```bash
ansible k8s_cluster -m shell -a 'systemctl is-enabled kubelet; systemctl is-active kubelet'
```

Résultat :

```text
enabled
inactive
```

Cet état est celui obtenu à l'issue de ce rôle seul, avant toute initialisation ou jonction. Il est normal.

Il faut distinguer :

```text
enabled
    =
le service est configuré pour démarrer automatiquement
```

et :

```text
active
    =
le processus est actuellement en fonctionnement
```

À l'issue de ce rôle, `kubelet` ne dispose d'aucune configuration de cluster : ni `kubeadm init` ni `kubeadm join` n'ont été exécutés.

Le service devient actif lorsque le nœud est initialisé ou joint, par les rôles `control_plane` et `worker`.

Résultat vérifié le 10 octobre 2026 sur le cluster construit par le playbook complet :

```text
kube-control : enabled active
kube-worker  : enabled active
```

---

## 10. Validation Ansible

L'installation a d'abord été testée avec :

```bash
ansible-playbook site.yml --syntax-check
```

Résultat :

```text
playbook: site.yml
```

La syntaxe du playbook est donc valide.

Une vérification en mode simulation a ensuite été effectuée :

```bash
ansible-playbook site.yml --check
```

Ansible a identifié les modifications nécessaires :

```text
TASK [kubernetes : Installer les composants Kubernetes]
changed: [kube-control]
changed: [kube-worker]
```

Cette simulation a fonctionné parce que les machines étaient déjà partiellement configurées : les rôles `common` et `containerd` avaient été appliqués auparavant.

Sur des machines neuves, le mode `--check` ne constitue pas une validation fiable de ce playbook, car chaque tâche dépend d'une tâche précédente que la simulation n'exécute pas réellement. Ce comportement a été constaté le 8 octobre 2026 et est décrit dans `13-troubleshooting.md` (problème 6).

L'installation réelle a ensuite été exécutée :

```bash
ansible-playbook site.yml
```

Résultat lors de la première installation :

```text
kube-control : changed=1
kube-worker  : changed=1
```

Résultat le 8 octobre 2026, sur les machines reconstruites, où les trois rôles ont été appliqués en une seule exécution :

```text
kube-control : ok=16   changed=13   unreachable=0    failed=0
kube-worker  : ok=16   changed=13   unreachable=0    failed=0
```

Les composants ont donc été installés sur les deux nœuds.

---

## 11. Vérification de l'idempotence

Le playbook a été exécuté une seconde fois :

```bash
ansible-playbook site.yml
```

Cette fois, Ansible a retourné :

```text
kube-control : changed=0
kube-worker  : changed=0
```

Résultat vérifié le 8 octobre 2026, après l'ajout du gel des versions :

```text
kube-control : ok=17   changed=0    unreachable=0    failed=0    skipped=1
kube-worker  : ok=17   changed=0    unreachable=0    failed=0    skipped=1
```

La tâche de gel des versions apparaît en `ok` et non en `changed` lors de cette seconde exécution. La tâche ignorée appartient au rôle `common` et est expliquée dans `07-kubernetes-prerequisites.md`.

Après l'ajout de `crictl`, le playbook compte une tâche de plus. Une simulation a été lancée le 8 octobre 2026 sur les deux nœuds déjà configurés, afin de détecter un éventuel écart entre le rôle et l'état réel :

```bash
ansible-playbook site.yml --check
```

Résultat vérifié :

```text
kube-control : ok=18   changed=0    unreachable=0    failed=0    skipped=1
kube-worker  : ok=18   changed=0    unreachable=0    failed=0    skipped=1
```

Aucun écart n'est détecté : les nœuds sont conformes au rôle. Le mode `--check` est ici pertinent, car les machines sont déjà configurées.

Le 9 octobre 2026, les deux machines ont été détruites puis recréées, et le playbook complet a été rejoué sur des systèmes neufs. Le rôle `kubernetes` compte alors neuf tâches et un handler. Le résultat de cette reconstruction porte sur l'ensemble du playbook et est présenté dans `06-roles.md` (section 8.3).

Cette vérification confirme l'idempotence de la configuration.

L'état souhaité étant déjà présent, Ansible n'effectue aucune modification supplémentaire.

```text
Première exécution
        |
        v
Installation
        |
        v
État souhaité
        |
        v
Deuxième exécution
        |
        v
Aucune modification
```

---

## 12. État obtenu

À la fin de cette étape, les deux nœuds disposent de tous les composants nécessaires au bootstrap Kubernetes.

```text
kube-control
├── Ubuntu 22.04       ✅
├── containerd 2.2.1  ✅
├── kubeadm 1.36.5    ✅
├── kubelet 1.36.5    ✅
├── kubectl 1.36.5    ✅
├── crictl 1.36.0     ✅
└── versions figées   ✅

kube-worker
├── Ubuntu 22.04       ✅
├── containerd 2.2.1  ✅
├── kubeadm 1.36.5    ✅
├── kubelet 1.36.5    ✅
├── kubectl 1.36.5    ✅
├── crictl 1.36.0     ✅
└── versions figées   ✅
```

---

## 13. Périmètre de cette étape

Cette étape installe les composants. Elle ne réalise volontairement aucune opération de bootstrap.

Les opérations suivantes n'en font pas partie. Elles sont réalisées par d'autres rôles et documentées séparément :

| Opération                                    | Rôle Ansible    | Document              |
| -------------------------------------------- | --------------- | --------------------- |
| Initialisation du Control Plane              | `control_plane` | `10-control-plane.md` |
| Configuration de l'accès `kubectl` au cluster | `control_plane` | `10-control-plane.md` |
| Installation du plugin réseau CNI            | `calico`        | `11-calico.md`        |
| Génération de la commande `kubeadm join`     | `worker`        | `12-worker.md`        |
| Jonction du Worker                           | `worker`        | `12-worker.md`        |
| Validation du cluster                        | —               | `12-worker.md`        |

---

## 14. Ce que cette étape ne garantit pas

La présence de `kubeadm`, `kubelet` et `kubectl` ne signifie pas qu'un cluster Kubernetes fonctionne.

À l'issue de ce rôle seul, l'état d'une machine est le suivant :

```text
Machine préparée
        |
        v
Runtime installé
        |
        v
Composants Kubernetes installés
        |
        X
Aucun cluster
```

Le cluster n'existe qu'une fois les rôles `control_plane`, `calico` et `worker` appliqués.

---

## 15. État du laboratoire

Le rôle `kubernetes` fait partie du premier play de `site.yml`. Les deux plays suivants, décrits dans `06-roles.md`, construisent le cluster.

État vérifié le 10 octobre 2026 :

| Élément                                   | État                                      |
| ----------------------------------------- | ----------------------------------------- |
| Composants Kubernetes installés et figés  | ✅ Sur les deux nœuds                      |
| Control Plane initialisé                  | ✅ Voir `10-control-plane.md`              |
| Plugin réseau installé                    | ✅ Voir `11-calico.md`                     |
| Worker joint au cluster                   | ✅ Voir `12-worker.md`                     |
| Nœuds                                     | ✅ `kube-control` et `kube-worker` `Ready` |

---

## 16. Étape suivante

La prochaine étape consiste à initialiser le Control Plane sur `kube-control`, avec `kubeadm init`.

Elle est documentée dans `10-control-plane.md` et traite notamment :

* l'adresse de l'API Server ;
* le réseau des Pods ;
* la configuration fournie à `kubeadm` ;
* la configuration de `kubectl` ;
* la validation du Control Plane.

L'installation du plugin réseau et la jonction du Worker sont documentées dans `11-calico.md` et `12-worker.md`.
