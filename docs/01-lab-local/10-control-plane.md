# 10 — Initialisation du Control Plane

## 1. Objectif

Ce document décrit l'initialisation et la validation du **Control Plane Kubernetes** du laboratoire local EshopOnContainer.

L'initialisation est automatisée par le rôle Ansible `control_plane`.

Il couvre :

* la configuration fournie à `kubeadm` ;
* l'initialisation avec `kubeadm init` ;
* la configuration de `kubectl` ;
* la validation du Control Plane.

Les sujets suivants sont traités dans des documents séparés :

* l'adresse du nœud imposée à `kubelet`, dans `09-kubernetes.md` (section 6.3) ;
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
| Adresse du nœud imposée à `kubelet`            | `09-kubernetes.md` (section 6.3) |

Ces prérequis sont appliqués par le premier play de `site.yml`. Le rôle `control_plane` appartient au second play : l'ordre des plays, décrit dans `06-roles.md`, garantit que les prérequis sont en place avant l'initialisation.

---

## 4. Les deux adresses à fixer

Chaque machine du laboratoire possède deux interfaces réseau, décrites dans `01-architecture.md`.

La route par défaut passe par l'interface NAT, dont l'adresse est attribuée en DHCP et change d'une création à l'autre.

Lorsqu'une machine possède plusieurs adresses, Kubernetes peut sélectionner automatiquement une adresse différente de celle prévue par l'architecture du laboratoire.

L'adresse prévue pour `kube-control` sur le réseau privé est :

```text
192.168.57.10
```

Deux paramètres distincts doivent désigner explicitement cette adresse.

| Paramètre          | Composant concerné | Ce qu'il fixe                                              | Où il se configure                 | Rôle Ansible    |
| ------------------ | ------------------ | ---------------------------------------------------------- | ---------------------------------- | --------------- |
| `advertiseAddress` | API Server         | Adresse annoncée par l'API Server                          | Fichier de configuration `kubeadm` | `control_plane` |
| `--node-ip`        | `kubelet`          | Adresse sous laquelle le nœud s'enregistre dans le cluster | `/etc/default/kubelet`             | `kubernetes`    |

Ces deux paramètres sont indépendants. Fixer `advertiseAddress` ne fixe pas l'adresse `InternalIP` du nœud.

L'option `--node-ip` doit être en place **avant** l'initialisation. Lors de la première construction du laboratoire, elle avait été ajoutée après coup et le nœud s'était d'abord enregistré avec l'adresse NAT. Cet incident et sa résolution sont décrits dans `13-troubleshooting.md` (problème 9).

---

## 5. Configuration kubeadm

### 5.1 Pourquoi un fichier de configuration ?

L'initialisation utilise un fichier de configuration plutôt que de nombreux paramètres transmis en ligne de commande.

Cette approche permet de conserver les paramètres du cluster dans un fichier lisible, versionné dans le dépôt et rejouable à l'identique.

### 5.2 Modèle

Le fichier est généré à partir d'un modèle du rôle :

```text
lab-local/ansible/roles/control_plane/templates/kubeadm-config.yaml.j2
```

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: {{ node_ip }}
  bindPort: {{ api_server_port }}
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: {{ inventory_hostname }}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: {{ kubernetes_release }}
networking:
  podSubnet: {{ pod_subnet }}
  serviceSubnet: {{ service_subnet }}
  dnsDomain: {{ cluster_dns_domain }}
```

Le fichier contient deux objets :

* `InitConfiguration`, qui décrit les paramètres spécifiques au nœud utilisé pour initialiser le cluster ;
* `ClusterConfiguration`, qui décrit les paramètres généraux du cluster.

Les expressions entre accolades sont remplacées par Ansible au moment de générer le fichier.

### 5.3 Variables

Les valeurs propres au cluster sont déclarées dans `lab-local/ansible/group_vars/control_plane.yml` :

```yaml
kubernetes_release: "v{{ kubernetes_version.split('-')[0] }}"
api_server_port: 6443
pod_subnet: "10.244.0.0/16"
service_subnet: "10.96.0.0/12"
cluster_dns_domain: "cluster.local"
```

| Expression du modèle  | Origine                                  | Valeur obtenue                           | Rôle dans le laboratoire                                      |
| --------------------- | ---------------------------------------- | ---------------------------------------- | ------------------------------------------------------------- |
| `node_ip`             | `group_vars/all.yml`, d'après l'inventaire | `192.168.57.10`                        | Adresse annoncée par l'API Server sur le réseau privé         |
| `api_server_port`     | `group_vars/control_plane.yml`           | `6443`                                   | Port de l'API Server Kubernetes                               |
| `inventory_hostname`  | Inventaire                               | `kube-control`                           | Nom du nœud dans le cluster                                   |
| `kubernetes_release`  | Calculée d'après `kubernetes_version`    | `v1.36.5`                                | Version Kubernetes utilisée par le cluster                    |
| `pod_subnet`          | `group_vars/control_plane.yml`           | `10.244.0.0/16`                          | Plage d'adresses réservée aux Pods                            |
| `service_subnet`      | `group_vars/control_plane.yml`           | `10.96.0.0/12`                           | Plage d'adresses virtuelles des Services                      |
| `cluster_dns_domain`  | `group_vars/control_plane.yml`           | `cluster.local`                          | Domaine DNS interne du cluster                                |

Le paramètre `criSocket` désigne le socket du runtime `containerd` installé dans `08-containerd.md`. Il est écrit en dur, car il ne dépend d'aucun choix propre au laboratoire.

La version du cluster n'est pas saisie une seconde fois : elle est déduite de la version des paquets installés par le rôle `kubernetes`. Les deux ne peuvent donc pas diverger.

### 5.4 Plages d'adresses

Les plages `pod_subnet` et `service_subnet` ne chevauchent aucun des réseaux utilisés par les machines :

```text
Réseau privé des machines    192.168.57.0/24
Réseau NAT                   192.168.200.0/24
Réseau des Pods              10.244.0.0/16
Réseau des Services          10.96.0.0/12
```

La plage `10.244.0.0/16` est exploitée par le plugin réseau Calico, documenté dans `11-calico.md`.

---

## 6. Mise en œuvre

Le rôle `control_plane` comporte quatre tâches, dans `lab-local/ansible/roles/control_plane/tasks/main.yml`.

### 6.1 Dépôt de la configuration

```yaml
- name: Déposer la configuration kubeadm
  ansible.builtin.template:
    src: kubeadm-config.yaml.j2
    dest: /etc/kubernetes/kubeadm-config.yaml
    owner: root
    group: root
    mode: '0644'
```

Cette tâche génère le fichier de configuration à partir du modèle et le dépose sur le Control Plane.

Le fichier est placé dans `/etc/kubernetes`, avec les autres fichiers de configuration du cluster, et non dans le répertoire personnel d'un utilisateur.

### 6.2 Initialisation

```yaml
- name: Initialiser le Control Plane
  ansible.builtin.command:
    cmd: kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --skip-token-print
    creates: /etc/kubernetes/admin.conf
```

La commande `kubeadm init` crée le Control Plane à partir du fichier de configuration. Elle réalise notamment les opérations nécessaires pour :

1. effectuer les vérifications préalables ;
2. générer les certificats du cluster ;
3. générer les fichiers de configuration nécessaires à l'administration ;
4. créer les manifests des Pods statiques du Control Plane ;
5. s'appuyer sur `kubelet` pour lancer les composants du Control Plane ;
6. installer CoreDNS et `kube-proxy` ;
7. créer un jeton permettant à d'autres nœuds de rejoindre le cluster.

Deux paramètres de la tâche méritent une explication.

**`creates: /etc/kubernetes/admin.conf`** est la garde d'idempotence. Ce fichier est créé par `kubeadm init`. S'il existe, le cluster est déjà initialisé et Ansible ne relance pas la commande.

**`--skip-token-print`** empêche `kubeadm` d'afficher le jeton de jonction qu'il crée. Sans cette option, le jeton apparaîtrait dans la sortie d'Ansible en mode détaillé. Le jeton utilisé pour joindre le Worker est créé séparément, comme décrit dans `12-worker.md`.

### 6.3 Accès kubectl

Après l'initialisation, `kubeadm` dépose la configuration d'administration dans `/etc/kubernetes/admin.conf`. Ce fichier appartient à `root` et n'est lisible que par lui.

Deux tâches donnent à l'utilisateur d'administration l'accès à `kubectl` :

```yaml
- name: Créer le répertoire de configuration de kubectl
  ansible.builtin.file:
    path: "/home/{{ ansible_user }}/.kube"
    state: directory
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0755'

- name: Donner l'accès kubectl à l'utilisateur d'administration
  ansible.builtin.copy:
    src: /etc/kubernetes/admin.conf
    dest: "/home/{{ ansible_user }}/.kube/config"
    remote_src: true
    owner: "{{ ansible_user }}"
    group: "{{ ansible_user }}"
    mode: '0600'
```

La première crée le répertoire attendu par `kubectl`. La seconde y copie la configuration d'administration.

L'option `remote_src: true` indique que le fichier source se trouve sur la machine distante, et non sur le poste de contrôle.

La variable `ansible_user` provient de l'inventaire et vaut `vagrant`.

Le fichier `~/.kube/config` contient un certificat permettant d'administrer le cluster. Il reçoit le mode `0600`, reste local à la machine et n'est pas versionné dans Git.

### 6.4 Exécution

Le rôle est appelé par le second play de `site.yml`, décrit dans `06-roles.md`.

L'initialisation a été réalisée par Ansible le **9 octobre 2026 à 20:16 UTC**, sur une machine recréée à neuf.

---

## 7. Vérification

Les résultats de cette section ont été vérifiés le **9 octobre 2026 à 20:26 UTC**, sur le cluster reconstruit.

### 7.1 État intermédiaire

Immédiatement après `kubeadm init`, et avant l'installation d'un plugin réseau, l'état attendu est le suivant :

| Élément               | État attendu | Raison                                            |
| --------------------- | ------------ | ------------------------------------------------- |
| Pods du Control Plane | `Running`    | Ils utilisent le réseau de la machine             |
| Nœud `kube-control`   | `NotReady`   | Aucun plugin réseau n'est encore installé         |
| Pods CoreDNS          | `Pending`    | Ils attendent la disponibilité du réseau des Pods |

Cet état intermédiaire n'a pas été relevé : le rôle `calico` s'exécute dans le même play, aussitôt après l'initialisation. Les résultats ci-dessous sont donc postérieurs à l'installation du plugin réseau, ce qui explique que le nœud y apparaisse `Ready`.

### 7.2 Configuration générée

```bash
sudo kubeadm config validate --config /etc/kubernetes/kubeadm-config.yaml
```

Cette commande vérifie que `kubeadm` comprend la structure et les champs du fichier.

Résultat vérifié :

```text
ok
```

Cette validation est **syntaxique et structurelle**. Elle confirme que `kubeadm` accepte le fichier, mais ne garantit pas à elle seule que le cluster fonctionne.

Le fichier généré contient les valeurs attendues :

```yaml
localAPIEndpoint:
  advertiseAddress: 192.168.57.10
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: kube-control
```

```yaml
kubernetesVersion: v1.36.5
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local
```

### 7.3 Accès à l'API

```bash
kubectl cluster-info
```

Cette commande vérifie que `kubectl` peut communiquer avec l'API Server à l'adresse configurée dans son kubeconfig.

Résultat vérifié :

```text
Kubernetes control plane is running at https://192.168.57.10:6443
CoreDNS is running at https://192.168.57.10:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

Ce résultat valide à la fois la configuration de `kubectl` pour l'utilisateur `vagrant` et l'adresse annoncée par l'API.

### 7.4 État et adresse du nœud

```bash
kubectl get nodes -o wide
```

L'option `-o wide` ajoute notamment l'adresse interne du nœud et le runtime utilisé.

Résultat vérifié pour le Control Plane :

```text
NAME           STATUS   ROLES           AGE     VERSION   INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
kube-control   Ready    control-plane   9m38s   v1.36.5   192.168.57.10   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic (amd64)   containerd://2.2.1
```

La colonne `INTERNAL-IP` contient l'adresse du réseau privé, conformément à `01-architecture.md`.

### 7.5 Prise en compte de l'option kubelet

La présence de l'option dans `/etc/default/kubelet` ne suffit pas à prouver que le processus en cours l'utilise.

```bash
ps -o args= -C kubelet | tr " " "\n" | grep node-ip
```

Cette commande affiche les arguments du processus `kubelet` en cours d'exécution et n'en conserve que l'option recherchée.

Résultat vérifié :

```text
--node-ip=192.168.57.10
```

### 7.6 Composants du Control Plane

```bash
kubectl get pods -n kube-system -o wide
```

Cette commande liste les Pods du namespace `kube-system` avec leur état, leur adresse et le nœud qui les héberge.

Résultat vérifié, limité aux composants créés par `kubeadm init` sur le Control Plane et aux colonnes utiles :

```text
NAME                                   READY   STATUS    RESTARTS   IP              NODE
coredns-589f44dc88-6n5cw               1/1     Running   0          10.244.222.2    kube-control
coredns-589f44dc88-gk6l2               1/1     Running   0          10.244.222.1    kube-control
etcd-kube-control                      1/1     Running   0          192.168.57.10   kube-control
kube-apiserver-kube-control            1/1     Running   0          192.168.57.10   kube-control
kube-controller-manager-kube-control   1/1     Running   0          192.168.57.10   kube-control
kube-proxy-b9mf7                       1/1     Running   0          192.168.57.10   kube-control
kube-scheduler-kube-control            1/1     Running   0          192.168.57.10   kube-control
```

Tous les composants sont en fonctionnement et aucun redémarrage n'est observé.

Les quatre Pods statiques (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`) affichent l'adresse du réseau privé. Ce point est important : lors de la première construction, ils affichaient l'adresse NAT. La section 8 y revient.

Les Pods liés à Calico sont également présents dans `kube-system`. Ils sont documentés dans `11-calico.md`.

### 7.7 Adresses réellement utilisées par le Control Plane

Trois vérifications complètent la précédente. Elles portent sur ce que les composants utilisent réellement, et non sur ce qu'affiche leur statut.

**Adresses configurées dans les composants.**

```bash
sudo grep -hoE -- \
  "--(advertise-address|listen-client-urls|listen-peer-urls|advertise-client-urls|initial-advertise-peer-urls)=[^ ]+" \
  /etc/kubernetes/manifests/*.yaml | sort -u
```

Cette commande extrait des fichiers de définition des Pods statiques les options qui fixent leurs adresses.

Résultat vérifié :

```text
--advertise-address=192.168.57.10
--advertise-client-urls=https://192.168.57.10:2379
--initial-advertise-peer-urls=https://192.168.57.10:2380
--listen-client-urls=https://127.0.0.1:2379,https://192.168.57.10:2379
--listen-peer-urls=https://192.168.57.10:2380
```

**Adresses en écoute.**

```bash
sudo ss -ltnH | awk '{print $4}' | grep -E ":(6443|2379|2380)$" | sort -u
```

Cette commande liste les adresses sur lesquelles l'API et `etcd` acceptent des connexions.

Résultat vérifié :

```text
127.0.0.1:2379
192.168.57.10:2379
192.168.57.10:2380
*:6443
```

**Adresses couvertes par le certificat de l'API.**

```bash
sudo openssl x509 \
  -in /etc/kubernetes/pki/apiserver.crt \
  -noout -ext subjectAltName
```

Cette commande affiche les noms et adresses pour lesquels le certificat de l'API est valide.

Résultat vérifié :

```text
DNS:kube-control, DNS:kubernetes, DNS:kubernetes.default,
DNS:kubernetes.default.svc,
DNS:kubernetes.default.svc.cluster.local,
IP Address:10.96.0.1,
IP Address:192.168.57.10
```

Le Service interne `kubernetes`, par lequel les Pods contactent l'API, dirige lui aussi les connexions vers `192.168.57.10:6443`.

Aucune de ces vérifications ne fait apparaître l'adresse NAT.

### 7.8 Idempotence

Une seconde exécution du playbook ne doit rien modifier, et en particulier ne pas relancer l'initialisation.

Résultat vérifié pour le rôle `control_plane` :

```text
TASK [control_plane : Déposer la configuration kubeadm]                    ok
TASK [control_plane : Initialiser le Control Plane]                        ok
TASK [control_plane : Créer le répertoire de configuration de kubectl]     ok
TASK [control_plane : Donner l'accès kubectl à l'utilisateur d'administration]  ok
```

Le récapitulatif complet des deux exécutions figure dans `06-roles.md` (section 8.3).

---

## 8. Ce qui a changé par rapport à la première construction

Le Control Plane a d'abord été initialisé à la main, le 8 octobre 2026, avant d'être automatisé. Deux différences sont à retenir.

| Sujet                         | Première construction, manuelle                         | Construction automatisée                              |
| ----------------------------- | ------------------------------------------------------- | ----------------------------------------------------- |
| Fichier de configuration      | Dans le répertoire personnel de `vagrant`, hors dépôt   | Généré depuis un modèle versionné                     |
| Option `--node-ip`            | Ajoutée après l'initialisation                          | En place avant l'initialisation                       |
| Adresse du nœud à l'inscription | Adresse NAT, puis corrigée                            | Adresse du réseau privé dès l'inscription             |
| Adresse affichée par les Pods statiques | Adresse NAT, même après correction            | Adresse du réseau privé                               |

Lors de la première construction, les quatre Pods statiques avaient conservé l'adresse NAT dans leur statut, sans effet sur le fonctionnement du cluster. Le mécanisme n'avait pas été établi.

La reconstruction apporte la réponse : avec l'option `--node-ip` en place avant `kubeadm init`, les Pods statiques sont créés directement avec l'adresse du réseau privé. L'adresse NAT qu'ils affichaient provenait donc, selon toute vraisemblance, du moment où ils avaient été créés, alors que `kubelet` n'avait reçu aucune adresse. Le mécanisme interne exact n'a pas été étudié.

Le détail de cet incident figure dans `13-troubleshooting.md` (problème 9).

---

## 9. Principes appliqués

* **Un fichier de configuration versionné.** Les paramètres du cluster sont regroupés dans un modèle du dépôt, et non saisis en ligne de commande ni conservés sur une machine.
* **Une valeur, un seul endroit.** La version du cluster est déduite de la version des paquets, et l'adresse du nœud de l'inventaire.
* **L'ordre avant la correction.** L'adresse du nœud est fixée avant l'initialisation, ce qui évite de devoir la corriger ensuite.
* **Une garde sur toute commande.** `kubeadm init` ne s'exécute que si le cluster n'existe pas.
* **Vérifier le processus, pas seulement le fichier.** L'option `--node-ip` a été contrôlée sur le processus `kubelet` en cours d'exécution.
* **Aucun secret dans la documentation ni dans les journaux.** Le jeton n'est pas affiché par `kubeadm`, et le contenu de `admin.conf` n'est pas versionné.

---

## 10. État et limites

### 10.1 État validé

| Élément                                         | État au 9 octobre 2026                   |
| ----------------------------------------------- | ---------------------------------------- |
| Configuration `kubeadm` générée et validée      | ✅                                        |
| Control Plane initialisé par Ansible            | ✅                                        |
| API accessible sur `192.168.57.10:6443`         | ✅                                        |
| `kubectl` configuré pour `vagrant`              | ✅                                        |
| Nœud enregistré avec `192.168.57.10`            | ✅                                        |
| Pods statiques sur l'adresse du réseau privé    | ✅                                        |
| Rôle idempotent                                 | ✅                                        |
| Validé par reconstruction complète              | ✅ — voir `06-roles.md`                   |

### 10.2 Limites connues

| Limite                                                                            | Conséquence                                                                 |
| --------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Le cluster ne comporte qu'un seul Control Plane                                   | L'arrêt de `kube-control` rend l'API indisponible                           |
| Le rôle ne sait pas réinitialiser un cluster existant                             | Modifier un paramètre du cluster demande de reconstruire les machines       |
| `kubeadm init` crée un jeton valable 24 heures, même s'il n'est pas affiché        | Ce jeton existe dans le cluster jusqu'à son expiration                      |
| `kubectl` n'est configuré que sur le Control Plane                                | L'administration du cluster passe par une session SSH sur `kube-control`    |

---

## 11. Documentation associée

| Fichier                 | Relation avec ce document                                             |
| ----------------------- | --------------------------------------------------------------------- |
| `01-architecture.md`    | Machines, interfaces et réseaux du laboratoire                        |
| `06-roles.md`           | Organisation des rôles, ordre des plays, résultat de la reconstruction |
| `08-containerd.md`      | Runtime utilisé par Kubernetes                                        |
| `09-kubernetes.md`      | Installation des composants et adresse du nœud                        |
| `11-calico.md`          | Installation et validation du plugin réseau                           |
| `12-worker.md`          | Jonction du Worker au cluster                                         |
| `13-troubleshooting.md` | Incidents et diagnostics, notamment le choix initial de l'adresse NAT |

---

## 12. Étape suivante

Le Control Plane est initialisé, mais un cluster a besoin d'un plugin réseau pour que ses Pods communiquent et que ses nœuds passent à l'état `Ready`.

La prochaine étape consiste à installer le plugin réseau Calico.

Elle est documentée dans `11-calico.md`.
