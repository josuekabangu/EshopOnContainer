# 14 — Le point d'entrée d'eShop et l'émetteur commun

## 1. Objectif

`WebApp` et `WebhookClient` sont utilisés depuis un navigateur. La connexion d'un utilisateur fait intervenir trois acteurs : le navigateur, le site, et `Identity.API`, qui délivre les jetons ([guide 02-docker/13](../02-docker/13-compose-webapp.md), section 2).

`Identity.API` inscrit dans chaque jeton son **émetteur**, qu'il déduit de l'adresse par laquelle on le joint. Une API n'accepte un jeton que si cet émetteur correspond à l'adresse qu'elle connaît pour `Identity.API`. Il faut donc une adresse que le navigateur et les pods comprennent de la même façon.

| | Docker Compose | Kubernetes, ce guide |
|---|---|---|
| Adresse commune | `http://identity-api:5223` | `http://identity.eshop.lab` |
| Côté navigateur | Fichier `hosts` : `identity-api` vers `127.0.0.1`, port publié | Fichier `hosts` : les noms en `.eshop.lab` vers `192.168.57.20`, l'adresse du point d'entrée |
| Côté conteneurs ou pods | Le réseau Docker | CoreDNS, qui renvoie les mêmes noms vers le point d'entrée |
| Modification du code | Aucune | Aucune |

La première version du projet avait figé l'émetteur dans le code d'`Identity.API`, et exposé ses services par des `NodePort`.

**État au 21 octobre 2026 :** le `Gateway` d'eShop répond sur `192.168.57.20`. Le navigateur de Windows et les pods voient le même émetteur, `http://identity.eshop.lab`. Les API vérifient les jetons à cette adresse, et une commande a été menée jusqu'à l'état `Paid` depuis le navigateur ([guide 15](15-webapp.md)).

## 2. Les composants

| Composant | Rôle | Où | Guide |
|---|---|---|---|
| MetalLB | Attribue l'adresse `192.168.57.20` au point d'entrée | Rôle Ansible `metallb` | [01-lab-local/16-metallb.md](../01-lab-local/16-metallb.md) |
| Envoy Gateway et la `GatewayClass` `eg` | Crée un proxy pour chaque `Gateway` | Rôle Ansible `envoy_gateway` | [01-lab-local/17-envoy-gateway.md](../01-lab-local/17-envoy-gateway.md) |
| CoreDNS | Renvoie les noms `.eshop.lab` vers le point d'entrée, pour les pods | Rôle Ansible `lab_dns` | [01-lab-local/18-lab-dns.md](../01-lab-local/18-lab-dns.md) |
| Le `Gateway` d'eShop et son `EnvoyProxy` | Le point d'entrée de l'application | `kubernetes/gateway/` | Ce guide, section 3 |
| Le fichier `hosts` de Windows | Les mêmes noms, pour le navigateur | `lab-local/scripts/add-hosts-entries.ps1` | Ce guide, section 4 |
| Les `HTTPRoute` | Un nom vers un `Service` | Avec chaque service | Ce guide, section 5, et guides 15 et 16 |

```text
Navigateur (Windows) ── hosts ──> 192.168.57.20 ──┐
                                                  ├──> proxy eshop-gateway ──> route selon le nom
Pod du cluster ──── CoreDNS ──> 10.108.250.206 ───┘      identity.eshop.lab -> identity-api:5223
                                                          shop.eshop.lab     -> webapp:8080
                                                          webhooks.eshop.lab -> webhook-client:8080
```

## 3. Le `Gateway` d'eShop

### Les deux besoins

| Besoin | Raison | Moyen |
|---|---|---|
| Une adresse fixe | Les noms du fichier `hosts` y pointent. Sans réglage, MetalLB donne la première adresse libre | L'annotation `metallb.io/loadBalancerIPs` sur le `Service` du proxy |
| Un nom de `Service` fixe | CoreDNS renvoie les noms vers ce `Service`. Sans réglage, Envoy Gateway le nomme `envoy-eshop-eshop-<empreinte>` | Le champ `envoyService.name` |

Les deux se règlent dans une ressource `EnvoyProxy`, désignée par le `Gateway` (`spec.infrastructure.parametersRef`). La définition de cette ressource, dans le fichier d'installation d'Envoy Gateway v1.9.2, offre `annotations`, `name`, `loadBalancerIP` et `externalTrafficPolicy` (par défaut `Local`) pour le `Service`. Le champ `loadBalancerIP` reprend un champ déprécié de Kubernetes : l'annotation de MetalLB lui est préférée.

La documentation d'Envoy Gateway recommande de créer l'`EnvoyProxy` avant le `Gateway`, pour éviter une coupure temporaire.

### `kubernetes/gateway/envoyproxy-eshop.yaml`

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: eshop
  namespace: eshop
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        # Nom fixe : CoreDNS y renverra les noms en .eshop.lab (étape 3b)
        name: eshop-gateway
        annotations:
          # Adresse figée : les noms du fichier hosts de Windows y pointent
          metallb.io/loadBalancerIPs: 192.168.57.20
```

### `kubernetes/gateway/gateway-eshop.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eshop
  namespace: eshop
spec:
  gatewayClassName: eg
  infrastructure:
    parametersRef:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: eshop
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.eshop.lab"
      allowedRoutes:
        namespaces:
          from: Same
```

| Réglage | Rôle |
|---|---|
| `hostname: "*.eshop.lab"` | Le point d'entrée n'accepte que les noms du projet |
| `allowedRoutes.namespaces.from: Same` | Seules les routes de l'espace de noms `eshop` s'y rattachent |

### Appliquer

L'ordre alphabétique des fichiers, `envoyproxy-…` puis `gateway-…`, est celui qu'il faut :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

for f in kubernetes/gateway/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop wait --for=condition=Programmed gateway/eshop --timeout=180s
kubectl -n eshop get gateway
kubectl -n envoy-gateway-system get service eshop-gateway -o wide
curl -s -m 5 -o /dev/null -w '%{http_code}\n' -H 'Host: identity.eshop.lab' http://192.168.57.20/
```

Résultat vérifié le 20 octobre 2026 :

```text
NAME    CLASS   ADDRESS         PROGRAMMED
eshop   eg      192.168.57.20   True

NAME            TYPE           CLUSTER-IP       EXTERNAL-IP     PORT(S)
eshop-gateway   LoadBalancer   10.108.250.206   192.168.57.20   80:30139/TCP

404
```

L'adresse et le nom du `Service` sont ceux demandés. Le `404` indique que le point d'entrée répond, sans route encore.

## 4. Le fichier `hosts` de Windows

### Le script

Celui de Compose, `docker/scripts/windows/add-hosts-entry.ps1`, déclare `identity-api` vers `127.0.0.1`. Le cluster demande trois noms vers une autre adresse, et les deux configurations doivent coexister. Un second script, `lab-local/scripts/add-hosts-entries.ps1`, ajoute une seule ligne :

```text
192.168.57.20	shop.eshop.lab identity.eshop.lab webhooks.eshop.lab	# EshopOnContainer lab
```

Il reprend les protections de celui de Compose : relancé, il ne fait rien ; il lève puis remet l'attribut lecture seule du fichier ; il écrit en UTF-8 sans BOM ; il refuse si un nom est déjà déclaré ailleurs ; `-Remove` ne retire que sa ligne, et garde une copie `.bak`. Sa marque, `# EshopOnContainer lab`, est distincte de celle de Compose : le motif de Compose, ancré sur `EshopOnContainer` en fin de ligne, ne la reconnaît pas, et chaque script ne touche qu'à sa propre ligne.

Le script est enregistré en UTF-8 **avec BOM** : sans lui, Windows PowerShell 5.1 affiche mal les accents de ses messages. Une version Linux, `lab-local/scripts/add-hosts-entries.sh`, fait de même pour `/etc/hosts`, et refuse de s'exécuter dans WSL2, dont `/etc/hosts` est régénéré depuis Windows. Elle n'a été vérifiée que pour ce refus, faute de poste Linux.

### Le lancer

Dans PowerShell en administrateur, **à la racine du dépôt** : la console d'administration s'ouvre dans `C:\WINDOWS\system32`, où le chemin relatif du script est introuvable.

```powershell
cd F:\chemin\vers\EshopOnContainer
powershell -ExecutionPolicy Bypass -File .\lab-local\scripts\add-hosts-entries.ps1
curl.exe -s -m 5 -o NUL -w "%{http_code}`n" http://identity.eshop.lab/
```

Résultat vérifié le 21 octobre 2026 :

```text
Ajouté : 192.168.57.20  shop.eshop.lab identity.eshop.lab webhooks.eshop.lab    # EshopOnContainer lab
Vérifié : shop.eshop.lab -> 192.168.57.20
Vérifié : identity.eshop.lab -> 192.168.57.20
Vérifié : webhooks.eshop.lab -> 192.168.57.20
Déjà présent : ...        (second lancement)
404
```

Windows atteint le point d'entrée par son nom.

## 5. La route d'Identity.API, et la preuve du même émetteur

### `kubernetes/identity-api/httproute-identity-api.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: identity-api
  namespace: eshop
spec:
  parentRefs:
    - name: eshop
  hostnames:
    - identity.eshop.lab
  rules:
    - backendRefs:
        - name: identity-api
          port: 5223
```

La route est rangée avec les autres fichiers d'`Identity.API` : elle décrit comment on l'atteint, comme son `Service`.

### L'émetteur, vu de trois côtés

```bash
kubectl apply -f - < kubernetes/identity-api/httproute-identity-api.yaml

kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: isstest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: isstest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
Y
kubectl -n eshop wait --for=condition=Ready pod/isstest --timeout=120s
kubectl -n eshop exec -i isstest -- sh <<'SH'
echo "pod, par le nom public : $(curl -s -m 5 http://identity.eshop.lab/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"')"
echo "pod, par le Service    : $(curl -s -m 5 http://identity-api:5223/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"')"
SH
kubectl -n eshop delete pod isstest
```

Et depuis PowerShell :

```powershell
curl.exe -s -m 5 http://identity.eshop.lab/.well-known/openid-configuration | Select-String -Pattern '"issuer":"[^"]*"' -AllMatches | ForEach-Object { $_.Matches.Value }
```

Résultats vérifiés le 21 octobre 2026 :

| Qui | Par où | Émetteur |
|---|---|---|
| Windows | `http://identity.eshop.lab` | **`http://identity.eshop.lab`** |
| Un pod | `http://identity.eshop.lab` | **`http://identity.eshop.lab`** |
| Un pod | `http://identity-api:5223`, le `Service` | `http://identity-api:5223` |

La route est `Accepted` et `ResolvedRefs`. Le navigateur et les pods voient le même émetteur, sans modification du code : le proxy transmet le nom demandé, dont `Identity.API` déduit son émetteur.

La troisième ligne montre pourquoi les API ne peuvent plus vérifier les jetons par le `Service`.

## 6. Les adresses des services

| Réglage | Avant | Après |
|---|---|---|
| `Identity__Url` de `Basket.API`, `Ordering.API` et `Webhooks.API` | `http://identity-api:5223` | `http://identity.eshop.lab` |
| `WebAppClient` d'`Identity.API` | Non défini | `http://shop.eshop.lab` |
| `WebhooksWebClient` d'`Identity.API` | Non défini | `http://webhooks.eshop.lab` |

Le changement d'`Identity__Url` a été fait dans les trois fichiers par une commande, depuis WSL2 :

```bash
sed -i 's#value: http://identity-api:5223#value: http://identity.eshop.lab#' \
  kubernetes/basket-api/deployment-basket-api.yaml \
  kubernetes/ordering-api/deployment-ordering-api.yaml \
  kubernetes/webhooks-api/deployment-webhooks-api.yaml
```

`sed -i` est à lancer dans WSL2 : celui de Git Bash convertit les fins de ligne des fichiers.

`Identity.API` lit les adresses de ses clients au démarrage, et les garde en mémoire : leur ajout demande un redémarrage, fait par l'application du `Deployment`. Les quatre `Deployment` ont été réappliqués le 21 octobre 2026 ; ils ont redémarré sans erreur.

Les API ne contactent `Identity.API` qu'à la première requête munie d'un jeton. La preuve que leurs nouvelles adresses sont justes vient donc d'un utilisateur connecté : `Basket.API` et `Ordering.API` ont accepté le jeton d'`alice` ([guide 15](15-webapp.md)), `Webhooks.API` aussi ([guide 16](16-webhook-client.md)).

## 7. Les limites

| Limite | Conséquence |
|---|---|
| HTTP seulement | Les cookies de connexion exigent les adaptations `72ee8fa` et `a6647c9` ([application/README.md](../../application/README.md)). HTTPS, avec un certificat approuvé par Windows **et** par chaque pod, les rendrait inutiles |
| Les noms dépendent du poste | Chaque poste doit lancer le script du fichier `hosts` |
| La liste des noms est en trois endroits | Variables Ansible, et les deux scripts `hosts` |
| Un seul proxy, sur un seul nœud | `externalTrafficPolicy: Local` : le point d'entrée suit `kube-worker` |

## 8. Tableau de validation

| Contrôle | Résultat |
|---|---|
| `Gateway` `eshop` | Programmé, `192.168.57.20` |
| `Service` du proxy | `eshop-gateway`, nom fixe |
| Noms résolus par Windows | Les trois, vers `192.168.57.20` |
| Noms résolus par les pods | Vers l'adresse interne d'`eshop-gateway` ([01-lab-local/18-lab-dns.md](../01-lab-local/18-lab-dns.md)) |
| Émetteur vu par Windows et par un pod | `http://identity.eshop.lab`, le même |
| Jetons acceptés par les API | Oui, avec `Identity__Url` à `http://identity.eshop.lab` |

## 9. Étape suivante

Déployer `WebApp` derrière ce point d'entrée, et mener une commande depuis le navigateur : [15 — WebApp sur le cluster](15-webapp.md).

**Bilan :** eShop dispose d'un point d'entrée unique, conforme à Gateway API, à une adresse fixe. Le navigateur et les pods joignent `Identity.API` par le même nom, et voient le même émetteur, sans modification du code et sans port publié.
