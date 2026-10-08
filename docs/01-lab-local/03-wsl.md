# 03 — WSL2 : environnement de contrôle

## 1. Objectif

Ce document présente l'utilisation de **WSL2 (Windows Subsystem for Linux 2)** comme environnement Linux de contrôle du laboratoire local EshopOnContainer.

WSL2 permet d'utiliser un environnement Linux directement depuis le poste Windows sans créer une machine virtuelle supplémentaire dédiée à l'administration.

Dans notre architecture, WSL2 constitue le **Control Node** utilisé pour administrer les machines virtuelles du laboratoire.

---

## 2. Rôle de WSL2

WSL2 se situe entre le poste Windows et les machines virtuelles du laboratoire.

```text
Windows
   |
   +----------------------+
   |                      |
   v                      v
WSL2             VMware Workstation
   |                      |
   |                      +---- kube-control
   |                      |
   |                      +---- kube-worker
   |
   +---- Ansible
   +---- SSH
   +---- Git
   +---- outils Linux
```

WSL2 n'héberge pas les nœuds Kubernetes.

Les nœuds Kubernetes restent hébergés dans les machines virtuelles VMware Workstation.

---

## 3. Pourquoi utiliser WSL2 ?

L'utilisation de WSL2 présente plusieurs avantages pour ce laboratoire :

* environnement Linux natif côté utilisateur ;
* accès aux outils Linux ;
* utilisation directe d'Ansible ;
* utilisation native de SSH ;
* accès aux fichiers du projet Windows ;
* possibilité de reproduire une logique de poste d'administration Linux.

Cela permet également de séparer clairement :

```text
Infrastructure
    ↓
VMware Workstation + Vagrant

Administration
    ↓
WSL2 + Ansible + SSH

Orchestration
    ↓
Kubernetes
```

---

## 4. Prérequis Windows

Les composants Windows nécessaires à WSL2 sont activés sur le poste.

Les fonctionnalités concernées sont notamment :

* `VirtualMachinePlatform`
* `Microsoft-Windows-Subsystem-Linux`

Elles peuvent être vérifiées depuis PowerShell avec :

```powershell
Get-WindowsOptionalFeature -Online |
    Where-Object FeatureName -in @(
        "VirtualMachinePlatform",
        "Microsoft-Windows-Subsystem-Linux"
    )
```

Les deux fonctionnalités doivent être activées pour utiliser correctement WSL2.

### 4.1 Dépendance à Hyper-V

WSL2 s'exécute dans une machine virtuelle légère gérée par l'hyperviseur Hyper-V de Windows. Hyper-V doit donc être actif au démarrage du poste.

Sa présence peut être vérifiée depuis PowerShell :

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent
```

Cette commande indique si un hyperviseur est chargé par Windows.

Résultat vérifié le 8 octobre 2026 :

```text
True
```

Cette dépendance a une conséquence directe sur le laboratoire : elle détermine le choix de l'hyperviseur des machines virtuelles. Ce choix est expliqué dans `01-architecture.md`.

Si Hyper-V est désactivé, par exemple avec `bcdedit /set hypervisorlaunchtype off`, WSL2 ne démarre plus.

---

## 5. Vérification de WSL

Depuis PowerShell :

```powershell
wsl --status
```

Pour afficher les distributions installées :

```powershell
wsl --list --verbose
```

La distribution Ubuntu utilisée par le laboratoire doit apparaître avec la version :

```text
2
```

La version 2 correspond à WSL2.

---

## 6. Distribution Linux

Le laboratoire utilise actuellement :

```text
Ubuntu 24.04.5 LTS
```

La version peut être vérifiée depuis Ubuntu :

```bash
cat /etc/os-release
```

ou :

```bash
lsb_release -a
```

Résultat vérifié le 8 octobre 2026 :

```text
Ubuntu 24.04.5 LTS
Codename: noble
```

---

## 7. Utilisateur Linux

L'environnement WSL2 utilise un compte utilisateur Linux dédié.

Le compte actuel est :

```text
ajkabs
```

L'utilisateur peut être vérifié avec :

```bash
whoami
```

Les opérations nécessitant des privilèges administrateur utilisent `sudo`.

Par exemple :

```bash
sudo -v
```

---

## 8. Accès au projet Windows

WSL2 permet d'accéder aux lecteurs Windows via `/mnt`.

Le projet EshopOnContainer se trouve actuellement sur le lecteur `F:`.

Son chemin depuis WSL2 est :

```text
/mnt/f/Users/x/Documents/apprentissage/EshopOnContainer
```

Le répertoire peut être atteint avec :

```bash
cd /mnt/f/Users/x/Documents/apprentissage/EshopOnContainer
```

Cette possibilité permet de travailler sur le même dépôt depuis Windows et depuis WSL2.

---

## 9. Connectivité réseau

WSL2 doit pouvoir communiquer avec les machines virtuelles sur le réseau privé du laboratoire, défini dans `01-architecture.md`.

WSL2 ne possède pas d'interface sur ce réseau. Son trafic sort par le poste Windows, qui le transmet au réseau privé. La connectivité dépend donc de l'adresse `192.168.57.1` portée par la carte `VMnet6` du poste Windows, dont la mise en place est décrite dans `02-vagrant.md`.

```text
WSL2 (172.26.x.x)
      |
      v
Poste Windows
      |
      | VMnet6 : 192.168.57.1
      v
kube-control / kube-worker
```

La connectivité réseau a été vérifiée depuis WSL2 le 8 octobre 2026.

### Test vers le Control Plane

```bash
ping -c 3 192.168.57.10
```

Résultat attendu :

```text
3 packets transmitted, 3 received, 0% packet loss
```

### Test vers le Worker

```bash
ping -c 3 192.168.57.11
```

Résultat attendu :

```text
3 packets transmitted, 3 received, 0% packet loss
```

Ces tests valident uniquement la connectivité IP.

Ils ne valident pas encore l'accès SSH.

---

## 10. Adresse IP de WSL2

L'adresse IP de WSL2 peut être obtenue avec :

```bash
ip addr show eth0
```

ou :

```bash
hostname -I
```

L'adresse observée pendant la configuration du laboratoire était :

```text
172.26.3.27
```

Cette adresse est susceptible de changer.

Elle ne doit donc pas être considérée comme une adresse IP fixe de l'architecture.

---

## 11. SSH

SSH sera utilisé depuis WSL2 pour administrer les machines virtuelles.

Le flux prévu est :

```text
WSL2
 |
 | SSH
 |
 +----> 192.168.57.10
 |       kube-control
 |
 +----> 192.168.57.11
         kube-worker
```

La validation détaillée des clés SSH, des utilisateurs et de l'inventaire Ansible est documentée dans :

```text
05-inventory.md
```

---

## 12. Ansible

Ansible sera exécuté depuis WSL2.

Le principe est :

```text
WSL2
 |
 +---- Ansible
 |
 +---- SSH
       |
       +---- kube-control
       |
       +---- kube-worker
```

L'installation et la configuration d'Ansible sont documentées dans :

```text
04-ansible.md
```

---

## 13. Outils utilisés depuis WSL2

L'environnement de contrôle pourra notamment contenir :

| Outil   | Utilisation                   |
| ------- | ----------------------------- |
| SSH     | Administration distante       |
| Ansible | Automatisation                |
| Git     | Gestion du dépôt              |
| kubectl | Administration Kubernetes     |
| Helm    | Gestion des charts Kubernetes |

Tous ces outils ne sont pas nécessairement installés au même moment.

Ils seront ajoutés au fur et à mesure de la construction du laboratoire.

---

## 14. Principe de séparation

WSL2 n'est pas un nœud Kubernetes.

Il joue le rôle de poste de contrôle :

```text
                WSL2
          Control Environment
                 |
        +--------+--------+
        |                 |
       SSH             Ansible
        |                 |
        +--------+--------+
                 |
        +--------+--------+
        |                 |
        v                 v
 kube-control       kube-worker
 Control Plane       Worker Node
```

Cette séparation permet de reproduire un fonctionnement proche d'un environnement professionnel dans lequel l'administration des serveurs est réalisée depuis un poste ou une machine de contrôle distincte.

---

## 15. Validation

L'environnement WSL2 est considéré comme correctement préparé lorsque :

* [x] WSL2 est activé ;
* [x] Ubuntu fonctionne sous WSL2 ;
* [x] le compte Linux est opérationnel ;
* [x] le projet est accessible depuis `/mnt/f` ;
* [x] `kube-control` est joignable en réseau ;
* [x] `kube-worker` est joignable en réseau ;
* [x] SSH vers `kube-control` est validé ;
* [x] SSH vers `kube-worker` est validé ;
* [x] Ansible peut contacter les deux machines.

Les trois derniers points sont validés dans `05-inventory.md`.

---

## 16. Étape suivante

La prochaine étape consiste à installer et configurer Ansible dans WSL2.

Elle est documentée dans `04-ansible.md`.
