# 14 — Le fournisseur de volumes : local-path-provisioner

## 1. Objectif

Le cluster construit par les guides précédents fait tourner des pods, mais ne sait pas leur fournir de stockage durable. Un pod qui écrit dans son conteneur perd ses données à sa suppression.

L'application eShop a besoin de trois composants qui conservent des données : PostgreSQL, Redis et RabbitMQ. Ils devront demander un volume au cluster, par un objet `PersistentVolumeClaim`. Encore faut-il qu'un composant du cluster sache créer ce volume : c'est le rôle d'un fournisseur de volumes, désigné par une `StorageClass`.

Ce guide installe ce fournisseur, `local-path-provisioner`, par un rôle Ansible, et vérifie qu'un volume conserve ses données.

**État au 16 octobre 2026 :** `local-path-provisioner` v0.0.37 est installé par le rôle `local_path`. La classe `local-path` est la classe de stockage par défaut. Un volume a conservé ses données après la suppression de son pod. Le rôle a été validé par une reconstruction complète du laboratoire.

## 2. Le constat de départ

kubeadm n’installe aucun fournisseur de volumes : contrairement à k3s ou aux clusters gérés des fournisseurs de cloud, un cluster construit par kubeadm n’a aucune `StorageClass`. La commande suivante le montre sur un cluster qui vient d’être construit :

```bash
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl get storageclass
```

Sans classe de stockage, une demande de volume reste indéfiniment à l’état `Pending` : rien ne crée le volume demandé.

## 3. Le choix de local-path-provisioner

`local-path-provisioner`, publié par Rancher, crée chaque volume dans un dossier du nœud qui exécute le pod. C’est le fournisseur par défaut de k3s, la distribution utilisée par la première version du projet.

Le choix entre les options disponibles, et ce qui se fait en entreprise, est expliqué dans [docs/03-kubernetes/02-stockage.md](../03-kubernetes/02-stockage.md). En résumé : avec un seul nœud de travail, aucune réplication n’est possible, et le fournisseur le plus simple ne masque rien de ce qu’il faut comprendre.

Le fichier d’installation de la version `v0.0.37`, la plus récente au 16 octobre 2026, crée :

| Objet | Rôle |
|---|---|
| Espace de noms `local-path-storage` | Contient le fournisseur |
| `ServiceAccount`, `Role`, `ClusterRole` et leurs liaisons | Droits du fournisseur sur l’API du cluster |
| `Deployment` `local-path-provisioner` | Le programme qui crée et supprime les volumes |
| `ConfigMap` `local-path-config` | Emplacement des volumes sur les nœuds : `/opt/local-path-provisioner` |
| `StorageClass` `local-path` | La classe à désigner, ou utilisée par défaut |

Deux réglages de la classe sont à connaître :

| Réglage | Valeur | Conséquence |
|---|---|---|
| `volumeBindingMode` | `WaitForFirstConsumer` | Le volume n’est créé qu’au placement du pod, sur le nœud choisi pour lui |
| `reclaimPolicy` | `Delete` | **Supprimer la demande de volume supprime les données**, sans confirmation |

Le fichier ne déclare pas `local-path` comme classe par défaut : le rôle s’en charge.

## 4. Le rôle `local_path`

### Pourquoi un rôle Ansible

`local-path-provisioner` est un composant du cluster, comme Calico, et non de l’application. Sa place est dans le laboratoire, et son installation doit survivre à une reconstruction : `rebuild.ps1 -Rebuild` recrée le cluster à partir de machines neuves, et un composant installé à la main disparaîtrait.

### Les variables

À la fin de `group_vars/control_plane.yml` :

```yaml
local_path_version: "v0.0.37"
local_path_manifest_url: "https://raw.githubusercontent.com/rancher/local-path-provisioner/{{ local_path_version }}/deploy/local-path-storage.yaml"
local_path_manifest_path: "/etc/kubernetes/local-path-storage-{{ local_path_version }}.yaml"
```

La version est figée et figure dans le nom du fichier téléchargé, comme pour Calico (guide 11).

### Les tâches

`roles/local_path/tasks/main.yml` suit la même méthode que le rôle `calico` :

| Tâche | Rôle | Idempotence |
|---|---|---|
| Télécharger le fichier de définition | Copie le fichier de la version figée sur `kube-control` | `get_url` ne retélécharge pas un fichier présent |
| Vérifier si l’espace de noms `local-path-storage` existe | Lit l’état, sans rien changer | `changed_when: false`, `failed_when: false` |
| Créer l’espace de noms | Seulement s’il est absent | `when: local_path_namespace.rc != 0` |
| Comparer le fichier avec l’état du cluster | `kubectl diff` : code 0 si identique, 1 si différent | `changed_when: false` ; échec seulement au-delà de 1 |
| Appliquer le fichier | `kubectl apply` | Seulement si la comparaison a trouvé une différence |
| Attendre que le fournisseur soit prêt | `kubectl rollout status`, jusqu’à 300 s | `changed_when: false` |
| Lire si `local-path` est la classe par défaut | Lit l’annotation `storageclass.kubernetes.io/is-default-class` | `changed_when: false` |
| Faire de `local-path` la classe par défaut | `kubectl patch`, qui ajoute l’annotation | Seulement si elle ne vaut pas déjà `true` |

Les deux tâches sur l’espace de noms ont été ajoutées après un premier échec, décrit dans le guide 13, problème 18 : `kubectl diff` ne peut pas comparer des objets placés dans un espace de noms qui n’existe pas encore.

La lecture de l’annotation utilise un chemin `jsonpath` où les points du nom de l’annotation sont protégés par une barre oblique inverse :

```yaml
    cmd: >-
      kubectl get storageclass local-path
      -o 'jsonpath={.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'
```

Sans cette protection, `jsonpath` lirait `storageclass`, puis `kubernetes`, puis `io/is-default-class` comme trois niveaux successifs.

### Un quatrième play

À la fin de `site.yml` :

```yaml
- name: Installer les composants du cluster
  hosts: control_plane
  become: true

  roles:
    - local_path
```

Le play cible le Control Plane, car l’installation passe par l’API du cluster, comme pour Calico. Mais il vient **après** la jonction du Worker : le pod du fournisseur ne peut pas tourner sur `kube-control`, réservé au Control Plane. Placé dans le deuxième play, avec Calico, il attendrait un nœud qui n’a pas encore rejoint le cluster, et la tâche `rollout status` échouerait sur des machines neuves.

## 5. Valider le rôle

Dans WSL2, depuis `lab-local/ansible` :

```bash
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml --list-hosts
ansible-playbook site.yml
ansible-playbook site.yml
```

`--list-hosts` doit afficher `kube-control` pour le quatrième play. Un nom de groupe mal écrit le ferait ignorer sans erreur (guide 13, problème 15).

Résultats vérifiés le 16 octobre 2026, sur le cluster existant :

| Passage | `kube-control` | Tâches du rôle |
|---|---|---|
| Premier | `changed=3`, `failed=0` | Espace de noms créé, fichier appliqué, classe mise par défaut |
| Second | `changed=0`, `failed=0` | Les trois tâches de modification sont sautées |

Le second passage vérifie aussi un point qui n’était pas acquis : `kubectl diff` ne signale pas l’annotation ajoutée par `kubectl patch`. Sinon, la comparaison aurait trouvé une différence à chaque passage, et le fichier aurait été réappliqué.

```bash
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl get storageclass
```

```text
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

### Sur des machines neuves

Le rôle a ensuite été validé par une reconstruction complète :

```powershell
powershell -ExecutionPolicy Bypass -File .\lab-local\scripts\rebuild.ps1 -Rebuild
```

| Contrôle | Résultat |
|---|---|
| Durée de la reconstruction | 6 min 26 |
| Quatrième play | Toutes les tâches exécutées, `failed=0` |
| Récapitulatif | `kube-control` : `ok=42 changed=30` ; `kube-worker` : `ok=28 changed=22` |
| Pod du fournisseur | `Running` sur `kube-worker` |
| Classe de stockage | `local-path (default)` |

## 6. Vérifier qu’un volume conserve ses données

Une classe par défaut ne prouve pas que les données survivent à un pod. Le test `lab-local/tests/storage-test.yaml`, rangé à côté du test réseau, le vérifie :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: storage-test
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-test
  namespace: storage-test
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 100Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
  namespace: storage-test
spec:
  containers:
    - name: test
      image: busybox:1.36
      command: ["sh", "-c", "[ -f /data/preuve.txt ] || date > /data/preuve.txt; sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: storage-test
```

- **La demande de volume ne précise aucune classe** : elle vérifie aussi que `local-path` est bien la classe par défaut.
- **`ReadWriteOnce`** : le volume ne peut être monté que par un seul nœud à la fois, ce que permet `local-path`.
- **`[ -f /data/preuve.txt ] ||`** : le fichier n’est écrit qu’à la première création du pod. Après recréation, il doit garder sa date d’origine.

### Le dérouler

Depuis WSL2, à la racine du dépôt :

```bash
CP="ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10"

# 1. Créer et lire
$CP kubectl apply -f - < lab-local/tests/storage-test.yaml
$CP kubectl -n storage-test wait --for=condition=Ready pod/storage-test --timeout=120s
$CP kubectl -n storage-test get pvc
$CP kubectl -n storage-test exec storage-test -- cat /data/preuve.txt

# 2. Supprimer le pod, le recréer, relire
$CP kubectl -n storage-test delete pod storage-test
$CP kubectl apply -f - < lab-local/tests/storage-test.yaml
$CP kubectl -n storage-test wait --for=condition=Ready pod/storage-test --timeout=120s
$CP kubectl -n storage-test exec storage-test -- cat /data/preuve.txt

# 3. Où sont les données ?
ssh -i ~/.ssh/vagrant/kube-worker vagrant@192.168.57.11 'sudo ls /opt/local-path-provisioner'
```

Résultats vérifiés le 16 octobre 2026 :

| Étape | Résultat |
|---|---|
| Demande de volume | `Bound`, classe `local-path`, 100 Mio, `RWO` |
| Fichier lu à la première création du pod | `Fri Oct 16 07:15:21 UTC 2026` |
| Fichier lu après suppression et recréation du pod | **`Fri Oct 16 07:15:21 UTC 2026`**, la même date |
| Dossier des données sur `kube-worker` | `pvc-82ba530c-…_storage-test_storage-test` |

Le volume persistant créé pour la demande montre où sont les données :

```bash
$CP kubectl get pv -o custom-columns=NOM:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,NOEUD:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]
```

| Propriété | Valeur | Conséquence |
|---|---|---|
| Politique de récupération | `Delete` | Les données sont supprimées avec la demande |
| Nœud | `kube-worker` | Le volume est attaché à ce nœud : tout pod qui l’utilise y sera placé |

### Le nettoyage, et la politique `Delete`

```bash
$CP kubectl delete -f - < lab-local/tests/storage-test.yaml
ssh -i ~/.ssh/vagrant/kube-worker vagrant@192.168.57.11 'sudo ls /opt/local-path-provisioner'
```

Résultat vérifié : le dossier des données a disparu dès le premier contrôle, et il ne reste aucun volume persistant. La suppression de la demande a bien effacé les données.

## 7. Les limites

| Limite | Conséquence | Traitement |
|---|---|---|
| Aucune réplication | Si `kube-worker` perd son disque, les données sont perdues | Acceptable pour un laboratoire ; des sauvegardes sont prévues dans la phase d’exploitation |
| Un volume reste attaché à son nœud | Un pod qui utilise un volume ne peut pas être déplacé sur un autre nœud | Sans conséquence avec un seul nœud de travail |
| Aucun plafond de taille | La taille demandée n’est pas imposée : un volume peut remplir le disque du nœud | À surveiller |
| Politique `Delete` | Supprimer la demande de volume d’une base efface ses données, sans confirmation | À trancher au déploiement de PostgreSQL : une classe en politique `Retain`, ou une règle de ne jamais supprimer ces demandes |

## 8. Tableau de validation

| Contrôle | Résultat au 16 octobre 2026 |
|---|---|
| Rôle `local_path`, quatrième play | Ajouté |
| Second passage du playbook | `changed=0` |
| Reconstruction complète | Réussie, 6 min 26 |
| Classe de stockage par défaut | `local-path` |
| Pod du fournisseur | `Running` sur `kube-worker` |
| Données conservées après recréation du pod | Oui, même date |
| Données effacées à la suppression de la demande | Oui, politique `Delete` |

## 9. Étape suivante

Le laboratoire fournit désormais des volumes. Le déploiement de l’application reprend dans la série [docs/03-kubernetes](../03-kubernetes/02-stockage.md), avec les dépendances qui en ont besoin : PostgreSQL, Redis et RabbitMQ.

## 10. Commandes de référence

```bash
# Classes de stockage
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl get storageclass

# Pod du fournisseur
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl -n local-path-storage get pods -o wide

# Demandes et volumes persistants
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl get pvc,pv -A

# Dossiers des volumes sur le nœud de travail
ssh -i ~/.ssh/vagrant/kube-worker vagrant@192.168.57.11 'sudo ls /opt/local-path-provisioner'
```

**Bilan :** le laboratoire fournit des volumes persistants, par un composant installé et figé par Ansible, qui survit aux reconstructions. Un volume conserve ses données au-delà de son pod, et ses limites, absence de réplication et suppression des données avec la demande, sont connues avant le déploiement des bases.
