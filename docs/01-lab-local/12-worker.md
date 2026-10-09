# 12 — Jonction et validation du Worker

## 1. Objectif

Ce document décrit l'intégration du nœud `kube-worker` au cluster Kubernetes initialisé sur `kube-control`, puis la validation du cluster à deux nœuds.

La jonction est automatisée par le rôle Ansible `worker`.

Il couvre :

* la génération de la commande de jonction ;
* la jonction avec `kubeadm join` ;
* la validation du nœud ;
* la validation fonctionnelle du réseau entre les deux nœuds.

Les sujets suivants sont traités dans des documents séparés :

* la préparation système et l'installation des composants, dans `07-kubernetes-prerequisites.md`, `08-containerd.md` et `09-kubernetes.md` ;
* l'adresse du nœud imposée à `kubelet`, dans `09-kubernetes.md` (section 6.3) ;
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
| Adresse du nœud imposée à `kubelet`                    | `09-kubernetes.md` (section 6.3) |
| Control Plane initialisé                               | `10-control-plane.md`            |
| Plugin réseau installé et disponible                   | `11-calico.md`                   |

Les quatre premiers prérequis sont appliqués aux deux machines par le premier play de `site.yml`. Le Worker est donc préparé exactement comme le Control Plane.

Les deux derniers sont réalisés par le second play. Le rôle `worker` appartient au troisième : il ne s'exécute que lorsque le cluster et son réseau sont prêts.

### Adresse du nœud

Le Worker possède les deux mêmes interfaces que le Control Plane, et sa route par défaut passe elle aussi par l'interface NAT. Son adresse doit donc être imposée à `kubelet` avant la jonction, sans quoi il s'enregistrerait avec son adresse NAT.

Cette configuration n'est pas propre au Worker : elle est appliquée à tous les nœuds par le rôle `kubernetes`. Le rôle `worker` ne s'en occupe pas.

---

## 4. Principe de la jonction

La jonction fait intervenir les deux machines :

```text
        kube-control                              kube-worker
             |                                         |
  1. crée un jeton et produit                          |
     la commande de jonction                           |
             |                                         |
             +------- commande de jonction ----------->|
                                                       |
                                          2. exécute kubeadm join
                                                       |
             |<-------- demande d'intégration ---------+
             |                                         |
  3. enregistre le nœud                                |
```

La commande de jonction a la forme suivante :

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

Le jeton donne le droit de rejoindre le cluster. Il n'est reproduit ni dans la documentation, ni dans le dépôt, ni dans la sortie d'Ansible.

---

## 5. Mise en œuvre

Le rôle `worker` comporte quatre tâches, dans `lab-local/ansible/roles/worker/tasks/main.yml`.

Le rôle s'exécute dans un play qui cible le Worker. Deux de ses tâches doivent pourtant s'exécuter sur le Control Plane : elles utilisent pour cela la délégation, expliquée en section 5.5.

### 5.1 Le nœud a-t-il déjà rejoint le cluster ?

```yaml
- name: Vérifier si le nœud a déjà rejoint le cluster
  ansible.builtin.stat:
    path: /etc/kubernetes/kubelet.conf
  register: kubelet_conf
```

Le module `stat` examine un fichier sans le modifier. Le fichier `/etc/kubernetes/kubelet.conf` est créé par `kubeadm join` : sa présence indique que le nœud fait déjà partie d'un cluster.

Le résultat est conservé dans la variable `kubelet_conf` et sert de garde aux deux tâches suivantes.

### 5.2 Génération de la commande de jonction

```yaml
- name: Générer la commande de jonction sur le Control Plane
  ansible.builtin.command:
    cmd: kubeadm token create --ttl 10m --print-join-command
  delegate_to: "{{ groups['control_plane'][0] }}"
  register: join_command
  when: not kubelet_conf.stat.exists
  changed_when: true
  no_log: true
```

La commande `kubeadm token create --print-join-command` crée un nouveau jeton et affiche la commande `kubeadm join` complète.

| Paramètre                           | Effet                                                                 |
| ----------------------------------- | --------------------------------------------------------------------- |
| `--ttl 10m`                         | Le jeton expire au bout de dix minutes, au lieu de 24 heures par défaut |
| `delegate_to`                       | La tâche s'exécute sur le Control Plane                               |
| `register: join_command`            | La commande produite est conservée pour la tâche suivante             |
| `when: not kubelet_conf.stat.exists` | Aucun jeton n'est créé si le nœud a déjà rejoint le cluster          |
| `changed_when: true`                | La tâche est comptée comme un changement, puisqu'elle crée un jeton   |
| `no_log: true`                      | Ansible n'affiche ni la commande ni son résultat                      |

Le jeton sert une seule fois, immédiatement. Une durée de vie de dix minutes limite la période pendant laquelle il pourrait être réutilisé.

### 5.3 Jonction

```yaml
- name: Rejoindre le cluster
  ansible.builtin.command:
    cmd: "{{ join_command.stdout }}"
    creates: /etc/kubernetes/kubelet.conf
  when: not kubelet_conf.stat.exists
  no_log: true
```

Cette tâche exécute sur le Worker la commande produite par la tâche précédente. Elle :

1. effectue les vérifications préalables du système ;
2. contacte l'API et vérifie l'identité du Control Plane avec l'empreinte ;
3. récupère la configuration du cluster ;
4. écrit la configuration de `kubelet` dans `/etc/kubernetes` ;
5. démarre `kubelet`, qui enregistre le nœud auprès du cluster.

La commande s'exécute avec les privilèges administrateur, demandés par le play. Lancée à la main sans `sudo`, elle échoue : ce cas est décrit dans `13-troubleshooting.md` (problème 10).

La tâche est protégée deux fois : par la condition `when`, et par `creates`, qui empêche la commande de s'exécuter si le fichier existe.

### 5.4 Attente de la disponibilité du nœud

```yaml
- name: Attendre que le nœud soit Ready
  ansible.builtin.command:
    cmd: "kubectl wait --for=condition=Ready node/{{ inventory_hostname }} --timeout=600s"
  delegate_to: "{{ groups['control_plane'][0] }}"
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  changed_when: false
```

Un nœud qui vient de rejoindre le cluster n'est pas immédiatement utilisable : le plugin réseau doit d'abord y être déployé. Cette tâche bloque le playbook jusqu'à ce que le nœud soit à l'état `Ready`.

Elle est déléguée au Control Plane, seule machine où `kubectl` est configuré.

### 5.5 Délégation

Le play cible le groupe `workers`. Par défaut, toutes ses tâches s'exécutent donc sur `kube-worker`.

L'option `delegate_to` fait exécuter une tâche sur une autre machine, tout en restant dans le contexte de la machine du play. La variable `inventory_hostname` y désigne toujours `kube-worker`, ce qui permet à la tâche d'attente de surveiller le bon nœud.

```yaml
delegate_to: "{{ groups['control_plane'][0] }}"
```

Cette expression désigne la première machine du groupe `control_plane` de l'inventaire. Le nom `kube-control` n'est ainsi écrit nulle part dans le rôle.

Dans la sortie d'Ansible, une tâche déléguée se reconnaît à la flèche :

```text
ok: [kube-worker -> kube-control(192.168.57.10)]
```

### 5.6 Diagnostic d'un échec

L'option `no_log: true` masque le jeton, mais aussi le message d'erreur si la jonction échoue. Pour diagnostiquer, la jonction peut être rejouée à la main.

Sur `kube-control` :

```bash
sudo kubeadm token create --ttl 10m --print-join-command
```

Puis, sur `kube-worker`, la commande obtenue, précédée de `sudo`.

### 5.7 Exécution

Le rôle est appelé par le troisième play de `site.yml`, décrit dans `06-roles.md`.

La jonction a été réalisée par Ansible le **9 octobre 2026 à 20:17 UTC**, sur une machine recréée à neuf, moins d'une minute après l'initialisation du Control Plane.

---

## 6. Vérification du nœud

Les résultats de cette section ont été vérifiés le **9 octobre 2026 à 20:26 UTC**, sur le cluster reconstruit.

### 6.1 Présence, état et adresse

Sur `kube-control` :

```bash
kubectl get nodes -o wide
```

Cette commande liste les nœuds du cluster avec leur état, leur adresse interne et leur runtime.

Résultat vérifié :

```text
NAME           STATUS   ROLES           AGE     VERSION   INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
kube-control   Ready    control-plane   9m38s   v1.36.5   192.168.57.10   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic (amd64)   containerd://2.2.1
kube-worker    Ready    <none>          8m58s   v1.36.5   192.168.57.11   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic (amd64)   containerd://2.2.1
```

Ce résultat valide quatre points :

* le Worker est présent dans le cluster ;
* son état est `Ready` ;
* il est enregistré avec l'adresse du réseau privé `192.168.57.11` ;
* il utilise la même version de Kubernetes et le même runtime que le Control Plane.

La colonne `ROLES` affiche `<none>` pour le Worker. C'est le comportement normal : `kubeadm` n'attribue un libellé de rôle qu'au Control Plane.

### 6.2 Prise en compte de l'option kubelet

Sur `kube-worker` :

```bash
ps -o args= -C kubelet | tr " " "\n" | grep node-ip
```

Cette commande vérifie l'option sur le processus `kubelet` en cours d'exécution, et non dans le fichier.

Résultat vérifié :

```text
--node-ip=192.168.57.11
```

L'adresse NAT du Worker valait `192.168.200.141` au moment de cette vérification, alors qu'elle valait `192.168.200.130` la veille. Ce changement confirme l'intérêt d'imposer l'adresse du réseau privé.

### 6.3 Composants système du Worker

Deux DaemonSets doivent avoir déployé un Pod sur le nouveau nœud : `kube-proxy` et `calico-node`.

Sur `kube-control` :

```bash
kubectl get pods -n kube-system -o wide | grep kube-worker
```

Cette commande n'affiche que les Pods système hébergés sur le Worker.

Résultat vérifié :

```text
calico-node-vnwhp   1/1   Running   0   192.168.57.11   kube-worker
kube-proxy-7r8tt    1/1   Running   0   192.168.57.11   kube-worker
```

La configuration réseau obtenue sur le Worker (bloc d'adresses, routes, adresse utilisée par Calico) est détaillée dans `11-calico.md` (section 7).

### 6.4 Jetons

```bash
sudo kubeadm token list
```

Cette commande liste les jetons de jonction existants et leur date d'expiration.

Résultat vérifié, valeurs des jetons non reproduites :

| Jeton                              | Expiration                  |
| ---------------------------------- | --------------------------- |
| Créé par `kubeadm init`            | 10 octobre 2026 à 20:16 UTC |
| Créé par le rôle `worker`          | 9 octobre 2026 à 20:27 UTC  |

Le jeton du rôle `worker` expire bien dix minutes après sa création.

### 6.5 Idempotence

Une seconde exécution du playbook ne doit ni créer de jeton ni relancer la jonction.

Résultat vérifié :

```text
TASK [worker : Vérifier si le nœud a déjà rejoint le cluster]         ok
TASK [worker : Générer la commande de jonction sur le Control Plane]  skipping
TASK [worker : Rejoindre le cluster]                                  skipping
TASK [worker : Attendre que le nœud soit Ready]                       ok
```

L'absence de création de jeton a aussi été contrôlée directement : le nombre de jetons listés sur le Control Plane est resté identique avant et après deux exécutions du playbook.

---

## 7. Validation fonctionnelle du réseau

Les vérifications précédentes montrent que le Worker est intégré. Elles ne prouvent pas qu'un Pod peut en joindre un autre.

Trois tests fonctionnels complètent donc la validation. Ils ont été réalisés une première fois le 8 octobre 2026, puis rejoués le **9 octobre 2026 à 21:45 UTC** sur un cluster entièrement reconstruit. Les résultats de cette section sont ceux du 9 octobre.

### 7.1 Principe

Chaque test isole une couche du réseau, afin qu'un échec indique où chercher :

| Test                       | Ce qu'il emprunte                       | Ce qu'il prouve                                     |
| -------------------------- | --------------------------------------- | --------------------------------------------------- |
| Pod à Pod, par adresse     | Le tunnel Calico entre les deux nœuds   | Le réseau des Pods fonctionne entre nœuds           |
| Service, par adresse       | `kube-proxy`                            | L'adresse virtuelle du Service mène au bon Pod      |
| DNS, par nom               | CoreDNS                                 | Le nom du Service est résolu vers son adresse       |

Le test du Service se fait par adresse et non par nom. S'il utilisait le nom, un échec ne permettrait pas de savoir si la panne vient du Service ou du DNS.

### 7.2 Ressources de test

Les ressources sont décrites dans un fichier du dépôt, ce qui permet de rejouer les tests à l'identique :

```text
kubernetes/tests/network-test.yaml
```

Le fichier crée quatre ressources dans un namespace temporaire :

| Ressource              | Type      | Rôle                                                       |
| ---------------------- | --------- | ---------------------------------------------------------- |
| `network-test`         | Namespace | Isole les ressources de test et facilite leur suppression  |
| `network-test-worker`  | Pod       | Serveur Nginx, placé sur `kube-worker`                     |
| `network-test-control` | Pod       | Client, placé sur `kube-control`                           |
| `network-test-service` | Service   | Adresse virtuelle de type `ClusterIP` devant le Pod Nginx  |

Trois éléments du fichier déterminent la validité des tests.

**Le placement des Pods.**

```yaml
  nodeSelector:
    kubernetes.io/hostname: kube-worker
```

Le champ `nodeSelector` impose le nœud d'exécution d'un Pod. Sans lui, les deux Pods seraient placés sur le Worker et le réseau entre nœuds ne serait pas testé.

**L'autorisation de s'exécuter sur le Control Plane.**

```yaml
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
```

Le Control Plane refuse les Pods applicatifs, comme indiqué en section 2. Ce champ autorise le Pod client à y être placé malgré cette restriction.

**La sélection du Service.**

```yaml
  selector:
    app: network-test
```

Seul le Pod Nginx porte le label `app: network-test`. Le Service ne dirige donc le trafic que vers lui.

Les images utilisées portent une version explicite (`nginx:1.27-alpine` et `busybox:1.36`), et non l'étiquette `latest`.

### 7.3 Déploiement

Depuis WSL2, à la racine du projet :

```bash
ssh kube-control kubectl apply -f - < kubernetes/tests/network-test.yaml
```

Cette commande envoie le contenu du fichier à `kubectl` à travers la connexion SSH. Le tiret après `-f` indique à `kubectl` de lire les ressources sur son entrée standard. Le fichier reste dans le dépôt et n'est pas copié sur le nœud.

Le sens de la redirection est important : `<` envoie le fichier à la commande. Le signe `>` ferait l'inverse et écraserait le fichier.

Résultat vérifié :

```text
namespace/network-test created
pod/network-test-worker created
pod/network-test-control created
service/network-test-service created
```

Les commandes suivantes sont exécutées sur `kube-control`.

```bash
kubectl wait -n network-test --for=condition=Ready pod --all --timeout=180s
kubectl get pods -n network-test -o wide
```

La première commande attend que les Pods soient prêts, le temps que leurs images soient téléchargées. La seconde affiche leur adresse et leur nœud.

Résultat vérifié :

```text
NAME                   READY   STATUS    RESTARTS   AGE     IP              NODE
network-test-control   1/1     Running   0          2m42s   10.244.222.4    kube-control
network-test-worker    1/1     Running   0          2m42s   10.244.73.129   kube-worker
```

Chaque Pod se trouve sur le nœud prévu, et son adresse appartient au bloc de ce nœud, indiqué dans `11-calico.md`.

### 7.4 Test 1 — Pod à Pod entre nœuds

```bash
WORKER_IP=$(kubectl get pod -n network-test network-test-worker -o jsonpath='{.status.podIP}')
kubectl exec -n network-test network-test-control -- wget -qO- -T 5 http://$WORKER_IP | grep title
```

La première commande récupère l'adresse du Pod Nginx. La seconde exécute, dans le Pod client, une requête HTTP vers cette adresse, avec un délai maximal de cinq secondes, et ne conserve que le titre de la page reçue.

Résultat vérifié :

```text
<title>Welcome to nginx!</title>
```

```text
Pod sur kube-control          Pod sur kube-worker
    10.244.222.4      HTTP        10.244.73.129
         |----------------------------->|
         |<-------- page Nginx ---------|
```

Le réseau des Pods fonctionne entre les deux nœuds.

### 7.5 Test 2 — Accès par le Service

```bash
kubectl get svc,endpointslices -n network-test
```

Cette commande affiche le Service et la liste des Pods vers lesquels il dirige le trafic.

Résultat vérifié :

```text
NAME                           TYPE        CLUSTER-IP      PORT(S)
service/network-test-service   ClusterIP   10.99.243.246   80/TCP

NAME                                                        ADDRESSTYPE   PORTS   ENDPOINTS
endpointslice.discovery.k8s.io/network-test-service-g9jxp   IPv4          80      10.244.73.129
```

L'adresse du Service appartient à la plage des Services définie dans `10-control-plane.md`. Sa destination est bien l'adresse du Pod Nginx.

```bash
SVC_IP=$(kubectl get svc -n network-test network-test-service -o jsonpath='{.spec.clusterIP}')
kubectl exec -n network-test network-test-control -- wget -qO- -T 5 http://$SVC_IP | grep title
```

Ces commandes reprennent le test précédent, en visant cette fois l'adresse du Service.

Résultat vérifié :

```text
<title>Welcome to nginx!</title>
```

```text
Pod  →  Service 10.99.243.246  →  Pod du Worker 10.244.73.129
```

La traduction d'adresse réalisée par `kube-proxy` fonctionne.

### 7.6 Test 3 — Résolution DNS

```bash
kubectl exec -n network-test network-test-control -- \
  nslookup network-test-service.network-test.svc.cluster.local
```

Cette commande demande au DNS du cluster de résoudre le nom complet du Service.

Résultat vérifié :

```text
Server:         10.96.0.10
Address:        10.96.0.10:53

Name:   network-test-service.network-test.svc.cluster.local
Address: 10.99.243.246
```

Le serveur interrogé est le Service `kube-dns` du cluster, et l'adresse retournée est celle du Service.

Le nom complet est utilisé pour obtenir une réponse sans ambiguïté. Avec le nom court, `nslookup` affiche aussi des réponses `NXDOMAIN`, qui correspondent aux autres suffixes de recherche essayés automatiquement par le résolveur.

Le nom court fonctionne néanmoins pour un usage normal :

```bash
kubectl exec -n network-test network-test-control -- wget -qO- -T 5 http://network-test-service | grep title
```

Résultat vérifié :

```text
<title>Welcome to nginx!</title>
```

Cette dernière requête traverse les trois couches à la fois : résolution du nom, Service, puis réseau entre nœuds.

### 7.7 Nettoyage

```bash
kubectl delete namespace network-test
kubectl get namespaces
```

La première commande supprime le namespace et toutes les ressources qu'il contient. La seconde vérifie qu'il a disparu.

Résultat vérifié :

```text
namespace "network-test" deleted
NAME              STATUS   AGE
default           Active   13m
kube-node-lease   Active   13m
kube-public       Active   13m
kube-system       Active   13m
```

### 7.8 Comparaison avec la première construction

Les mêmes tests avaient réussi le 8 octobre 2026 sur le cluster construit à la main. Les Pods de test ont reçu les mêmes adresses lors des deux constructions (`10.244.222.4` et `10.244.73.129`), ce qui confirme que la reconstruction par Ansible produit un réseau identique.

---

## 8. Principes appliqués

* **Préparer avant de joindre.** L'adresse du nœud est en place avant la jonction, grâce à l'ordre des plays.
* **Un jeton à usage immédiat.** Le jeton de jonction ne vit que dix minutes.
* **Aucun secret affiché.** L'option `no_log` tient le jeton hors de la sortie d'Ansible, et la documentation utilise des textes de substitution.
* **Une garde sur toute action.** Ni jeton ni jonction si le nœud appartient déjà au cluster.
* **Attendre l'état réel.** Le rôle ne se termine que lorsque le nœud est `Ready`.
* **Distinguer intégration et fonctionnement.** Un nœud `Ready` ne prouve pas que le réseau fonctionne : des tests entre Pods de nœuds différents sont nécessaires.
* **Aucun nom de machine en dur.** Le Control Plane est désigné par son groupe d'inventaire.

---

## 9. État et limites

### 9.1 État validé

| Élément                                      | État    | Nature de la validation                                   |
| -------------------------------------------- | ------- | --------------------------------------------------------- |
| Worker joint par Ansible                     | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| Worker `Ready`                               | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| Adresse `192.168.57.11` enregistrée          | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| Kubernetes `v1.36.5`, `containerd` `2.2.1`   | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| `calico-node` et `kube-proxy` sur le Worker  | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| Jeton de dix minutes                         | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| Rôle idempotent                              | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| Pod à Pod entre nœuds                        | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| Pod vers Service                             | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |
| Résolution DNS                               | ✅       | Vérifié le 9 octobre 2026 sur le cluster reconstruit      |

### 9.2 Limites connues

| Limite                                                                            | Conséquence                                                          |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Les tests fonctionnels sont lancés à la main, et non par le playbook              | Ils doivent être rejoués après chaque reconstruction, voir section 7 |
| `no_log` masque aussi les erreurs de la jonction                                  | Un échec se diagnostique à la main, voir section 5.6                 |
| Le rôle ne gère pas le retrait d'un nœud                                          | Un nœud à retirer doit l'être à la main                              |
| Le cluster ne comporte qu'un seul Worker                                          | L'arrêt de ce nœud interrompt toutes les applications                |

---

## 10. Documentation associée

| Fichier                 | Lien avec ce document                                              |
| ----------------------- | ------------------------------------------------------------------ |
| `01-architecture.md`    | Machines, adresses et réseaux                                      |
| `06-roles.md`           | Organisation des rôles, ordre des plays, résultat de la reconstruction |
| `09-kubernetes.md`      | Installation des composants et adresse du nœud                     |
| `10-control-plane.md`   | Adresse de l'API, plages des Pods et des Services                  |
| `11-calico.md`          | Configuration réseau obtenue sur chaque nœud                       |
| `13-troubleshooting.md` | Jonction sans privilèges et avertissement `kube-proxy` (problèmes 10 et 11) |

---

## 11. Étape suivante

Le laboratoire local dispose maintenant d'un cluster Kubernetes fonctionnel à deux nœuds, reconstructible par une seule commande Ansible :

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
