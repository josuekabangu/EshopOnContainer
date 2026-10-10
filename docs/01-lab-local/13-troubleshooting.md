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
| 12 | Vagrant déclare `not created` des machines qui tournent ; machines en double | Deux installations de Vagrant sur le même dossier | Vagrant           |
| 13 | Ansible : `UNREACHABLE` alors que Windows joint les machines     | WSL2 en mode réseau `mirrored`                          | Réseau WSL2       |
| 14 | Tâche `kubectl apply` en `changed` à chaque exécution            | `kubectl apply` annonce `configured` sans rien modifier | Ansible           |
| 15 | Un play entier est ignoré, sans erreur                           | Nom de groupe mal orthographié dans `hosts`             | Ansible           |

Les problèmes 1 à 11 ont été rencontrés le 8 octobre 2026, lors de la construction manuelle du laboratoire. Les problèmes 12 à 15 l'ont été le 9 octobre 2026, lors de son automatisation.

Les problèmes 1 à 8 ont été diagnostiqués pas à pas, avec les résultats de commande relevés au moment de la panne. Pour le problème 9, le symptôme et l'état initial du fichier `/etc/default/kubelet` proviennent des notes prises lors de l'intervention ; la table de routage et la validation ont été vérifiées après correction. Pour les problèmes 10 et 11, les messages proviennent également des notes prises lors de l'intervention ; l'état final du nœud a été vérifié sur le cluster. Les problèmes 12 à 15 ont été diagnostiqués pas à pas, avec les résultats relevés au moment de l'incident.

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
(/chemin/absolu/vers/EshopOnContainer/lab-local/ansible),
ignoring it as an ansible.cfg source.
[WARNING]: No inventory was parsed, only implicit localhost is available
[WARNING]: provided hosts list is empty, only localhost is available.
```

Ce symptôme apparaît lorsque Ansible est lancé depuis un shell qui n'a pas chargé le profil de l'utilisateur.

Dans les sorties de cette section, l'emplacement réel du dépôt est remplacé par `/chemin/absolu/vers/EshopOnContainer`, selon la convention décrite dans `03-wsl.md` (section 8).

### Diagnostic

```bash
ansible --version | grep "config file"
```

Cette commande affiche le fichier de configuration réellement chargé par Ansible.

```text
config file = None
```

```bash
stat -c "%A %n" /chemin/absolu/vers/EshopOnContainer/lab-local/ansible
```

Cette commande affiche les permissions du répertoire.

```text
drwxrwxrwx /chemin/absolu/vers/EshopOnContainer/lab-local/ansible
```

### Cause

Le projet se trouve sur un lecteur Windows monté dans WSL2. Sur ce montage, tous les répertoires apparaissent comme accessibles en écriture à tous les utilisateurs.

Ansible refuse de charger un `ansible.cfg` trouvé dans un tel répertoire, car n'importe quel utilisateur du système pourrait y déposer une configuration malveillante. Sans ce fichier, Ansible ne connaît ni l'inventaire, ni l'utilisateur distant, ni l'emplacement des rôles.

### Correction

Le chemin du fichier est indiqué explicitement par la variable d'environnement `ANSIBLE_CONFIG`, définie dans `~/.bashrc`. La configuration est décrite dans `04-ansible.md` (section 8.1).

### Validation

```text
config file = /chemin/absolu/vers/EshopOnContainer/lab-local/ansible/ansible.cfg
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

La première correction a été manuelle. Le fichier `/etc/default/kubelet` a été modifié pour contenir :

```text
KUBELET_EXTRA_ARGS=--node-ip=192.168.57.10
```

Le service a ensuite été redémarré :

```bash
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

La première commande demande à `systemd` de relire sa configuration. La seconde redémarre `kubelet`, qui prend alors en compte l'option `--node-ip`.

### Validation

```text
NAME           STATUS   ROLES           VERSION   INTERNAL-IP
kube-control   Ready    control-plane   v1.36.5   192.168.57.10
```

L'option est bien reçue par le processus en cours d'exécution :

```text
--node-ip=192.168.57.10
```

### Effet résiduel de la correction manuelle

Après cette correction, quatre Pods statiques du Control Plane affichaient encore l'adresse NAT dans leur statut :

```text
NAME                                   HOSTIP          PODIP
etcd-kube-control                      192.168.57.10   192.168.200.129
kube-apiserver-kube-control            192.168.57.10   192.168.200.129
kube-controller-manager-kube-control   192.168.57.10   192.168.200.129
kube-scheduler-kube-control            192.168.57.10   192.168.200.129
```

Les options des composants, les ports en écoute, le certificat de l'API et le Service `kubernetes` utilisaient tous `192.168.57.10`. L'écart se limitait à l'affichage du statut des Pods et n'avait pas d'effet fonctionnel.

### Résolution à la racine

La correction manuelle traitait le symptôme : elle intervenait après l'initialisation. Le 9 octobre 2026, l'option `--node-ip` a été intégrée au rôle Ansible `kubernetes`, appliqué à tous les nœuds **avant** l'initialisation et la jonction. La mise en œuvre est décrite dans `09-kubernetes.md` (section 6.3).

Le cluster a ensuite été entièrement reconstruit.

Validation sur le cluster reconstruit :

```text
NAME           STATUS   ROLES           VERSION   INTERNAL-IP
kube-control   Ready    control-plane   v1.36.5   192.168.57.10
kube-worker    Ready    <none>          v1.36.5   192.168.57.11
```

```text
NAME                                   HOSTIP          PODIP
etcd-kube-control                      192.168.57.10   192.168.57.10
kube-apiserver-kube-control            192.168.57.10   192.168.57.10
kube-controller-manager-kube-control   192.168.57.10   192.168.57.10
kube-scheduler-kube-control            192.168.57.10   192.168.57.10
```

Les deux nœuds s'enregistrent directement avec l'adresse du réseau privé, et l'effet résiduel sur les Pods statiques a disparu.

### À retenir

Sur une machine à plusieurs interfaces, l'adresse du nœud doit être fixée explicitement, et **avant** que le nœud ne rejoigne ou n'initialise un cluster.

Corriger après coup fonctionne, mais laisse des traces. Placer la configuration au bon endroit dans l'ordre de construction supprime le problème au lieu de le réparer.

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

Le rôle de `kube-proxy`, l'accès aux Services, a par ailleurs été validé par le test décrit dans `12-worker.md` (section 7.5).

### Cause

La cause n'a pas été investiguée. La valeur `0.0.0.0` n'a pas été choisie dans ce laboratoire : le fichier de configuration `kubeadm` ne contient aucun paramètre relatif à `kube-proxy`.

### Décision

Aucune modification n'a été appliquée.

### À retenir

Un avertissement doit être lu et vérifié, mais il ne justifie pas à lui seul une modification de configuration. Ici, le composant visé fonctionne sur les deux nœuds et le test fonctionnel qui en dépend réussit.

---

## 15. Problème 12 — Deux installations de Vagrant sur le même dossier

### Symptôme

Après une recréation des machines, plusieurs anomalies apparaissent en même temps :

```powershell
vagrant status
```

```text
kube-control              not created (vmware_desktop)
kube-worker               not created (vmware_desktop)
```

Vagrant annonce que les machines n'existent pas, alors qu'elles répondent en SSH sur leurs adresses.

### Diagnostic

Le diagnostic a été mené sans passer par Vagrant, en interrogeant directement VMware.

```powershell
& "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe" list
```

Cette commande liste les machines virtuelles en cours d'exécution dans VMware, indépendamment de ce que Vagrant en sait.

```text
Total running VMs: 3
...\kube-control\vmware_desktop\fb79a3e1-...\ubuntu-22.04-amd64.vmx
...\kube-control\vmware_desktop\0f6bdd92-...\ubuntu-22.04-amd64.vmx
...\kube-worker\vmware_desktop\d69a656f-...\ubuntu-22.04-amd64.vmx
```

Trois machines tournent, dont **deux `kube-control`**. Leur date de création diffère de plusieurs heures : la première est une machine orpheline, restée en fonctionnement après avoir été remplacée. Les deux portent la même adresse `192.168.57.10`.

Le répertoire d'état de Vagrant a ensuite été examiné :

```powershell
Get-ChildItem -Force -Recurse lab-local\vagrant\.vagrant\machines
```

Constat pour chacune des trois machines :

| Fichier                                | État     |
| -------------------------------------- | -------- |
| `id` (lien entre Vagrant et la machine) | Absent   |
| `private_key`                          | Absent   |
| Fichier `.vmx` de la machine           | Absent   |
| Disques, journal                       | Présents, car verrouillés par la machine en cours d'exécution |

Les machines tournaient donc sans leur fichier de définition, et Vagrant n'avait plus aucun moyen de les retrouver.

La cause est apparue dans la configuration de WSL2 :

```bash
grep VAGRANT ~/.bashrc
```

```text
export VAGRANT_WSL_ENABLE_WINDOWS_ACCESS=1
export VAGRANT_DEFAULT_PROVIDER=vmware_desktop
```

Ces deux lignes activent le Vagrant installé dans WSL2 et l'autorisent à piloter VMware sur Windows.

### Cause

Deux installations de Vagrant agissaient sur le même dossier `lab-local/vagrant` : celle de Windows, lancée depuis PowerShell, et celle de WSL2, lancée depuis le terminal Linux.

Chacune enregistre les machines qu'elle crée à sa façon. Aucune ne reconnaît celles de l'autre.

Or, lorsqu'un Vagrant considère qu'une machine n'existe pas, il efface le contenu de son répertoire d'état. C'est le comportement constaté ici : une simple commande `vagrant status`, lancée par l'installation qui n'avait pas créé les machines, a supprimé leurs fichiers `id`, `private_key` et `.vmx`. Seuls les fichiers verrouillés ont subsisté.

L'incident s'est produit dans les deux sens au cours de la même journée :

1. d'après les dates de création des machines, le Vagrant de WSL2 n'a pas reconnu une machine `kube-control` créée depuis Windows, l'a laissée tourner et en a créé une seconde ; cette première occurrence n'a pas été observée directement, elle est déduite de l'état constaté ;
2. le Vagrant de Windows n'a pas reconnu les machines créées depuis WSL2 et a effacé leur état ; cette seconde occurrence a été observée, les fichiers ayant disparu au moment d'une commande `vagrant status` lancée depuis Windows.

### Correction

**Arrêt des machines orphelines.** Vagrant ne pouvant plus les piloter, leurs processus ont été arrêtés directement, dans PowerShell :

```powershell
Get-Process vmware-vmx
Stop-Process -Id <identifiants> -Force
```

La première commande liste les processus des machines VMware en cours. La seconde arrête ceux dont l'identifiant est indiqué.

**Suppression de l'état résiduel**, depuis `lab-local\vagrant` :

```powershell
Remove-Item -Recurse -Force .vagrant
```

**Retour à une seule installation.** Les deux lignes `VAGRANT_*` ont été retirées de `~/.bashrc`.

**Recréation des machines**, depuis PowerShell, comme décrit dans `02-vagrant.md`.

### Validation

```text
Total running VMs: 2
```

```text
kube-control | SUCCESS => { ... "ping": "pong" }
kube-worker  | SUCCESS => { ... "ping": "pong" }
```

### À retenir

Un dossier Vagrant ne doit être piloté que par une seule installation de Vagrant. Dans ce laboratoire, la règle est :

| Outil                                  | Terminal                              |
| -------------------------------------- | ------------------------------------- |
| `vagrant`                              | PowerShell, dans `lab-local\vagrant`  |
| `ansible`, `ansible-playbook`, `ssh`   | WSL2                                  |

Une commande `vagrant status` n'est pas sans effet : elle peut effacer l'état de machines qu'elle ne reconnaît pas. Pour diagnostiquer un doute sur l'état des machines, `vmrun list` et un test SSH direct sont plus sûrs.

---

## 16. Problème 13 — WSL2 ne joint plus les machines en mode réseau mirrored

### Symptôme

Depuis WSL2, Ansible ne joint plus les machines :

```text
kube-control | UNREACHABLE! => {"msg": "Failed to connect to the host via ssh:
ssh: connect to host 192.168.57.10 port 22: Connection timed out"}
```

La commande `ssh-keyscan` vers les mêmes adresses ne retourne rien.

Ce symptôme est le même que celui du problème 4, mais la cause est différente.

### Diagnostic

**Le poste Windows joint-il les machines ?**

```powershell
Test-NetConnection 192.168.57.10 -Port 22
```

```text
TcpTestSucceeded : True
InterfaceAlias   : VMware Network Adapter VMnet6
```

Windows joint les machines par la carte `VMnet6`, qui porte bien l'adresse `192.168.57.1`. Le problème 4 est donc écarté : le blocage se situe entre WSL2 et Windows.

**Quel réseau voit WSL2 ?**

```bash
ip -4 -br addr
ip route
```

Ces commandes affichent les interfaces de WSL2 et sa table de routage.

```text
eth1             UP             192.168.1.52/24
default via 192.168.1.254 dev eth1
```

WSL2 ne possède plus son adresse habituelle en `172.26.x.x`. Il porte l'adresse du poste sur le réseau local, et sa route par défaut mène à la passerelle de ce réseau. Aucune route ne mène à `192.168.57.0/24`.

**Comment WSL2 est-il configuré ?**

```powershell
Get-Content $env:USERPROFILE\.wslconfig
```

```text
[wsl2]
networkingMode=mirrored
```

### Cause

En mode réseau `mirrored`, WSL2 ne passe plus par le poste Windows pour sortir : il reproduit directement les interfaces réseau de celui-ci.

Dans ce laboratoire, seule la carte du réseau local a été reproduite. La carte `VMnet6` de VMware ne l'a pas été. WSL2 n'a donc aucun accès au réseau privé des machines, et le trafic destiné à `192.168.57.x` part vers la passerelle du réseau local, qui ne le connaît pas.

Dans le mode par défaut, le trafic de WSL2 sort par le poste Windows, qui le transmet à la carte `VMnet6`, comme décrit dans `03-wsl.md`.

### Correction

La ligne `networkingMode=mirrored` a été retirée du fichier `.wslconfig`, puis WSL2 a été redémarré depuis PowerShell :

```powershell
wsl --shutdown
```

Cette commande arrête WSL2 et ferme tous ses terminaux. La nouvelle configuration est prise en compte au démarrage suivant.

### Validation

```text
eth0             UP             172.26.3.27/20
default via 172.26.0.1 dev eth0
```

```text
kube-control | SUCCESS => { ... "ping": "pong" }
kube-worker  | SUCCESS => { ... "ping": "pong" }
```

### À retenir

Devant un `UNREACHABLE`, tester d'abord depuis Windows. Si Windows joint les machines et WSL2 non, la cause est dans la configuration réseau de WSL2, et non dans VMware.

Le mode `mirrored` ne convient pas à ce laboratoire, qui repose sur un réseau privé VMware.

---

## 17. Problème 14 — kubectl apply annonce un changement à chaque exécution

### Symptôme

La tâche qui applique le fichier de définition de Calico répond `changed` à chaque exécution du playbook, y compris lorsque rien n'a changé :

```text
TASK [calico : Appliquer le fichier de définition de Calico]
changed: [kube-control]
```

Le récapitulatif de la seconde exécution n'atteint donc jamais `changed=0` :

```text
kube-control : ok=28   changed=1
```

### Diagnostic

La tâche décidait de son état d'après la sortie de `kubectl apply` :

```yaml
changed_when: "'created' in calico_apply.stdout or 'configured' in calico_apply.stdout"
```

La commande a été rejouée en simulation, pour lire cette sortie sans rien modifier :

```bash
kubectl apply --dry-run=server -f /etc/kubernetes/calico-v3.30.3.yaml | grep -v unchanged
```

L'option `--dry-run=server` demande au cluster de calculer le résultat sans l'enregistrer. Le filtre ne conserve que les ressources qui ne sont pas annoncées inchangées.

```text
poddisruptionbudget.policy/calico-kube-controllers configured (server dry run)
customresourcedefinition.apiextensions.k8s.io/bgpconfigurations.crd.projectcalico.org configured (server dry run)
...
daemonset.apps/calico-node configured (server dry run)
```

Sur 39 ressources, 26 sont annoncées `configured` : 24 définitions de ressources personnalisées, le DaemonSet et le PodDisruptionBudget.

**Ces ressources sont-elles réellement modifiées ?**

```bash
kubectl diff -f /etc/kubernetes/calico-v3.30.3.yaml
echo $?
```

`kubectl diff` compare le fichier avec l'état du cluster. La seconde commande affiche son code de retour.

Résultat : aucune sortie, et un code de retour égal à `0`. Il n'existe aucune différence.

**Le DaemonSet a-t-il été redéployé ?**

```bash
kubectl -n kube-system get ds calico-node -o jsonpath='{.metadata.generation}'
```

Cette commande affiche le numéro de génération du DaemonSet, qui augmente à chaque modification de sa définition.

Résultat : `1`. Le DaemonSet n'a jamais été modifié depuis sa création, et ses Pods n'ont pas redémarré.

### Cause

`kubectl apply` annonce `configured` dès qu'il envoie une modification au cluster, même lorsque l'état obtenu est identique à l'état existant. Pour ce fichier de définition, c'est le cas de 26 ressources à chaque exécution.

Le mot `configured` dans la sortie n'est donc pas un indicateur fiable de changement. La tâche produisait un faux positif : le cluster n'était pas modifié, mais Ansible l'affirmait.

### Correction

L'idempotence ne repose plus sur la sortie de `kubectl apply`, mais sur le code de retour de `kubectl diff`, qui compare l'état final. La tâche d'application ne s'exécute que si une différence existe. Les tâches sont décrites dans `11-calico.md` (section 5.3).

### Validation

```text
TASK [calico : Comparer le fichier de définition de Calico avec l'état du cluster]  ok
TASK [calico : Appliquer le fichier de définition de Calico]                        skipping
```

```text
kube-control : ok=28   changed=0    unreachable=0    failed=0    skipped=2
```

Sur un cluster neuf, la comparaison signale une différence et l'application a bien lieu : ce cas a été vérifié lors de la reconstruction du 9 octobre 2026.

### À retenir

Ce défaut n'est apparu qu'à la seconde exécution du playbook. Une seule exécution réussie ne prouve pas l'idempotence.

Pour une commande, l'idempotence doit s'appuyer sur une comparaison de l'état réel, et non sur le texte affiché par l'outil.

---

## 18. Problème 15 — Un play est ignoré sans erreur

### Symptôme

Après l'ajout d'un play à `site.yml`, les rôles de ce play ne s'exécutent pas. Le playbook se termine pourtant normalement, sans tâche en échec.

Trois signes le révèlent.

À la vérification de syntaxe :

```text
[WARNING]: Could not match supplied host pattern, ignoring: Workers

playbook: site.yml
```

Pendant l'exécution :

```text
PLAY [Joindre les Workers au cluster]
skipping: no hosts matched
```

Dans le récapitulatif, où le nombre de tâches est inférieur à celui attendu :

```text
kube-worker : ok=19
```

au lieu de `ok=22`.

### Diagnostic

```bash
grep -n "hosts:" site.yml
grep -n "^\[" inventory.ini
```

La première commande affiche les machines ciblées par chaque play. La seconde affiche les groupes déclarés dans l'inventaire.

```text
hosts: Workers
```

```text
[control_plane]
[workers]
[k8s_cluster:children]
```

### Cause

Le play ciblait `Workers`, alors que le groupe de l'inventaire s'appelle `workers`. Les noms de groupes sont sensibles à la casse.

Ansible ne considère pas un groupe introuvable comme une erreur : il estime que le play ne concerne aucune machine et passe au suivant. La vérification de syntaxe réussit, puisque le fichier est correctement écrit.

Le même incident s'est produit avec `Control_plan` à la place de `control_plane`.

### Correction

Le nom du groupe a été corrigé dans `site.yml` :

```yaml
  hosts: workers
```

### Validation

```bash
ansible-playbook site.yml --list-hosts
```

Cette commande affiche les machines retenues par chaque play, sans rien exécuter.

Résultat attendu : `kube-control` et `kube-worker` pour le premier play, `kube-control` pour le deuxième, `kube-worker` pour le troisième.

```text
kube-worker : ok=22   changed=0   skipped=3
```

### À retenir

Un avertissement de `--syntax-check` doit être traité avant de lancer le playbook. Les commandes de validation se lancent une par une, et non en bloc : sinon l'exécution démarre malgré l'avertissement.

Connaître à l'avance le nombre de tâches attendu dans le récapitulatif permet de repérer un play ou un rôle qui n'a pas tourné.

---

## 19. Points de vigilance

Les points suivants ont été identifiés mais ne sont pas des pannes. Ils sont listés pour ne pas être oubliés.

### 19.1 Points résolus

| Point                                                                                       | Résolution                                                                  |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| L'option `--node-ip` était écrite à la main sur chaque nœud                                 | Intégrée au rôle `kubernetes` le 9 octobre 2026                             |
| L'initialisation, l'installation de Calico et la jonction n'étaient pas dans le dépôt       | Automatisées par les rôles `control_plane`, `calico` et `worker`            |
| La commande de jonction, jeton compris, figurait dans l'historique shell de `kube-worker`   | Machines détruites ; la jonction passe désormais par Ansible, sans affichage du jeton |
| Les clés SSH devaient être recopiées à la main après chaque recréation des machines         | Script `lab-local/scripts/setup-ssh.sh`, décrit dans `05-inventory.md` (section 11.2) |
| Le script `setup-ssh.sh` appelait `vagrant` depuis WSL2                                     | Réécrit le 9 octobre 2026 : il n'appelle plus Vagrant et lit l'inventaire Ansible |
| Le script `setup-ssh.sh` n'avait pas été éprouvé à la suite d'une recréation des machines   | Utilisé avec succès lors de la seconde reconstruction du 9 octobre 2026     |
| Le paquet `containerd` n'était pas figé, contrairement aux paquets Kubernetes               | Figé par le rôle `containerd` le 9 octobre 2026, voir `08-containerd.md` (section 6) |
| Les tests fonctionnels du réseau n'avaient pas été rejoués après la reconstruction          | Rejoués le 9 octobre 2026 depuis `kubernetes/tests/network-test.yaml`, voir `12-worker.md` (section 7) |

### 19.2 Points ouverts

| Point                                                                                         | Risque                                                              | Traitement prévu      |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | --------------------- |
| Les tests fonctionnels du réseau sont lancés à la main                                        | Ils peuvent être oubliés après une reconstruction                   | À décider             |
| Le paquet `runc`, dépendance de `containerd`, n'est pas figé                                  | Une mise à jour du système pourrait changer sa version              | À décider             |
| Le `Vagrantfile` ne fixe pas de provider par défaut                                           | Un `vagrant up` sans option `--provider` peut choisir un autre hyperviseur | À décider             |
| La reconstruction demande encore trois commandes, dans deux terminaux                         | Enchaînement manuel entre PowerShell et WSL2                        | À décider             |
| La plage `192.168.57.0/24` est partagée avec le laboratoire `cka-lab`                         | Les deux laboratoires ne peuvent pas fonctionner en même temps      | À décider             |

---

## 20. Documentation associée

| Fichier                          | Lien avec ce document                              |
| -------------------------------- | -------------------------------------------------- |
| `10-control-plane.md`            | Adresse du nœud (problème 9)                       |
| `12-worker.md`                   | Jonction du Worker (problèmes 10 et 11)            |
| `06-roles.md`                    | Noms de groupes, méthode de validation (problème 15) |
| `11-calico.md`                   | Idempotence de l'installation de Calico (problème 14) |
| `03-wsl.md`                      | Mode réseau de WSL2 (problème 13)                  |
| `01-architecture.md`             | Choix de l'hyperviseur, réseaux                    |
| `02-vagrant.md`                  | Prérequis VMware, réseau privé, installation unique de Vagrant (problèmes 1 à 4 et 12) |
| `04-ansible.md`                  | Chargement de `ansible.cfg` (problème 8)           |
| `05-inventory.md`                | Clés SSH après recréation (problème 5)             |
| `07-kubernetes-prerequisites.md` | Désactivation du swap (problème 7)                 |
| `08-containerd.md`               | Installation de `containerd` (problème 6)          |
