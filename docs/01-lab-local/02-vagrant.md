# 02 — Vagrant : création et gestion des machines virtuelles

## 1. Objectif

Ce document présente l'utilisation de **Vagrant** pour créer et gérer les machines virtuelles du laboratoire local EshopOnContainer.

Il décrit :

* les prérequis à installer sur le poste Windows ;
* le `Vagrantfile` du projet ;
* la création et la vérification des machines ;
* leur cycle de vie.

L'architecture du laboratoire (rôles des machines, adresses IP, réseaux) est présentée dans `01-architecture.md` et n'est pas reprise ici.

---

## 2. Pourquoi Vagrant ?

Vagrant permet de décrire les machines virtuelles dans un fichier texte versionné, puis de les créer ou de les détruire avec une seule commande.

Le laboratoire devient ainsi reproductible : une personne qui récupère le dépôt obtient les mêmes machines sans les configurer à la main dans l'hyperviseur.

Vagrant se situe au niveau de la création de l'infrastructure.

```text
Vagrant
   |
   v
VMware Workstation
   |
   +---- kube-control
   |
   +---- kube-worker
```

Vagrant n'est pas responsable de :

* la configuration système des machines ;
* l'installation de containerd ;
* l'installation de Kubernetes ;
* la configuration du cluster.

Ces responsabilités sont confiées à Ansible, puis à Kubernetes.

---

## 3. Prérequis

Vagrant pilote VMware Workstation à travers deux composants supplémentaires : un service Windows et un plugin.

| Composant                | Version utilisée | Rôle                                                        |
| ------------------------ | ---------------- | ----------------------------------------------------------- |
| VMware Workstation       | 17.6.1           | Hyperviseur                                                 |
| Vagrant                  | 2.4.9            | Définition et gestion des machines                          |
| Vagrant VMware Utility   | 1.0.24           | Service Windows qui crée les réseaux VMware pour Vagrant    |
| `vagrant-vmware-desktop` | 3.0.5            | Plugin qui apporte à Vagrant le provider `vmware_desktop`   |

Le choix de VMware Workstation est expliqué dans `01-architecture.md`.

### Une seule installation de Vagrant

Le poste dispose de deux installations de Vagrant : celle de Windows, et celle de la distribution Ubuntu de WSL2.

Dans ce laboratoire, **seule celle de Windows est utilisée**, depuis PowerShell. Toutes les commandes `vagrant` de ce document se lancent dans PowerShell.

Deux installations qui agissent sur le même dossier ne reconnaissent pas les machines l'une de l'autre et effacent leur état. Cet incident s'est produit et est décrit dans `13-troubleshooting.md` (problème 12).

### 3.1 Installation du plugin

Le Vagrant VMware Utility s'installe avec son programme d'installation Windows.

Le plugin s'installe ensuite avec :

```powershell
vagrant plugin install vagrant-vmware-desktop
```

Cette commande télécharge le plugin et l'enregistre dans l'installation de Vagrant.

### 3.2 Vérification des prérequis

```powershell
vagrant plugin list
```

Cette commande affiche les plugins installés. Elle permet de confirmer que le provider VMware est disponible.

Résultat vérifié :

```text
vagrant-vmware-desktop (3.0.5, global)
```

```powershell
Get-Service VagrantVMware
```

Cette commande affiche l'état du service Vagrant VMware Utility. Sans ce service, Vagrant ne peut pas créer les réseaux VMware.

Résultat vérifié :

```text
Status : Running
```

Si le plugin est absent, Vagrant ignore la configuration VMware et utilise VirtualBox sans prévenir. Ce cas est décrit dans `13-troubleshooting.md` (problème 2).

---

## 4. Organisation

Les fichiers d'infrastructure locale sont organisés comme suit :

```text
lab-local/
└── vagrant/
    ├── Vagrantfile
    └── .vagrant/        (généré par Vagrant, non versionné)
```

Le `Vagrantfile` constitue le fichier de définition de l'infrastructure.

Le répertoire `.vagrant/` est créé par Vagrant. Il contient l'état des machines et leurs clés privées SSH. Il est exclu du dépôt par le fichier `.gitignore`.

---

## 5. Vagrantfile

Le laboratoire utilise le `Vagrantfile` suivant :

```ruby
Vagrant.configure("2") do |config|
  # ========================================
  # BOX UBUNTU
  # ========================================
  config.vm.box = "bento/ubuntu-22.04"

  # ========================================
  # KUBE CONTROL PLANE
  # ========================================
  config.vm.define "kube-control" do |control|
    control.vm.hostname = "kube-control"
    control.vm.network "private_network",
      ip: "192.168.57.10"

    control.vm.provider "vmware_desktop" do |v|
      v.gui = false
      v.vmx["displayname"] = "eshop-kube-control"
      v.vmx["memsize"] = "3072"
      v.vmx["numvcpus"] = "2"
    end
  end

  # ========================================
  # KUBE WORKER
  # ========================================
  config.vm.define "kube-worker" do |worker|
    worker.vm.hostname = "kube-worker"
    worker.vm.network "private_network",
      ip: "192.168.57.11"

    worker.vm.provider "vmware_desktop" do |v|
      v.gui = false
      v.vmx["displayname"] = "eshop-kube-worker"
      v.vmx["memsize"] = "6144"
      v.vmx["numvcpus"] = "2"
    end
  end
end
```

---

## 6. Paramètres du Vagrantfile

### 6.1 Box

```ruby
config.vm.box = "bento/ubuntu-22.04"
```

Une box est l'image de base à partir de laquelle Vagrant crée les machines.

La box `bento/ubuntu-22.04` est utilisée parce qu'elle est publiée pour le provider `vmware_desktop`. La box `ubuntu/jammy64`, utilisée au début du projet, n'existe que pour VirtualBox.

La version installée est `202309.08.0`. Elle date de septembre 2023, ce qui a deux conséquences documentées ailleurs :

* l'index APT des machines est ancien à la création (`13-troubleshooting.md`, problème 6) ;
* le swap est actif par défaut (`07-kubernetes-prerequisites.md`).

### 6.2 Paramètres par machine

| Paramètre                 | `kube-control`       | `kube-worker`       | Rôle du paramètre                         |
| ------------------------- | -------------------- | ------------------- | ----------------------------------------- |
| `config.vm.define`        | `kube-control`       | `kube-worker`       | Nom de la machine pour Vagrant            |
| `vm.hostname`             | `kube-control`       | `kube-worker`       | Nom d'hôte configuré dans le système      |
| `v.vmx["displayname"]`    | `eshop-kube-control` | `eshop-kube-worker` | Nom affiché dans VMware Workstation       |
| `v.vmx["memsize"]`        | `3072`               | `6144`              | Mémoire en Mo                             |
| `v.vmx["numvcpus"]`       | `2`                  | `2`                 | Nombre de CPU virtuels                    |
| `v.gui`                   | `false`              | `false`             | Démarrage sans fenêtre VMware             |

Les clés `v.vmx[...]` écrivent directement dans le fichier de configuration `.vmx` de la machine VMware.

Les adresses IP déclarées avec `private_network` sont celles définies dans `01-architecture.md`.

---

## 7. Réseau privé

La ligne suivante demande à Vagrant de connecter la machine à un réseau privé avec une adresse fixe :

```ruby
control.vm.network "private_network", ip: "192.168.57.10"
```

Vagrant demande alors à VMware de créer un réseau de type host-only correspondant à ce sous-réseau. Sur ce poste, VMware a créé le réseau `VMnet6`.

Chaque machine reçoit en plus, automatiquement, une interface NAT pour l'accès à Internet.

### 7.1 Adresse du poste Windows sur le réseau privé

Pour que le poste Windows et WSL2 puissent joindre les machines, la carte réseau Windows associée à `VMnet6` doit porter l'adresse `192.168.57.1`.

```powershell
Get-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet6" -AddressFamily IPv4
```

Cette commande affiche l'adresse IPv4 de la carte Windows reliée au réseau privé du laboratoire.

Résultat attendu :

```text
IPAddress    : 192.168.57.1
PrefixLength : 24
```

Lors de la création du réseau, cette adresse n'a pas été attribuée automatiquement et a dû être configurée à la main. Le diagnostic et la correction sont décrits dans `13-troubleshooting.md` (problème 4).

Résultat vérifié le 8 octobre 2026, après correction :

```text
VMware Network Adapter VMnet6   192.168.57.1/24
```

### 7.2 Plage d'adresses déjà utilisée

Un réseau VMware ne peut pas être créé sur un sous-réseau déjà porté par une autre carte du poste. Ce cas s'est produit avec une ancienne carte VirtualBox et est décrit dans `13-troubleshooting.md` (problème 3).

---

## 8. Création des machines

Depuis le répertoire Vagrant :

```powershell
cd lab-local\vagrant
```

La création et le démarrage des machines s'effectuent avec :

```powershell
vagrant up --provider vmware_desktop
```

Cette commande crée les machines qui n'existent pas encore et démarre celles qui existent.

L'option `--provider vmware_desktop` indique explicitement l'hyperviseur à utiliser. Le `Vagrantfile` ne fixe pas de provider par défaut : sans cette option, le choix dépend de l'ordre de préférence de Vagrant.

Vagrant :

1. télécharge la box si elle n'est pas déjà présente ;
2. clone la box pour créer chaque machine ;
3. vérifie ou crée les réseaux VMware ;
4. applique la mémoire et les CPU déclarés ;
5. démarre les machines ;
6. remplace la clé SSH par défaut par une clé propre à chaque machine.

La première ligne affichée permet de contrôler le provider réellement utilisé :

```text
Bringing machine 'kube-control' up with 'vmware_desktop' provider...
```

---

## 9. Vérification

### 9.1 État des machines

```powershell
vagrant status
```

Cette commande affiche l'état des machines gérées par Vagrant ainsi que le provider utilisé.

Résultat vérifié le 8 octobre 2026 :

```text
kube-control              running (vmware_desktop)
kube-worker               running (vmware_desktop)
```

### 9.2 Ressources et interfaces

```powershell
vagrant ssh kube-control -c "hostname; ip -4 -br addr"
```

Cette commande exécute des commandes dans la machine sans ouvrir de session interactive. Elle permet de vérifier que le nom d'hôte et les adresses correspondent au `Vagrantfile`.

Résultat vérifié :

```text
kube-control
lo               UNKNOWN        127.0.0.1/8
eth0             UP             192.168.200.129/24 metric 100
eth1             UP             192.168.57.10/24
```

Les ressources ont également été contrôlées dans chaque machine :

| Machine        | CPU | Mémoire vue par le système |
| -------------- | --- | -------------------------- |
| `kube-control` | 2   | 2968 Mo                    |
| `kube-worker`  | 2   | 5922 Mo                    |

La mémoire vue par le système est légèrement inférieure à la valeur déclarée, car une partie est réservée par le noyau.

### 9.3 Connectivité depuis le poste Windows

```powershell
ping 192.168.57.10
```

Cette commande vérifie que le poste Windows joint la machine sur le réseau privé.

Résultat vérifié : 4 paquets envoyés, 4 reçus.

La connectivité depuis WSL2 est traitée dans `03-wsl.md`.

---

## 10. Connexion à une machine

Vagrant permet d'ouvrir une session SSH directement :

```powershell
vagrant ssh kube-control
```

Cette méthode convient aux opérations d'administration ponctuelles. Vagrant utilise sa propre clé et un port redirigé sur `127.0.0.1`.

La configuration SSH utilisée peut être affichée avec :

```powershell
vagrant ssh-config
```

Cette commande indique, pour chaque machine, l'hôte, le port, l'utilisateur et le chemin de la clé privée.

Résultat vérifié :

```text
Host kube-control
  Port 2222
  IdentityFile .../.vagrant/machines/kube-control/vmware_desktop/private_key

Host kube-worker
  Port 2200
  IdentityFile .../.vagrant/machines/kube-worker/vmware_desktop/private_key
```

Ansible n'utilise pas ces ports redirigés. Il se connecte aux adresses du réseau privé, comme décrit dans `05-inventory.md`.

---

## 11. Cycle de vie des machines

| Action              | Commande                               | Effet                                             |
| ------------------- | -------------------------------------- | ------------------------------------------------- |
| Créer ou démarrer   | `vagrant up --provider vmware_desktop` | Crée les machines absentes, démarre les autres    |
| Arrêter             | `vagrant halt`                         | Éteint les machines en conservant leurs disques   |
| Redémarrer          | `vagrant reload`                       | Redémarre et relit le `Vagrantfile`               |
| Se connecter        | `vagrant ssh kube-control`             | Ouvre une session SSH                             |
| Détruire            | `vagrant destroy`                      | Supprime les machines et leurs disques            |

La commande `destroy` supprime les machines virtuelles et doit être utilisée avec précaution.

Après une destruction suivie d'une recréation, Vagrant génère de nouvelles clés SSH. Les clés utilisées par Ansible doivent alors être recopiées, comme indiqué dans `05-inventory.md`.

### Reconstruction complète du laboratoire

Détruire puis recréer les machines permet de repartir de systèmes neufs. Le cluster est ensuite reconstruit par Ansible.

| Étape | Commande                               | Terminal   | Document de référence |
| ----- | -------------------------------------- | ---------- | --------------------- |
| 1     | `vagrant destroy -f`                   | PowerShell | Ce document           |
| 2     | `vagrant up --provider vmware_desktop` | PowerShell | Ce document           |
| 3     | `bash lab-local/scripts/setup-ssh.sh`  | WSL2       | `05-inventory.md` (section 11.2) |
| 4     | `ansible-playbook site.yml`            | WSL2       | `06-roles.md`         |

L'option `-f` de `vagrant destroy` supprime les machines sans demander de confirmation.

L'étape 3 remet en place les accès SSH du poste de contrôle. Elle se lance depuis la racine du projet.

Les étapes 2 à 4 ont été réalisées le 9 octobre 2026 : la création des deux machines a pris 2 minutes 36, et la construction du cluster par Ansible 2 minutes 31. Ce jour-là, l'étape 3 a été effectuée à la main, le script ayant été écrit ensuite.

La procédure a été rejouée plus tard le même jour, cette fois avec le script à l'étape 3. Les machines ont été recréées, les accès SSH remis en place par le script, et le cluster reconstruit par Ansible sans échec. Ce jour-là, les machines précédentes n'ont pas été supprimées par `vagrant destroy`, mais arrêtées à la main à la suite de l'incident décrit dans `13-troubleshooting.md` (problème 12).

---

## 12. Séparation avec Ansible

Le laboratoire applique la séparation suivante :

```text
Vagrant
   |
   | crée
   v
Machines virtuelles
   |
   | administrées via SSH
   v
Ansible
   |
   | configure
   v
Systèmes Linux
```

Vagrant ne doit pas devenir un second outil de configuration système. Le `Vagrantfile` ne contient donc aucun bloc de provisionnement.

### Pourquoi ne pas utiliser `ansible_local` ?

`ansible_local` ferait exécuter Ansible à l'intérieur des machines virtuelles.

Dans notre architecture, WSL2 joue volontairement le rôle de Control Node Ansible. Cette approche représente mieux une administration distante et permet de travailler avec un véritable inventaire.

---

## 13. Validation

L'infrastructure Vagrant est considérée comme opérationnelle lorsque :

* [x] le plugin `vagrant-vmware-desktop` est installé ;
* [x] le service Vagrant VMware Utility est en cours d'exécution ;
* [x] `kube-control` et `kube-worker` sont à l'état `running (vmware_desktop)` ;
* [x] les adresses IP privées sont configurées dans les machines ;
* [x] la carte `VMnet6` du poste Windows porte l'adresse `192.168.57.1` ;
* [x] le poste Windows joint les machines sur le réseau privé.

Ces points ont été vérifiés le 8 octobre 2026.

---

## 14. Documentation associée

| Fichier                 | Responsabilité                          |
| ----------------------- | --------------------------------------- |
| `01-architecture.md`    | Architecture globale, adresses et rôles |
| `03-wsl.md`             | Environnement de contrôle WSL2          |
| `05-inventory.md`       | Inventaire et accès SSH                 |
| `13-troubleshooting.md` | Diagnostic des problèmes                |

---

## 15. Étape suivante

La prochaine étape consiste à préparer l'environnement de contrôle WSL2 depuis lequel les machines seront administrées.

Elle est documentée dans `03-wsl.md`.
