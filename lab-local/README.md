# Laboratoire Kubernetes local

## 1. Objectif

Ce laboratoire permet de construire et d'administrer un cluster Kubernetes
multi-nœuds local afin de pratiquer le provisionnement, la configuration
système et l'orchestration des conteneurs.

L'infrastructure repose sur VMware Workstation, Vagrant, WSL2 Ubuntu,
Ansible, containerd, Kubernetes et Calico.

Ce document est un guide de démarrage. Les explications détaillées se
trouvent dans la [documentation technique](../docs/01-lab-local/01-architecture.md),
listée en section 10.

## 2. Architecture

| Machine | Fonction | Adresse IP |
|---|---|---|
| `kube-control` | Kubernetes Control Plane | `192.168.57.10` |
| `kube-worker` | Kubernetes Worker Node | `192.168.57.11` |

Les deux machines utilisent le réseau privé `192.168.57.0/24`.

Ansible est exécuté depuis WSL2 Ubuntu et configure les deux machines
à l'aide de l'inventaire et des playbooks du projet.

Deux terminaux sont utilisés, et chaque outil a le sien :

| Outil | Terminal |
|---|---|
| `vagrant` | PowerShell, dans `lab-local\vagrant` |
| `ansible`, `ansible-playbook`, `ssh` | WSL2 Ubuntu |

Pour ce laboratoire, PowerShell est l'environnement de référence pour
toutes les commandes Vagrant. Lancé depuis WSL2, Vagrant ne reconnaît pas
les machines créées depuis Windows : il les considère comme non créées et
efface leur état. Voir le problème 12 du
[guide de dépannage](../docs/01-lab-local/13-troubleshooting.md).

## 3. Prérequis

### 3.1 Poste Windows

| Prérequis | Vérification, dans PowerShell |
|---|---|
| VMware Workstation | — |
| Vagrant | `vagrant --version` |
| Vagrant VMware Utility, service démarré | `Get-Service VagrantVMware` |
| Plugin `vagrant-vmware-desktop` | `vagrant plugin list` |
| Carte `VMnet6` en `192.168.57.1`, une fois les machines créées | `Get-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet6" -AddressFamily IPv4` |

Le plugin et le service sont deux composants distincts, tous deux
nécessaires. Sans le plugin, Vagrant utilise VirtualBox sans prévenir.

Les deux machines demandent environ 9 Go de mémoire : 3 Go pour
`kube-control` et 6 Go pour `kube-worker`.

### 3.2 WSL2 Ubuntu

| Prérequis | Vérification, dans WSL2 |
|---|---|
| Ansible | `ansible --version` |
| Fichier `ansible.cfg` du projet chargé | `ansible --version`, ligne `config file` |
| Mode réseau par défaut, et non `mirrored` | `ip -4 -br addr` affiche une adresse en `172.x.x.x` |

Le projet se trouve sur un lecteur Windows. Ansible refuse d'y lire
`ansible.cfg` tant que son chemin n'est pas déclaré dans `~/.bashrc` :

```bash
export ANSIBLE_CONFIG="/chemin/absolu/vers/EshopOnContainer/lab-local/ansible/ansible.cfg"
```

Le chemin est à remplacer par l'emplacement réel du dépôt, tel qu'il est
vu depuis WSL2. Pour un dépôt situé sur le lecteur `F:`, il commence par
`/mnt/f/`.

Le détail de ces prérequis est décrit dans
[02-vagrant.md](../docs/01-lab-local/02-vagrant.md),
[03-wsl.md](../docs/01-lab-local/03-wsl.md) et
[04-ansible.md](../docs/01-lab-local/04-ansible.md).

## 4. Démarrer les machines virtuelles

Dans PowerShell :

```powershell
cd lab-local\vagrant
vagrant up --provider vmware_desktop
```

Cette commande crée les deux machines si elles n'existent pas, puis les
démarre. Compter environ trois minutes pour une première création.

La première ligne affichée doit annoncer le provider `vmware_desktop` :

```text
Bringing machine 'kube-control' up with 'vmware_desktop' provider...
```

Si elle annonce `virtualbox`, interrompre la commande : le plugin VMware
n'est pas installé.

## 5. Préparer les accès SSH

Dans WSL2, à la racine du projet :

```bash
bash lab-local/scripts/setup-ssh.sh
```

Ce script copie les clés générées par Vagrant, renouvelle les empreintes
des machines et teste la connexion. Il est à relancer après chaque
recréation des machines, car leurs clés changent.

> **Précaution de sécurité.** Le script enregistre l'empreinte SSH que
> chaque machine présente au moment de son exécution, sans la vérifier
> par un autre moyen. Cette confiance est acceptable pour des machines
> locales que l'on vient de créer soi-même sur un réseau privé. Elle ne
> l'est pas en production : ce script ne doit pas y être réutilisé tel
> quel. La limite est expliquée dans
> [05-inventory.md](../docs/01-lab-local/05-inventory.md), section 11.1.

Résultat attendu :

```text
Connexion SSH OK : kube-control (192.168.57.10)
Connexion SSH OK : kube-worker (192.168.57.11)
```

Puis vérifier qu'Ansible joint les deux machines :

```bash
cd lab-local/ansible
ansible all -m ping
```

Chaque machine doit répondre `"ping": "pong"`.

## 6. Construire le cluster

Dans WSL2, depuis `lab-local/ansible` :

```bash
ansible-playbook site.yml
```

Cette commande prépare les deux machines, initialise le Control Plane,
installe le réseau Calico et fait rejoindre le cluster au Worker. Compter
environ trois minutes sur des machines neuves.

Aucune tâche ne doit échouer : le récapitulatif doit afficher `failed=0`
pour les deux machines.

Le playbook est conçu pour être idempotent. Lors d'une seconde
exécution sur un environnement déjà conforme, vérifier que le
récapitulatif affiche `changed=0` et `failed=0` pour les deux machines.

Les compteurs `ok` et `skipped` dépendent du nombre de tâches et varient
donc avec la version du playbook. Le critère est l'absence d'échec et,
à la seconde exécution, l'absence de changement.

Cette propriété a été vérifiée sur ce laboratoire, y compris après deux
reconstructions complètes. Le détail figure dans
[06-roles.md](../docs/01-lab-local/06-roles.md).

## 7. Vérifier le cluster

Se connecter au Control Plane depuis WSL2 :

```bash
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10
```

Puis, sur `kube-control` :

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

Résultat attendu :

- les deux nœuds à l'état `Ready` ;
- la colonne `INTERNAL-IP` en `192.168.57.10` et `192.168.57.11` ;
- tous les Pods du namespace `kube-system` à l'état `Running`.

Un nœud `Ready` ne prouve pas que le réseau fonctionne. Trois tests
(Pod à Pod entre nœuds, Service, DNS) le vérifient. Ils s'appuient sur le
fichier `kubernetes/tests/network-test.yaml` et sont décrits dans
[12-worker.md](../docs/01-lab-local/12-worker.md), section 7.

## 8. Arrêter, redémarrer, reconstruire

| Action | Commande | Terminal |
|---|---|---|
| Arrêter les machines | `vagrant halt` | PowerShell |
| Les redémarrer | `vagrant up --provider vmware_desktop` | PowerShell |
| Les détruire | `vagrant destroy -f` | PowerShell |

Pour reconstruire le laboratoire à partir de machines neuves, détruire
les machines puis reprendre les sections 4, 5 et 6 dans l'ordre.

La commande `vagrant destroy` supprime les machines et leur contenu.

## 9. Structure

```text
lab-local/
├── README.md
├── vagrant/
│   └── Vagrantfile
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini
│   ├── site.yml
│   ├── group_vars/
│   └── roles/
│       ├── common/
│       ├── containerd/
│       ├── kubernetes/
│       ├── control_plane/
│       ├── calico/
│       └── worker/
└── scripts/
    └── setup-ssh.sh
```

## 10. Documentation technique

| Guide | Sujet |
|---|---|
| [01-architecture.md](../docs/01-lab-local/01-architecture.md) | Machines, réseaux, état du laboratoire |
| [02-vagrant.md](../docs/01-lab-local/02-vagrant.md) | Création et gestion des machines |
| [03-wsl.md](../docs/01-lab-local/03-wsl.md) | Poste de contrôle WSL2 |
| [04-ansible.md](../docs/01-lab-local/04-ansible.md) | Installation et configuration d'Ansible |
| [05-inventory.md](../docs/01-lab-local/05-inventory.md) | Inventaire et accès SSH |
| [06-roles.md](../docs/01-lab-local/06-roles.md) | Rôles, playbook, validation |
| [07-kubernetes-prerequisites.md](../docs/01-lab-local/07-kubernetes-prerequisites.md) | Préparation des systèmes |
| [08-containerd.md](../docs/01-lab-local/08-containerd.md) | Runtime de conteneurs |
| [09-kubernetes.md](../docs/01-lab-local/09-kubernetes.md) | Composants Kubernetes |
| [10-control-plane.md](../docs/01-lab-local/10-control-plane.md) | Initialisation du Control Plane |
| [11-calico.md](../docs/01-lab-local/11-calico.md) | Réseau des Pods |
| [12-worker.md](../docs/01-lab-local/12-worker.md) | Jonction du Worker, tests réseau |
| [13-troubleshooting.md](../docs/01-lab-local/13-troubleshooting.md) | Problèmes rencontrés et corrections |

## 11. En cas de problème

Le [guide de dépannage](../docs/01-lab-local/13-troubleshooting.md)
consigne quinze problèmes réellement rencontrés, avec leur diagnostic.
Les plus fréquents au démarrage :

| Symptôme | Problème |
|---|---|
| Vagrant démarre sous `virtualbox` | 2 |
| Les machines ne répondent pas depuis Windows | 4 |
| Ansible : `UNREACHABLE` alors que Windows joint les machines | 13 |
| Ansible : `No inventory was parsed` | 8 |
| Un play du playbook est ignoré sans erreur | 15 |
| Vagrant annonce `not created` pour des machines qui tournent | 12 |
