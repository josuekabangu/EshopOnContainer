# 04 — L'amorçage : un cluster neuf qui se remplit seul depuis GitHub

## 1. Objectif

Jusqu'ici, l'`ApplicationSet` `eshop` n'existait dans le cluster que parce qu'il y avait été appliqué à la main ([guide 02](02-applicationset.md)). Après un `rebuild.ps1 -Rebuild`, le laboratoire aurait eu Argo CD, mais **aucune application** : il aurait fallu se souvenir de la commande.

Ce guide fait appliquer l'`ApplicationSet` par le rôle Ansible `argocd`. Puis il en apporte la preuve par une reconstruction complète, sans aucune commande de déploiement.

**État au 24 novembre 2026 :** une reconstruction produit, en 9 min 49, un cluster sur lequel Argo CD déploie seul les 13 applications. Le dernier service est prêt 1 min 30 après la première synchronisation. Le parcours dans le navigateur fonctionne : création d'un compte, commande payée, notification reçue par WebhookClient.

## 2. Les tâches d'amorçage

### La variable

Dans `lab-local/ansible/group_vars/control_plane.yml`, après celles d'Argo CD ([guide 01](01-installation.md)) :

```yaml
argocd_applicationset_path: "/etc/kubernetes/argocd-eshop.yaml"
```

### Les trois tâches

À la fin de [lab-local/ansible/roles/argocd/tasks/main.yml](../../lab-local/ansible/roles/argocd/tasks/main.yml) (commit `2b4fbdd`) :

```yaml
# Amorçage : une fois l'ApplicationSet en place, Argo CD déploie eShop depuis GitHub.
# Le fichier vient du dépôt (argocd/eshop.yaml), pas du rôle : une seule source
- name: Déposer l'ApplicationSet d'eShop
  ansible.builtin.copy:
    src: "{{ playbook_dir }}/../../argocd/eshop.yaml"
    dest: "{{ argocd_applicationset_path }}"
    owner: root
    group: root
    mode: '0644'

- name: Comparer l'ApplicationSet d'eShop avec l'état du cluster
  ansible.builtin.command:
    cmd: "kubectl diff -f {{ argocd_applicationset_path }}"
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  register: argocd_applicationset_diff
  changed_when: false
  failed_when: argocd_applicationset_diff.rc > 1

- name: Appliquer l'ApplicationSet d'eShop
  ansible.builtin.command:
    cmd: "kubectl apply -f {{ argocd_applicationset_path }}"
  environment:
    KUBECONFIG: /etc/kubernetes/admin.conf
  when: argocd_applicationset_diff.rc == 1
```

| Élément | Rôle |
|---|---|
| `{{ playbook_dir }}/../../argocd/eshop.yaml` | `playbook_dir` est le dossier de `site.yml`, `lab-local/ansible/` : on remonte à la racine du dépôt. Le fichier n'est pas copié dans `roles/argocd/files/`, où une seconde version finirait par diverger de la première |
| `kubectl diff`, `failed_when: rc > 1` | Code 0 : aucun écart ; 1 : un écart, ou l'objet n'existe pas encore ; 2 et plus : une erreur. La même garde que les rôles `calico`, `metallb` ou `lab_dns` ([01-lab-local/06-roles.md](../01-lab-local/06-roles.md), section 7) |
| `kubectl apply`, sans `--server-side` | Le mode dans lequel l'`ApplicationSet` avait été appliqué à la main : la comparaison et l'application restent cohérentes |

Ces tâches suivent l'exposition de l'interface : elles ont besoin d'Argo CD prêt, et le rôle `sealed_secrets`, plus tôt dans le même play, a déjà restauré la clé qui déchiffre les secrets d'eShop ([01-lab-local/15-sealed-secrets.md](../01-lab-local/15-sealed-secrets.md)).

Ansible ne fait que **déposer la déclaration** : c'est Argo CD qui déploie, depuis GitHub. Une modification de l'application ne demande donc jamais de relancer le playbook.

## 3. La preuve : une reconstruction

Dans PowerShell, à la racine du dépôt :

```powershell
.\lab-local\scripts\rebuild.ps1 -Rebuild
```

Puis plus aucune commande de déploiement. Résultats vérifiés le 24 novembre 2026 :

| Contrôle | Résultat |
|---|---|
| Récapitulatif d'Ansible | `kube-control` `ok=92 changed=55 failed=0 skipped=4`, `kube-worker` `ok=28 changed=22 failed=0` |
| Durée de la reconstruction | 9 min 49, création des machines comprise |
| `Déposer l'ApplicationSet d'eShop` | `changed` : le fichier est copié depuis le dépôt |
| `Comparer…` | `ok` : `kubectl diff` a répondu 1, l'objet n'existait pas |
| `Appliquer…` | `changed` : l'`ApplicationSet` est créé |

Juste après, sur `kube-control`, la comparaison faite par le rôle :

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl diff -f /etc/kubernetes/argocd-eshop.yaml
```

La sortie est vide, code 0 : au passage suivant du playbook, `Appliquer…` serait ignoré. Ce passage suivant n'a pas encore été lancé ; ses compteurs restent à relever.

### Le déploiement par Argo CD

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,DEBUT:.status.operationState.startedAt,FIN:.status.operationState.finishedAt
kubectl -n eshop get pods -o custom-columns='NAME:.metadata.name,CREE:.metadata.creationTimestamp,PRET:.status.conditions[?(@.type=="Ready")].lastTransitionTime'
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl list_queues name consumers
```

`DEBUT` et `FIN` sont ceux de l'**application des objets** par Argo CD, pas de leur mise en service. L'heure où chaque pod est devenu prêt est la condition `Ready` du pod.

| Étape, 24 novembre 2026 (UTC) | Heure | Depuis la première synchronisation |
|---|---|---|
| Premières synchronisations, les 13 en parallèle | 10:02:03 | 0 s |
| Objets des 13 applications appliqués | 10:02:08 | 5 s |
| PostgreSQL prêt | 10:02:46 | 43 s |
| RabbitMQ prêt | 10:03:04 | 1 min 01 |
| Redis prêt | 10:03:08 | 1 min 05 |
| Dernier service prêt, `catalog-api` | 10:03:33 | **1 min 30** |

| Contrôle | Résultat |
|---|---|
| Applications | Les 13 `Synced Healthy` |
| Services | Les 9 `Running`, **0 redémarrage**, sur les images `f9bbdda` désignées par `main` |
| Dépendances | `postgres-0` et `redis-0` sans redémarrage ; `rabbitmq-0` avec **1 redémarrage** (section 4) |
| Files RabbitMQ | Les 7, avec 1 consommateur chacune |
| Parcours dans le navigateur | Base vide sur ce cluster neuf : compte créé, article ajouté au panier, commande menée à `Paid`, notification reçue par WebhookClient |

Le 22 octobre 2026, `helm/deploy.sh` avait mis 2 min 54 sur un cluster tout juste reconstruit, en attendant chaque dépendance avant de passer à la suivante ([docs/04-helm/04-deploiement.md](../04-helm/04-deploiement.md)). Argo CD lance tout en même temps. Les services n'ont pourtant pas redémarré : leur `initContainer` attend que RabbitMQ accepte les connexions ([docs/03-kubernetes/17-ordre-de-demarrage.md](../03-kubernetes/17-ordre-de-demarrage.md)). Ce que `deploy.sh` garantissait par l'ordre, chaque service le garantit pour lui-même.

## 4. Le redémarrage de RabbitMQ

### Symptôme

`rabbitmq-0` a redémarré une fois, environ une minute après sa création. Le pod suivant a fonctionné.

### Diagnostic

```bash
kubectl -n eshop get pod rabbitmq-0 -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}'
kubectl -n eshop logs rabbitmq-0 --previous --tail=50
```

| Observation | Ce qu'elle exclut ou montre |
|---|---|
| `reason: Error`, `exitCode: 1` | Pas une sonde : un arrêt par Kubernetes donnerait le code 137. Pas `OOMKilled` non plus. RabbitMQ s'est arrêté de lui-même |
| Conteneur démarré à 10:02:50, arrêté à 10:02:55 | L'erreur survient dès le démarrage |
| Journal : `Error when reading /var/lib/rabbitmq/.erlang.cookie: eacces` | RabbitMQ n'a pas le droit de lire son cookie |

Le cookie Erlang est le secret partagé entre le serveur RabbitMQ et ses outils en ligne de commande (`rabbitmq-diagnostics`, `rabbitmqctl`) : un outil qui n'a pas le même cookie ne peut pas lui parler. Le premier des deux qui démarre le crée, s'il n'existe pas encore, dans `$HOME`.

```bash
kubectl -n eshop exec rabbitmq-0 -- sh -c 'id; id rabbitmq; echo "HOME=$HOME"; ls -ln /var/lib/rabbitmq/.erlang.cookie'
kubectl -n eshop exec rabbitmq-0 -- grep -n -A2 'chown' /usr/local/bin/docker-entrypoint.sh
```

Le contenu du cookie n'est jamais affiché : `ls -ln` ne montre que son propriétaire et ses droits.

| Sortie | Ce qu'elle montre |
|---|---|
| `uid=0(root)` | Les commandes `exec`, donc les sondes, tournent en `root`, l'utilisateur par défaut de l'image |
| `uid=999(rabbitmq)` | L'utilisateur sous lequel tourne le serveur |
| `HOME=/var/lib/rabbitmq` | Le cookie est cherché, ou créé, sur le volume |
| Cookie : propriétaire `999`, **groupe `0`** | Le fichier a été créé par `root`, puis rendu à `rabbitmq` |
| Script d'entrée, ligne 7 : `find /var/lib/rabbitmq \! -user rabbitmq -exec chown rabbitmq '{}' +` | Au démarrage, le script redonne à `rabbitmq` ce qui ne lui appartient pas, propriétaire seulement : le groupe d'origine reste |

### Cause

Une course entre la sonde de démarrage et le serveur, au **premier** démarrage, sur un volume vide :

1. le conteneur démarre en `root` ; le script d'entrée prépare le dossier, puis lance le serveur sous `rabbitmq` ;
2. la sonde de démarrage, `rabbitmq-diagnostics`, s'exécute en `root`, sans délai initial ;
3. si elle passe avant que le serveur ait créé le cookie, c'est elle qui le crée : propriétaire `root`, droits `0400`. Le serveur, sous `rabbitmq`, ne peut plus le lire, et s'arrête ;
4. au redémarrage du conteneur, le script d'entrée rend le fichier à `rabbitmq` : tout fonctionne.

Le groupe `0` du cookie est la trace laissée par l'étape 3 : un fichier créé par le serveur aurait le groupe `999`.

La course existait avant Argo CD : le 22 octobre, avec `deploy.sh`, le serveur l'avait gagnée. Avec les 13 applications démarrées en même temps sur le même Worker, la sonde est passée la première.

### Correction

Faire tourner tout le pod sous l'utilisateur de l'image. Dans [helm/rabbitmq/templates/statefulset.yaml](../../helm/rabbitmq/templates/statefulset.yaml) (commit `6a86fd4`) :

```yaml
    spec:
      # Serveur et sondes sous l'utilisateur de l'image : la sonde de démarrage, en root,
      # avait créé .erlang.cookie avant le serveur, qui ne pouvait plus le lire (24 novembre 2026)
      securityContext:
        runAsUser: 999
        runAsGroup: 999
      containers:
```

| Effet | Explication |
|---|---|
| La course disparaît | Le serveur et les sondes ont le même utilisateur : le premier qui crée le cookie le crée lisible par l'autre |
| RabbitMQ ne tourne plus en `root` | Le `chown` du script d'entrée est dans un bloc conditionnel (ligne 8 : `fi`), prévu pour un démarrage en `root` : il n'a plus de raison de s'exécuter |
| Volume neuf | `local-path` crée le dossier du volume avec des droits ouverts : `rabbitmq` peut y écrire |
| Volume existant | Tout y appartient déjà à `999` ; le cookie, en `0400`, reste lisible par son propriétaire |

Avant le commit, l'effet de la correction sur le cluster, depuis WSL2 :

```bash
helm template rabbitmq helm/rabbitmq -n eshop -f helm/values/rabbitmq.yaml \
  | kubectl diff --server-side --force-conflicts -f -
```

Résultat vérifié : un seul écart, le `securityContext` du `StatefulSet`, vide auparavant (`{}`).

### Validation

Après le push, Argo CD a redémarré `rabbitmq-0` de lui-même. Résultats vérifiés le 24 novembre 2026 :

| Contrôle | Résultat |
|---|---|
| `kubectl -n eshop exec rabbitmq-0 -- id` | `uid=999(rabbitmq) gid=999(rabbitmq)` : les sondes ne tournent plus en `root` |
| `rabbitmq-0` | Nouveau pod, `1/1 Running`, 0 redémarrage |
| Services | Aucun redémarré : même âge, 0 redémarrage |
| Files RabbitMQ | Les 7, avec 1 consommateur chacune |

Le dernier point répond à une question restée ouverte depuis le 21 octobre ([docs/03-kubernetes/17-ordre-de-demarrage.md](../03-kubernetes/17-ordre-de-demarrage.md), section 5) : **après un redémarrage de RabbitMQ, les services se reconnectent et se réabonnent seuls.** Un consommateur n'est pas conservé par RabbitMQ : chacun des 7 a été recréé par son service.

La preuve que la course a disparu au premier démarrage reste à faire : elle ne se rejoue que sur un volume vide, donc à la prochaine reconstruction. Il faudra y vérifier `rabbitmq-0` sans redémarrage.

**Leçon :** une sonde `exec` s'exécute sous l'utilisateur du conteneur, pas forcément sous celui du processus qu'elle surveille. Quand l'image démarre en `root` puis change d'utilisateur, la sonde reste en `root`, et ce qu'elle écrit appartient à `root`.

## 5. Les limites

| Limite | Conséquence |
|---|---|
| Le second passage du playbook n'a pas été relevé | La garde est démontrée par le `kubectl diff` vide, pas encore par un récapitulatif `changed=0` |
| L'`ApplicationSet` est appliqué par Ansible, pas géré par Argo CD | Une modification d'`argocd/eshop.yaml` demande de relancer le playbook, ou `kubectl apply`. En entreprise, une application « racine » gérée par Argo CD lui-même porte souvent cette déclaration |
| PostgreSQL n'a pas d'attente équivalente à celle de RabbitMQ | Aucun service n'a redémarré, mais rien ne le garantit ([docs/03-kubernetes/17-ordre-de-demarrage.md](../03-kubernetes/17-ordre-de-demarrage.md), section 5) |
| Les clés d'hôte SSH changent à chaque reconstruction | `rebuild.ps1` renouvelle les empreintes dans WSL2, pas dans le `known_hosts` de Windows : un accès SSH depuis PowerShell signale un changement de clé après chaque reconstruction |

## 6. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Synchronisations et applications
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,DEBUT:.status.operationState.startedAt,FIN:.status.operationState.finishedAt

# Heure de création et de mise en service de chaque pod
kubectl -n eshop get pods -o custom-columns='NAME:.metadata.name,CREE:.metadata.creationTimestamp,PRET:.status.conditions[?(@.type=="Ready")].lastTransitionTime'

# Pourquoi le conteneur précédent s'est arrêté, et son journal
kubectl -n eshop get pod rabbitmq-0 -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}'
kubectl -n eshop logs rabbitmq-0 --previous --tail=50
```

**Bilan :** la chaîne est complète. Une reconstruction donne un cluster qui se remplit seul depuis GitHub, et un commit sur `main` arrive jusqu'au cluster sans intervention. Le dépôt est la seule description de ce qui tourne.
