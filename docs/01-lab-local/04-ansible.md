# 04 — Ansible : installation et configuration

## 1. Objectif

Ce document présente l'installation et la configuration d'**Ansible** pour le laboratoire local EshopOnContainer.

Ansible sera utilisé depuis l'environnement WSL2 afin d'automatiser la configuration des machines virtuelles du laboratoire.

L'objectif est de remplacer progressivement les opérations manuelles par une configuration :

* reproductible ;
* versionnable ;
* idempotente ;
* structurée ;
* automatisable.

L'environnement WSL2 utilisé comme poste de contrôle est présenté dans `03-wsl.md`.

---

## 2. Rôle d'Ansible dans l'architecture

Ansible intervient après la création des machines virtuelles par Vagrant.

```text
Vagrant
   |
   | crée
   v
Machines virtuelles
   |
   | SSH
   v
Ansible
   |
   | configure
   v
Systèmes Linux
   |
   v
Kubernetes
```

La séparation des responsabilités est volontaire :

| Technologie        | Responsabilité                  |
| ------------------ | ------------------------------- |
| VMware Workstation | Virtualisation                  |
| Vagrant            | Création et gestion des VMs     |
| WSL2               | Environnement de contrôle       |
| SSH                | Communication distante          |
| Ansible            | Automatisation de configuration |
| Kubernetes         | Orchestration                   |

---

## 3. Qu'est-ce qu'Ansible ?

Ansible est un outil d'automatisation permettant d'administrer des systèmes et de déployer des configurations de manière déclarative.

Ansible utilise principalement :

* un **Control Node** ;
* un **Managed Node** ;
* un **Inventory** ;
* des **Modules** ;
* des **Playbooks** ;
* des **Roles**.

Dans notre laboratoire :

```text
Control Node
     |
     | WSL2
     |
     v
  Ansible
     |
     +----------+
     |          |
     v          v
kube-control kube-worker
Managed Node Managed Node
```

---

## 4. Architecture agentless

Ansible fonctionne selon un modèle **agentless**.

Cela signifie qu'aucun agent Ansible permanent n'est installé sur les machines administrées.

Dans notre laboratoire, Ansible utilisera principalement SSH pour communiquer avec les machines Ubuntu.

```text
WSL2
 |
 | Ansible
 |
 | SSH
 |
 +-------> kube-control
 |
 +-------> kube-worker
```

Cette architecture simplifie l'administration et réduit les composants nécessaires sur les nœuds.

---

## 5. Installation

Ansible est installé dans Ubuntu WSL2.

Avant l'installation, les dépôts peuvent être actualisés :

```bash
sudo apt update
```

Installation :

```bash
sudo apt install -y ansible
```

L'installation peut être vérifiée avec :

```bash
ansible --version
```

---

## 6. Version utilisée dans le laboratoire

La version actuellement installée est :

```text
Ansible Core 2.16.3
```

L'environnement Python utilisé est :

```text
Python 3.12.3
```

Ces informations ont été obtenues avec :

```bash
ansible --version
```

La version exacte peut évoluer lors de futures mises à jour du système.

La documentation décrit donc principalement les principes et la configuration du projet plutôt qu'une dépendance stricte à une version particulière.

---

## 7. Organisation du répertoire Ansible

Les fichiers Ansible du laboratoire sont regroupés dans :

```text
lab-local/
└── ansible/
```

L'organisation cible est :

```text
ansible/
├── ansible.cfg
├── inventory.ini
├── site.yml
├── group_vars/
│   ├── all.yml
│   ├── control_plane.yml
│   └── workers.yml
└── roles/
    ├── common/
    ├── containerd/
    ├── kubernetes/
    ├── control_plane/
    ├── calico/
    └── worker/
```

Le rôle de chaque élément est décrit dans `06-roles.md`.

---

## 8. Configuration Ansible

Par défaut, Ansible recherche notamment un fichier :

```text
ansible.cfg
```

Le projet utilisera un fichier de configuration propre au laboratoire :

```text
lab-local/ansible/ansible.cfg
```

Cela permet d'éviter de dépendre de la configuration globale de l'utilisateur.

Le fichier contient :

```ini
[defaults]
inventory = ./inventory.ini
roles_path = ./roles
remote_user = vagrant
host_key_checking = True
retry_files_enabled = False
interpreter_python = auto_silent

[privilege_escalation]
become = False
become_method = sudo
become_user = root
```

| Paramètre             | Effet dans le laboratoire                                                     |
| --------------------- | ----------------------------------------------------------------------------- |
| `inventory`           | Évite de préciser `-i inventory.ini` à chaque commande                        |
| `roles_path`          | Indique où se trouvent les rôles du projet                                    |
| `remote_user`         | Utilisateur SSH par défaut des machines Vagrant                               |
| `host_key_checking`   | Ansible vérifie l'empreinte SSH des machines avant de s'y connecter           |
| `retry_files_enabled` | Empêche la création de fichiers `.retry` dans le dépôt                        |
| `interpreter_python`  | Détection automatique de Python sur les machines, sans avertissement          |
| `become`              | L'élévation de privilèges n'est pas activée par défaut ; le playbook la demande |

### 8.1 Chargement du fichier depuis un lecteur Windows

Le projet se trouve sur le lecteur `F:`, monté dans WSL2 sous `/mnt/f`. Sur ce type de montage, tous les répertoires apparaissent avec les permissions `drwxrwxrwx`.

Or Ansible refuse, par sécurité, de lire un `ansible.cfg` situé dans un répertoire accessible en écriture à tous les utilisateurs. Il l'ignore et affiche :

```text
[WARNING]: Ansible is being run in a world writable directory (...),
ignoring it as an ansible.cfg source.
[WARNING]: No inventory was parsed, only implicit localhost is available
```

Pour qu'Ansible utilise malgré tout le fichier du projet, son chemin est indiqué explicitement par une variable d'environnement, définie dans `~/.bashrc` :

```bash
export ANSIBLE_CONFIG="/mnt/f/Users/x/Documents/apprentissage/EshopOnContainer/lab-local/ansible/ansible.cfg"
```

Lorsque cette variable est définie, Ansible charge le fichier désigné quel que soit le répertoire courant.

Cette configuration se trouve dans le profil de l'utilisateur WSL2 et non dans le dépôt. Elle doit donc être refaite sur tout nouveau poste de contrôle. Le diagnostic correspondant est décrit dans `13-troubleshooting.md` (problème 8).

### 8.2 Vérification

```bash
ansible --version
```

Cette commande affiche la version d'Ansible ainsi que le fichier de configuration réellement chargé.

Résultat attendu :

```text
config file = /mnt/f/Users/x/Documents/apprentissage/EshopOnContainer/lab-local/ansible/ansible.cfg
```

Résultat vérifié le 8 octobre 2026 : conforme lorsque `ANSIBLE_CONFIG` est définie. Sans cette variable, la ligne affichée est `config file = None`.

---

## 9. Vérification de la configuration

Ansible permet d'afficher les paramètres modifiés :

```bash
ansible-config dump --only-changed
```

Cette commande est utile pour comprendre la configuration réellement appliquée.

Elle permet notamment d'éviter de supposer qu'une valeur est active alors qu'elle provient d'une autre configuration.

Résultat vérifié le 8 octobre 2026 : les neuf paramètres modifiés proviennent tous du fichier `ansible.cfg` du projet, notamment :

```text
DEFAULT_HOST_LIST = ['.../lab-local/ansible/inventory.ini']
DEFAULT_REMOTE_USER = vagrant
DEFAULT_ROLES_PATH = ['.../lab-local/ansible/roles']
HOST_KEY_CHECKING = True
```

---

## 10. Inventaire

Ansible doit connaître les machines qu'il doit administrer.

Cette information est fournie par l'**Inventory**.

Dans notre laboratoire :

```text
ansible/
└── inventory.ini
```

L'inventaire définira notamment :

* les machines ;
* leur adresse IP ;
* leur utilisateur SSH ;
* leur clé privée ;
* leur appartenance à un groupe.

La structure détaillée de l'inventaire est documentée dans :

```text
05-inventory.md
```

---

## 11. Communication avec les machines

Ansible doit pouvoir établir une connexion avec les machines administrées.

Le laboratoire utilise :

```text
WSL2
   |
   | SSH
   |
   +---- 192.168.57.10
   |
   +---- 192.168.57.11
```

La connectivité réseau a déjà été vérifiée avec `ping`.

La validation de la connexion SSH constitue une étape distincte.

Elle sera réalisée dans `05-inventory.md`.

---

## 12. Playbooks

Un **Playbook** décrit les opérations qu'Ansible doit effectuer.

Le projet utilisera notamment un playbook principal :

```text
site.yml
```

Il orchestre six rôles, répartis en trois plays :

```text
site.yml
   |
   +---- common, containerd, kubernetes     (tous les nœuds)
   |
   +---- control_plane, calico              (Control Plane)
   |
   +---- worker                             (Workers)
```

L'objectif est d'éviter un playbook monolithique contenant toutes les opérations. Le contenu du playbook est détaillé dans `06-roles.md`.

---

## 13. Rôles Ansible

Les rôles permettront de séparer les responsabilités.

Les trois premiers rôles préparent les machines :

```text
roles/
├── common/
├── containerd/
└── kubernetes/
```

Trois autres rôles construisent ensuite le cluster : `control_plane`, `calico` et `worker`. Les six rôles sont présentés dans `06-roles.md`.

### `common`

Responsable de la configuration commune des nœuds :

* paquets de base ;
* configuration système ;
* modules nécessaires ;
* paramètres communs.

### `containerd`

Responsable de :

* l'installation de containerd ;
* sa configuration ;
* son activation ;
* sa validation.

### `kubernetes`

Responsable de la préparation et de l'installation des composants Kubernetes.

La conception détaillée des rôles sera présentée dans :

```text
06-roles.md
```

---

## 14. Idempotence

Un principe important d'Ansible est l'**idempotence**.

Une opération idempotente peut être exécutée plusieurs fois sans produire inutilement de nouvelles modifications lorsque l'état souhaité est déjà atteint.

Par exemple, un rôle peut vérifier qu'un paquet est installé avant de l'installer.

L'objectif est d'obtenir :

```text
État initial
    |
    v
Ansible
    |
    v
État souhaité
```

Puis, si Ansible est relancé :

```text
État souhaité
    |
    v
Ansible
    |
    v
Aucune modification inutile
```

Cette propriété est particulièrement importante pour l'automatisation des infrastructures.

---

## 15. Sécurité

Les clés privées SSH ne doivent jamais être enregistrées dans le dépôt Git.

Le projet doit notamment éviter :

```text
❌ private_key
❌ id_rsa
❌ secrets
❌ mots de passe en clair
```

Les clés utilisées par Vagrant resteront en dehors du dépôt versionné.

Les éventuels secrets nécessaires ultérieurement pourront être gérés avec des mécanismes adaptés, notamment **Ansible Vault** lorsque cela deviendra nécessaire.

---

## 16. Vérification finale d'Ansible

Ansible est considéré comme correctement installé lorsque :

```bash
ansible --version
```

retourne une version valide.

La connexion aux machines ne sera considérée comme validée qu'après exécution réussie :

```bash
ansible all -i inventory.ini -m ping
```

Cette commande sera exécutée après la configuration de l'inventaire et de SSH.

---

## 17. Documentation associée

| Fichier                          | Responsabilité                          |
| -------------------------------- | --------------------------------------- |
| `03-wsl.md`                      | Environnement Linux de contrôle         |
| `04-ansible.md`                  | Installation et configuration d'Ansible |
| `05-inventory.md`                | Inventaire et accès SSH                 |
| `06-roles.md`                    | Organisation des rôles                  |
| `07-kubernetes-prerequisites.md` | Préparation des nœuds Kubernetes        |

---

## 18. Résumé

L'architecture Ansible retenue est :

```text
                    WSL2
                     |
                     v
                  Ansible
                     |
                    SSH
              +------+------+
              |             |
              v             v
        kube-control    kube-worker
        192.168.57.10   192.168.57.11
```

Ansible constitue la couche d'automatisation entre l'infrastructure créée par Vagrant et la future installation de Kubernetes.

---

## 19. Étape suivante

La prochaine étape consiste à établir et valider la connexion SSH puis à construire l'inventaire Ansible.

Elle est documentée dans `05-inventory.md`.
