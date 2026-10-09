# 12 — Jonction et validation du Worker

## 1. Objectif

Ce document décrit l'intégration du nœud `kube-worker` au cluster Kubernetes initialisé sur `kube-control`, puis la validation du cluster à deux nœuds.

Il couvre :

* la configuration de l'adresse du nœud avant la jonction ;
* la génération de la commande de jonction ;
* la jonction avec `kubeadm join` ;
* la validation du nœud ;
* la validation fonctionnelle du réseau entre les deux nœuds.

Les sujets suivants sont traités dans des documents séparés :

* la préparation système et l'installation des composants, dans `07-kubernetes-prerequisites.md`, `08-containerd.md` et `09-kubernetes.md` ;
* l'initialisation du Control Plane, dans `10-control-plane.md` ;
* le plugin réseau, dans `11-calico.md` ;
* les incidents rencontrés, dans `13-troubleshooting.md`.

---

## 2. Pourquoi cette étape ?

À l'issue de `11-calico.md`, le cluster ne comporte qu'un nœud, le Control Plane. Celui-ci porte une restriction qui empêche d'y planifier les Pods applicatifs :

```text
node-role.kubernetes.io/control-plane:NoSchedule
```

Les applications ont donc besoin d'un nœud de travail. Dans le laboratoire, ce rôle revient à `kube-worker`, qui dispose de davantage de mémoire, comme indiqué dans `01-architecture.md`.

Un second nœud est aussi nécessaire pour vérifier que le réseau des Pods fonctionne **entre** les nœuds, ce qu'un cluster à un seul nœud ne permet pas de tester.

---

## 3. Prérequis

| Prérequis                                              | Document de référence            |
| ------------------------------------------------------ | -------------------------------- |
| Swap désactivé, modules et `sysctl` configurés         | `07-kubernetes-prerequisites.md` |
| `containerd` actif                                     | `08-containerd.md`               |
| `kubeadm`, `kubelet`, `kubectl` et `crictl` installés  | `09-kubernetes.md`               |
| Control Plane initialisé                               | `10-control-plane.md`            |
| Plugin réseau installé                                 | `11-calico.md`                   |

Ces prérequis sont appliqués aux deux machines par le même playbook Ansible. Le Worker est donc préparé de la même manière que le Control Plane.

Les commandes de ce document sont exécutées soit sur `kube-worker`, soit sur `kube-control`. La machine concernée est précisée à chaque fois.

La connexion au Worker depuis WSL2 s'effectue avec :

```bash
ssh -i ~/.ssh/vagrant/kube-worker vagrant@192.168.57.11
```

---

## 4. Adresse du nœud

### 4.1 Pourquoi la fixer avant la jonction ?

Le Worker possède les deux mêmes interfaces que le Control Plane, et sa route par défaut passe elle aussi par l'interface NAT.

Lors de l'initialisation du Control Plane, l'adresse du nœud n'avait pas été fixée et `kubelet` avait retenu l'adresse NAT. Cet incident est décrit dans `13-troubleshooting.md` (problème 9).

Pour le Worker, l'adresse a donc été fixée **avant** la jonction. Le nœud s'enregistre ainsi directement avec la bonne adresse.

### 4.2 Configuration

Sur `kube-worker` :

```bash
sudo tee /etc/default/kubelet <<'EOF'
KUBELET_EXTRA_ARGS=--node-ip=192.168.57.11
EOF
```

Cette commande écrit dans le fichier lu par `kubelet` l'option qui lui impose l'adresse du réseau privé. La commande `tee` est utilisée avec `sudo`, car le fichier appartient à `root`.

Le rôle de ce fichier et de l'option `--node-ip` est expliqué dans `10-control-plane.md` (section 4).

Cette configuration a été réalisée le 8 octobre 2026 à 20:05 UTC, avant la jonction.

### 4.3 État de kubelet avant la jonction

Avant la jonction, le service `kubelet` n'est pas actif de façon stable. Cet état est normal : `kubelet` ne dispose pas encore de la configuration que `kubeadm join` lui fournira.

---

## 5. Vérification du runtime avant la jonction

`kubeadm join` s'appuie sur le runtime de conteneurs. Son état a été contrôlé sur `kube-worker` avec `crictl`, l'outil de diagnostic du runtime installé par le rôle `kubernetes`.

```bash
sudo crictl info | grep -E 'RuntimeReady|NetworkReady'
```

Cette commande interroge `containerd` à travers l'interface CRI, comme le fait `kubelet`, et affiche les deux conditions qui indiquent si le runtime et le réseau sont prêts.

Résultat vérifié le 8 octobre 2026, après la jonction : les deux conditions `RuntimeReady` et `NetworkReady` sont présentes.

Avant l'installation du plugin réseau sur un nœud, la condition `NetworkReady` n'est pas satisfaite. Elle le devient lorsque le Pod `calico-node` du nœud est en exécution.

---

## 6. Génération de la commande de jonction

Sur `kube-control` :

```bash
kubeadm token create --print-join-command
```

Cette commande crée un nouveau jeton et affiche la commande `kubeadm join` complète à exécuter sur le nœud à intégrer.

La commande produite a la forme suivante :

```bash
kubeadm join 192.168.57.10:6443 \
  --token <JETON> \
  --discovery-token-ca-cert-hash sha256:<EMPREINTE>
```

| Élément                          | Rôle                                                                 |
| -------------------------------- | -------------------------------------------------------------------- |
| `192.168.57.10:6443`             | Adresse de l'API du cluster, sur le réseau privé                     |
| `--token`                        | Jeton qui autorise le nœud à demander son intégration                |
| `--discovery-token-ca-cert-hash` | Empreinte qui permet au nœud de vérifier l'identité du Control Plane |

Le jeton donne le droit de rejoindre le cluster. Il n'est reproduit ni dans la documentation ni dans le dépôt.

Un jeton expire au bout de 24 heures. Les jetons existants peuvent être listés avec :

```bash
sudo kubeadm token list
```

Résultat vérifié le 8 octobre 2026 : trois jetons sont actifs, le dernier expirant le 9 octobre à 20:47 UTC. Passé ce délai, un nouveau jeton devra être créé pour intégrer un autre nœud.

---

## 7. Jonction

Sur `kube-worker`, la commande générée est exécutée avec les privilèges administrateur :

```bash
sudo kubeadm join 192.168.57.10:6443 --token <JETON> --discovery-token-ca-cert-hash sha256:<EMPREINTE>
```

Cette commande :

1. effectue les vérifications préalables du système ;
2. contacte l'API et vérifie l'identité du Control Plane avec l'empreinte ;
3. récupère la configuration du cluster ;
4. écrit la configuration de `kubelet` dans `/etc/kubernetes` ;
5. démarre `kubelet`, qui enregistre le nœud auprès du cluster.

Les privilèges administrateur sont nécessaires, car la commande écrit dans `/etc/kubernetes` et configure un service système. Une première tentative sans `sudo` a échoué ; elle est décrite dans `13-troubleshooting.md` (problème 10).

Résultat obtenu :

```text
This node has joined the cluster
```

Un avertissement relatif à `kube-proxy` a été affiché pendant la jonction. Il est analysé dans `13-troubleshooting.md` (problème 11).

La jonction a été réalisée le 8 octobre 2026 à 20:53 UTC.

---

## 8. Vérification du nœud

Les vérifications suivantes ont été relevées le 8 octobre 2026 à 21:29 UTC.

### 8.1 Présence, état et adresse

Sur `kube-control` :

```bash
kubectl get nodes -o wide
```

Cette commande liste les nœuds du cluster avec leur état, leur adresse interne et leur runtime.

Résultat vérifié :

```text
NAME           STATUS   ROLES           AGE     VERSION   INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
kube-control   Ready    control-plane   6h16m   v1.36.5   192.168.57.10   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic (amd64)   containerd://2.2.1
kube-worker    Ready    <none>          36m     v1.36.5   192.168.57.11   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic (amd64)   containerd://2.2.1
```

Ce résultat valide quatre points :

* le Worker est présent dans le cluster ;
* son état est `Ready` ;
* il est enregistré avec l'adresse du réseau privé `192.168.57.11` ;
* il utilise la même version de Kubernetes et le même runtime que le Control Plane.

La colonne `ROLES` affiche `<none>` pour le Worker. C'est le comportement normal : `kubeadm` n'attribue un libellé de rôle qu'au Control Plane.

### 8.2 Prise en compte de l'option kubelet

Sur `kube-worker` :

```bash
ps -o args= -C kubelet | tr " " "\n" | grep node-ip
```

Cette commande vérifie l'option sur le processus `kubelet` en cours d'exécution, et non dans le fichier.

Résultat vérifié :

```text
--node-ip=192.168.57.11
```

### 8.3 Composants système du Worker

Deux DaemonSets doivent avoir déployé un Pod sur le nouveau nœud : `kube-proxy` et `calico-node`.

Sur `kube-control` :

```bash
kubectl get pods -n kube-system -o wide | grep kube-worker
```

Cette commande n'affiche que les Pods système hébergés sur le Worker.

Résultat vérifié :

```text
calico-node-bjnhw   1/1   Running   0   192.168.57.11   kube-worker
kube-proxy-jn6wl    1/1   Running   0   192.168.57.11   kube-worker
```

La configuration réseau obtenue sur le Worker (bloc d'adresses, routes, adresse utilisée par Calico) est détaillée dans `11-calico.md` (section 7).

---

## 9. Validation fonctionnelle du réseau

Les vérifications précédentes montrent que le Worker est intégré. Elles ne prouvent pas qu'un Pod peut en joindre un autre.

Une validation fonctionnelle a donc été réalisée dans un namespace temporaire `network-test`, avec des Pods Nginx.

Les résultats de cette section ont été relevés pendant l'intervention. Les ressources de test ayant été supprimées ensuite, ils n'ont pas été rejoués lors de la relecture de ce document.

### 9.1 Communication entre Pods de nœuds différents

Un Pod a été placé sur chaque nœud :

| Pod                     | Nœud           | Adresse         |
| ----------------------- | -------------- | --------------- |
| `network-test-control`  | `kube-control` | `10.244.222.4`  |
| Pod Nginx               | `kube-worker`  | `10.244.73.129` |

Chaque adresse appartient au bloc de son nœud, indiqué dans `11-calico.md`.

Une requête HTTP émise depuis le Pod du Control Plane vers l'adresse du Pod du Worker a retourné la page d'accueil de Nginx.

```text
Pod sur kube-control          Pod sur kube-worker
    10.244.222.4      HTTP        10.244.73.129
         |----------------------------->|
         |<-------- page Nginx ---------|
```

Le réseau des Pods fonctionne donc entre les deux nœuds.

### 9.2 Accès par un Service

Un Service de type `ClusterIP` a été créé devant le Pod Nginx du Worker :

```text
network-test-service   ClusterIP   10.103.159.18
```

L'adresse du Service appartient à la plage des Services définie dans `10-control-plane.md`.

Depuis le Pod du Control Plane :

```bash
kubectl exec -n network-test network-test-control -- \
  wget -qO- http://network-test-service
```

Cette commande exécute, à l'intérieur du Pod, une requête HTTP vers le nom du Service.

Résultat obtenu : la page d'accueil de Nginx.

```text
Pod  →  Service ClusterIP  →  Pod du Worker
```

Ce test valide la traduction d'adresse réalisée par `kube-proxy`.

### 9.3 Résolution DNS

Le service DNS du cluster est exposé par le Service `kube-dns` :

```bash
kubectl get svc -n kube-system kube-dns
```

```text
NAME       TYPE        CLUSTER-IP
kube-dns   ClusterIP   10.96.0.10
```

Depuis le Pod du Control Plane :

```bash
kubectl exec -n network-test network-test-control -- \
  nslookup network-test-service
```

Cette commande demande au DNS du cluster de résoudre le nom du Service.

Résultat obtenu :

```text
Server:   10.96.0.10

Name:     network-test-service.network-test.svc.cluster.local
Address:  10.103.159.18
```

CoreDNS résout donc le nom du Service vers son adresse.

La commande `nslookup` affiche aussi des réponses `NXDOMAIN`. Elles correspondent aux autres suffixes de recherche que le résolveur essaie automatiquement, et ne remettent pas en cause la résolution réussie.

### 9.4 Nettoyage

Les ressources de test ont été supprimées :

```bash
kubectl delete namespace network-test
```

Cette commande supprime le namespace et toutes les ressources qu'il contient.

Résultat vérifié le 8 octobre 2026 à 21:29 UTC : le namespace `network-test` n'existe plus dans le cluster.

---

## 10. Principes appliqués

* **Tirer parti d'un incident précédent.** L'adresse du nœud a été fixée avant la jonction, parce que son absence avait posé problème sur le Control Plane.
* **Distinguer intégration et fonctionnement.** Un nœud `Ready` ne prouve pas que le réseau fonctionne. Trois tests fonctionnels ont été réalisés : Pod à Pod, Service, DNS.
* **Tester entre les nœuds.** Les Pods de test ont été placés sur deux nœuds différents, afin d'éprouver le tunnel entre les machines et non le réseau local d'un seul nœud.
* **Nettoyer après les tests.** Les ressources temporaires ont été supprimées pour ne pas laisser d'état inutile dans le cluster.
* **Aucun secret dans la documentation.** Le jeton et l'empreinte sont remplacés par des textes de substitution.
* **Analyser un avertissement avant d'agir.** L'avertissement affiché pendant la jonction n'a entraîné aucune modification, faute de dysfonctionnement observé.

---

## 11. État et limites

### 11.1 État validé

| Élément                                      | État au 8 octobre 2026 | Nature de la validation       |
| -------------------------------------------- | ---------------------- | ----------------------------- |
| Worker présent dans le cluster               | ✅                      | Vérifié sur le cluster        |
| Worker `Ready`                               | ✅                      | Vérifié sur le cluster        |
| Adresse `192.168.57.11` enregistrée          | ✅                      | Vérifié sur le cluster        |
| Kubernetes `v1.36.5`, `containerd` `2.2.1`   | ✅                      | Vérifié sur le cluster        |
| `calico-node` et `kube-proxy` sur le Worker  | ✅                      | Vérifié sur le cluster        |
| Pod à Pod entre nœuds                        | ✅                      | Relevé pendant l'intervention |
| Pod vers Service                             | ✅                      | Relevé pendant l'intervention |
| Résolution DNS                               | ✅                      | Relevé pendant l'intervention |

### 11.2 Limites connues

| Limite                                                                                   | Conséquence                                                              |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| L'option `--node-ip` est écrite à la main sur chaque nœud                                | Elle doit être refaite après une reconstruction des machines             |
| La jonction est réalisée à la main, contrairement aux étapes 07 à 09 automatisées avec Ansible | La reconstruction du cluster n'est pas entièrement automatisée     |
| Les tests fonctionnels ne sont pas conservés sous forme de fichiers dans le dépôt        | Ils doivent être réécrits pour être rejoués                              |
| Le cluster ne comporte qu'un seul Worker                                                 | L'arrêt de ce nœud interrompt toutes les applications                    |

---

## 12. Documentation associée

| Fichier                 | Lien avec ce document                                              |
| ----------------------- | ------------------------------------------------------------------ |
| `01-architecture.md`    | Machines, adresses et réseaux                                      |
| `09-kubernetes.md`      | Installation de `kubeadm`, `kubelet`, `kubectl` et `crictl`        |
| `10-control-plane.md`   | Adresse de l'API, option `--node-ip`, plages des Pods et Services  |
| `11-calico.md`          | Configuration réseau obtenue sur chaque nœud                       |
| `13-troubleshooting.md` | Jonction sans privilèges et avertissement `kube-proxy` (problèmes 10 et 11) |

---

## 13. Étape suivante

Le laboratoire local dispose maintenant d'un cluster Kubernetes fonctionnel à deux nœuds :

```text
                 Cluster Kubernetes
                        |
          +-------------+-------------+
          |                           |
    kube-control                 kube-worker
    Control Plane                  Worker
    192.168.57.10               192.168.57.11
          |                           |
          +---------- Calico ---------+
                 10.244.0.0/16
```

La construction du laboratoire local est terminée. Les documents de `01` à `12` permettent de le reproduire, et `13-troubleshooting.md` consigne les problèmes rencontrés.

La suite du projet consiste à déployer l'application eShop sur ce cluster. Elle fera l'objet d'une nouvelle série de documents.
