# 05 — Inventaire Ansible et accès SSH

## 1. Objectif

Ce document présente la configuration de l'inventaire Ansible et la mise en place de l'accès SSH aux machines virtuelles du laboratoire EshopOnContainer.

L'objectif est de permettre au Control Node WSL2 de communiquer avec :

* `kube-control` ;
* `kube-worker`.

La communication utilisée par Ansible repose sur SSH.

---

## 2. Architecture

Le flux d'administration est le suivant :

```text
                     WSL2
                Control Node
                     |
                     |
                    SSH
                     |
          +----------+----------+
          |                     |
          v                     v
   kube-control           kube-worker
   192.168.57.10          192.168.57.11
```

WSL2 doit donc être capable :

1. de joindre les adresses IP ;
2. d'établir une connexion TCP vers SSH ;
3. de s'authentifier ;
4. de permettre ensuite à Ansible d'exécuter ses modules.

---

## 3. Inventaire Ansible

L'inventaire décrit les machines gérées par Ansible.

Le fichier utilisé par le projet est :

```text
lab-local/ansible/inventory.ini
```

L'inventaire est organisé en groupes correspondant aux rôles des machines.

```text
control_plane
    |
    +---- kube-control

workers
    |
    +---- kube-worker

k8s_cluster
    |
    +---- control_plane
    +---- workers
```

---

## 4. Groupes

### `control_plane`

Ce groupe contient les machines qui hébergent les composants du Control Plane Kubernetes.

Actuellement :

```text
kube-control
```

### `workers`

Ce groupe contient les nœuds destinés à exécuter les workloads Kubernetes.

Actuellement :

```text
kube-worker
```

### `k8s_cluster`

Ce groupe parent représente l'ensemble des nœuds Kubernetes.

Il regroupe :

```text
control_plane
workers
```

Cette organisation permet d'appliquer certaines tâches uniquement au Control Plane, uniquement aux Workers ou à l'ensemble du cluster. Le playbook du laboratoire s'en sert pour ses trois plays, comme décrit dans `06-roles.md`.

---

## 5. Structure de l'inventaire

La structure est la suivante :

```ini
[control_plane]
kube-control ...

[workers]
kube-worker ...

[k8s_cluster:children]
control_plane
workers
```

Les paramètres de connexion sont associés à chaque machine.

---

## 6. Adresse IP utilisée

Les connexions Ansible utilisent les adresses IP privées du laboratoire :

```text
kube-control → 192.168.57.10
kube-worker  → 192.168.57.11
```

Il est important de distinguer ces adresses des ports SSH redirigés par Vagrant.

### Adresse privée

```text
192.168.57.10
192.168.57.11
```

Ces adresses permettent à WSL2 de joindre directement les VMs sur le réseau du laboratoire.

### SSH Vagrant avec port redirigé

Vagrant peut également exposer SSH sur le localhost Windows avec des ports tels que :

```text
127.0.0.1:2222
127.0.0.1:2200
```

Ces ports sont attribués par Vagrant et peuvent changer d'une création à l'autre. Ils sont principalement utiles à Vagrant.

Dans notre architecture, Ansible utilise les adresses privées.

---

## 7. Utilisateur SSH

Les machines Vagrant utilisent l'utilisateur :

```text
vagrant
```

Ansible utilise donc :

```ini
ansible_user=vagrant
```

Cette information est définie dans l'inventaire, pour chaque machine.

---

## 8. Clés SSH Vagrant

Vagrant génère une clé privée SSH associée à chaque machine.

Les clés sont stockées dans le répertoire `.vagrant` de la machine concernée.

Exemple :

```text
.vagrant/
└── machines/
    └── kube-control/
        └── vmware_desktop/
            └── private_key
```

et :

```text
.vagrant/
└── machines/
    └── kube-worker/
        └── vmware_desktop/
            └── private_key
```

Le répertoire intermédiaire porte le nom du provider Vagrant utilisé. Il s'agit de `vmware_desktop` depuis la migration décrite dans `01-architecture.md`.

Ces clés sont des informations sensibles.

Elles ne doivent pas être versionnées dans Git.

---

## 9. Pourquoi copier les clés dans WSL ?

Le projet est stocké sur un lecteur Windows monté dans WSL via `/mnt/f`.

Or les permissions Linux appliquées aux fichiers présents sur un montage Windows peuvent être différentes de celles attendues par SSH.

SSH peut refuser une clé privée dont les permissions sont considérées comme trop permissives.

Pour éviter ce problème, les clés utilisées par SSH peuvent être copiées dans le système de fichiers Linux de WSL2.

Répertoire retenu :

```text
~/.ssh/vagrant/
```

---

## 10. Préparation du répertoire SSH

Depuis WSL2 :

```bash
mkdir -p ~/.ssh/vagrant
```

Puis :

```bash
chmod 700 ~/.ssh
chmod 700 ~/.ssh/vagrant
```

---

## 11. Copie des clés

Depuis le répertoire :

```bash
cd /chemin/absolu/vers/EshopOnContainer/lab-local/ansible
```

les clés Vagrant peuvent être copiées avec :

```bash
cp ../vagrant/.vagrant/machines/kube-control/vmware_desktop/private_key \
   ~/.ssh/vagrant/kube-control
```

et :

```bash
cp ../vagrant/.vagrant/machines/kube-worker/vmware_desktop/private_key \
   ~/.ssh/vagrant/kube-worker
```

Les permissions doivent ensuite être limitées :

```bash
chmod 600 ~/.ssh/vagrant/kube-control
chmod 600 ~/.ssh/vagrant/kube-worker
```

### 11.1 Après chaque recréation des machines

Vagrant génère une nouvelle paire de clés chaque fois qu'une machine est créée. Après un `vagrant destroy` suivi d'un `vagrant up`, les clés copiées dans WSL2 ne correspondent donc plus aux machines.

Deux opérations sont alors nécessaires.

**Recopier les clés**, avec les commandes `cp` et `chmod` ci-dessus.

**Effacer les anciennes empreintes d'hôte**, car l'identité SSH des machines change elle aussi :

```bash
ssh-keygen -R 192.168.57.10
ssh-keygen -R 192.168.57.11
```

Cette commande supprime du fichier `~/.ssh/known_hosts` l'empreinte enregistrée pour l'adresse indiquée.

**Enregistrer les nouvelles empreintes** :

```bash
ssh-keyscan -H 192.168.57.10 192.168.57.11 >> ~/.ssh/known_hosts
```

Cette commande interroge les deux machines, récupère leur empreinte d'hôte et l'ajoute au fichier `~/.ssh/known_hosts`. L'option `-H` enregistre les adresses sous forme masquée, comme le fait SSH par défaut.

Sans cette étape, SSH demande de confirmer chaque nouvelle empreinte à la première connexion. Comme `host_key_checking` est activé dans `ansible.cfg`, la question apparaît alors au milieu de l'exécution d'Ansible, une fois par machine :

```text
The authenticity of host '192.168.57.11 (192.168.57.11)' can't be established.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Cette situation s'est produite le 8 octobre 2026 lors de la reconstruction des machines sous VMware Workstation. Elle est décrite dans `13-troubleshooting.md` (problème 5).

Enregistrer les empreintes de cette façon revient à faire confiance aux machines telles qu'elles se présentent à cet instant. C'est acceptable pour des machines locales que l'on vient de créer soi-même. Sur un réseau non maîtrisé, l'empreinte devrait être vérifiée par un autre canal.

La procédure complète, avec enregistrement préalable des empreintes, a été appliquée le 9 octobre 2026 : `ansible all -m ping` a répondu `pong` sur les deux machines et le playbook s'est exécuté sans aucune question.

### 11.2 Script de remise en place des accès

#### Pourquoi un script ?

Les opérations de la section 11.1 doivent être refaites à l'identique après chaque recréation des machines. Elles sont faciles à oublier ou à exécuter dans le désordre. Un script les regroupe en une seule commande.

Le script se trouve dans :

```text
lab-local/scripts/setup-ssh.sh
```

#### Ce qu'il fait

| Étape | Action                                                                                  |
| ----- | --------------------------------------------------------------------------------------- |
| 1     | Vérifie la présence des outils et lit la liste des machines dans `inventory.ini`        |
| 2     | Copie chaque clé générée par Vagrant vers le chemin déclaré dans l'inventaire, en mode `600` |
| 3     | Attend, jusqu'à 60 secondes, que le port 22 de chaque machine réponde                   |
| 4     | Supprime l'ancienne empreinte de chaque machine et enregistre la nouvelle               |
| 5     | Se connecte à chaque machine et vérifie que le nom d'hôte renvoyé est celui attendu     |

Le script s'arrête à la première anomalie, avec un message qui indique quoi vérifier.

#### Principes retenus

* **Une seule source de vérité.** Le script ne contient ni nom de machine, ni adresse, ni chemin de clé. Il lit ces informations dans `inventory.ini` : `ansible_host`, `ansible_user` et `ansible_ssh_private_key_file`. Ajouter une machine à l'inventaire suffit pour qu'il la prenne en compte.
* **Les mêmes chemins qu'Ansible.** Le script dépose chaque clé à l'emplacement exact où l'inventaire la déclare. Comme l'inventaire utilise `~`, et que `bash` ne remplace pas un `~` contenu dans une variable, le script le remplace lui-même par le répertoire personnel, dans sa fonction `inventory_key`. Sans cela, il créerait un répertoire nommé littéralement `~`.
* **Aucun appel à Vagrant.** Le script lit les clés que Vagrant a produites, mais ne lance aucune commande `vagrant`. Les machines sont créées au préalable depuis PowerShell, comme décrit dans `02-vagrant.md`. Cette séparation évite l'incident décrit dans `13-troubleshooting.md` (problème 12).
* **Les adresses du réseau privé.** Le script teste les machines sur leurs adresses `192.168.57.x`, celles qu'utilise Ansible, et non sur les ports redirigés par Vagrant.
* **Vérifier l'identité de la machine.** La comparaison du nom d'hôte détecterait une machine qui répondrait à la place d'une autre sur la même adresse.

#### Utilisation

Depuis WSL2, à la racine du projet, après la création des machines :

```bash
bash lab-local/scripts/setup-ssh.sh
```

Cette commande exécute le script avec `bash`. Le script ne modifie rien sur les machines : il n'agit que sur le répertoire `~/.ssh` du poste de contrôle.

Résultat vérifié le 9 octobre 2026. Le nom du compte y est remplacé par `<utilisateur>` :

```text
=== 1. Vérification des prérequis ===
Machines de l'inventaire : kube-control kube-worker

=== 2. Copie des clés privées ===
Clé copiée : kube-control -> /home/<utilisateur>/.ssh/vagrant/kube-control
Clé copiée : kube-worker -> /home/<utilisateur>/.ssh/vagrant/kube-worker

=== 3. Attente du service SSH ===
Port 22 ouvert : kube-control (192.168.57.10)
Port 22 ouvert : kube-worker (192.168.57.11)

=== 4. Renouvellement des empreintes ===
Empreinte enregistrée : kube-control (192.168.57.10)
Empreinte enregistrée : kube-worker (192.168.57.11)

=== 5. Vérification des connexions SSH ===
Connexion SSH OK : kube-control (192.168.57.10)
Connexion SSH OK : kube-worker (192.168.57.11)
```

La commande `ansible all -m ping`, lancée ensuite, a répondu `pong` sur les deux machines.

Cette première validation a été faite sur des machines dont les accès étaient déjà en place.

Le script a ensuite été éprouvé dans le cas pour lequel il est prévu : le 9 octobre 2026, les deux machines ont été recréées, puis le script a été lancé. Les cinq étapes ont réussi, `ansible all -m ping` a répondu `pong` sur les deux machines, et le playbook a reconstruit le cluster sans qu'aucune question ne soit posée sur l'authenticité des machines.

#### Fins de ligne

Un script shell doit utiliser des fins de ligne de type LF. Avec des fins de ligne Windows (CRLF), `bash` refuse de l'exécuter.

Le dépôt est utilisé sous Windows, où Git peut convertir les fins de ligne lors d'un clone. Le fichier `.gitattributes`, à la racine du projet, impose le format LF aux scripts :

```text
*.sh text eol=lf
```

L'application de cette règle se vérifie avec :

```bash
git check-attr text eol -- lab-local/scripts/setup-ssh.sh
```

Cette commande affiche les attributs que Git applique au fichier indiqué.

Résultat vérifié :

```text
lab-local/scripts/setup-ssh.sh: text: set
lab-local/scripts/setup-ssh.sh: eol: lf
```

---

## 12. Vérification des permissions

Les permissions peuvent être contrôlées avec :

```bash
ls -la ~/.ssh/vagrant/
```

Les clés privées doivent être accessibles uniquement par l'utilisateur courant.

Une configuration typique est :

```text
-rw------- kube-control
-rw------- kube-worker
```

---

## 13. Test SSH direct

Avant d'utiliser Ansible, il est important de tester SSH directement.

Cette étape permet de séparer deux problèmes différents :

```text
SSH fonctionne ?
       |
       +---- NON → problème réseau/authentification/clé
       |
       +---- OUI → problème éventuel de configuration Ansible
```

### Test du Control Plane

```bash
ssh -i ~/.ssh/vagrant/kube-control \
    vagrant@192.168.57.10
```

### Test du Worker

```bash
ssh -i ~/.ssh/vagrant/kube-worker \
    vagrant@192.168.57.11
```

Lors de la première connexion, SSH peut demander de confirmer l'empreinte de la machine.

Après connexion, vérifier :

```bash
hostname
```

Le résultat attendu est respectivement :

```text
kube-control
```

ou :

```text
kube-worker
```

Quitter ensuite la session :

```bash
exit
```

---

## 14. Vérification de la connectivité SSH

Une fois les tests directs réalisés, la chaîne suivante est validée :

```text
WSL2
 |
 | réseau IP
 v
192.168.57.x
 |
 | TCP/22
 v
SSH
 |
 | clé privée
 v
vagrant
 |
 v
VM
```

Il s'agit d'une validation plus complète que le simple `ping`.

---

## 15. Inventaire initial

Le fichier `inventory.ini` du projet contient :

```ini
[control_plane]
kube-control ansible_host=192.168.57.10 ansible_user=vagrant ansible_ssh_private_key_file=~/.ssh/vagrant/kube-control

[workers]
kube-worker ansible_host=192.168.57.11 ansible_user=vagrant ansible_ssh_private_key_file=~/.ssh/vagrant/kube-worker

[k8s_cluster:children]
control_plane
workers
```

Cette configuration permet à Ansible de connaître :

* le nom logique de la machine ;
* son adresse IP ;
* l'utilisateur SSH ;
* la clé privée à utiliser.

### Portabilité du chemin des clés

Le chemin de chaque clé commence par `~`, qui désigne le répertoire personnel de l'utilisateur qui lance Ansible. L'inventaire ne contient ainsi aucun nom de compte et fonctionne tel quel sur un autre poste.

L'inventaire a d'abord contenu un chemin absolu, de la forme `/home/<utilisateur>/.ssh/vagrant/kube-control`. Il ne fonctionnait que pour ce compte. Il a été remplacé le 10 octobre 2026.

Ansible remplace lui-même le `~` par le répertoire personnel. La valeur lue dans l'inventaire se vérifie avec :

```bash
ansible all -m debug -a "var=ansible_ssh_private_key_file"
```

Le module `debug` affiche la valeur d'une variable pour chaque machine, sans rien modifier.

Résultat vérifié le 10 octobre 2026 :

```text
kube-control | SUCCESS => {
    "ansible_ssh_private_key_file": "~/.ssh/vagrant/kube-control"
}
kube-worker | SUCCESS => {
    "ansible_ssh_private_key_file": "~/.ssh/vagrant/kube-worker"
}
```

La commande `ansible all -m ping` a ensuite répondu `pong` sur les deux machines : Ansible retrouve bien les clés à partir de ce chemin.

---

## 16. Vérification de l'inventaire

Avant de contacter les machines, il est recommandé de vérifier que l'inventaire est correctement interprété.

Afficher la structure :

```bash
ansible-inventory -i inventory.ini --graph
```

Résultat vérifié le 8 octobre 2026 :

```text
@all:
  |--@ungrouped:
  |--@k8s_cluster:
  |  |--@control_plane:
  |  |  |--kube-control
  |  |--@workers:
  |  |  |--kube-worker
```

Il s'agit d'une **validation syntaxique** : elle confirme qu'Ansible interprète correctement le fichier, sans contacter les machines.

L'option `-i inventory.ini` est facultative lorsque le fichier `ansible.cfg` du projet est chargé, car il désigne déjà l'inventaire. Les conditions de ce chargement sont décrites dans `04-ansible.md`.

Pour afficher les variables :

```bash
ansible-inventory -i inventory.ini --list
```

Cette commande permet notamment de vérifier les adresses et paramètres SSH.

---

## 17. Test Ansible Ping

Lorsque SSH fonctionne directement, Ansible peut être testé.

Depuis :

```text
lab-local/ansible
```

exécuter :

```bash
ansible all -i inventory.ini -m ping
```

Le module `ping` Ansible ne correspond pas au programme réseau `ping`.

Il vérifie principalement :

* que la machine est joignable ;
* que l'authentification fonctionne ;
* qu'Ansible peut exécuter un module ;
* que Python est disponible sur la machine distante.

Résultat vérifié le 8 octobre 2026 :

```text
kube-control | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python3"
    },
    "changed": false,
    "ping": "pong"
}
kube-worker | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python3"
    },
    "changed": false,
    "ping": "pong"
}
```

Il s'agit d'une **validation fonctionnelle** : Ansible s'est réellement connecté aux deux machines et y a exécuté un module.

---

## 18. Différence entre `ping` réseau et `ansible ping`

Il est important de ne pas confondre les deux.

### ICMP

```bash
ping 192.168.57.10
```

Teste principalement :

```text
Connectivité IP
```

### Ansible

```bash
ansible all -i inventory.ini -m ping
```

Teste une chaîne beaucoup plus complète :

```text
WSL2
 ↓
Réseau
 ↓
SSH
 ↓
Authentification
 ↓
Python distant
 ↓
Module Ansible
```

Cette distinction est importante lors du diagnostic.

---

## 19. Sécurité

Les clés privées SSH ne doivent jamais être ajoutées au dépôt Git.

Le répertoire suivant doit notamment rester hors du dépôt :

```text
~/.ssh/vagrant/
```

Les fichiers `.vagrant/` ne doivent également pas être versionnés.

Le fichier `.gitignore` du projet les exclut.

Extrait :

```gitignore
.vagrant/
*.retry
```

Aucun secret ne doit être stocké en clair dans l'inventaire.

---

## 20. Évolution de l'inventaire

Les variables de configuration des rôles ne sont pas placées dans l'inventaire. Elles se trouvent dans :

```text
group_vars/
```

Par exemple :

```text
group_vars/
├── all.yml
├── control_plane.yml
└── workers.yml
```

Cela évite de surcharger l'inventaire avec des variables de configuration. Le contenu de ces fichiers est décrit dans `06-roles.md`.

L'inventaire conserve la description des machines et leur organisation logique.

---

## 21. État de validation

### Réseau

* [x] WSL2 → `192.168.57.10`
* [x] WSL2 → `192.168.57.11`

### SSH

* [x] Clé `kube-control` préparée dans WSL2
* [x] SSH vers `kube-control` validé
* [x] Clé `kube-worker` préparée dans WSL2
* [x] SSH vers `kube-worker` validé

### Ansible

* [x] Inventaire créé
* [x] Inventaire validé avec `ansible-inventory`
* [x] `ansible all -m ping` réussi

Ces éléments ont été vérifiés le 8 octobre 2026, après la reconstruction des machines sous VMware Workstation.

L'accès SSH a été validé à travers Ansible : le module `ping` ne réussit que si la connexion SSH et l'authentification par clé fonctionnent.

---

## 22. Résumé

L'inventaire permet de transformer les machines virtuelles en cibles administrables par Ansible.

L'architecture retenue est :

```text
                  WSL2
                   |
                Ansible
                   |
                 SSH
                   |
       +-----------+-----------+
       |                       |
       v                       v
kube-control             kube-worker
192.168.57.10            192.168.57.11
   vagrant                   vagrant
       |                       |
       +-----------+-----------+
                   |
             Kubernetes
```

---

## 23. Étape suivante

La prochaine étape consiste à organiser l'automatisation en rôles Ansible.

Elle est documentée dans `06-roles.md`.
