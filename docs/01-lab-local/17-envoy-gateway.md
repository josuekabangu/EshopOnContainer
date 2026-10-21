# 17 — Le point d'entrée : Envoy Gateway

## 1. Objectif

Les navigateurs doivent atteindre plusieurs services du cluster, `WebApp`, `Identity.API` et `WebhookClient`, par une adresse unique. Le projet utilise pour cela **Gateway API**, l'interface standard de Kubernetes pour les points d'entrée, et **Envoy Gateway**, une de ses implémentations.

Ce guide installe Envoy Gateway par un rôle Ansible, et vérifie qu'un `Gateway` reçoit une adresse de MetalLB ([16-metallb.md](16-metallb.md)) et répartit les requêtes selon le nom demandé. La configuration propre à eShop, ses noms et ses routes, relève de la série `docs/03-kubernetes`.

**État au 20 octobre 2026 :** Envoy Gateway v1.9.2 est installé par le rôle `envoy_gateway`, avec la `GatewayClass` `eg`. Un `Gateway` de test a reçu l'adresse `192.168.57.20`, et a routé une requête vers son service selon le nom demandé, depuis WSL2 comme depuis Windows.

## 2. Le choix

### Gateway API plutôt qu'Ingress

| Option | Constat au 20 octobre 2026 |
|---|---|
| Ingress, avec ingress-nginx | Le dépôt `kubernetes/ingress-nginx` est **archivé** sur GitHub, dernière version publiée le 19 mars 2026 : le contrôleur Ingress le plus répandu n'est plus maintenu |
| **Gateway API** | Le successeur d'Ingress, maintenu par le projet Kubernetes : v1.6.3, du 6 octobre 2026. Il sépare les rôles : la `GatewayClass` pour l'exploitant du cluster, le `Gateway` et les routes pour l'équipe de l'application |

La première version du projet avait exposé ses services par des `NodePort`, en élargissant la plage de ports de k3s, et n'avait jamais terminé son Ingress.

Sur EKS, les mêmes routes seront servies par le contrôleur d'AWS, avec de vrais noms DNS.

### Envoy Gateway

Envoy Gateway v1.9.2, du 28 septembre 2026, est la dernière version. Sa matrice de compatibilité annonce, pour la série 1.9, Kubernetes 1.33 à 1.36 et Gateway API v1.6.1 ; le cluster est en 1.36.5.

Il fonctionne en deux niveaux :

| Composant | Rôle |
|---|---|
| Le contrôleur, `envoy-gateway` | Surveille les `Gateway` et les routes ; pour chaque `Gateway`, crée un proxy Envoy et lui transmet sa configuration |
| Le proxy, un pod par `Gateway` | Reçoit le trafic, et l'envoie au service choisi par les routes |

## 3. Le fichier d'installation

`install.yaml` contient 41 objets, dont 21 définitions de ressources : celles de Gateway API et celles d'Envoy Gateway. Deux particularités imposent un rôle différent de ceux de `local_path` et `metallb`.

### Sa taille

Le fichier pèse 4 Mo ; la définition `envoyproxies.gateway.envoyproxy.io` fait à elle seule 1,4 Mo. Or `kubectl apply` ordinaire range une copie de chaque objet dans une annotation, limitée à 256 Kio. Le fichier est donc appliqué **côté serveur**, `kubectl apply --server-side` : le serveur garde lui-même la trace des champs appliqués, sans annotation.

### Un `Job` éphémère

Le fichier contient un `Job`, `eg-gateway-helm-certgen`, qui génère les certificats du contrôleur. Il porte `ttlSecondsAfterFinished: 30` : Kubernetes le supprime 30 secondes après son exécution. Une garde par `kubectl diff` verrait à chaque passage un objet manquant, et réappliquerait le fichier, relançant la génération des certificats.

La garde retenue est donc **la version installée** : le fichier n'est appliqué que si l'image du `Deployment` `envoy-gateway` n'est pas celle de la version voulue. La contrepartie : une modification faite à la main sur un objet d'Envoy Gateway ne serait pas corrigée par le rôle, seul un changement de version déclenche une application.

## 4. Le rôle `envoy_gateway`

### Les variables

À la fin de `group_vars/control_plane.yml` :

```yaml
envoy_gateway_version: "v1.9.2"
envoy_gateway_manifest_url: "https://github.com/envoyproxy/gateway/releases/download/{{ envoy_gateway_version }}/install.yaml"
envoy_gateway_manifest_path: "/etc/kubernetes/envoy-gateway-{{ envoy_gateway_version }}.yaml"
envoy_gateway_class_path: "/etc/kubernetes/envoy-gateway-class.yaml"
```

### La `GatewayClass` : `roles/envoy_gateway/files/gatewayclass.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

La `GatewayClass` déclare, à l'échelle du cluster, quel contrôleur gère les `Gateway` qui la citent. Elle ne dépend pas de l'application : sa place est dans le rôle. Le fichier ne contient aucune variable, il est copié tel quel depuis `files/`.

### Les tâches

| Tâche | Rôle | Garde |
|---|---|---|
| Télécharger le fichier de définition | Version figée, copiée sur `kube-control` | `get_url` |
| Lire la version installée | Image du `Deployment` `envoy-gateway`, ou rien s'il n'existe pas | `changed_when: false`, `failed_when: false` |
| Appliquer le fichier | `kubectl apply --server-side --force-conflicts` | Seulement si l'image n'est pas `envoyproxy/gateway:v1.9.2` |
| Attendre le contrôleur | `kubectl rollout status` | `changed_when: false` |
| Déposer, comparer, appliquer la `GatewayClass` | `copy`, `kubectl diff`, `kubectl apply` | Application seulement si `diff` répond `1` |
| Attendre que la `GatewayClass` soit acceptée | `kubectl wait --for=condition=Accepted` | `changed_when: false` |

La garde de l'application s'écrit :

```yaml
  when: envoy_gateway_image.stdout != "envoyproxy/gateway:" ~ envoy_gateway_version
```

`~` assemble deux chaînes en Jinja. `--force-conflicts` fait prévaloir le fichier si le serveur signale qu'un champ appartient à un autre gestionnaire, cas d'une mise à jour.

### Le play

Le rôle termine le quatrième play de `site.yml` :

```yaml
  roles:
    - local_path
    - sealed_secrets
    - metallb
    - envoy_gateway
```

## 5. Valider le rôle

Dans WSL2, depuis `lab-local/ansible` :

```bash
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml
ansible-playbook site.yml
```

Résultats vérifiés le 20 octobre 2026, sur le cluster existant :

| Passage | `kube-control` | Tâches du rôle |
|---|---|---|
| Premier | `ok=55 changed=4 failed=0` | Téléchargement, application du fichier, `GatewayClass` déposée et appliquée |
| Second | `ok=53 changed=0 failed=0` | La garde par la version a sauté l'application |

Le rôle a ensuite été validé par une reconstruction complète, le 21 octobre 2026 : sur machines neuves, l'application côté serveur et la `GatewayClass` se sont exécutées, et le `Gateway` d'eShop a été programmé ([06-roles.md](06-roles.md), section 8.3).

## 6. Vérifier qu'un `Gateway` route les requêtes

### Le test : `lab-local/tests/gateway-test.yaml`

Il crée un espace de noms `gw-test`, un pod `traefik/whoami:v1.12.0` et son `Service` ordinaire, un `Gateway` `test` de la classe `eg`, et une `HTTPRoute` qui envoie le nom `whoami.test.lab` vers le `Service` :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: test
  namespace: gw-test
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: whoami
  namespace: gw-test
spec:
  parentRefs:
    - name: test
  hostnames:
    - whoami.test.lab
  rules:
    - backendRefs:
        - name: whoami
          port: 80
```

Le `Service` de `whoami` est cette fois un `ClusterIP` : c'est le `Gateway` qui reçoit l'adresse de MetalLB.

### Le dérouler

Depuis WSL2, à la racine du dépôt :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

kubectl get gatewayclass
kubectl apply -f - < lab-local/tests/gateway-test.yaml
kubectl -n gw-test wait --for=condition=Programmed gateway/test --timeout=180s
kubectl -n gw-test get gateway,httproute
kubectl -n envoy-gateway-system get pods,services -o wide
curl -s -m 5 -H 'Host: whoami.test.lab' http://192.168.57.20/ | head -2
curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://192.168.57.20/
```

Puis depuis PowerShell :

```powershell
curl.exe -s -m 5 -H "Host: whoami.test.lab" http://192.168.57.20/
```

`-H 'Host: ...'` donne le nom demandé sans passer par un fichier `hosts` : c'est sur ce nom que le proxy choisit la route.

Résultats vérifiés le 20 octobre 2026 :

```text
NAME   CONTROLLER                                      ACCEPTED
eg     gateway.envoyproxy.io/gatewayclass-controller   True

NAME                                     CLASS   ADDRESS         PROGRAMMED
gateway.gateway.networking.k8s.io/test   eg      192.168.57.20   True

pod/envoy-gateway-6579bbfdf-xlrx5                 1/1     Running   kube-worker
pod/envoy-gw-test-test-e3b985f1-789999c4f-95t8p   2/2     Running   kube-worker
service/envoy-gw-test-test-e3b985f1   LoadBalancer   10.96.61.50   192.168.57.20   80:31897/TCP
```

| Contrôle | Résultat |
|---|---|
| `GatewayClass` `eg` | Acceptée par le contrôleur |
| `Gateway` `test` | Programmé, adresse `192.168.57.20` |
| Objets créés par le contrôleur pour le `Gateway` | Un pod proxy, à deux conteneurs, et un `Service` `LoadBalancer`, dans `envoy-gateway-system` |
| Requête avec le nom `whoami.test.lab`, depuis WSL2 et depuis Windows | Le pod `whoami` répond |
| Requête sans nom reconnu | `404` : aucune route ne correspond |

### L'adresse du client est conservée

La réponse reçue sous Windows contient :

```text
RemoteAddr: 10.244.73.157:33746
X-Envoy-External-Address: 192.168.57.1
X-Forwarded-For: 192.168.57.1
```

Le pod voit la requête venir du proxy (`10.244.73.157`), qui transmet l'adresse réelle du client, celle de Windows, dans l'en-tête `X-Forwarded-For`. Avec le test de MetalLB seul, le pod voyait une adresse du réseau NAT ([16-metallb.md](16-metallb.md), section 5). La différence a été vérifiée :

```bash
kubectl -n envoy-gateway-system get service -l gateway.envoyproxy.io/owning-gateway-name=test \
  -o custom-columns=NOM:.metadata.name,POLITIQUE:.spec.externalTrafficPolicy
kubectl -n envoy-gateway-system get events --field-selector reason=nodeAssigned
```

```text
NOM                           POLITIQUE
envoy-gw-test-test-e3b985f1   Local

nodeAssigned   service/envoy-gw-test-test-e3b985f1   announcing from node "kube-worker" with protocol "layer2"
```

Envoy Gateway crée le `Service` de son proxy avec `externalTrafficPolicy: Local` : seul le nœud qui héberge le proxy reçoit le trafic, et l'adresse source n'est pas remplacée. MetalLB en tient compte, et annonce l'adresse depuis ce nœud, `kube-worker`.

### Le nettoyage

```bash
kubectl delete -f - < lab-local/tests/gateway-test.yaml
```

Supprimer le `Gateway` supprime aussi le proxy et son `Service` : l'adresse `192.168.57.20` redevient libre.

## 7. Les limites

| Limite | Conséquence |
|---|---|
| Un proxy, sur un seul nœud | `externalTrafficPolicy: Local` : si `kube-worker` tombe, le point d'entrée tombe avec lui. Sans conséquence avec un seul nœud de travail |
| HTTP seulement | Les cookies de connexion d'eShop exigent alors l'adaptation `72ee8fa` ([application/README.md](../../application/README.md)). HTTPS, avec un certificat, reste à mettre en place |
| Garde par la version | Une modification manuelle des objets d'Envoy Gateway n'est pas corrigée par le rôle |

## 8. Tableau de validation

| Contrôle | Résultat au 20 octobre 2026 |
|---|---|
| Rôle `envoy_gateway`, quatrième play | Ajouté |
| Reconstruction complète | Réussie le 21 octobre 2026, en 8 min 02 |
| Second passage du playbook | `changed=0` |
| `GatewayClass` `eg` | Acceptée |
| `Gateway` de test | Programmé, `192.168.57.20` |
| Routage selon le nom, depuis WSL2 et Windows | Oui ; `404` sans nom reconnu |
| Adresse du client transmise | Oui, `X-Forwarded-For: 192.168.57.1` |

## 9. Étape suivante

Le laboratoire dispose d'un point d'entrée. Les noms de l'application doivent maintenant être résolus de la même façon par les pods et par le navigateur : [18-lab-dns.md](18-lab-dns.md). Le `Gateway` d'eShop et ses routes sont décrits dans [docs/03-kubernetes/14-point-entree.md](../03-kubernetes/14-point-entree.md).

## 10. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Classe, Gateway et routes
kubectl get gatewayclass
kubectl get gateway,httproute -A

# Contrôleur et proxys
kubectl -n envoy-gateway-system get pods,services -o wide

# Journal du contrôleur
kubectl -n envoy-gateway-system logs deployment/envoy-gateway
```

**Bilan :** le laboratoire dispose d'un point d'entrée conforme à Gateway API. Envoy Gateway, installé par Ansible malgré un fichier hors normes, crée pour chaque `Gateway` un proxy qui reçoit une adresse de MetalLB, route selon le nom demandé, et transmet l'adresse réelle du client.
