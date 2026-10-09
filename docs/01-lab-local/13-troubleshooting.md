# 13 — Diagnostic des problèmes

## 1. Objectif

Ce document consigne les problèmes réellement rencontrés lors de la construction du laboratoire local EshopOnContainer, avec leur diagnostic et leur correction.

Il sert à deux usages :

* retrouver rapidement la cause d'un symptôme déjà rencontré ;
* garder la trace du raisonnement qui a mené à chaque correction.

Il ne décrit pas le fonctionnement normal des composants, qui est documenté dans les fichiers `01` à `12`.

---

## 2. Méthode

Chaque problème est décrit selon la même progression :

```text
Symptôme
   ↓
Diagnostic (commande → résultat)
   ↓
Cause
   ↓
Correction
   ↓
Validation
```

Un problème n'est déclaré résolu que lorsque sa validation a été réellement observée.

---

## 3. Index des problèmes

| N° | Symptôme                                                        | Cause                                                   | Couche            |
| -- | --------------------------------------------------------------- | ------------------------------------------------------- | ----------------- |
| 1  | `vagrant up` : `Timed out while waiting for the machine to boot` | Hyper-V actif, VirtualBox en mode dégradé               | Hyperviseur       |
| 2  | Vagrant démarre sous `virtualbox` malgré le `Vagrantfile`        | Plugin `vagrant-vmware-desktop` absent                  | Vagrant           |
| 3  | `would collide with another device 'Ethernet 6'`                 | Plage `192.168.57.x` déjà portée par une carte VirtualBox | Réseau hôte       |
| 4  | Ansible : `UNREACHABLE`, `Connection timed out`                  | Carte Windows `VMnet6` sans adresse valide              | Réseau hôte       |
| 5  | Question sur l'authenticité de l'hôte pendant Ansible            | Clés et empreintes SSH changées par la recréation       | SSH               |
| 6  | `--check` : `no available installation candidate for containerd` | Index APT non actualisé en mode simulation              | Ansible           |
| 7  | Swap actif alors que la documentation le disait désactivé        | Changement de box Vagrant                               | Système           |
| 8  | `No inventory was parsed`, `ansible.cfg` ignoré                  | Répertoire du projet accessible en écriture à tous      | Ansible sous WSL2 |
| 9  | Le nœud s'enregistre avec l'adresse NAT `192.168.200.129`        | `kubelet` choisit l'interface de la route par défaut    | Kubernetes        |
| 10 | `kubeadm join` : `user is not running as root`                   | Commande lancée sans privilèges administrateur          | Kubernetes        |
| 11 | Avertissement `bindAddress` de `kube-proxy` pendant la jonction  | Non investiguée, aucun dysfonctionnement observé        | Kubernetes        |

Tous ces problèmes ont été rencontrés le 8 octobre 2026.

Les problèmes 1 à 8 ont été diagnostiqués pas à pas, avec les résultats de commande relevés au moment de la panne. Pour le problème 9, le symptôme et l'état initial du fichier `/etc/default/kubelet` proviennent des notes prises lors de l'intervention ; la table de routage et la validation ont été vérifiées après correction. Pour les problèmes 10 et 11, les messages proviennent également des notes prises lors de l'intervention ; l'état final du nœud a été vérifié sur le cluster.

Un problème plus ancien, propre à la configuration de `containerd`, est documenté dans `08-containerd.md` (sections 15 à 17).

---

## 4. Problème 1 — Les machines se figent au démarrage sous VirtualBox

### Symptôme

La commande `vagrant up` crée la machine, la démarre, puis échoue après cinq minutes :

```text
==> kube-control: Waiting for machine to boot. This may take a few minutes...
    kube-control: SSH address: 127.0.0.1:2200
    kube-control: SSH username: vagrant
    kube-control: SSH auth method: private key
Timed out while waiting for the machine to boot.
```

La seconde machine n'est jamais créée, car Vagrant s'arrête à la première erreur.

### Diagnostic

Le `Vagrantfile` n'est pas en cause :

```powershell
vagrant validate
```

Cette commande vérifie la syntaxe et la cohérence du `Vagrantfile`.

```text
Vagrantfile validated successfully.
```

La machine est bien démarrée du point de vue de l'hyperviseur :

```powershell
vagrant status
```

```text
kube-control              running (virtualbox)
kube-worker               not created (virtualbox)
```

Le port SSH redirigé accepte la connexion, mais la machine ne répond pas :

```powershell
ssh -v -p 2200 vagrant@127.0.0.1
```

L'option `-v` affiche les étapes de la connexion.

```text
debug1: Connection established.
Connection timed out during banner exchange
```

Le système invité n'a donc pas terminé son démarrage. Le journal de la machine virtuelle en donne la raison :

```powershell
Select-String -Path "$env:USERPROFILE\VirtualBox VMs\eshop-kube-control\Logs\VBox.log" -Pattern "VT-x|Snail"
```

Cette commande recherche dans le journal VirtualBox les lignes relatives au mode de virtualisation.

```text
HM: HMR3Init: Attempting fall back to NEM: VT-x is not available
NEM: NEMR3Init: Snail execution mode is active!
```

VirtualBox n'a pas accès à la virtualisation matérielle. La raison se vérifie côté Windows :

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
```

Cette commande indique si un hyperviseur est déjà chargé par Windows.

```text
True
```

Deux captures de la console de la machine, prises à plusieurs minutes d'intervalle, étaient identiques : le noyau était figé environ 4,4 secondes après son lancement, juste après la détection des cartes réseau.

### Cause

Hyper-V est actif sur le poste, car WSL2 en dépend (voir `03-wsl.md`).

Lorsque Hyper-V est chargé, il s'approprie la virtualisation matérielle. VirtualBox se rabat alors sur une interface de Windows nettement plus lente, qu'il nomme lui-même « Snail execution mode ». Dans ce mode, les machines Ubuntu à plusieurs CPU virtuels de ce laboratoire ne terminent pas leur démarrage.

### Correction

Deux corrections ont été essayées.

**Désactiver Hyper-V**, dans un terminal PowerShell administrateur, puis redémarrer le poste :

```powershell
bcdedit /set hypervisorlaunchtype off
```

Cette commande demande à Windows de ne plus charger l'hyperviseur au démarrage.

Après redémarrage, `HypervisorPresent` valait `False` et les deux machines sont passées à l'état `running` sous VirtualBox. Cette correction n'a pas été retenue : elle empêche WSL2 de fonctionner, or WSL2 est le poste de contrôle du laboratoire.

Hyper-V a donc été réactivé. La commande correspondante est :

```powershell
bcdedit /set hypervisorlaunchtype auto
```

Elle rétablit le chargement de l'hyperviseur au démarrage et nécessite elle aussi un redémarrage du poste.

**Changer d'hyperviseur.** C'est la correction retenue. Les machines sont désormais créées avec VMware Workstation, qui fonctionne avec Hyper-V actif. La mise en œuvre est décrite dans `02-vagrant.md`.

### Validation

Avec Hyper-V actif (`HypervisorPresent` à `True`) et WSL2 en cours d'exécution :

```text
kube-control              running (vmware_desktop)
kube-worker               running (vmware_desktop)
```

Les deux machines répondent en SSH, comme le montre la validation du problème 4.

---

## 5. Problème 2 — Vagrant utilise VirtualBox malgré le Vagrantfile

### Symptôme

Le `Vagrantfile` déclare le provider `vmware_desktop`, mais Vagrant continue d'utiliser VirtualBox et le problème 1 se reproduit :

```text
Bringing machine 'kube-control' up with 'virtualbox' provider...
...
Timed out while waiting for the machine to boot.
```

### Diagnostic

La première ligne affichée par `vagrant up` indique le provider réellement utilisé. Ici, il ne s'agit pas de celui déclaré.

```powershell
vagrant plugin list
```

Cette commande affiche les plugins installés dans Vagrant.

```text
No plugins installed.
```

### Cause

Le provider `vmware_desktop` n'est pas intégré à Vagrant : il est fourni par le plugin `vagrant-vmware-desktop`.

En l'absence du plugin, Vagrant ne connaît pas ce provider. Il ignore le bloc `provider "vmware_desktop"` sans afficher d'erreur et utilise le provider disponible, VirtualBox.

L'installation du Vagrant VMware Utility ne suffit pas : il s'agit de deux composants distincts.

### Correction

```powershell
vagrant destroy -f
vagrant plugin install vagrant-vmware-desktop
vagrant up --provider vmware_desktop
```

La première commande supprime la machine créée par erreur sous VirtualBox. La deuxième installe le plugin. La troisième crée les machines en désignant explicitement le provider.

### Validation

```text
vagrant-vmware-desktop (3.0.5, global)
```

```text
Bringing machine 'kube-control' up with 'vmware_desktop' provider...
Bringing machine 'kube-worker' up with 'vmware_desktop' provider...
```

### À retenir

Toujours lire la première ligne de `vagrant up`. Si elle n'annonce pas le provider attendu, il est inutile d'attendre la fin du délai : la commande peut être interrompue immédiatement.

---

## 6. Problème 3 — Collision d'adresses avec une carte réseau existante

### Symptôme

Une fois le plugin installé, la création des machines échoue sur le réseau :

```text
==> kube-control: Verifying vmnet devices are healthy...
The host only network with the IP '192.168.57.10' would collide with
another device 'Ethernet 6'. This means that VMware cannot create
a proper networking device to route to your VM. Please choose
another IP or shut down the existing device.
```

### Diagnostic

Le message désigne une carte du poste Windows. Les cartes créées par VirtualBox se listent avec :

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" list hostonlyifs
```

Cette commande affiche les cartes réseau host-only gérées par VirtualBox, avec leur adresse.

```text
Name:            VirtualBox Host-Only Ethernet Adapter #3
IPAddress:       192.168.57.1
NetworkMask:     255.255.255.0
```

### Cause

La plage `192.168.57.0/24` était déjà portée par une carte VirtualBox, héritée de l'époque où le laboratoire tournait sous VirtualBox. VMware refuse de créer un second réseau sur un sous-réseau déjà présent sur le poste, car Windows ne saurait plus par quelle carte joindre les machines.

### Correction

Deux corrections étaient possibles : changer la plage d'adresses du laboratoire, ou libérer la plage existante.

La seconde a été retenue afin de conserver les adresses déjà utilisées dans l'inventaire Ansible et dans la documentation. La carte VirtualBox a été retirée :

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" hostonlyif remove "VirtualBox Host-Only Ethernet Adapter #3"
```

Cette commande supprime la carte host-only VirtualBox désignée.

### Validation

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -like "192.168.57.*"
```

Cette commande liste les cartes du poste qui portent une adresse de la plage du laboratoire.

Résultat vérifié :

```text
VMware Network Adapter VMnet6  192.168.57.1
```

Seule la carte VMware porte une adresse de cette plage. La carte `VirtualBox Host-Only Ethernet Adapter #3` n'existe plus sur le poste, et `vagrant up` franchit l'étape de vérification des réseaux.

### Conséquence connue

Le laboratoire `cka-lab`, distinct de ce projet, utilise la même plage sous VirtualBox. S'il est relancé, VirtualBox recréera sa carte et la collision réapparaîtra. Les deux laboratoires ne peuvent pas fonctionner en même temps tant qu'ils partagent cette plage.

---

## 7. Problème 4 — Les machines sont injoignables depuis Windows et WSL2

### Symptôme

Les machines sont démarrées, mais Ansible ne peut pas s'y connecter :

```text
fatal: [kube-control]: UNREACHABLE! => {"changed": false, "msg": "Failed to connect
to the host via ssh: ssh: connect to host 192.168.57.10 port 22: Connection timed out",
"unreachable": true}
```

### Diagnostic

Le diagnostic suit le chemin du trafic, de la machine virtuelle vers le poste de contrôle.

**Les machines sont-elles démarrées ?**

```powershell
vagrant status
```

```text
kube-control              running (vmware_desktop)
kube-worker               running (vmware_desktop)
```

**Ont-elles la bonne adresse ?**

```powershell
vagrant ssh kube-control -c "ip -4 -br addr"
```

Cette commande passe par le port redirigé de Vagrant et ne dépend donc pas du réseau privé.

```text
eth0             UP             192.168.200.129/24 metric 100
eth1             UP             192.168.57.10/24
```

La machine est correctement configurée. Le problème se situe donc entre la machine et le poste.

**Le poste Windows joint-il la machine ?**

```powershell
Test-NetConnection 192.168.57.10 -Port 22
```

Cette commande teste à la fois la réponse au ping et l'ouverture du port indiqué.

```text
PingSucceeded    : False
TcpTestSucceeded : False
InterfaceAlias   : Ethernet
```

Le trafic part par la carte `Ethernet`, c'est-à-dire vers la passerelle par défaut du poste et non vers le réseau privé. Windows ne possède donc aucune route vers `192.168.57.0/24`.

**Quelle adresse porte la carte du réseau privé ?**

```powershell
Get-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet6" -AddressFamily IPv4
```

```text
IPAddress : 169.254.79.96
```

### Cause

VMware a bien créé le réseau `VMnet6` sur le sous-réseau `192.168.57.0/24` et y a connecté les machines. En revanche, la carte Windows associée est restée configurée en DHCP, alors qu'aucun service DHCP n'existe sur ce réseau.

Faute de réponse, Windows lui a attribué une adresse automatique de la plage `169.254.0.0/16`, inutilisable ici. Le poste n'a donc pas de présence sur le réseau privé. WSL2, dont le trafic sort par le poste Windows, est bloqué de la même manière.

La raison pour laquelle l'adresse n'a pas été attribuée automatiquement à la création du réseau n'a pas été établie.

### Correction

Dans un terminal PowerShell administrateur :

```powershell
New-NetIPAddress -InterfaceAlias "VMware Network Adapter VMnet6" -IPAddress 192.168.57.1 -PrefixLength 24
```

Cette commande attribue une adresse IPv4 fixe à la carte désignée et désactive le DHCP sur celle-ci. L'adresse est enregistrée de façon persistante.

### Validation

Depuis Windows :

```powershell
ping 192.168.57.10
```

```text
Paquets : envoyés = 4, reçus = 4, perdus = 0 (perte 0%)
```

Depuis WSL2, vers les deux machines :

| Test    | `192.168.57.10` | `192.168.57.11` |
| ------- | --------------- | --------------- |
| Ping    | Réussi          | Réussi          |
| Port 22 | Ouvert          | Ouvert          |

### À retenir

Un `ping` qui échoue depuis Windows vers `192.168.57.10`, alors que les machines sont démarrées, doit conduire à vérifier en premier l'adresse de la carte `VMnet6`.

---

## 8. Problème 5 — Clés et empreintes SSH après une recréation des machines

### Symptôme

Lors de la première exécution d'Ansible après la reconstruction des machines, une question interrompt la collecte des faits :

```text
TASK [Gathering Facts]
The authenticity of host '192.168.57.11 (192.168.57.11)' can't be established.
ED25519 key fingerprint is SHA256:...
This host key is known by the following other names/addresses:
    ~/.ssh/known_hosts:5: [hashed name]
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

### Diagnostic

```bash
ls -la ~/.ssh/vagrant/
```

Cette commande affiche les clés privées copiées dans WSL2 ainsi que leur date.

Avant correction, les fichiers dataient du 4 octobre, alors que les machines venaient d'être recréées le 8 octobre.

### Cause

À chaque création d'une machine, Vagrant génère une nouvelle paire de clés pour l'utilisateur `vagrant`, et le système génère une nouvelle identité SSH d'hôte.

Deux éléments enregistrés dans WSL2 deviennent donc obsolètes :

* les clés privées copiées dans `~/.ssh/vagrant/` ;
* les empreintes d'hôte enregistrées dans `~/.ssh/known_hosts`.

### Correction

Les clés ont été recopiées et les anciennes empreintes effacées, selon la procédure décrite dans `05-inventory.md` (section 11.1).

La question d'authenticité a ensuite été acceptée en répondant `yes`.

### Validation

```bash
ansible all -m ping
```

```text
kube-control | SUCCESS => { ... "ping": "pong" }
kube-worker | SUCCESS => { ... "ping": "pong" }
```

### Remarque

Les clés ayant été recopiées avant de relancer Ansible, l'erreur d'authentification `Permission denied (publickey)` n'a pas été observée. C'est le symptôme attendu si cette étape est oubliée.

---

## 9. Problème 6 — Le mode simulation échoue sur l'installation de containerd

### Symptôme

Sur des machines neuves, la simulation du playbook échoue :

```bash
ansible-playbook site.yml --check
```

```text
TASK [containerd : Installer containerd]
fatal: [kube-control]: FAILED! => {"cache_update_time": 1694246382, "cache_updated": true,
"changed": false, "msg": "no available installation candidate for containerd=2.2.1-0ubuntu1~22.04.2"}
```

### Diagnostic

**La version demandée existe-t-elle ?** L'index du dépôt Ubuntu a été consulté directement :

```text
jammy-updates/main  containerd 2.2.1-0ubuntu1~22.04.2
jammy-security/main containerd 2.2.1-0ubuntu1~22.04.2
```

La version demandée est bien publiée. Le rôle est donc correct.

**Que connaît la machine ?**

```bash
apt-cache policy containerd
```

Cette commande affiche les versions d'un paquet connues de l'index APT local.

```text
containerd:
  Installed: (none)
  Candidate: 1.7.2-0ubuntu1~22.04.1
```

**De quand date l'index local ?**

```bash
ls -la --time-style=long-iso /var/lib/apt/lists/ | grep jammy-updates
```

```text
2023-09-09 06:40  us.archive.ubuntu.com_ubuntu_dists_jammy-updates_main_binary-amd64_Packages
```

Le message d'erreur d'Ansible contient la même information : `cache_update_time: 1694246382` correspond au 9 septembre 2023.

### Cause

L'index APT des machines neuves est celui de la box, fabriquée en septembre 2023. Il ne connaît pas `containerd` 2.2.1.

Lors d'une exécution réelle, la première tâche du rôle `common` actualise cet index. En mode `--check`, Ansible **simule** cette actualisation sans l'effectuer : il annonce `cache_updated: true`, mais l'index reste celui de 2023. La tâche suivante cherche alors une version que l'index ne contient pas.

Plus généralement, ce playbook est une chaîne dans laquelle chaque tâche dépend de l'effet réel de la précédente : création d'un répertoire avant le dépôt d'un fichier, ajout d'un dépôt avant l'installation d'un paquet. Le mode simulation ne peut pas valider une telle chaîne sur une machine neuve.

### Correction

Aucune modification du rôle n'est nécessaire. Le playbook a été exécuté réellement :

```bash
ansible-playbook site.yml
```

### Validation

```text
kube-control : ok=16   changed=13   unreachable=0    failed=0
kube-worker  : ok=16   changed=13   unreachable=0    failed=0
```

```bash
ansible all -m shell -a 'containerd --version'
```

```text
containerd github.com/containerd/containerd/v2 2.2.1
```

### À retenir

Sur des machines neuves, la validation de ce playbook se fait en trois temps :

| Validation    | Commande                                   | Ce qu'elle prouve                              |
| ------------- | ------------------------------------------ | ---------------------------------------------- |
| Syntaxique    | `ansible-playbook site.yml --syntax-check` | Le playbook est correctement écrit             |
| Fonctionnelle | `ansible-playbook site.yml`                | Les tâches s'exécutent sans échec              |
| Idempotence   | Seconde exécution de `ansible-playbook site.yml` | `changed=0` : l'état souhaité est atteint |

Le mode `--check` redevient utile sur des machines déjà configurées, pour détecter un écart.

---

## 10. Problème 7 — Le swap est actif sur les nœuds

### Symptôme

Aucune erreur n'a été affichée. L'écart a été détecté par une vérification de l'état des nœuds après l'exécution du playbook :

```bash
ansible all -m shell -a 'swapon --show'
```

```text
NAME      TYPE SIZE USED PRIO
/swap.img file   2G   0B   -2
```

La documentation indiquait pourtant que le swap était désactivé et qu'aucune tâche Ansible n'était nécessaire.

### Diagnostic

```bash
ansible all -m shell -a 'free -h'
```

```text
Swap:          2.0Gi          0B       2.0Gi
```

```bash
ansible all -m shell -a 'grep swap /etc/fstab'
```

```text
/swap.img	none	swap	sw	0	0
```

Le swap est actif et sera réactivé à chaque démarrage.

### Cause

L'affirmation de la documentation était exacte pour la box `ubuntu/jammy64`, qui démarre sans swap. Elle ne l'était plus après le passage à la box `bento/ubuntu-22.04`, imposé par le changement d'hyperviseur, qui crée un fichier de swap de 2 Go.

Un état constaté sur une machine dépend de l'image utilisée. Il ne peut pas être tenu pour acquis après un changement d'image.

### Correction

Deux tâches ont été ajoutées au rôle `common`. Elles sont décrites dans `07-kubernetes-prerequisites.md` (section 8).

### Validation

```text
Swap:             0B          0B          0B
```

```text
# /swap.img     none    swap    sw      0       0
```

### À retenir

Un prérequis qui n'est garanti que par l'état initial de l'image doit être automatisé. Il est alors garanti quelle que soit l'image.

---

## 11. Problème 8 — Ansible ignore le fichier ansible.cfg du projet

### Symptôme

Depuis le répertoire `lab-local/ansible`, Ansible ne trouve aucune machine :

```text
[WARNING]: Ansible is being run in a world writable directory
(/mnt/f/Users/x/Documents/apprentissage/EshopOnContainer/lab-local/ansible),
ignoring it as an ansible.cfg source.
[WARNING]: No inventory was parsed, only implicit localhost is available
[WARNING]: provided hosts list is empty, only localhost is available.
```

Ce symptôme apparaît lorsque Ansible est lancé depuis un shell qui n'a pas chargé le profil de l'utilisateur.

### Diagnostic

```bash
ansible --version | grep "config file"
```

Cette commande affiche le fichier de configuration réellement chargé par Ansible.

```text
config file = None
```

```bash
stat -c "%A %n" /mnt/f/Users/x/Documents/apprentissage/EshopOnContainer/lab-local/ansible
```

Cette commande affiche les permissions du répertoire.

```text
drwxrwxrwx /mnt/f/Users/x/Documents/apprentissage/EshopOnContainer/lab-local/ansible
```

### Cause

Le projet se trouve sur un lecteur Windows monté dans WSL2. Sur ce montage, tous les répertoires apparaissent comme accessibles en écriture à tous les utilisateurs.

Ansible refuse de charger un `ansible.cfg` trouvé dans un tel répertoire, car n'importe quel utilisateur du système pourrait y déposer une configuration malveillante. Sans ce fichier, Ansible ne connaît ni l'inventaire, ni l'utilisateur distant, ni l'emplacement des rôles.

### Correction

Le chemin du fichier est indiqué explicitement par la variable d'environnement `ANSIBLE_CONFIG`, définie dans `~/.bashrc`. La configuration est décrite dans `04-ansible.md` (section 8.1).

### Validation

```text
config file = /mnt/f/Users/x/Documents/apprentissage/EshopOnContainer/lab-local/ansible/ansible.cfg
```

```bash
ansible-inventory --graph
```

```text
@all:
  |--@ungrouped:
  |--@k8s_cluster:
  |  |--@control_plane:
  |  |  |--kube-control
  |  |--@workers:
  |  |  |--kube-worker
```

---

## 12. Problème 9 — Le nœud s'enregistre avec l'adresse NAT

### Symptôme

Après `kubeadm init`, le Control Plane fonctionne et l'API répond sur l'adresse attendue, mais le nœud est enregistré avec l'adresse de l'interface NAT :

```bash
kubectl get nodes -o wide
```

```text
NAME           STATUS   ROLES           VERSION   INTERNAL-IP
kube-control   ...      control-plane   v1.36.5   192.168.200.129
```

L'adresse attendue, définie dans `01-architecture.md`, est `192.168.57.10`.

### Diagnostic

**L'API est-elle annoncée sur la bonne adresse ?**

```bash
kubectl cluster-info
```

```text
Kubernetes control plane is running at https://192.168.57.10:6443
```

Le paramètre `advertiseAddress` du fichier de configuration `kubeadm` a donc bien été pris en compte. L'écart ne concerne que l'adresse du nœud.

**Par quelle interface passe la route par défaut ?**

```bash
ip route
```

Cette commande affiche la table de routage de la machine.

```text
default via 192.168.200.2 dev eth0 proto dhcp src 192.168.200.129 metric 100
192.168.57.0/24 dev eth1 proto kernel scope link src 192.168.57.10
```

**Quelles options reçoit kubelet ?**

```bash
cat /etc/default/kubelet
```

```text
KUBELET_EXTRA_ARGS=
```

Aucune adresse n'est imposée à `kubelet`.

### Cause

L'adresse de l'API et l'adresse du nœud sont deux paramètres indépendants, comme expliqué dans `10-control-plane.md` (section 4).

Le fichier de configuration `kubeadm` fixait `advertiseAddress`, qui ne concerne que l'API. Rien n'indiquait à `kubelet` quelle adresse utiliser pour le nœud. Il a donc retenu celle de l'interface portant la route par défaut, c'est-à-dire l'interface NAT.

Cette adresse est attribuée en DHCP et peut changer. Un nœud enregistré avec elle pourrait devenir injoignable pour le reste du cluster après un redémarrage.

### Correction

L'option `--node-ip=192.168.57.10` a été ajoutée dans `/etc/default/kubelet`, puis `kubelet` a été redémarré. La procédure est décrite dans `10-control-plane.md` (section 6.3).

### Validation

```text
NAME           STATUS   ROLES           VERSION   INTERNAL-IP
kube-control   Ready    control-plane   v1.36.5   192.168.57.10
```

L'option est bien reçue par le processus en cours d'exécution :

```text
--node-ip=192.168.57.10
```

### Effet résiduel

Quatre Pods statiques du Control Plane affichent encore l'adresse NAT dans leur statut. Les vérifications montrant que cet affichage est sans effet sont détaillées dans `10-control-plane.md` (section 8).

### À retenir

Sur une machine à plusieurs interfaces, l'adresse du nœud doit être fixée explicitement. Le Worker possède les deux mêmes interfaces : la précaution a été appliquée avant sa jonction, comme décrit dans `12-worker.md` (section 4), et il s'est enregistré directement avec `192.168.57.11`.

Dans ce laboratoire, l'adresse a été corrigée après l'initialisation. Elle peut aussi être fournie dès l'initialisation, dans le fichier de configuration `kubeadm`, ce qui éviterait de passer par l'adresse NAT. Cette piste n'a pas été appliquée.

---

## 13. Problème 10 — kubeadm join échoue sans privilèges administrateur

### Symptôme

Sur `kube-worker`, la commande de jonction échoue dès les vérifications préalables :

```bash
kubeadm join 192.168.57.10:6443 --token <JETON> --discovery-token-ca-cert-hash sha256:<EMPREINTE>
```

```text
[ERROR IsPrivilegedUser]: user is not running as root
```

### Diagnostic

Le message désigne directement la vérification en échec : `IsPrivilegedUser`. La commande a été lancée par l'utilisateur `vagrant`, sans élévation de privilèges.

### Cause

`kubeadm join` écrit dans `/etc/kubernetes` et configure le service `kubelet`. Ces opérations sont réservées à `root`. `kubeadm` le vérifie avant toute modification, ce qui évite de laisser le nœud dans un état partiel.

### Correction

La même commande a été relancée avec `sudo` :

```bash
sudo kubeadm join 192.168.57.10:6443 --token <JETON> --discovery-token-ca-cert-hash sha256:<EMPREINTE>
```

### Validation

```text
This node has joined the cluster
```

```text
kube-worker    Ready    <none>          v1.36.5   192.168.57.11
```

### À retenir

L'échec s'est produit avant toute modification du nœud. Aucun nettoyage n'a été nécessaire avant de relancer la commande.

---

## 14. Problème 11 — Avertissement kube-proxy pendant la jonction

### Symptôme

Pendant l'exécution de `kubeadm join`, un avertissement est affiché :

```text
The recommended value for "bindAddress" in "KubeProxyConfiguration" is: ::;
the provided value is: 0.0.0.0
```

La jonction se termine malgré tout avec succès.

### Diagnostic

Il s'agit d'un avertissement et non d'une erreur : la commande n'a pas été interrompue.

L'effet sur le composant concerné a été vérifié sur le cluster :

```bash
kubectl -n kube-system get daemonset kube-proxy
kubectl get pods -n kube-system -o wide | grep kube-proxy
```

Ces commandes affichent l'état du DaemonSet `kube-proxy` et celui de ses Pods sur chaque nœud.

Résultat vérifié : 2 Pods attendus, 2 Pods prêts, sans aucun redémarrage.

```text
kube-proxy-6k5xb   1/1   Running   0   192.168.57.10   kube-control
kube-proxy-jn6wl   1/1   Running   0   192.168.57.11   kube-worker
```

Le rôle de `kube-proxy`, l'accès aux Services, a par ailleurs été validé par le test décrit dans `12-worker.md` (section 9.2).

### Cause

La cause n'a pas été investiguée. La valeur `0.0.0.0` n'a pas été choisie dans ce laboratoire : le fichier de configuration `kubeadm` ne contient aucun paramètre relatif à `kube-proxy`.

### Décision

Aucune modification n'a été appliquée.

### À retenir

Un avertissement doit être lu et vérifié, mais il ne justifie pas à lui seul une modification de configuration. Ici, le composant visé fonctionne sur les deux nœuds et le test fonctionnel qui en dépend réussit.

---

## 15. Points de vigilance non encore traités

Les points suivants ont été identifiés mais ne sont pas des pannes. Ils sont listés pour ne pas être oubliés.

| Point                                                                                         | Risque                                                              | Traitement prévu      |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | --------------------- |
| L'option `--node-ip` est écrite à la main dans `/etc/default/kubelet` sur les deux nœuds      | Après une reconstruction, un nœud s'enregistrerait de nouveau avec son adresse NAT (problème 9) | À décider |
| L'initialisation du Control Plane, l'installation de Calico et la jonction du Worker ne sont pas dans le dépôt | La reconstruction du cluster n'est pas entièrement reproductible | À décider |
| Le paquet `containerd` n'est pas figé, contrairement aux paquets Kubernetes                   | Une mise à jour du système pourrait changer la version du runtime   | À décider             |
| La commande de jonction, jeton compris, figure dans l'historique shell de `kube-worker`       | Limité : le jeton expire le 9 octobre 2026 à 20:47 UTC              | Aucun                 |
| Le `Vagrantfile` ne fixe pas de provider par défaut                                           | Un `vagrant up` sans option `--provider` peut choisir un autre hyperviseur | À décider             |
| Les clés SSH doivent être recopiées après chaque recréation des machines                      | Étape manuelle facile à oublier                                     | À décider             |
| La plage `192.168.57.0/24` est partagée avec le laboratoire `cka-lab`                         | Les deux laboratoires ne peuvent pas fonctionner en même temps      | À décider             |

---

## 16. Documentation associée

| Fichier                          | Lien avec ce document                              |
| -------------------------------- | -------------------------------------------------- |
| `10-control-plane.md`            | Adresse du nœud (problème 9)                       |
| `12-worker.md`                   | Jonction du Worker (problèmes 10 et 11)            |
| `01-architecture.md`             | Choix de l'hyperviseur, réseaux                    |
| `02-vagrant.md`                  | Prérequis VMware, réseau privé (problèmes 1 à 4)   |
| `04-ansible.md`                  | Chargement de `ansible.cfg` (problème 8)           |
| `05-inventory.md`                | Clés SSH après recréation (problème 5)             |
| `07-kubernetes-prerequisites.md` | Désactivation du swap (problème 7)                 |
| `08-containerd.md`               | Installation de `containerd` (problème 6)          |
