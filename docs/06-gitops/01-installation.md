# 01 — L'installation d'Argo CD et l'accès à son interface

## 1. Objectif

À la fin de la série précédente, la chaîne s'arrêtait à mi-chemin : GitHub Actions publie les images et écrit leur étiquette dans `helm/values/` ([docs/05-ci/02-etiquettes-helm.md](../05-ci/02-etiquettes-helm.md)), mais le cluster ne change que si quelqu'un lance `helm/deploy.sh`. Le dépôt et le cluster peuvent donc diverger sans que personne le remarque.

Argo CD supprime ce dernier geste manuel : il tourne **dans** le cluster, lit le dépôt, compare ce qu'il y trouve à ce qui tourne, et rapproche le cluster du dépôt. C'est l'approche GitOps : le dépôt Git devient la seule description de ce qui doit tourner.

Ce guide installe Argo CD par un rôle Ansible et rend son interface joignable depuis Windows. Il ne déclare encore aucune application : c'est l'objet du [guide 02](02-applicationset.md).

**État au 24 novembre 2026 :** Argo CD v3.5.6 est installé par le rôle `argocd`, à chaque reconstruction du laboratoire. Son interface répond en HTTPS à `https://192.168.57.21`, adresse fixe attribuée par MetalLB.

## 2. Les choix

| Question | Choix | Raison |
|---|---|---|
| Quelle installation ? | Le fichier officiel `install.yaml` de la version v3.5.6, **sans haute disponibilité** | Le laboratoire n'a qu'un Worker : les copies multiples de la variante haute disponibilité n'auraient nulle part où se répartir |
| Par quoi ? | Un rôle Ansible, `argocd`, comme MetalLB et Envoy Gateway | Argo CD fait partie de la plateforme, pas de l'application : il doit exister **avant** de pouvoir déployer quoi que ce soit. Le laboratoire reconstruit l'a donc d'office |
| Appliqué comment ? | `kubectl apply --server-side` | La définition de l'objet `ApplicationSet` (un CRD) dépasse la taille permise pour l'annotation qu'utilise `kubectl apply` ordinaire |
| Quelle garde ? | La version de l'image d'`argocd-server` | Comme pour Envoy Gateway ([01-lab-local/17-envoy-gateway.md](../01-lab-local/17-envoy-gateway.md)) : `kubectl diff` n'est pas fiable sur un fichier appliqué côté serveur. Le fichier n'est appliqué que si la version installée n'est pas celle voulue |
| Comment joindre l'interface ? | Le `Service` `argocd-server` en type `LoadBalancer`, à l'adresse fixe `192.168.57.21` | Voir la section 4 |

## 3. Le rôle `argocd`

### Les variables

Dans `lab-local/ansible/group_vars/control_plane.yml` :

```yaml
argocd_version: "v3.5.6"
argocd_manifest_url: "https://raw.githubusercontent.com/argoproj/argo-cd/{{ argocd_version }}/manifests/install.yaml"
argocd_manifest_path: "/etc/kubernetes/argocd-{{ argocd_version }}.yaml"
argocd_namespace: "argocd"
argocd_server_address: "192.168.57.21"
```

La variable `argocd_applicationset_path` qui suit est celle de l'amorçage ([guide 04](04-amorcage.md)).

### Les tâches de l'installation

Le fichier complet : [lab-local/ansible/roles/argocd/tasks/main.yml](../../lab-local/ansible/roles/argocd/tasks/main.yml).

| Tâche | Rôle | Garde |
|---|---|---|
| Télécharger le fichier de définition | `get_url` vers `/etc/kubernetes/argocd-v3.5.6.yaml` | Pas de nouveau téléchargement si le fichier est là |
| Vérifier, puis créer l'espace de noms `argocd` | Les objets du fichier officiel n'ont pas d'espace de noms : il est donné à `kubectl apply -n argocd`, et doit exister avant | Création seulement s'il est absent |
| Lire la version installée | L'image du `Deployment` `argocd-server` | `changed_when: false` |
| Appliquer le fichier | `kubectl apply -n argocd --server-side --force-conflicts` | Seulement si l'image n'est pas `quay.io/argoproj/argocd:v3.5.6` |
| Attendre les composants | `kubectl rollout status`, sur le `StatefulSet` du contrôleur et les six `Deployment` | `changed_when: false` |

Le rôle est placé dans le quatrième play de `site.yml`, après `lab_dns` et avant `workstation` : il a besoin de MetalLB pour la section suivante.

## 4. L'accès à l'interface

### Pourquoi pas par le point d'entrée d'eShop

Le `Gateway` `eshop` ([docs/03-kubernetes/14-point-entree.md](../03-kubernetes/14-point-entree.md)) n'écoute qu'en HTTP. `argocd-server`, lui, sert déjà son interface en HTTPS, avec un certificat auto-signé qu'il génère à l'installation. Le faire passer par le `Gateway` aurait demandé soit de désactiver ce HTTPS, soit de configurer un passage TLS dans Envoy Gateway : deux réglages de plus pour un outil d'administration.

Le plus simple est de donner au `Service` `argocd-server` sa propre adresse, à côté de celle du `Gateway` (`192.168.57.20`), dans la plage de MetalLB ([01-lab-local/16-metallb.md](../01-lab-local/16-metallb.md)).

### Les tâches de l'exposition

| Tâche | Rôle | Garde |
|---|---|---|
| Lire le type et l'adresse demandée du `Service` | `jsonpath={.spec.type} {.metadata.annotations.metallb\.io/loadBalancerIPs}` | `changed_when: false` |
| Exposer `argocd-server` | `kubectl patch --type merge` : type `LoadBalancer` et annotation `metallb.io/loadBalancerIPs: 192.168.57.21` | Seulement si la lecture ne donne pas `LoadBalancer 192.168.57.21` |
| Attendre l'adresse | `.status.loadBalancer.ingress[0].ip` égale à `192.168.57.21` | 12 essais, toutes les 5 s |

Le correctif est construit par Ansible (`argocd_server_patch | to_json`) plutôt qu'écrit à la main : les guillemets d'un JSON écrit dans une commande sont une source d'erreurs.

Le fichier officiel ne fixe pas le type du `Service`. Le modifier ainsi ne crée donc pas de conflit lors d'une future mise à jour d'Argo CD.

### Le mot de passe d'administration

À l'installation, Argo CD génère un mot de passe pour le compte `admin` et le range dans le secret `argocd-initial-admin-secret`. Il ne doit pas apparaître à l'écran ni dans un fichier. Depuis WSL2, il est copié directement dans le presse-papiers de Windows :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }
kubectl -n argocd get secret argocd-initial-admin-secret -o 'jsonpath={.data.password}' | base64 -d | clip.exe
```

| Élément | Rôle |
|---|---|
| `jsonpath={.data.password}` | Le seul champ utile, encodé en base64 |
| `base64 -d` | Le décode, dans WSL2 |
| `clip.exe` | L'outil de Windows qui place l'entrée dans le presse-papiers : rien ne s'affiche |

Le mot de passe est ensuite collé dans la page de connexion. Chaque reconstruction installe un nouvel Argo CD, donc un nouveau mot de passe.

## 5. Vérifier

### L'installation, sur le cluster existant

Dans WSL2, depuis `lab-local/ansible`, deux passages du playbook, avant l'ajout des tâches d'exposition. Résultats vérifiés le 23 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Premier passage | `kube-control` `ok=68 changed=3 failed=0` : téléchargement, création de l'espace de noms, application du fichier |
| Second passage | `kube-control` `ok=66 changed=0` : l'image installée est la bonne, rien n'est réappliqué |
| Pods | Les 7 composants `Running`, tous sur `kube-worker` : le Control Plane n'accepte pas les pods ordinaires |
| Définitions d'objets | 3 CRD : `applications`, `applicationsets` et `appprojects` en `argoproj.io` |
| Version | `quay.io/argoproj/argocd:v3.5.6` |
| Mémoire de `kube-worker` | 3 702 Mo disponibles sur 5 922 après l'installation |

### L'interface

Le 23 octobre 2026, depuis le navigateur de Windows, `https://192.168.57.21` affiche un avertissement de certificat (attendu, il est auto-signé), puis la page de connexion. La connexion d'`admin`, avec le mot de passe copié, fonctionne : la page « Applications » est vide, aucune n'étant encore déclarée.

Les compteurs du playbook après l'ajout des tâches d'exposition n'ont pas été relevés sur le cluster existant. Le rôle complet a ensuite été validé par une reconstruction, le 24 novembre 2026 : sur machines neuves, l'espace de noms est créé, le fichier appliqué, le `Service` exposé (`changed`), et MetalLB attribue `192.168.57.21` dès le premier essai d'attente ([guide 04](04-amorcage.md)).

## 6. Les limites

| Limite | Conséquence |
|---|---|
| Le compte `admin` est le seul compte | Pas de comptes nominatifs ni d'authentification unique (SSO). En entreprise, Argo CD est relié à l'annuaire de l'organisation |
| Certificat auto-signé | Le navigateur avertit à chaque nouvelle installation. Un certificat signé par une autorité du laboratoire supprimerait l'avertissement |
| Argo CD ne se gère pas lui-même | Ses mises à jour passent par la variable `argocd_version` et le playbook, pas par Git |
| Le mot de passe initial n'est pas changé | Le secret `argocd-initial-admin-secret` reste dans le cluster ; la documentation d'Argo CD conseille de le supprimer une fois le mot de passe changé |

## 7. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Composants et version
kubectl -n argocd get pods -o wide
kubectl -n argocd get deployment argocd-server -o 'jsonpath={.spec.template.spec.containers[0].image}'; echo

# Adresse de l'interface
kubectl -n argocd get service argocd-server

# Mot de passe d'admin, dans le presse-papiers de Windows
kubectl -n argocd get secret argocd-initial-admin-secret -o 'jsonpath={.data.password}' | base64 -d | clip.exe
```

## 8. Étape suivante

Déclarer les 13 releases d'eShop à Argo CD, et lui faire reprendre les objets déployés par Helm : [02-applicationset.md](02-applicationset.md).
