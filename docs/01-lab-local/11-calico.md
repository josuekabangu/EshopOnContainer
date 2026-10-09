# 11 — Installation et validation de Calico

## 1. Objectif

Ce document décrit l'installation et la validation du plugin réseau du cluster Kubernetes du laboratoire local EshopOnContainer.

Le plugin retenu est **Calico**. Son installation est automatisée par le rôle Ansible `calico`.

Il couvre :

* la raison pour laquelle un plugin réseau est nécessaire ;
* l'installation de Calico par Ansible ;
* la configuration réellement obtenue ;
* la validation du réseau des Pods.

Les sujets suivants sont traités dans des documents séparés :

* l'initialisation du Control Plane, dans `10-control-plane.md` ;
* la jonction du Worker et les tests réseau entre nœuds, dans `12-worker.md` ;
* les incidents rencontrés, dans `13-troubleshooting.md`.

---

## 2. Pourquoi un plugin réseau ?

`kubeadm init` crée le Control Plane, mais ne fournit pas de réseau aux Pods. Kubernetes délègue cette fonction à un composant externe, à travers l'interface **CNI** (Container Network Interface).

Tant qu'aucun plugin n'est installé :

* le nœud reste à l'état `NotReady` ;
* les Pods qui ont besoin d'une adresse, comme CoreDNS, restent à l'état `Pending`.

Le plugin réseau a trois responsabilités :

* attribuer une adresse IP à chaque Pod ;
* permettre aux Pods d'un même nœud de communiquer ;
* acheminer le trafic entre les Pods situés sur des nœuds différents.

```text
kubelet
   |
   | CNI
   v
Calico
   |
   +---- attribue une adresse au Pod
   +---- configure son interface réseau
   +---- annonce les routes aux autres nœuds
```

### Pourquoi Calico ?

Calico prend en charge les **NetworkPolicies** Kubernetes, qui permettent de filtrer le trafic entre Pods. Cette fonction sera utile pour cloisonner les services de l'application eShop.

---

## 3. Prérequis

| Prérequis                                              | Document de référence |
| ------------------------------------------------------ | --------------------- |
| Control Plane initialisé                               | `10-control-plane.md` |
| Plage des Pods `10.244.0.0/16` déclarée à `kubeadm`    | `10-control-plane.md` |
| Nœud enregistré avec son adresse du réseau privé       | `10-control-plane.md` |

Les réseaux des machines sont décrits dans `01-architecture.md`. Les plages des Pods et des Services sont définies dans `10-control-plane.md`.

Le rôle `calico` s'exécute sur le Control Plane, dans le même play que le rôle `control_plane` et juste après lui, comme décrit dans `06-roles.md`.

---

## 4. Fonctionnement de Calico dans le laboratoire

Calico découpe la plage des Pods en blocs et attribue un bloc à chaque nœud. Les Pods d'un nœud reçoivent leur adresse dans le bloc de ce nœud.

Chaque nœud annonce ensuite son bloc aux autres avec le protocole de routage BGP. Chaque nœud sait ainsi vers quelle machine envoyer le trafic destiné à un Pod distant.

Entre deux nœuds, le trafic des Pods est encapsulé dans un tunnel IP-in-IP, porté par l'interface `tunl0`.

```text
        kube-control                         kube-worker
       192.168.57.10                        192.168.57.11
             |                                    |
   bloc 10.244.222.0/26                 bloc 10.244.73.128/26
             |                                    |
           tunl0  <======= tunnel IP-in-IP =====>  tunl0
                     sur le réseau privé
                      192.168.57.0/24
```

Les valeurs de ce schéma sont celles relevées sur le cluster, détaillées en section 7.

---

## 5. Installation

### 5.1 Mode d'installation

Calico peut s'installer de deux façons : par un opérateur, ou par un fichier de définition unique.

Le laboratoire utilise le **fichier de définition unique**. Ce mode crée toutes les ressources directement dans le namespace `kube-system`.

### 5.2 Variables

La version et l'emplacement du fichier sont déclarés dans `lab-local/ansible/group_vars/control_plane.yml` :

```yaml
calico_version: "v3.30.3"
calico_manifest_url: "https://raw.githubusercontent.com/projectcalico/calico/{{ calico_version }}/manifests/calico.yaml"
calico_manifest_path: "/etc/kubernetes/calico-{{ calico_version }}.yaml"
```

La version n'est écrite qu'une fois. L'adresse de téléchargement et le nom du fichier local en sont déduits. Changer de version revient à modifier une seule ligne.

### 5.3 Tâches

Le rôle comporte cinq tâches, dans `lab-local/ansible/roles/calico/tasks/main.yml`.

**Téléchargement du fichier de définition.**

```yaml
- name: Télécharger le fichier de définition de Calico
  ansible.builtin.get_url:
    url: "{{ calico_manifest_url }}"
    dest: "{{ calico_manifest_path }}"
    owner: root
    group: root
    mode: '0644'
```

Le fichier est conservé sur le Control Plane plutôt qu'appliqué directement depuis Internet. Il reste ainsi consultable, et les tâches suivantes travaillent sur une copie connue.

**Comparaison avec l'état du cluster.**

```yaml
- name: Comparer le fichier de définition de Calico avec l'état du cluster
  ansible.builtin.command:
    cmd: "kubectl diff -f {{ calico_manifest_path }}"
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  register: calico_diff
  changed_when: false
  failed_when: calico_diff.rc > 1
```

`kubectl diff` compare le fichier avec ce qui existe dans le cluster, sans rien modifier. Son code de retour indique le résultat :

| Code de retour  | Signification            | Effet dans le rôle                                  |
| --------------- | ------------------------ | --------------------------------------------------- |
| `0`             | Aucune différence        | La tâche d'application est ignorée                  |
| `1`             | Des différences existent | La tâche d'application s'exécute                    |
| supérieur à `1` | Erreur de `kubectl`      | La tâche échoue                                     |

Par défaut, Ansible traite tout code de retour non nul comme un échec. La ligne `failed_when: calico_diff.rc > 1` lui indique que le code `1` est ici un résultat normal.

La ligne `changed_when: false` signale que cette tâche ne modifie jamais rien.

**Application.**

```yaml
- name: Appliquer le fichier de définition de Calico
  ansible.builtin.command:
    cmd: "kubectl apply -f {{ calico_manifest_path }}"
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  when: calico_diff.rc == 1
```

`kubectl apply` crée dans le cluster les ressources décrites par le fichier. La tâche ne s'exécute que si la comparaison a signalé une différence.

La raison pour laquelle l'idempotence repose sur `kubectl diff`, et non sur la sortie de `kubectl apply`, est expliquée dans `13-troubleshooting.md` (problème 14).

**Attente de la disponibilité du réseau.**

```yaml
- name: Attendre que calico-node soit prêt
  ansible.builtin.command:
    cmd: kubectl -n kube-system rollout status daemonset/calico-node --timeout=600s
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  changed_when: false

- name: Attendre que le nœud soit Ready
  ansible.builtin.command:
    cmd: "kubectl wait --for=condition=Ready node/{{ inventory_hostname }} --timeout=600s"
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  changed_when: false
```

`kubectl apply` rend la main dès que les ressources sont enregistrées, bien avant que les Pods ne soient en fonctionnement. Ces deux tâches bloquent le playbook jusqu'à ce que le réseau soit réellement disponible.

Cette attente est nécessaire à la suite : sans elle, le play suivant ferait rejoindre le Worker à un cluster dont le réseau n'est pas encore en place.

### 5.4 Variable KUBECONFIG

Les tâches s'exécutent avec les privilèges administrateur. L'utilisateur `root` ne dispose pas de configuration `kubectl`. La variable d'environnement `KUBECONFIG` lui désigne celle créée par `kubeadm init`.

### 5.5 Ressources créées

| Ressource                 | Type       | Rôle                                                              |
| ------------------------- | ---------- | ----------------------------------------------------------------- |
| `calico-node`             | DaemonSet  | Un Pod par nœud : configure le réseau des Pods et annonce les routes |
| `calico-kube-controllers` | Deployment | Synchronise l'état de Calico avec celui du cluster                |

Un DaemonSet garantit la présence d'un Pod sur chaque nœud. Un nœud qui rejoint le cluster reçoit donc automatiquement son Pod `calico-node`.

L'installation a été réalisée par Ansible le **9 octobre 2026 à 20:16 UTC**, quelques secondes après l'initialisation du Control Plane.

---

## 6. Vérification de l'installation

Les résultats de cette section et de la suivante ont été vérifiés le **9 octobre 2026 à 20:26 UTC**, sur le cluster reconstruit, après la jonction du Worker.

### 6.1 Composants déployés

```bash
kubectl -n kube-system get daemonset,deployment
```

Cette commande liste les DaemonSets et les Deployments du namespace système, avec le nombre de Pods attendus et prêts.

Résultat vérifié, présenté sous forme résumée :

| Ressource                            | Pods attendus | Pods prêts |
| ------------------------------------ | ------------- | ---------- |
| DaemonSet `calico-node`              | 2             | 2          |
| DaemonSet `kube-proxy`               | 2             | 2          |
| Deployment `calico-kube-controllers` | 1             | 1          |
| Deployment `coredns`                 | 2             | 2          |

### 6.2 Pods Calico

```bash
kubectl get pods -n kube-system -o wide | grep calico
```

Cette commande affiche les Pods Calico avec leur adresse et le nœud qui les héberge.

Résultat vérifié :

```text
calico-kube-controllers-7d598bd8b5-8x8fd   1/1   Running   0   10.244.222.3    kube-control
calico-node-gb2lm                          1/1   Running   0   192.168.57.10   kube-control
calico-node-vnwhp                          1/1   Running   0   192.168.57.11   kube-worker
```

Les Pods `calico-node` portent l'adresse de leur nœud, car ils utilisent directement le réseau de la machine. Le Pod `calico-kube-controllers` porte une adresse de la plage des Pods.

### 6.3 Namespace des composants

Avec le mode d'installation retenu, les composants se trouvent dans `kube-system`. Le namespace `calico-system` n'existe que lorsque Calico est installé par l'opérateur.

```bash
kubectl get namespaces
```

Résultat vérifié :

```text
default
kube-node-lease
kube-public
kube-system
```

### 6.4 Effet sur le nœud et sur CoreDNS

L'installation du plugin réseau doit faire passer le nœud à l'état `Ready` et les Pods CoreDNS à l'état `Running`.

```bash
kubectl get nodes
kubectl get pods -n kube-system -o wide | grep coredns
```

Résultat vérifié :

```text
kube-control   Ready    control-plane   v1.36.5
kube-worker    Ready    <none>          v1.36.5
```

```text
coredns-589f44dc88-6n5cw   1/1   Running   0   10.244.222.2   kube-control
coredns-589f44dc88-gk6l2   1/1   Running   0   10.244.222.1   kube-control
```

Les deux Pods CoreDNS ont reçu une adresse prise dans la plage des Pods.

### 6.5 Idempotence

Une seconde exécution du playbook ne doit pas réappliquer le fichier de définition.

Résultat vérifié :

```text
TASK [calico : Télécharger le fichier de définition de Calico]                      ok
TASK [calico : Comparer le fichier de définition de Calico avec l'état du cluster]  ok
TASK [calico : Appliquer le fichier de définition de Calico]                        skipping
TASK [calico : Attendre que calico-node soit prêt]                                  ok
TASK [calico : Attendre que le nœud soit Ready]                                     ok
```

La comparaison ne détecte aucune différence, donc l'application est ignorée.

La comparaison peut aussi être lancée à la main sur le Control Plane :

```bash
kubectl diff -f /etc/kubernetes/calico-v3.30.3.yaml
echo $?
```

La seconde commande affiche le code de retour de la première.

Résultat vérifié : aucune sortie, et un code de retour égal à `0`.

---

## 7. Configuration obtenue

Aucun paramètre n'a été modifié dans le fichier de définition. Cette section décrit la configuration que Calico a retenue par défaut dans ce cluster.

### 7.1 Plage et encapsulation

```bash
kubectl get ippools.crd.projectcalico.org -o yaml
```

Cette commande affiche les plages d'adresses gérées par Calico.

Résultat vérifié :

| Paramètre     | Valeur                | Signification                                                        |
| ------------- | --------------------- | -------------------------------------------------------------------- |
| Nom           | `default-ipv4-ippool` | Plage créée automatiquement à l'installation                         |
| `cidr`        | `10.244.0.0/16`       | Plage des Pods                                                       |
| `blockSize`   | `26`                  | Blocs de 64 adresses attribués aux nœuds                             |
| `ipipMode`    | `Always`              | Trafic entre nœuds toujours encapsulé en IP-in-IP                    |
| `vxlanMode`   | `Never`               | Encapsulation VXLAN non utilisée                                     |
| `natOutgoing` | `true`                | Les Pods sortent vers l'extérieur avec l'adresse de leur nœud        |

La plage `10.244.0.0/16` n'a pas été indiquée à Calico. Il a repris la valeur `podSubnet` déclarée à `kubeadm`, ce qui garantit la cohérence entre les deux.

### 7.2 Bloc attribué à chaque nœud

```bash
kubectl get blockaffinities.crd.projectcalico.org \
  -o jsonpath='{range .items[*]}{.spec.node} {.spec.cidr}{"\n"}{end}'
```

Cette commande affiche le bloc d'adresses réservé à chaque nœud. L'option `-o jsonpath` limite l'affichage au nom du nœud et à son bloc.

Résultat vérifié :

| Nœud           | Bloc               |
| -------------- | ------------------ |
| `kube-control` | `10.244.222.0/26`  |
| `kube-worker`  | `10.244.73.128/26` |

Ces deux blocs sont identiques à ceux attribués lors de la première construction, le 8 octobre 2026.

### 7.3 Adresse utilisée par Calico sur chaque nœud

Chaque machine possède deux interfaces. Calico doit utiliser celle du réseau privé pour échanger avec les autres nœuds, et non l'interface NAT.

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,ADRESSE_CALICO:.metadata.annotations.projectcalico\.org/IPv4Address,ADRESSE_NOEUD:.status.addresses[0].address'
```

Cette commande compare, pour chaque nœud, l'adresse retenue par Calico et l'adresse sous laquelle le nœud est enregistré dans le cluster.

Résultat vérifié :

```text
NAME           ADRESSE_CALICO     ADRESSE_NOEUD
kube-control   192.168.57.10/24   192.168.57.10
kube-worker    192.168.57.11/24   192.168.57.11
```

Calico utilise bien le réseau privé sur les deux nœuds.

Cette adresse est choisie par détection automatique : le fichier de définition contient `IP=autodetect`, sans méthode de détection précisée. Le résultat a été identique lors des deux constructions du cluster, mais il n'est pas imposé par la configuration.

### 7.4 Routes entre les nœuds

```bash
ip route | grep -E "tunl0|blackhole"
```

Cette commande affiche, sur un nœud, les routes installées par Calico.

Résultat vérifié sur `kube-control` :

```text
10.244.73.128/26 via 192.168.57.11 dev tunl0 proto bird onlink
blackhole 10.244.222.0/26 proto bird
```

Résultat vérifié sur `kube-worker` :

```text
blackhole 10.244.73.128/26 proto bird
10.244.222.0/26 via 192.168.57.10 dev tunl0 proto bird onlink
```

Chaque nœud connaît le bloc de l'autre et l'atteint par le tunnel, à travers l'adresse du réseau privé. La mention `proto bird` indique que la route a été apprise par BGP.

La route `blackhole` concerne le bloc du nœud lui-même : elle écarte le trafic destiné à une adresse du bloc qui n'est attribuée à aucun Pod.

---

## 8. Validation fonctionnelle

Les vérifications précédentes montrent que Calico est installé et configuré. Elles ne prouvent pas qu'un Pod peut réellement en joindre un autre.

La validation fonctionnelle du réseau des Pods demande au moins deux nœuds. Elle est décrite dans `12-worker.md` :

* communication entre deux Pods situés sur des nœuds différents ;
* accès à un Pod à travers un Service ;
* résolution d'un nom de Service par le DNS du cluster.

---

## 9. Principes appliqués

* **Une version explicite.** Le rôle installe la version `v3.30.3` et non la dernière version disponible. Le laboratoire reste reproductible.
* **Une plage unique.** La plage des Pods est définie une seule fois, dans la configuration `kubeadm`. Calico la reprend au lieu de la redéfinir.
* **Comparer avant d'appliquer.** L'application n'a lieu que si le cluster diffère du fichier de définition.
* **Attendre l'état réel.** Le rôle ne se termine que lorsque le réseau est disponible, et non lorsque la commande d'installation a rendu la main.
* **Vérifier la configuration obtenue.** Aucun paramètre n'ayant été fourni à Calico, les valeurs par défaut ont été relevées sur le cluster plutôt que supposées.
* **Vérifier l'interface utilisée.** Sur des machines à deux interfaces, l'adresse retenue par Calico a été contrôlée sur chaque nœud.

---

## 10. État et limites

### 10.1 État validé

| Élément                                           | État au 9 octobre 2026 |
| ------------------------------------------------- | ---------------------- |
| Calico `v3.30.3` installé par Ansible             | ✅                      |
| Un Pod `calico-node` prêt sur chaque nœud         | ✅                      |
| `calico-kube-controllers` prêt                    | ✅                      |
| Plage des Pods cohérente avec `kubeadm`           | ✅                      |
| Calico utilise le réseau privé sur les deux nœuds | ✅                      |
| Routes entre les blocs des deux nœuds             | ✅                      |
| CoreDNS en exécution                              | ✅                      |
| Rôle idempotent                                   | ✅                      |
| Validé par reconstruction complète                | ✅ — voir `06-roles.md` |

### 10.2 Limites connues

| Limite                                                                                       | Conséquence                                                                        |
| -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| L'adresse utilisée par Calico repose sur la détection automatique                            | Sur une autre machine, Calico pourrait retenir l'interface NAT                     |
| La compatibilité de Calico `v3.30.3` avec Kubernetes `v1.36.5` n'a pas été vérifiée dans la documentation de Calico | Le fonctionnement est constaté dans ce laboratoire, mais n'est pas garanti par l'éditeur |
| Le fichier de définition est téléchargé depuis Internet à chaque reconstruction               | La reconstruction échoue si l'adresse de téléchargement est indisponible           |
| Aucune NetworkPolicy n'est définie                                                           | Tous les Pods peuvent communiquer entre eux                                        |

---

## 11. Documentation associée

| Fichier                 | Lien avec ce document                                   |
| ----------------------- | ------------------------------------------------------- |
| `01-architecture.md`    | Réseaux des machines                                    |
| `06-roles.md`           | Organisation des rôles, ordre des plays                 |
| `10-control-plane.md`   | Plage des Pods, adresse du nœud                         |
| `12-worker.md`          | Validation fonctionnelle du réseau entre deux nœuds     |
| `13-troubleshooting.md` | Fausse détection de changement par `kubectl apply` (problème 14) |

---

## 12. Étape suivante

Le réseau des Pods est disponible sur le Control Plane, mais un seul nœud ne permet pas de vérifier la communication entre nœuds.

La prochaine étape consiste à faire rejoindre le cluster au Worker.

Elle est documentée dans `12-worker.md`.
