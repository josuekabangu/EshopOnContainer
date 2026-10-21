# 16 — Les adresses du point d'entrée : MetalLB

## 1. Objectif

Les navigateurs doivent atteindre `WebApp` et `Identity.API`, qui tournent dans le cluster. Le projet a choisi un point d'entrée unique, selon Gateway API ([docs/03-kubernetes/14-point-entree.md](../03-kubernetes/14-point-entree.md)). Ce point d'entrée est un `Service` de type `LoadBalancer` : il demande une adresse IP joignable depuis l'extérieur du cluster.

Dans le cloud, le fournisseur attribue cette adresse. Un cluster construit par kubeadm n'a personne pour le faire : le `Service` reste indéfiniment avec une adresse `<pending>`. MetalLB comble ce manque, en attribuant des adresses prises sur le réseau du laboratoire.

Ce guide installe MetalLB par un rôle Ansible, et vérifie qu'un `Service` de type `LoadBalancer` reçoit une adresse, joignable depuis Windows.

**État au 20 octobre 2026 :** MetalLB v0.16.0 est installé par le rôle `metallb`. Il attribue les adresses `192.168.57.20` à `192.168.57.29`. Un `Service` de test a reçu `192.168.57.20`, et répond depuis WSL2 comme depuis Windows.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Version | MetalLB v0.16.0, du 20 mai 2026 | La plus récente au 20 octobre 2026 |
| Mode | **L2** | Le nœud qui porte une adresse répond aux requêtes ARP du réseau local : les autres machines l'associent à son adresse matérielle. Le mode BGP suppose un routeur, absent du laboratoire |
| Plage d'adresses | `192.168.57.20` à `192.168.57.29` | Sur le réseau privé, que Windows et WSL2 joignent déjà. Hors des adresses utilisées : `.1` pour Windows, `.10` et `.11` pour les nœuds |
| Interface annoncée | `eth1` seulement | `eth0` est le réseau NAT de VMware, où ces adresses n'ont aucun sens ([01-architecture.md](01-architecture.md), section 5) |
| Installation et configuration | Un rôle Ansible, `metallb`, dans le quatrième play | Composant du cluster, comme `local_path` et `sealed_secrets` : il doit survivre aux reconstructions. La plage d'adresses décrit le réseau du laboratoire, pas l'application |

Le fichier d'installation, `metallb-native.yaml`, crée dans l'espace de noms `metallb-system` :

| Objet | Rôle |
|---|---|
| `Deployment` `controller` | Attribue les adresses aux `Service`, et sert le webhook qui valide la configuration |
| `DaemonSet` `speaker` | Un pod par nœud : répond aux requêtes ARP pour les adresses dont son nœud est chargé |
| 9 définitions de ressources | Dont `IPAddressPool` et `L2Advertisement`, utilisées ici |

Le `speaker` tolère les marques `node-role.kubernetes.io/master` et `node-role.kubernetes.io/control-plane` : il tourne aussi sur `kube-control`. Les deux nœuds ayant une interface sur `192.168.57.0/24`, chacun peut être élu pour répondre à une adresse. Une première lecture du fichier, avec `grep -A3`, n'avait vu que la première des deux tolérances, et avait conclu à tort que le `speaker` ne tournerait que sur `kube-worker`.

## 3. Le rôle `metallb`

### Les variables

À la fin de `group_vars/control_plane.yml` :

```yaml
metallb_version: "v0.16.0"
metallb_manifest_url: "https://raw.githubusercontent.com/metallb/metallb/{{ metallb_version }}/config/manifests/metallb-native.yaml"
metallb_manifest_path: "/etc/kubernetes/metallb-{{ metallb_version }}.yaml"
metallb_config_path: "/etc/kubernetes/metallb-config.yaml"
# Adresses attribuées aux Services de type LoadBalancer, sur le réseau privé du laboratoire
metallb_address_range: "192.168.57.20-192.168.57.29"
metallb_interface: "eth1"
```

### La configuration : `roles/metallb/templates/metallb-config.yaml.j2`

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab
  namespace: metallb-system
spec:
  addresses:
    - {{ metallb_address_range }}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab
  # Le réseau privé seulement : eth0 est le réseau NAT de VMware
  interfaces:
    - {{ metallb_interface }}
```

| Objet | Rôle |
|---|---|
| `IPAddressPool` | La réserve d'adresses où MetalLB puise |
| `L2Advertisement` | Annonce les adresses de cette réserve en mode L2, sur `eth1` seulement |

### Les tâches

`roles/metallb/tasks/main.yml` reprend la méthode de `local_path` ([14-local-path.md](14-local-path.md), section 4), en deux temps :

| Tâche | Rôle | Garde |
|---|---|---|
| Télécharger le fichier de définition | Version figée, copiée sur `kube-control` | `get_url` ne retélécharge pas un fichier présent |
| Vérifier, puis créer l'espace de noms `metallb-system` | `kubectl diff` échoue sur des objets d'un espace de noms inexistant ([13-troubleshooting.md](13-troubleshooting.md), problème 18) | Création seulement s'il est absent |
| Comparer, puis appliquer le fichier | `kubectl diff`, puis `kubectl apply` | Application seulement si `diff` répond `1` |
| Attendre le `controller` et le `speaker` | `kubectl rollout status` pour chacun | `changed_when: false` |
| Déposer la configuration | Le modèle, rendu dans `/etc/kubernetes/metallb-config.yaml` | `template` ne réécrit pas un fichier identique |
| Comparer, puis appliquer la configuration | Même garde que le fichier d'installation | Application seulement si `diff` répond `1` |

L'attente du `controller` vient **avant** la configuration : c'est lui qui sert le webhook chargé de valider les objets `IPAddressPool` et `L2Advertisement`. Appliquée trop tôt, la configuration serait refusée faute de webhook.

### Le play

Le rôle rejoint le quatrième play de `site.yml` :

```yaml
  roles:
    - local_path
    - sealed_secrets
    - metallb
```

## 4. Valider le rôle

Dans WSL2, depuis `lab-local/ansible` :

```bash
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml
ansible-playbook site.yml
```

Résultats vérifiés le 20 octobre 2026, sur le cluster existant :

| Passage | `kube-control` | Tâches du rôle |
|---|---|---|
| Premier | `ok=50 changed=5 failed=0` | Téléchargement, espace de noms créé, fichier appliqué, configuration déposée et appliquée |
| Second | `ok=47 changed=0 failed=0` | Les tâches de modification sont sautées |

Le rôle a ensuite été validé par une reconstruction complète, le 21 octobre 2026 : sur machines neuves, ses cinq tâches de modification se sont exécutées, et le `Gateway` d'eShop a reçu son adresse `192.168.57.20` ([06-roles.md](06-roles.md), section 8.3).

## 5. Vérifier qu'un `Service` reçoit une adresse

### Le mode de `kube-proxy`

En mode IPVS, `kube-proxy` répond lui-même aux requêtes ARP pour les adresses des `Service`, et MetalLB demande alors le réglage `strictARP: true`. La configuration kubeadm du projet ne fixe aucun mode : il faut vérifier le mode réel.

```bash
ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 sh <<'SH'
kubectl -n kube-system get configmap kube-proxy -o 'jsonpath={.data.config\.conf}' | grep -E '^mode|strictARP'
SH
```

Résultat vérifié : `mode: ""` et `strictARP: false`. Un mode vide est le mode par défaut, iptables : aucun réglage n'est nécessaire.

La commande passe tout entière par l'entrée standard de SSH. Une première tentative, par la fonction `kubectl` qui passe ses arguments à SSH, n'avait rien affiché : les guillemets simples avaient disparu, et le shell de `kube-control` avait retiré la barre oblique de `config\.conf`.

### Le test : `lab-local/tests/loadbalancer-test.yaml`

Rangé avec les tests du réseau et du stockage, il crée un espace de noms, un pod `traefik/whoami:v1.12.0`, qui répond par son nom et ses adresses, et un `Service` de type `LoadBalancer` :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: lb-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: lb-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
        - name: whoami
          image: traefik/whoami:v1.12.0
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: lb-test
spec:
  type: LoadBalancer
  selector:
    app: whoami
  ports:
    - port: 80
      targetPort: 80
```

Depuis WSL2, **à la racine du dépôt** :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

kubectl -n metallb-system get pods -o wide
kubectl apply -f - < lab-local/tests/loadbalancer-test.yaml
kubectl -n lb-test rollout status deployment/whoami --timeout=120s
kubectl -n lb-test get service whoami
kubectl -n lb-test describe service whoami | grep -A3 Events
curl -s -m 5 http://192.168.57.20/ | head -3
```

Puis depuis PowerShell, sous Windows :

```powershell
curl.exe -s -m 5 http://192.168.57.20/
```

Une première tentative avait été lancée depuis `lab-local/ansible` : le chemin du test, relatif à la racine du dépôt, était introuvable.

Résultats vérifiés le 20 octobre 2026 :

```text
NAME                          READY   STATUS    RESTARTS   AGE   IP              NODE
controller-867dbd646d-l26rz   1/1     Running   0          91s   10.244.73.152   kube-worker
speaker-l6zg6                 1/1     Running   0          91s   192.168.57.10   kube-control
speaker-t7s22                 1/1     Running   0          91s   192.168.57.11   kube-worker

NAME     TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)
whoami   LoadBalancer   10.109.80.128   192.168.57.20   80:31651/TCP

Normal  IPAllocated   5s    metallb-controller  Assigned IP ["192.168.57.20"]
```

```text
Hostname: whoami-5ff6d988bf-t9clg
IP: 127.0.0.1
IP: ::1
IP: 10.244.73.153
...
RemoteAddr: 192.168.200.155:63049
GET / HTTP/1.1
Host: 192.168.57.20
```

| Contrôle | Résultat |
|---|---|
| Pods de MetalLB | Le `controller`, et un `speaker` par nœud |
| Adresse du `Service` | `192.168.57.20`, attribuée par MetalLB, au lieu de `<pending>` |
| Réponse depuis WSL2 | Le nom du pod |
| Réponse depuis Windows | Le nom du pod : le navigateur pourra joindre le cluster par cette adresse |

### L'adresse vue par le pod

Le pod voit la requête venir de `192.168.200.155`, une adresse du réseau NAT de VMware, et non de Windows (`192.168.57.1`). Lecture probable, non vérifiée : le nœud élu par MetalLB a transmis la requête au pod en remplaçant l'adresse source par la sienne, comme le fait `kube-proxy` avec `externalTrafficPolicy: Cluster`, réglage par défaut, et par son interface `eth0`, qui porte sa route par défaut. L'adresse réelle du client se perd donc. C'est sans conséquence pour eShop ; `externalTrafficPolicy: Local` la conserverait, en n'acceptant le trafic que sur le nœud qui héberge le pod.

> **Complément du 20 octobre 2026.** Le point d'entrée d'Envoy Gateway utilise justement `externalTrafficPolicy: Local` : l'adresse de Windows y arrive intacte, et MetalLB annonce l'adresse depuis le nœud du proxy ([17-envoy-gateway.md](17-envoy-gateway.md), section 6).

### Le nettoyage

```bash
kubectl delete -f - < lab-local/tests/loadbalancer-test.yaml
```

## 6. Les limites

| Limite | Conséquence |
|---|---|
| Mode L2 : un seul nœud répond pour une adresse | Pas de répartition de charge entre nœuds au niveau du réseau. Si ce nœud tombe, un autre est élu, après quelques secondes |
| Dix adresses | Suffisant : le projet n'en utilisera qu'une, celle du point d'entrée |
| L'adresse du client est perdue | Voir section 5 |

## 7. Tableau de validation

| Contrôle | Résultat au 20 octobre 2026 |
|---|---|
| Rôle `metallb`, quatrième play | Ajouté |
| Reconstruction complète | Réussie le 21 octobre 2026, en 8 min 02 |
| Second passage du playbook | `changed=0` |
| Mode de `kube-proxy` | iptables : `strictARP` inutile |
| Adresse attribuée à un `Service` `LoadBalancer` | `192.168.57.20` |
| Réponse depuis WSL2 et depuis Windows | Oui |

## 8. Étape suivante

Installer Envoy Gateway, l'implémentation de Gateway API, dont le point d'entrée recevra une adresse de MetalLB : [17-envoy-gateway.md](17-envoy-gateway.md).

## 9. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Pods de MetalLB
kubectl -n metallb-system get pods -o wide

# Réserve d'adresses et annonce
kubectl -n metallb-system get ipaddresspools,l2advertisements

# Services qui ont reçu une adresse
kubectl get services -A --field-selector spec.type=LoadBalancer
```

**Bilan :** le laboratoire attribue désormais des adresses aux `Service` de type `LoadBalancer`, comme le ferait un fournisseur de cloud. MetalLB, installé et configuré par Ansible, les annonce sur le réseau privé, et une adresse attribuée répond depuis Windows.
