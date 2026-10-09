# 08 — Containerd

## 1. Objectif

Ce document décrit l'installation et la configuration du runtime de conteneurs `containerd` sur les nœuds du laboratoire Kubernetes EshopOnContainer.

Cette étape intervient après la préparation système réalisée par le rôle Ansible `common`.

L'objectif est de fournir aux nœuds Kubernetes un runtime de conteneurs fonctionnel et correctement configuré pour être utilisé par `kubelet` via l'interface CRI.

La configuration est automatisée avec Ansible à travers le rôle :

```text
lab-local/
└── ansible/
    └── roles/
        └── containerd/
```

---

## 2. Pourquoi containerd ?

Kubernetes nécessite un runtime capable d'exécuter les conteneurs.

Dans notre architecture, `containerd` est utilisé comme runtime de conteneurs sur les nœuds du cluster.

L'architecture est la suivante :

```text
Kubernetes
    │
    └── kubelet
          │
          └── CRI
                │
                └── containerd
                      │
                      └── runc
                            │
                            └── conteneurs
```

### Rôle de chaque composant

* **kubelet** : agent Kubernetes présent sur chaque nœud ;
* **CRI** : interface permettant à kubelet de communiquer avec le runtime ;
* **containerd** : runtime chargé de gérer le cycle de vie des conteneurs et des images ;
* **runc** : runtime OCI utilisé par containerd pour créer et exécuter les conteneurs.

Cette séparation permet de distinguer les responsabilités entre l'orchestrateur Kubernetes et le runtime chargé de l'exécution des conteneurs.

---

## 3. Périmètre

La configuration concerne actuellement les deux nœuds du laboratoire :

| Nœud           | Rôle          |
| -------------- | ------------- |
| `kube-control` | Control Plane |
| `kube-worker`  | Worker        |

Le système et l'architecture des machines sont indiqués dans `07-kubernetes-prerequisites.md`.

La version de `containerd` retenue pour ce laboratoire est :

```text
2.2.1
```

Cette version correspond au paquet Ubuntu utilisé sur nos machines :

```text
containerd=2.2.1-0ubuntu1~22.04.2
```

La version est définie dans les variables Ansible globales :

```yaml
kubernetes_minor_version: "1.36"
containerd_version: "2.2.1"
```

---

## 4. Organisation du rôle Ansible

Le rôle `containerd` est organisé selon la structure suivante :

```text
lab-local/
└── ansible/
    └── roles/
        └── containerd/
            ├── handlers/
            │   └── main.yml
            ├── tasks/
            │   └── main.yml
            └── templates/
                └── 10-kubernetes.toml.j2
```

Chaque répertoire possède une responsabilité précise.

### `tasks/`

Contient les tâches permettant :

* d'installer `containerd` ;
* de figer sa version ;
* de créer les répertoires nécessaires ;
* de générer la configuration principale ;
* de déployer la configuration spécifique à Kubernetes.

### `templates/`

Contient le fragment de configuration spécifique à Kubernetes :

```text
10-kubernetes.toml.j2
```

### `handlers/`

Contient les actions déclenchées uniquement lorsqu'une configuration ayant un impact sur le service est modifiée.

Dans notre cas, le handler permet de redémarrer `containerd`.

---

## 5. Ordre d'exécution

Le rôle `containerd` est exécuté après le rôle `common`.

L'ordre global de préparation est donc :

```text
┌───────────────────────┐
│        common         │
│                       │
│ - paquets système     │
│ - modules kernel      │
│ - sysctl              │
│ - prérequis système   │
└───────────┬───────────┘
            │
            ▼
┌───────────────────────┐
│      containerd       │
│                       │
│ - installation        │
│ - configuration       │
│ - SystemdCgroup       │
│ - service             │
└───────────┬───────────┘
            │
            ▼
┌───────────────────────┐
│   Kubernetes tools    │
│                       │
│ - kubeadm             │
│ - kubelet             │
│ - kubectl             │
└───────────────────────┘
```

Cette organisation permet de séparer clairement la préparation du système, la configuration du runtime et l'installation des composants Kubernetes.

---

## 6. Installation de containerd

L'installation est réalisée avec le module Ansible `ansible.builtin.apt`.

La version est explicitement définie afin d'éviter qu'une évolution du dépôt APT ne modifie involontairement l'environnement du laboratoire.

La tâche utilisée est :

```yaml
- name: Installer containerd
  ansible.builtin.apt:
    name: "containerd={{ containerd_version }}-0ubuntu1~22.04.2"
    state: present
    update_cache: true
    cache_valid_time: 3600
```

Le rôle installe ainsi la version définie par :

```yaml
containerd_version: "2.2.1"
```

La version installée a été vérifiée sur les deux nœuds avec :

```bash
ansible k8s_cluster -m shell -a 'containerd --version'
```

Le résultat obtenu est :

```text
containerd github.com/containerd/containerd/v2 2.2.1
```

La même version est donc présente sur :

```text
kube-control
kube-worker
```

### Disponibilité du paquet sur une machine neuve

Sur une machine qui vient d'être créée, l'index APT est celui de la box et ne connaît pas encore cette version de `containerd`. L'option `update_cache: true` actualise l'index avant l'installation.

Cette actualisation n'a pas lieu en mode simulation (`--check`), ce qui fait échouer la tâche sur une machine neuve. Ce cas est décrit dans `13-troubleshooting.md` (problème 6).

### Gel de la version

#### Pourquoi figer la version ?

Installer une version précise ne suffit pas à la conserver. Une mise à jour du système (`apt upgrade`) pourrait installer une version plus récente de `containerd`, sans que personne ne l'ait décidé.

Le runtime exécute tous les conteneurs du cluster. Un changement de version non maîtrisé peut modifier son comportement ou sa configuration, sur un seul nœud à la fois si les mises à jour ne sont pas simultanées.

Les paquets Kubernetes sont figés pour la même raison, comme décrit dans `09-kubernetes.md` (section 6.1).

#### Tâche

La tâche suivante est placée juste après l'installation :

```yaml
- name: Figer la version de containerd
  ansible.builtin.dpkg_selections:
    name: containerd
    selection: hold
```

Le module `ansible.builtin.dpkg_selections` enregistre l'état `hold` pour le paquet. APT ne le met alors plus à jour automatiquement.

L'ordre des tâches compte : le paquet doit être installé avant d'être figé.

Le gel est réalisé par le rôle qui installe le paquet. Chaque rôle reste ainsi responsable de bout en bout de ce qu'il installe.

#### Vérification

```bash
ansible all -m shell -a 'apt-mark showhold'
```

Cette commande liste les paquets figés sur chaque nœud.

Résultat vérifié le 9 octobre 2026 sur les deux nœuds :

```text
containerd
cri-tools
kubeadm
kubectl
kubelet
```

Le gel ne redémarre pas le service. Son état a été contrôlé après l'application de la tâche :

```bash
ansible all -m shell -a 'systemctl is-active containerd; containerd --version'
```

Résultat vérifié sur les deux nœuds :

```text
active
containerd github.com/containerd/containerd/v2 2.2.1
```

#### Idempotence

La tâche a été ajoutée sur un cluster déjà construit. Le premier passage du playbook a modifié une seule chose sur chaque nœud, et le second plus rien :

```text
Premier passage
kube-control : ok=29   changed=1    unreachable=0    failed=0    skipped=2
kube-worker  : ok=23   changed=1    unreachable=0    failed=0    skipped=3

Second passage
kube-control : ok=29   changed=0    unreachable=0    failed=0    skipped=2
kube-worker  : ok=23   changed=0    unreachable=0    failed=0    skipped=3
```

#### Conséquence pour un changement de version

Un paquet figé ne peut plus être modifié par la tâche d'installation. Pour changer la valeur de `containerd_version`, il faudra ajouter l'option `allow_change_held_packages: true` à la tâche « Installer containerd ». La montée de version devient ainsi une décision explicite.

---

## 7. Configuration principale de containerd

Après l'installation, `containerd` doit disposer d'une configuration principale dans :

```text
/etc/containerd/config.toml
```

Cette configuration est générée à partir de la configuration par défaut fournie par `containerd`.

La tâche Ansible utilisée est :

```yaml
- name: Générer la configuration par défaut de containerd
  ansible.builtin.shell:
    cmd: containerd config default > /etc/containerd/config.toml
    creates: /etc/containerd/config.toml
  notify: Redémarrer containerd
```

### Pourquoi utiliser `creates` ?

Le paramètre :

```yaml
creates: /etc/containerd/config.toml
```

indique à Ansible de ne pas exécuter la commande si le fichier existe déjà.

Cela permet notamment de conserver le comportement idempotent du rôle.

Sans cette condition, la configuration par défaut serait régénérée à chaque exécution du playbook.

La configuration générée utilise la version de configuration attendue par `containerd 2.x` :

```toml
version = 3
```

---

## 8. Répertoire des fragments de configuration

Le rôle crée également le répertoire :

```text
/etc/containerd/conf.d/
```

La tâche utilisée est :

```yaml
- name: Créer le répertoire des fragments de configuration containerd
  ansible.builtin.file:
    path: /etc/containerd/conf.d
    state: directory
    owner: root
    group: root
    mode: '0755'
```

Ce répertoire permet de séparer la configuration spécifique à Kubernetes de la configuration principale générée par `containerd`.

L'organisation obtenue est :

```text
/etc/containerd/
├── config.toml
└── conf.d/
    └── 10-kubernetes.toml
```

Cette organisation facilite la maintenance de la configuration.

---

## 9. Import des fragments

La configuration principale générée par `containerd` contient :

```toml
imports = ['/etc/containerd/conf.d/*.toml']
```

Cette directive indique à `containerd` de charger les fichiers correspondant au motif :

```text
/etc/containerd/conf.d/*.toml
```

Le fichier :

```text
/etc/containerd/conf.d/10-kubernetes.toml
```

est donc chargé automatiquement lors de la lecture de la configuration.

L'utilisation d'un fragment permet d'éviter de modifier directement la configuration principale générée par `containerd`.

---

## 10. Configuration spécifique à Kubernetes

Le rôle déploie le fichier :

```text
/etc/containerd/conf.d/10-kubernetes.toml
```

à partir du template Ansible :

```text
roles/containerd/templates/10-kubernetes.toml.j2
```

Le contenu du template est :

```toml
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
```

Cette configuration active l'utilisation de `systemd` comme gestionnaire de cgroups pour les conteneurs exécutés par `runc`.

---

## 11. Pourquoi `SystemdCgroup = true` ?

Linux utilise les cgroups pour contrôler et isoler les ressources utilisées par les processus.

Kubernetes et le runtime de conteneurs doivent utiliser une configuration cohérente pour la gestion des cgroups.

Dans notre environnement, `containerd` est donc configuré avec :

```toml
SystemdCgroup = true
```

La configuration concerne le runtime `runc` utilisé par containerd :

```text
containerd
    │
    └── CRI
          │
          └── runc
                │
                └── SystemdCgroup = true
```

Cette configuration est indispensable à `kubelet`, installé à l'étape suivante : les deux doivent utiliser le même gestionnaire de cgroups.

---

## 12. Handler de redémarrage

La modification de la configuration de `containerd` doit être suivie d'un redémarrage du service afin que la nouvelle configuration soit prise en compte.

Le rôle utilise un handler :

```text
roles/containerd/handlers/main.yml
```

avec :

```yaml
---
- name: Redémarrer containerd
  ansible.builtin.systemd_service:
    name: containerd
    state: restarted
```

Les tâches qui modifient la configuration utilisent :

```yaml
notify: Redémarrer containerd
```

Le redémarrage n'est donc effectué que lorsqu'une tâche ayant notifié le handler a réellement provoqué un changement.

Cela évite de redémarrer inutilement `containerd` lors d'une exécution idempotente.

---

## 13. Activation et état du service

Après l'installation, le service `containerd` doit être :

* activé au démarrage ;
* actuellement actif.

La vérification réalisée sur les deux nœuds est :

```bash
ansible k8s_cluster -m shell -a 'systemctl is-enabled containerd && systemctl is-active containerd'
```

Résultat obtenu :

```text
enabled
active
```

Les deux nœuds présentent donc l'état attendu :

```text
kube-control
    └── containerd : enabled / active

kube-worker
    └── containerd : enabled / active
```

---

## 14. Validation de la configuration effective

La présence du fichier de configuration ne suffit pas à vérifier que `containerd` utilise réellement la configuration Kubernetes.

La configuration effective est donc vérifiée avec :

```bash
ansible k8s_cluster -m shell -a 'containerd config dump 2>/dev/null | grep -E "SystemdCgroup|disabled_plugins|version"'
```

Le résultat attendu est :

```text
version = 3
disabled_plugins = []
SystemdCgroup = true
```

La présence de :

```text
SystemdCgroup = true
```

dans `containerd config dump` confirme que le fragment :

```text
10-kubernetes.toml
```

est effectivement pris en compte par `containerd`.

---

## 15. Problème rencontré lors de la configuration

Lors de la première configuration du rôle, le fragment :

```text
/etc/containerd/conf.d/10-kubernetes.toml
```

était bien présent sur les deux machines.

Cependant, la commande :

```bash
containerd config dump
```

retournait des résultats différents :

```text
kube-control → SystemdCgroup = true
kube-worker  → SystemdCgroup = false
```

La première hypothèse était que le fragment de configuration n'était pas correctement déployé.

Une vérification plus précise a montré que le problème était différent.

La commande utilisée était :

```bash
ansible k8s_cluster -m shell -a 'echo "=== config.toml ==="; ls -l /etc/containerd/config.toml 2>&1; echo "=== imports ==="; grep -n "^imports" /etc/containerd/config.toml 2>/dev/null || true'
```

Le résultat a montré :

```text
kube-control
    /etc/containerd/config.toml présent
    imports = ['/etc/containerd/conf.d/*.toml']

kube-worker
    /etc/containerd/config.toml absent
```

Le fichier `10-kubernetes.toml` existait donc sur le Worker, mais il n'était pas chargé car aucune configuration principale n'existait pour importer le répertoire `conf.d`.

---

## 16. Correction du problème

La tâche de génération de la configuration principale a été ajoutée au rôle :

```yaml
- name: Générer la configuration par défaut de containerd
  ansible.builtin.shell:
    cmd: containerd config default > /etc/containerd/config.toml
    creates: /etc/containerd/config.toml
  notify: Redémarrer containerd
```

Après correction, le fichier suivant est présent sur les deux nœuds :

```text
/etc/containerd/config.toml
```

et contient :

```toml
imports = ['/etc/containerd/conf.d/*.toml']
```

Le fragment Kubernetes peut donc être chargé automatiquement.

---

## 17. Validation après correction

La présence de la configuration principale a été vérifiée :

```bash
ansible k8s_cluster -m shell -a 'echo "=== config.toml ==="; ls -l /etc/containerd/config.toml; echo "=== imports ==="; grep -n "^imports" /etc/containerd/config.toml'
```

Les deux nœuds présentent :

```text
/etc/containerd/config.toml
```

avec :

```text
imports = ['/etc/containerd/conf.d/*.toml']
```

La configuration effective a ensuite été vérifiée :

```bash
ansible k8s_cluster -m shell -a 'containerd config dump 2>/dev/null | grep -E "SystemdCgroup|disabled_plugins|version"'
```

Résultat :

```text
version = 3
disabled_plugins = []
SystemdCgroup = true
```

sur les deux nœuds.

La configuration est donc effectivement chargée par `containerd`.

### Revalidation après reconstruction des machines

Les machines ont été recréées le 8 octobre 2026 lors du passage à VMware Workstation, puis le rôle a été appliqué en une seule exécution sur des systèmes neufs.

Les mêmes vérifications ont été refaites et donnent le même résultat sur les deux nœuds : `config.toml` présent, directive `imports` présente, `SystemdCgroup = true` dans la configuration effective, service `enabled` et `active`.

Le problème décrit en section 15 ne s'est pas reproduit, puisque la tâche de génération de la configuration principale fait désormais partie du rôle.

---

## 18. Idempotence du rôle

Après la correction de la configuration, le playbook a été exécuté une nouvelle fois :

```bash
ansible-playbook site.yml
```

Résultat obtenu à l'époque, lorsque le playbook ne contenait que les rôles `common` et `containerd` :

```text
kube-control : ok=9 changed=0 unreachable=0 failed=0
kube-worker  : ok=9 changed=0 unreachable=0 failed=0
```

Résultat obtenu le 8 octobre 2026 avec les trois rôles, sur les machines reconstruites :

```text
kube-control : ok=17   changed=0    unreachable=0    failed=0    skipped=1
kube-worker  : ok=17   changed=0    unreachable=0    failed=0    skipped=1
```

La tâche ignorée appartient au rôle `common` et est expliquée dans `07-kubernetes-prerequisites.md`.

Aucun changement n'est nécessaire lors d'une nouvelle exécution.

Le rôle `containerd` est donc idempotent dans l'état final obtenu.

---

## 19. État final

À l'issue de cette étape, les deux nœuds disposent d'un runtime `containerd` fonctionnel :

```text
kube-control
    ├── containerd 2.2.1 installé
    ├── version figée
    ├── service enabled
    ├── service active
    ├── /etc/containerd/config.toml
    ├── imports /etc/containerd/conf.d/*.toml
    ├── 10-kubernetes.toml
    └── SystemdCgroup = true

kube-worker
    ├── containerd 2.2.1 installé
    ├── version figée
    ├── service enabled
    ├── service active
    ├── /etc/containerd/config.toml
    ├── imports /etc/containerd/conf.d/*.toml
    ├── 10-kubernetes.toml
    └── SystemdCgroup = true
```

Le runtime de conteneurs est donc considéré comme validé.

---

## 20. Limites de cette étape

Cette étape ne réalise pas :

* l'installation de `kubeadm` ;
* l'installation de `kubelet` ;
* l'installation de `kubectl` ;
* l'initialisation du Control Plane ;
* l'installation du CNI ;
* la jonction du Worker au cluster.

Ces opérations sont réalisées dans les étapes suivantes.

### Limite connue

Le paquet `runc`, sur lequel `containerd` s'appuie pour exécuter les conteneurs, est installé automatiquement comme dépendance. Il n'est pas figé. Une mise à jour du système peut donc encore faire évoluer sa version, indépendamment de celle de `containerd`.

---

## 21. Étape suivante

La prochaine étape consiste à installer les composants Kubernetes nécessaires aux nœuds :

```text
kubeadm
kubelet
kubectl
```

Cette configuration est documentée dans :

```text
docs/01-lab-local/09-kubernetes.md
```

Le rôle Ansible correspondant est :

```text
lab-local/
└── ansible/
    └── roles/
        └── kubernetes/
```

L'initialisation du Control Plane et la jonction du Worker au cluster sont traitées séparément, dans `10-control-plane.md` et `12-worker.md`.
