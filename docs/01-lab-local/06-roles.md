# 06 — Organisation des rôles Ansible

## 1. Objectif

Ce document définit l'organisation des rôles Ansible du laboratoire local EshopOnContainer.

L'objectif est de séparer les responsabilités de configuration, de faciliter la maintenance et de permettre la réutilisation des tâches.

Les rôles seront exécutés depuis le Control Node WSL2 et cibleront les machines déclarées dans l'inventaire Ansible.

## 2. Principes d'organisation

Le projet applique les principes suivants :

* **Séparation des responsabilités** : chaque rôle possède un objectif clairement défini.
* **Réutilisabilité** : un rôle peut être appliqué à plusieurs machines.
* **Idempotence** : les tâches doivent converger vers l'état souhaité sans effectuer de modifications inutiles lors des exécutions suivantes.
* **Lisibilité** : les playbooks orchestrent les rôles sans concentrer toute la logique dans un fichier unique.
* **Sécurité** : les secrets et les clés privées ne sont pas versionnés dans le dépôt.
* **Validation progressive** : chaque rôle est testé avant d'ajouter le suivant.

## 3. Architecture cible

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
        ├── containerd/
        └── kubernetes/
```

Cette architecture sera mise en place progressivement. Les fichiers ne seront créés que lorsque leur rôle dans l'automatisation aura été défini.

## 4. Rôle `common`

Le rôle `common` prépare les systèmes Linux de manière commune.

Responsabilités prévues :

* installation des dépendances système nécessaires ;
* configuration des modules du noyau Linux requis ;
* configuration des paramètres réseau avec `sysctl` ;
* désactivation du swap conformément aux prérequis Kubernetes retenus ;
* vérification des paramètres système nécessaires au fonctionnement du cluster.

Ce rôle sera appliqué à l'ensemble des nœuds Kubernetes.

## 5. Rôle `containerd`

Le rôle `containerd` installe et configure le runtime de conteneurs.

Responsabilités prévues :

* installation du paquet containerd depuis une source définie ;
* génération ou gestion du fichier de configuration ;
* configuration du gestionnaire de groupes de contrôle selon les versions retenues ;
* activation et démarrage du service ;
* validation de l'état du service.

Le rôle devra utiliser des tâches idempotentes et des handlers lorsque le redémarrage d'un service est nécessaire après une modification.

## 6. Rôle `kubernetes`

Le rôle `kubernetes` installe les composants nécessaires aux nœuds Kubernetes.

Responsabilités prévues :

* configuration de la source officielle des paquets adaptée à la version retenue ;
* gestion de la clé de signature selon les recommandations de la source ;
* installation de `kubeadm`, `kubelet` et, lorsque nécessaire, `kubectl` ;
* gel des versions installées, pour qu'une mise à jour du système ne les modifie pas ;
* vérification des versions installées.

L'installation des composants ne constitue pas l'initialisation du cluster.

Les opérations `kubeadm init` et `kubeadm join` seront documentées et exécutées dans des étapes distinctes.

## 7. Structure interne d'un rôle

Un rôle peut contenir les répertoires suivants :

```text
roles/<nom_du_role>/
├── defaults/
│   └── main.yml
├── handlers/
│   └── main.yml
├── tasks/
│   └── main.yml
├── templates/
├── files/
├── vars/
│   └── main.yml
├── meta/
│   └── main.yml
└── README.md
```

Tous ces répertoires ne sont pas obligatoires. Ils seront ajoutés lorsque leur utilisation sera justifiée.

* `tasks/` : tâches exécutées par le rôle.
* `handlers/` : actions déclenchées par notification, par exemple un redémarrage de service.
* `defaults/` : variables par défaut pouvant être surchargées.
* `vars/` : variables internes au rôle, généralement de priorité supérieure.
* `templates/` : modèles Jinja2.
* `files/` : fichiers statiques.
* `meta/` : métadonnées et dépendances.
* `README.md` : documentation du rôle.

## 8. Variables de groupe

Les variables seront organisées dans `group_vars/`.

* `all.yml` : paramètres communs à tous les nœuds.
* `control_plane.yml` : paramètres propres au groupe `control_plane`.
* `workers.yml` : paramètres propres au groupe `workers`.

Les variables seront définies à un seul endroit lorsque cela est possible, afin d'éviter les incohérences entre les rôles.

Les secrets ne seront pas stockés en clair dans ces fichiers.

## 9. Playbook principal

Le fichier `site.yml` orchestre l'application des rôles.

Exemple conceptuel :

```yaml
---
- name: Préparer tous les nœuds Kubernetes
  hosts: k8s_cluster
  become: true
  roles:
    - common
    - containerd
    - kubernetes
```

Cet exemple illustre l'organisation cible. Il ne doit être exécuté qu'après la création et la validation des rôles, des variables et des prérequis nécessaires.

## 10. Ordre de mise en œuvre

Les rôles seront développés dans l'ordre suivant :

1. `common` : préparation du système.
2. `containerd` : installation et configuration du runtime.
3. `kubernetes` : installation des composants Kubernetes.

L'initialisation du Control Plane, l'installation du CNI et la jonction du Worker seront traitées séparément.

## 11. Validation

Chaque rôle devra être vérifié avant de passer au suivant.

Les validations comprendront notamment :

* la syntaxe YAML ;
* la syntaxe des playbooks ;
* la connexion aux hôtes ciblés ;
* l'exécution des tâches ;
* l'état réel des systèmes après exécution ;
* la relance du rôle pour vérifier son idempotence.

## 12. Documentation associée

| Fichier                          | Responsabilité                              |
| -------------------------------- | ------------------------------------------- |
| `04-ansible.md`                  | Installation et configuration d'Ansible     |
| `05-inventory.md`                | Inventaire et accès SSH                     |
| `06-roles.md`                    | Organisation des rôles Ansible              |
| `07-kubernetes-prerequisites.md` | Préparation des systèmes                    |
| `08-containerd.md`               | Installation et configuration de containerd |
| `09-kubernetes.md`               | Installation des composants Kubernetes      |
| `10-control-plane.md`            | Initialisation du Control Plane             |
| `11-calico.md`                   | Installation du CNI Calico                  |
| `12-worker.md`                   | Jonction du Worker                          |
| `13-troubleshooting.md`          | Diagnostic des problèmes                    |

## 13. État de mise en œuvre

Les trois rôles sont écrits et appliqués aux deux nœuds. Leur validation est détaillée dans le document propre à chaque rôle.

| Rôle         | Document de référence            | État au 8 octobre 2026 |
| ------------ | -------------------------------- | ---------------------- |
| `common`     | `07-kubernetes-prerequisites.md` | Appliqué et validé     |
| `containerd` | `08-containerd.md`               | Appliqué et validé     |
| `kubernetes` | `09-kubernetes.md`               | Appliqué et validé     |

## 14. Conclusion

L'organisation par rôles permet de séparer la préparation du système, l'installation du runtime et l'installation des composants Kubernetes.

Cette structure facilite les tests, la maintenance, la réutilisation et l'évolution du laboratoire.

## 15. Étape suivante

La prochaine étape consiste à préparer les systèmes avec le rôle `common`.

Elle est documentée dans `07-kubernetes-prerequisites.md`.
