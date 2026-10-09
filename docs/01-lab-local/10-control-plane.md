# 10 — Initialisation du Control Plane

## 1. Objectif

Ce document décrit l'initialisation et la validation du **Control Plane Kubernetes** du laboratoire local EshopOnContainer.

Il couvre :

* la configuration fournie à `kubeadm` ;
* l'initialisation avec `kubeadm init` ;
* la configuration de `kubectl` ;
* la configuration de l'adresse IP du nœud ;
* la validation du Control Plane.

Les sujets suivants sont traités dans des documents séparés :

* le plugin réseau Calico, dans `11-calico.md` ;
* la jonction du Worker, dans `12-worker.md` ;
* les incidents rencontrés, dans `13-troubleshooting.md`.

---

## 2. Pourquoi cette étape ?

À l'issue de `09-kubernetes.md`, les deux machines disposent de `kubeadm`, `kubelet` et `kubectl`, mais aucun cluster Kubernetes n'existe encore.

Le **Control Plane** constitue le plan de contrôle du cluster. Il doit être créé en premier, car le Worker le rejoindra ensuite.

Il fournit notamment :

* l'API Kubernetes, point d'entrée de l'administration du cluster ;
* `etcd`, qui conserve l'état du cluster ;
* le Scheduler, qui sélectionne les nœuds sur lesquels les Pods peuvent être exécutés ;
* le Controller Manager, qui veille au respect de l'état souhaité du cluster.

Dans le laboratoire, le Control Plane est porté par la machine `kube-control`, définie dans `01-architecture.md`.

---

## 3. Prérequis

Les prérequis suivants sont validés dans les documents précédents :

| Prérequis                                      | Document de référence            |
| ---------------------------------------------- | -------------------------------- |
| Swap désactivé, modules et `sysctl` configurés | `07-kubernetes-prerequisites.md` |
| `containerd` actif avec `SystemdCgroup = true` | `08-containerd.md`               |
| `kubeadm`, `kubelet`, `kubectl` en v1.36.5     | `09-kubernetes.md`               |

Les commandes de ce document sont exécutées sur la machine `kube-control`, avec l'utilisateur `vagrant`.

La connexion depuis WSL2 s'effectue avec :

```bash
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10
```

Cette commande ouvre une session SSH sur le Control Plane avec la clé décrite dans `05-inventory.md`.

---

## 4. Les deux adresses à fixer

Chaque machine du laboratoire possède deux interfaces réseau, décrites dans `01-architecture.md`.

La route par défaut passe par l'interface NAT, dont l'adresse est attribuée en DHCP.

Lorsqu'une machine possède plusieurs adresses, Kubernetes peut sélectionner automatiquement une adresse différente de celle prévue par l'architecture du laboratoire.

Dans notre environnement, l'adresse NAT de `kube-control` est :

```text
192.168.200.129
```

alors que l'adresse prévue pour le réseau privé Kubernetes est :

```text
192.168.57.10
```

Deux paramètres distincts doivent donc désigner explicitement l'adresse du réseau privé.

| Paramètre          | Composant concerné | Ce qu'il fixe                                              | Où il se configure                 |
| ------------------ | ------------------ | ---------------------------------------------------------- | ---------------------------------- |
| `advertiseAddress` | API Server         | Adresse annoncée par l'API Server                          | Fichier de configuration `kubeadm` |
| `--node-ip`        | `kubelet`          | Adresse sous laquelle le nœud s'enregistre dans le cluster | `/etc/default/kubelet`             |

Ces deux paramètres sont indépendants.

Fixer `advertiseAddress` ne fixe donc pas automatiquement l'adresse `InternalIP` du nœud. C'est ce qui a été constaté dans ce laboratoire et qui est décrit dans `13-troubleshooting.md` (problème 9).

---

## 5. Configuration kubeadm

### 5.1 Fichier utilisé

L'initialisation utilise un fichier de configuration plutôt que de nombreux paramètres transmis directement en ligne de commande.

Cette approche permet de conserver les paramètres importants du cluster dans un fichier lisible et rejouable.

Le fichier se trouve dans le répertoire personnel de l'utilisateur `vagrant` sur `kube-control` :

```text
~/kubeadm-config.yaml
```

Son contenu est :

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration

localAPIEndpoint:
  advertiseAddress: 192.168.57.10
  bindPort: 6443

nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: kube-control

---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration

kubernetesVersion: v1.36.5

networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local
```

Le fichier contient deux objets :

* `InitConfiguration`, qui décrit les paramètres spécifiques au nœud utilisé pour initialiser le cluster ;
* `ClusterConfiguration`, qui décrit les paramètres généraux du cluster.

### 5.2 Paramètres

| Paramètre           | Valeur                                   | Rôle dans le laboratoire                                      |
| ------------------- | ---------------------------------------- | ------------------------------------------------------------- |
| `advertiseAddress`  | `192.168.57.10`                          | Adresse annoncée par l'API Server sur le réseau privé         |
| `bindPort`          | `6443`                                   | Port de l'API Server Kubernetes                               |
| `criSocket`         | `unix:///run/containerd/containerd.sock` | Socket du runtime containerd installé dans `08-containerd.md` |
| `name`              | `kube-control`                           | Nom du nœud dans le cluster                                   |
| `kubernetesVersion` | `v1.36.5`                                | Version Kubernetes utilisée par le cluster                    |
| `podSubnet`         | `10.244.0.0/16`                          | Plage d'adresses réservée aux Pods                            |
| `serviceSubnet`     | `10.96.0.0/12`                           | Plage d'adresses virtuelles des Services                      |
| `dnsDomain`         | `cluster.local`                          | Domaine DNS interne du cluster                                |

Les plages `podSubnet` et `serviceSubnet` ne chevauchent aucun des réseaux utilisés par les machines :

```text
192.168.57.0/24
192.168.200.0/24
```

Ce découpage permet de séparer :

```text
Réseau privé des machines
192.168.57.0/24

Réseau NAT
192.168.200.0/24

Réseau des Pods
10.244.0.0/16

Réseau des Services
10.96.0.0/12
```

La plage `10.244.0.0/16` sera exploitée par le plugin réseau Calico, documenté dans `11-calico.md`.

### 5.3 Validation de la configuration

Avant de procéder à l'initialisation :

```bash
kubeadm config validate --config ~/kubeadm-config.yaml
```

Cette commande vérifie que `kubeadm` comprend la structure et les champs utilisés dans le fichier.

Résultat obtenu :

```text
ok
```

Cette validation est **syntaxique et structurelle**. Elle confirme que `kubeadm` accepte le fichier, mais ne garantit pas à elle seule que le cluster fonctionnera correctement après son initialisation.

---

## 6. Mise en œuvre

### 6.1 Initialisation

L'initialisation est effectuée avec :

```bash
sudo kubeadm init --config ~/kubeadm-config.yaml
```

Cette commande nécessite les privilèges administrateur, car elle doit notamment créer et configurer des fichiers dans `/etc/kubernetes`.

Elle réalise notamment les opérations nécessaires pour :

1. effectuer les vérifications préalables ;
2. générer les certificats du cluster ;
3. générer les fichiers de configuration nécessaires à l'administration ;
4. créer les manifests des Pods statiques du Control Plane ;
5. s'appuyer sur `kubelet` pour lancer les composants du Control Plane ;
6. préparer les composants système nécessaires au cluster ;
7. générer les informations permettant à d'autres nœuds de rejoindre le cluster.

Les principaux composants du Control Plane sont :

```text
kube-apiserver
etcd
kube-scheduler
kube-controller-manager
```

L'initialisation a été réalisée le **8 octobre 2026 à 15:12 UTC**.

À la fin de l'exécution, `kubeadm` affiche également une commande `kubeadm join` permettant à un Worker de rejoindre le cluster.

Le jeton contenu dans cette commande constitue une information sensible. Il n'est donc pas reproduit dans la documentation ni dans le dépôt.

La procédure de jonction du Worker est documentée dans `12-worker.md`.

### 6.2 Configuration de kubectl

Après l'initialisation, `kubeadm` dépose la configuration d'administration dans :

```text
/etc/kubernetes/admin.conf
```

Ce fichier appartient à `root`.

Pour permettre à l'utilisateur `vagrant` d'utiliser `kubectl` :

```bash
mkdir -p ~/.kube

sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config

sudo chown $(id -u):$(id -g) ~/.kube/config
```

Les trois commandes permettent respectivement de :

1. créer le répertoire de configuration de `kubectl` ;
2. copier la configuration d'administration ;
3. donner à l'utilisateur courant la propriété du fichier.

Le fichier `~/.kube/config` contient des informations d'authentification permettant d'administrer le cluster.

Il reste donc local à la machine et n'est pas versionné dans Git.

### 6.3 Adresse IP du nœud

Après l'initialisation, le nœud s'était enregistré avec l'adresse NAT :

```text
192.168.200.129
```

alors que l'architecture prévoit :

```text
192.168.57.10
```

Le diagnostic est documenté dans `13-troubleshooting.md` (problème 9).

Le paquet `kubelet` lit notamment ses options supplémentaires dans :

```text
/etc/default/kubelet
```

Le fichier contenait initialement :

```text
KUBELET_EXTRA_ARGS=
```

Il a été modifié pour contenir :

```text
KUBELET_EXTRA_ARGS=--node-ip=192.168.57.10
```

Le service a ensuite été redémarré :

```bash
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

La première commande demande à `systemd` de relire sa configuration.

La seconde redémarre `kubelet`, qui prend alors en compte l'option `--node-ip`.

Cette modification a été réalisée le **8 octobre 2026 à 17:51 UTC**.

---

## 7. Vérification

### 7.1 État attendu après l'initialisation

Immédiatement après `kubeadm init`, et avant l'installation d'un plugin réseau, l'état attendu est le suivant :

| Élément               | État attendu | Raison                                            |
| --------------------- | ------------ | ------------------------------------------------- |
| Pods du Control Plane | `Running`    | Ils utilisent le réseau de la machine             |
| Nœud `kube-control`   | `NotReady`   | Aucun plugin réseau n'est encore installé         |
| Pods CoreDNS          | `Pending`    | Ils attendent la disponibilité du réseau des Pods |

Cet état intermédiaire n'a pas été relevé au moment exact de l'initialisation.

Les résultats présentés dans les sections suivantes ont été vérifiés le **8 octobre 2026 vers 18:15 UTC**, après l'installation du plugin réseau Calico.

C'est pourquoi le nœud apparaît ensuite `Ready`.

### 7.2 Accès à l'API

La communication avec l'API Server est vérifiée avec :

```bash
kubectl cluster-info
```

Cette commande vérifie que `kubectl` peut communiquer avec l'API Server à l'adresse configurée dans son kubeconfig.

Résultat vérifié :

```text
Kubernetes control plane is running at https://192.168.57.10:6443

CoreDNS is running at https://192.168.57.10:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

L'API Kubernetes est donc accessible sur :

```text
192.168.57.10:6443
```

### 7.3 État et adresse du nœud

```bash
kubectl get nodes -o wide
```

L'option `-o wide` ajoute notamment l'adresse interne du nœud et le runtime utilisé.

Résultat vérifié :

```text
NAME           STATUS   ROLES           AGE    VERSION   INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
kube-control   Ready    control-plane   3h1m   v1.36.5   192.168.57.10   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic (amd64)   containerd://2.2.1
```

La colonne `INTERNAL-IP` contient bien :

```text
192.168.57.10
```

Cette adresse correspond à l'architecture définie dans `01-architecture.md`.

### 7.4 Prise en compte de l'option kubelet

La présence de l'option dans `/etc/default/kubelet` ne suffit pas à prouver que le processus en cours l'utilise.

Le processus peut être contrôlé directement :

```bash
ps -o args= -C kubelet | tr " " "\n" | grep node-ip
```

Résultat vérifié :

```text
--node-ip=192.168.57.10
```

L'option est donc bien présente dans le processus `kubelet` actuellement exécuté.

### 7.5 Composants système

Les composants système peuvent être vérifiés avec :

```bash
kubectl get pods -n kube-system -o wide
```

Cette commande liste les Pods du namespace `kube-system` avec notamment leur état, leur adresse IP et le nœud qui les héberge.

Résultat vérifié pour les composants pertinents :

```text
NAME                                  READY   STATUS    RESTARTS   IP                NODE
coredns-589f44dc88-9fqkg              1/1     Running   0          10.244.222.2      kube-control
coredns-589f44dc88-bphp6              1/1     Running   0          10.244.222.3      kube-control
etcd-kube-control                     1/1     Running   0          192.168.200.129   kube-control
kube-apiserver-kube-control           1/1     Running   0          192.168.200.129   kube-control
kube-controller-manager-kube-control  1/1     Running   0          192.168.200.129   kube-control
kube-proxy-6k5xb                      1/1     Running   0          192.168.57.10     kube-control
kube-scheduler-kube-control           1/1     Running   0          192.168.200.129   kube-control
```

Tous les composants sont actuellement en fonctionnement et aucun redémarrage n'est observé dans ce relevé.

Les Pods liés au réseau Calico sont également présents dans `kube-system`. Leur fonctionnement est documenté dans `11-calico.md`.

Les quatre Pods statiques du Control Plane affichent encore l'adresse NAT dans leur colonne `IP`. Ce point est analysé dans la section suivante.

---

## 8. Adresse affichée par les Pods statiques

### 8.1 Constat

Les quatre Pods statiques du Control Plane affichent :

```text
192.168.200.129
```

dans la colonne `IP`, alors que le nœud est maintenant enregistré avec :

```text
192.168.57.10
```

La différence peut être observée avec :

```bash
kubectl -n kube-system get pods \
  -o custom-columns=NAME:.metadata.name,HOSTIP:.status.hostIP,PODIP:.status.podIP
```

Résultat vérifié :

```text
NAME                                  HOSTIP          PODIP
etcd-kube-control                     192.168.57.10   192.168.200.129
kube-apiserver-kube-control           192.168.57.10   192.168.200.129
kube-controller-manager-kube-control  192.168.57.10   192.168.200.129
kube-scheduler-kube-control           192.168.57.10   192.168.200.129
```

L'adresse du nœud (`HOSTIP`) est correcte.

La valeur différente apparaît uniquement dans le statut `PODIP` de ces Pods statiques.

### 8.2 Vérification de l'utilisation réelle des adresses

La présence de l'adresse NAT dans le statut des Pods ne suffit pas à déterminer si cette adresse est réellement utilisée pour les communications du Control Plane.

Plusieurs vérifications ont donc été effectuées.

#### Adresses configurées dans les composants

```bash
sudo grep -hoE -- \
  "--(advertise-address|listen-client-urls|listen-peer-urls|advertise-client-urls|initial-advertise-peer-urls)=[^ ]+" \
  /etc/kubernetes/manifests/*.yaml | sort -u
```

Résultat vérifié :

```text
--advertise-address=192.168.57.10
--advertise-client-urls=https://192.168.57.10:2379
--initial-advertise-peer-urls=https://192.168.57.10:2380
--listen-client-urls=https://127.0.0.1:2379,https://192.168.57.10:2379
--listen-peer-urls=https://192.168.57.10:2380
```

Les manifests du Control Plane ne configurent donc pas l'adresse NAT comme adresse d'annonce.

#### Adresses réellement en écoute

```bash
sudo ss -ltnH | awk '{print $4}' | grep -E ":(6443|2379|2380)$" | sort -u
```

Résultat vérifié :

```text
127.0.0.1:2379
192.168.57.10:2379
192.168.57.10:2380
*:6443
```

`etcd` écoute donc sur l'adresse privée `192.168.57.10` pour ses communications réseau.

L'API Server écoute sur le port `6443`.

#### Adresses couvertes par le certificat de l'API

```bash
sudo openssl x509 \
  -in /etc/kubernetes/pki/apiserver.crt \
  -noout -ext subjectAltName
```

Résultat vérifié :

```text
DNS:kube-control, DNS:kubernetes, DNS:kubernetes.default,
DNS:kubernetes.default.svc,
DNS:kubernetes.default.svc.cluster.local,
IP Address:10.96.0.1,
IP Address:192.168.57.10
```

L'adresse NAT `192.168.200.129` n'apparaît pas dans les SAN du certificat de l'API Server.

#### Adresse derrière le Service `kubernetes`

```bash
kubectl get endpointslices -n default
```

La vérification montre que le Service interne `kubernetes` dirige les connexions vers :

```text
192.168.57.10:6443
```

### 8.3 Conclusion

Les vérifications montrent que :

* l'API Server annonce `192.168.57.10` ;
* `etcd` annonce et écoute sur `192.168.57.10` ;
* le certificat de l'API couvre `192.168.57.10` ;
* le Service interne `kubernetes` utilise `192.168.57.10` ;
* `kubelet` enregistre le nœud avec `192.168.57.10`.

L'adresse NAT `192.168.200.129` apparaît uniquement dans le statut `PODIP` des quatre Pods statiques.

Aucun impact fonctionnel n'a été identifié sur le fonctionnement actuel du cluster.

Il n'est donc pas nécessaire de modifier manuellement les composants du Control Plane uniquement pour faire disparaître cette valeur du statut des Pods.

Le mécanisme exact à l'origine de la persistance de cette valeur n'a pas été déterminé dans le cadre de ce laboratoire. Ce point n'a pas fait l'objet d'une modification supplémentaire.

---

## 9. Principes appliqués

### Un fichier de configuration plutôt que des options dispersées

Les paramètres principaux du cluster sont regroupés dans `kubeadm-config.yaml`.

Cette approche améliore la lisibilité et facilite la reproduction de la configuration.

### Valider avant d'initialiser

La commande :

```bash
kubeadm config validate
```

permet de détecter une erreur de structure avant l'initialisation.

À l'inverse, une initialisation interrompue peut laisser un état partiellement configuré à analyser ou à nettoyer.

### Vérifier le processus, pas seulement le fichier

La présence de :

```text
KUBELET_EXTRA_ARGS=--node-ip=192.168.57.10
```

dans `/etc/default/kubelet` ne suffit pas.

L'option a également été vérifiée sur le processus `kubelet` réellement exécuté.

### Prouver avant de conclure

L'adresse NAT affichée par les Pods statiques n'a pas été considérée comme un problème fonctionnel sans vérification.

Les manifests, les ports en écoute, le certificat de l'API et le Service interne ont été contrôlés.

### Aucun secret dans la documentation

Le jeton `kubeadm join` n'est pas reproduit.

Le contenu de `admin.conf` n'est pas versionné.

Les informations d'authentification du cluster restent donc hors du dépôt.

---

## 10. État et limites

### 10.1 État validé

| Élément                                  | État au 8 octobre 2026                   |
| ---------------------------------------- | ---------------------------------------- |
| Configuration `kubeadm` validée          | ✅                                        |
| Control Plane initialisé                 | ✅                                        |
| API accessible sur `192.168.57.10:6443`  | ✅                                        |
| `kubectl` configuré pour `vagrant`       | ✅                                        |
| Nœud enregistré avec `192.168.57.10`     | ✅                                        |
| Composants du Control Plane en exécution | ✅                                        |
| Calico installé                          | ✅ — voir `11-calico.md`                  |
| Worker joint au cluster                  | ✅ — voir `12-worker.md`                  |

### 10.2 Limites connues

| Limite                                                                                                 | Conséquence                                                                                    |
| ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| `kubeadm-config.yaml` existe uniquement dans le répertoire personnel de la machine                     | Il est perdu si la machine est détruite                                                        |
| L'initialisation est réalisée manuellement, contrairement aux étapes 07 à 09 automatisées avec Ansible | La reconstruction du cluster n'est pas entièrement automatisée                                 |
| L'adresse du nœud est fixée après l'initialisation par une modification manuelle                       | Une reconstruction suivant exactement cette procédure repassera initialement par l'adresse NAT |
| Quatre Pods statiques affichent encore l'adresse NAT dans leur statut                                  | Aucun impact fonctionnel identifié ; voir section 8                                            |

Cette dernière limite est documentée afin de conserver une trace de l'observation sans transformer une anomalie d'affichage en modification inutile du Control Plane.

---

## 11. Documentation associée

| Fichier                 | Relation avec ce document                                             |
| ----------------------- | --------------------------------------------------------------------- |
| `01-architecture.md`    | Machines, interfaces et réseaux du laboratoire                        |
| `08-containerd.md`      | Runtime utilisé par Kubernetes                                        |
| `09-kubernetes.md`      | Installation de `kubeadm`, `kubelet` et `kubectl`                     |
| `11-calico.md`          | Installation et validation du plugin réseau                           |
| `12-worker.md`          | Jonction du Worker au cluster                                         |
| `13-troubleshooting.md` | Incidents et diagnostics, notamment le choix initial de l'adresse NAT |

---

## 12. Étape suivante

Le Control Plane est initialisé, mais un cluster a besoin d'un plugin réseau pour que ses Pods communiquent et que ses nœuds passent à l'état `Ready`.

La prochaine étape consiste à installer le plugin réseau Calico.

Elle est documentée dans `11-calico.md`.

La jonction du Worker, qui vient ensuite, est documentée dans `12-worker.md`.
