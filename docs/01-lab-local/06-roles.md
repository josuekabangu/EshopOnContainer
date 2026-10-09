# 06 — Organisation des rôles Ansible

## 1. Objectif

Ce document décrit l'organisation de l'automatisation Ansible du laboratoire local EshopOnContainer : les rôles, les variables, le playbook principal et la façon de les valider.

Il donne la vue d'ensemble. Le contenu détaillé de chaque rôle est décrit dans le document qui lui est consacré, indiqué en section 4.

Les rôles sont exécutés depuis le Control Node WSL2 et ciblent les machines déclarées dans l'inventaire, décrit dans `05-inventory.md`.

---

## 2. Pourquoi des rôles ?

Un playbook unique contenant toutes les tâches devient vite difficile à lire, à tester et à faire évoluer. Les rôles découpent l'automatisation en unités qui ont chacune une seule responsabilité.

Le projet applique les principes suivants :

* **Séparation des responsabilités** : chaque rôle a un objectif unique.
* **Idempotence** : relancer un rôle sur un système déjà configuré ne modifie rien.
* **Lisibilité** : le playbook principal se contente d'ordonner les rôles.
* **Une seule source de vérité** : une valeur n'est déclarée qu'à un seul endroit.
* **Aucun secret dans le dépôt** : ni clé privée, ni jeton.
* **Validation progressive** : chaque rôle est validé avant d'ajouter le suivant.

---

## 3. Organisation

```text
lab-local/
└── ansible/
    ├── ansible.cfg
    ├── inventory.ini
    ├── site.yml
    ├── group_vars/
    │   ├── all.yml
    │   ├── control_plane.yml
    │   └── workers.yml
    └── roles/
        ├── common/
        │   └── tasks/main.yml
        ├── containerd/
        │   ├── handlers/main.yml
        │   ├── tasks/main.yml
        │   └── templates/10-kubernetes.toml.j2
        ├── kubernetes/
        │   ├── handlers/main.yml
        │   └── tasks/main.yml
        ├── control_plane/
        │   ├── tasks/main.yml
        │   └── templates/kubeadm-config.yaml.j2
        ├── calico/
        │   └── tasks/main.yml
        └── worker/
            └── tasks/main.yml
```

Un rôle ne contient que les répertoires dont il a besoin :

| Répertoire   | Contenu                                                   | Rôles qui l'utilisent                   |
| ------------ | --------------------------------------------------------- | --------------------------------------- |
| `tasks/`     | Tâches exécutées par le rôle                              | Tous                                    |
| `handlers/`  | Actions déclenchées seulement si une tâche a modifié quelque chose | `containerd`, `kubernetes`     |
| `templates/` | Fichiers générés à partir de variables                    | `containerd`, `control_plane`           |

---

## 4. Les six rôles

Les trois premiers rôles préparent les machines. Les trois suivants construisent le cluster.

| Rôle            | Machines ciblées | Responsabilité                                                          | Document de référence            |
| --------------- | ---------------- | ----------------------------------------------------------------------- | -------------------------------- |
| `common`        | Tous les nœuds   | Paquets de base, modules du noyau, `sysctl`, désactivation du swap      | `07-kubernetes-prerequisites.md` |
| `containerd`    | Tous les nœuds   | Installation, gel de version et configuration du runtime de conteneurs  | `08-containerd.md`               |
| `kubernetes`    | Tous les nœuds   | `kubeadm`, `kubelet`, `kubectl`, `crictl`, gel des versions, adresse du nœud | `09-kubernetes.md`          |
| `control_plane` | Control Plane    | Configuration `kubeadm`, initialisation du cluster, accès `kubectl`     | `10-control-plane.md`            |
| `calico`        | Control Plane    | Installation du plugin réseau et attente de sa disponibilité            | `11-calico.md`                   |
| `worker`        | Workers          | Jonction du nœud au cluster                                             | `12-worker.md`                   |

Le rôle `calico` cible le Control Plane, car le plugin réseau s'installe en envoyant des ressources à l'API du cluster. C'est ensuite le cluster qui le déploie sur chaque nœud.

---

## 5. Variables de groupe

Les variables sont réparties selon les machines qui en ont besoin.

| Fichier                        | Portée          | Contenu                                                                     |
| ------------------------------ | --------------- | --------------------------------------------------------------------------- |
| `group_vars/all.yml`           | Tous les nœuds  | Versions de Kubernetes, `containerd` et `crictl`, dépôt APT, adresse du nœud |
| `group_vars/control_plane.yml` | Control Plane   | Paramètres du cluster (port de l'API, plages des Pods et des Services, domaine DNS), version et emplacement de Calico |
| `group_vars/workers.yml`       | Workers         | Vide : le Worker ne nécessite aucun paramètre propre                        |

Deux variables sont calculées à partir d'une autre, afin de ne pas écrire deux fois la même information :

```yaml
node_ip: "{{ ansible_host }}"
kubernetes_release: "v{{ kubernetes_version.split('-')[0] }}"
```

La première reprend l'adresse déjà présente dans l'inventaire. La seconde déduit la version du cluster (`v1.36.5`) de la version des paquets (`1.36.5-1.1`).

---

## 6. Playbook principal

Le fichier `site.yml` ordonne les rôles en trois plays :

```yaml
---
- name: Préparer les noeuds du cluster Kubernetes
  hosts: k8s_cluster
  become: true

  roles:
    - common
    - containerd
    - kubernetes

- name: Initialiser le Control Plane
  hosts: control_plane
  become: true

  roles:
    - control_plane
    - calico

- name: Joindre les Workers au cluster
  hosts: workers
  become: true

  roles:
    - worker
```

### 6.1 Pourquoi trois plays ?

Chaque play cible un groupe de machines différent, et l'ordre des plays garantit l'ordre de construction :

```text
Play 1 : tous les nœuds     préparation des systèmes
              |
              v
Play 2 : Control Plane      création du cluster, puis du réseau
              |
              v
Play 3 : Workers            jonction à un cluster dont le réseau est prêt
```

Un play ne commence que lorsque le précédent est terminé sur toutes ses machines. Les handlers d'un play s'exécutent à la fin de celui-ci : `kubelet` est donc redémarré avec la bonne adresse avant que le cluster ne soit initialisé.

Le second play installe aussi le plugin réseau, bien que son nom ne mentionne que l'initialisation.

### 6.2 Élévation de privilèges

`become: true` fait exécuter les tâches avec les privilèges administrateur. L'élévation n'est pas activée par défaut dans `ansible.cfg` : chaque play la demande explicitement.

### 6.3 Nom des groupes

Les valeurs de `hosts` doivent correspondre exactement aux groupes de l'inventaire, casse comprise. Un nom mal orthographié ne provoque pas d'erreur : le play est simplement ignoré. Ce cas s'est produit deux fois et est décrit dans `13-troubleshooting.md` (problème 15).

---

## 7. Idempotence

Chaque rôle doit pouvoir être relancé sans effet sur un système déjà configuré. Les modules Ansible le garantissent d'eux-mêmes pour les fichiers et les paquets. Les tâches qui lancent une commande ont besoin d'une garde explicite.

| Rôle            | Action non idempotente par nature      | Garde utilisée                                              |
| --------------- | -------------------------------------- | ----------------------------------------------------------- |
| `common`        | `swapoff -a`                           | Exécutée seulement si du swap est présent                   |
| `containerd`    | Génération de `config.toml`            | Ignorée si le fichier existe                                |
| `kubernetes`    | Conversion de la clé du dépôt          | Ignorée si le fichier converti existe                       |
| `control_plane` | `kubeadm init`                         | Ignorée si `/etc/kubernetes/admin.conf` existe              |
| `calico`        | `kubectl apply`                        | Exécutée seulement si `kubectl diff` signale une différence |
| `worker`        | Création d'un jeton et `kubeadm join`  | Ignorées si `/etc/kubernetes/kubelet.conf` existe           |

---

## 8. Validation

### 8.1 Méthode

Quatre commandes, lancées séparément et dans cet ordre depuis `lab-local/ansible` :

```bash
ansible-playbook site.yml --syntax-check
```

Cette commande vérifie que le playbook et les rôles sont correctement écrits. Un avertissement doit être traité avant de poursuivre, même si la commande se termine normalement.

```bash
ansible-playbook site.yml --list-hosts
```

Cette commande affiche les machines retenues par chaque play, sans rien exécuter. Elle fait apparaître immédiatement un play qui ne cible aucune machine.

```bash
ansible-playbook site.yml
```

Cette commande applique le playbook. Aucune tâche ne doit échouer.

```bash
ansible-playbook site.yml
```

La seconde exécution vérifie l'idempotence : elle doit se terminer avec `changed=0`.

Le mode `--check` n'est pas une validation fiable sur des machines neuves. La raison est expliquée dans `13-troubleshooting.md` (problème 6).

### 8.2 Validation sur le cluster existant

Les rôles `control_plane`, `calico` et `worker` ont été écrits le 9 octobre 2026, alors que le cluster avait été construit à la main la veille.

Chaque rôle a été écrit pour reproduire exactement l'opération manuelle correspondante, puis appliqué au cluster existant. Le résultat attendu était `changed=0` : un rôle qui ne modifie rien sur un système construit à la main décrit fidèlement ce système.

Les seuls changements constatés étaient voulus : le dépôt de la configuration `kubeadm` et du fichier de définition de Calico dans `/etc/kubernetes`, et le resserrement des permissions du répertoire `~/.kube`.

### 8.3 Validation par reconstruction

La validation sur le cluster existant ne prouve pas que les rôles savent construire un cluster : leurs gardes empêchent précisément l'initialisation et la jonction de s'exécuter.

Les deux machines ont donc été détruites puis recréées, comme décrit dans `02-vagrant.md`, et le playbook a été lancé sur des systèmes neufs :

```bash
time ansible-playbook site.yml
```

La commande `time` affiche la durée totale de l'exécution.

Résultat vérifié le 9 octobre 2026 :

```text
kube-control : ok=32   changed=25   unreachable=0    failed=0    skipped=0
kube-worker  : ok=27   changed=21   unreachable=0    failed=0    skipped=0

real    2m30.939s
```

Le cluster complet a été construit en 2 minutes 31, sans intervention manuelle et sans échec.

Seconde exécution :

```text
kube-control : ok=28   changed=0    unreachable=0    failed=0    skipped=2
kube-worker  : ok=22   changed=0    unreachable=0    failed=0    skipped=3
```

Les tâches ignorées sont les gardes de la section 7 : la désactivation du swap sur les deux nœuds, l'application de Calico sur le Control Plane, la création du jeton et la jonction sur le Worker.

L'état du cluster obtenu est vérifié dans `10-control-plane.md`, `11-calico.md` et `12-worker.md`.

Les machines ont été recréées une seconde fois le même jour, et le playbook rejoué. Le résultat a été identique :

```text
kube-control : ok=32   changed=25   unreachable=0    failed=0    skipped=0
kube-worker  : ok=27   changed=21   unreachable=0    failed=0    skipped=0
```

Depuis ces deux reconstructions, une tâche a été ajoutée au rôle `containerd` pour figer sa version. Une exécution sur un cluster déjà construit se termine désormais avec `ok=29` sur `kube-control` et `ok=23` sur `kube-worker`, toujours avec `changed=0`.

Deux reconstructions successives donnant le même résultat confirment que la construction est reproductible. Les tests fonctionnels du réseau, décrits dans `12-worker.md` (section 7), ont été rejoués avec succès sur ce second cluster.

---

## 9. État et limites

### 9.1 État validé

| Rôle            | État au 9 octobre 2026                                  |
| --------------- | ------------------------------------------------------- |
| `common`        | Appliqué, idempotent, validé par reconstruction         |
| `containerd`    | Appliqué, idempotent, validé par reconstruction         |
| `kubernetes`    | Appliqué, idempotent, validé par reconstruction         |
| `control_plane` | Appliqué, idempotent, validé par reconstruction         |
| `calico`        | Appliqué, idempotent, validé par reconstruction         |
| `worker`        | Appliqué, idempotent, validé par reconstruction         |

### 9.2 Limites connues

| Limite                                                                               | Conséquence                                                          |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| La création des machines reste une étape séparée, lancée depuis PowerShell           | La reconstruction complète demande trois commandes, dans deux terminaux, listées dans `02-vagrant.md` |
| Les accès SSH doivent être remis en place dans WSL2 après chaque recréation des machines | Un script s'en charge, décrit dans `05-inventory.md` (section 11.2) |
| Le rôle `worker` ne gère pas le retrait d'un nœud                                    | Un nœud à retirer doit l'être à la main                              |
| Les tests fonctionnels du réseau ne font pas partie du playbook                      | Ils sont lancés à la main depuis un fichier du dépôt, comme décrit dans `12-worker.md` (section 7) |

---

## 10. Documentation associée

| Fichier                          | Responsabilité                              |
| -------------------------------- | ------------------------------------------- |
| `04-ansible.md`                  | Installation et configuration d'Ansible     |
| `05-inventory.md`                | Inventaire et accès SSH                     |
| `07-kubernetes-prerequisites.md` | Rôle `common`                               |
| `08-containerd.md`               | Rôle `containerd`                           |
| `09-kubernetes.md`               | Rôle `kubernetes`                           |
| `10-control-plane.md`            | Rôle `control_plane`                        |
| `11-calico.md`                   | Rôle `calico`                               |
| `12-worker.md`                   | Rôle `worker`                               |
| `13-troubleshooting.md`          | Diagnostic des problèmes                    |

---

## 11. Étape suivante

La prochaine étape consiste à préparer les systèmes avec le rôle `common`.

Elle est documentée dans `07-kubernetes-prerequisites.md`.
