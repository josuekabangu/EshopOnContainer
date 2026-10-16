# 02 — Le stockage

## 1. Objectif

PostgreSQL, Redis et RabbitMQ conservent des données. Sur Kubernetes, un pod qui veut garder ses données au-delà de sa propre vie demande un volume au cluster, par un objet `PersistentVolumeClaim`. Un composant du cluster, désigné par une `StorageClass`, crée alors ce volume.

Le cluster du laboratoire, construit par kubeadm, n’en avait aucun. Ce guide explique le choix du stockage, pour le laboratoire et pour la future infrastructure AWS. L’installation elle-même relève du laboratoire et fait l’objet de [docs/01-lab-local/14-local-path.md](../01-lab-local/14-local-path.md).

**État au 16 octobre 2026 :** le laboratoire dispose de la classe de stockage par défaut `local-path`. Sur AWS, le projet utilisera EBS CSI.

## 2. Les options pour un cluster kubeadm

| Option | Principe | Données répliquées ? | Prérequis |
|---|---|---|---|
| Volumes locaux statiques | Chaque volume est créé à la main, dans un dossier d’un nœud | Non | Aucun, mais aucun volume n’est créé automatiquement |
| **local-path-provisioner** (Rancher) | Crée automatiquement un dossier sur le nœud qui exécute le pod | Non | Un `Deployment` léger. Fournisseur par défaut de k3s |
| OpenEBS LocalPV | Même principe, avec des variantes sur LVM ou ZFS : quotas, instantanés | Non | Quelques composants |
| NFS (`csi-driver-nfs`) | Un serveur NFS partagé ; chaque volume en est un sous-dossier | Non : le serveur est un point unique de panne | Un serveur NFS. Seule option à permettre un volume partagé par plusieurs pods (`ReadWriteMany`) ; lente pour une base de données |
| Longhorn (projet CNCF) | Chaque volume est copié sur plusieurs nœuds | Oui | Idéalement trois nœuds, `open-iscsi`, de la mémoire |
| Rook-Ceph | Ceph, le stockage distribué de référence, piloté depuis Kubernetes | Oui | Trois nœuds au moins, des disques dédiés, plusieurs Go de mémoire par nœud |

## 3. Ce qui se fait en entreprise

### Dans le cloud : le stockage du fournisseur

C’est le cas le plus courant. Le cluster utilise le pilote CSI de son fournisseur, et chaque volume est un disque géré par le cloud. Aucun fournisseur n’est à installer : le cluster en dispose dès sa création.

| Cloud | Pilote | Volume créé |
|---|---|---|
| AWS | EBS CSI | Un disque EBS |
| Azure | Azure Disk CSI | Un disque géré Azure |
| Google Cloud | Persistent Disk CSI | Un disque persistant |

### Sur site : le stockage existant

| Contexte | Solution courante |
|---|---|
| Baie de stockage, SAN ou NAS | Le pilote CSI du constructeur : NetApp Trident, Dell, Pure Storage (Portworx), HPE |
| Machines virtuelles VMware vSphere | vSphere CSI : chaque volume devient un disque de machine virtuelle |
| Serveurs avec disques locaux, sans baie | Rook-Ceph, Longhorn ou Portworx, pour répliquer entre nœuds |

### Les bases de données, souvent hors du cluster

En production, beaucoup d’entreprises ne font pas tourner PostgreSQL, Redis ou RabbitMQ dans Kubernetes. Elles utilisent les services gérés de leur fournisseur : Amazon RDS, ElastiCache, Amazon MQ, ou leurs équivalents. La question du stockage ne se pose alors que pour les applications.

Quand une base reste dans le cluster, la pratique moderne est un **opérateur**, qui gère la réplication au niveau de la base elle-même :

| Composant | Opérateurs courants |
|---|---|
| PostgreSQL | CloudNativePG (projet CNCF), Zalando, Crunchy |
| RabbitMQ | RabbitMQ Cluster Operator |
| Redis | Opérateurs Redis, ou Valkey |

Chaque copie de la base écrit alors sur un disque local rapide, et l’opérateur duplique les données entre les copies. Un fournisseur local comme `local-path` redevient, dans ce modèle, un choix sérieux même en production.

## 4. Les décisions du projet

| Environnement | Stockage | Raison |
|---|---|---|
| Laboratoire local | **local-path-provisioner**, classe par défaut | Avec un seul nœud de travail, aucune réplication n’est possible ; le fournisseur est léger, sur un nœud de 6 Go qui portera l’application ; il ne masque rien de ce qu’il faut comprendre : `StorageClass`, `PersistentVolumeClaim`, attachement d’un volume à son nœud |
| AWS | **EKS** avec **EBS CSI** | L’usage courant en entreprise : un cluster géré par AWS, et des volumes qui sont des disques EBS. Décision du 16 octobre 2026 |

La décision EKS a une conséquence sur l’organisation du dépôt : sur AWS, AWS gère les nœuds et le plan de contrôle. Ansible ne sert donc qu’à construire le laboratoire, et reste dans `lab-local/ansible/`.

## 5. Ce que le choix du laboratoire implique pour l’application

Les limites de `local-path`, vérifiées dans le guide du laboratoire, pèseront sur le déploiement des dépendances :

| Limite | Conséquence pour l’application |
|---|---|
| Aucune réplication | Une panne du disque de `kube-worker` perdrait les bases, les paniers et les messages en attente |
| Un volume reste attaché à son nœud | PostgreSQL, Redis et RabbitMQ seront toujours placés sur `kube-worker` |
| Politique `Delete` | Supprimer la demande de volume d’une base efface ses données, sans confirmation. À trancher au déploiement de PostgreSQL |
| Accès `ReadWriteOnce` seulement | Un volume n’est monté que par un nœud à la fois ; aucun service d’eShop n’a besoin d’un volume partagé |

## 6. Pistes pour plus tard

- **CloudNativePG** pour PostgreSQL, pour pratiquer l’approche des entreprises : une base répliquée et sauvegardée par un opérateur. Il faudrait un second nœud de travail pour que la réplication ait un sens.
- **EBS CSI**, dans la phase AWS.

## 7. Étape suivante

Déployer les dépendances de l’application, en commençant par PostgreSQL, avec un volume demandé à la classe `local-path`.

**Bilan :** le laboratoire utilise un fournisseur de volumes local, choisi en connaissance de ses limites, et la future infrastructure AWS suivra l’usage des entreprises, avec EKS et EBS CSI.
