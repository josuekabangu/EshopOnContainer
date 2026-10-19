# 15 — Le contrôleur Sealed Secrets et la clé du cluster

## 1. Objectif

Le dépôt est public. Un objet `Secret` de Kubernetes n'y a donc pas sa place : ses valeurs sont seulement encodées en base64, pas chiffrées. Jusqu'ici, les secrets de l'application étaient donc créés par commande, et disparaissaient à chaque reconstruction du cluster.

Sealed Secrets règle ce problème. Un secret est chiffré sur le poste de contrôle, et le fichier chiffré, un `SealedSecret`, peut être commité. Dans le cluster, un contrôleur le déchiffre et crée le `Secret` ordinaire correspondant.

Ce guide installe ce contrôleur par un rôle Ansible, et règle le point délicat de l'outil : **la clé qui permet de déchiffrer doit survivre aux reconstructions du cluster**. L'usage, c'est-à-dire chiffrer un secret et l'appliquer, fait l'objet de [docs/03-kubernetes/04-secrets.md](../03-kubernetes/04-secrets.md).

**État au 18 octobre 2026 :** le contrôleur Sealed Secrets v0.40.0 est installé par le rôle `sealed_secrets`. Sa clé est sauvegardée sur le poste de contrôle et restaurée à chaque reconstruction. Une reconstruction complète a retrouvé la même clé, et les secrets du dépôt ont été déchiffrés sans rien ressaisir.

## 2. Le problème de la clé

Le contrôleur utilise une paire de clés :

| Clé | Rôle | Où elle vit |
|---|---|---|
| Clé publique (certificat) | Chiffrer. Elle ne permet pas de déchiffrer | Dans le dépôt : `kubernetes/sealed-secrets-cert.pem` |
| Clé privée | Déchiffrer | Dans un `Secret` de `kube-system`, et dans une sauvegarde hors du dépôt |

Au premier démarrage, le contrôleur cherche une clé existante. S'il n'en trouve pas, il en crée une. Or `rebuild.ps1 -Rebuild` reconstruit le cluster à partir de machines neuves : sans précaution, le contrôleur réinstallé créerait une nouvelle paire, et **tous les fichiers chiffrés du dépôt deviendraient indéchiffrables**.

D'où trois règles :

| Règle | Raison |
|---|---|
| Sauvegarder la clé privée hors du dépôt, sur le poste de contrôle, avec une copie dans un gestionnaire de mots de passe | Elle déchiffre tous les secrets : elle ne doit jamais entrer dans Git |
| La restaurer **avant** le démarrage du contrôleur | Il adopte alors la clé existante au lieu d'en créer une |
| Désactiver le renouvellement automatique de la clé | Par défaut, le contrôleur ajoute une nouvelle clé tous les 30 jours. Il faudrait toutes les sauvegarder |

Le dernier point est une simplification de laboratoire. En entreprise, on garde le renouvellement, et l'on sauvegarde toutes les clés, par exemple avec une tâche planifiée.

## 3. Le fichier d'installation

La version `v0.40.0`, la plus récente au 17 octobre 2026, est publiée le 10 septembre 2026. Le projet a changé d'adresse sur GitHub : il est désormais sous `bitnami/sealed-secrets`, au lieu de `bitnami-labs/sealed-secrets`.

Le fichier `controller.yaml` de la version crée, dans `kube-system` :

| Objet | Rôle |
|---|---|
| `CustomResourceDefinition` `sealedsecrets.bitnami.com` | Le nouveau type d'objet `SealedSecret` |
| `Deployment` `sealed-secrets-controller` | Le contrôleur, image `docker.io/bitnami/sealed-secrets-controller:0.40.0` |
| `ServiceAccount`, `Role`, `ClusterRole` et leurs liaisons | Droits du contrôleur : lire les `SealedSecret`, créer les `Secret`, gérer sa clé |
| Deux `Service` | L'accès au contrôleur, par exemple pour récupérer le certificat, et ses métriques |

Le contrôleur y reçoit une liste d'arguments vide, `args: []`. Le rôle la remplace.

## 4. Le rôle `sealed_secrets`

### Les variables

À la fin de `group_vars/control_plane.yml` :

```yaml
sealed_secrets_version: "v0.40.0"
sealed_secrets_manifest_url: "https://github.com/bitnami/sealed-secrets/releases/download/{{ sealed_secrets_version }}/controller.yaml"
sealed_secrets_manifest_path: "/etc/kubernetes/sealed-secrets-{{ sealed_secrets_version }}.yaml"
# Sauvegarde de la clé privée, sur le poste de contrôle (WSL2), hors du dépôt
sealed_secrets_backup_dir: "{{ lookup('env', 'HOME') }}/.config/eshoponcontainer/sealed-secrets"
```

`lookup('env', 'HOME')` lit le dossier personnel de l'utilisateur qui lance Ansible, dans WSL2. La sauvegarde est ainsi rangée hors du dépôt, sans écrire de chemin personnel dans un fichier.

### Les tâches

`roles/sealed_secrets/tasks/main.yml` suit l'ordre suivant :

| Tâche | Rôle | Condition ou garde |
|---|---|---|
| Télécharger le fichier de définition | Copie la version figée sur `kube-control` | `get_url` ne retélécharge pas un fichier présent |
| Désactiver le renouvellement de la clé | Remplace `- args: []` par `- args: ["--key-renew-period=0"]` | `replace` ne modifie rien si le remplacement est déjà fait |
| Chercher la sauvegarde de la clé | `stat` sur `tls.key`, **dans WSL2** | `delegate_to: localhost` |
| Chercher la clé active dans le cluster | Un `Secret` de `kube-system` étiqueté `sealedsecrets.bitnami.com/sealed-secrets-key=active` | `changed_when: false` |
| **Restaurer la clé** (bloc) | Copier `tls.crt` et `tls.key` sur `kube-control`, créer le `Secret` de type TLS `sealed-secrets-key`, l'étiqueter comme active, supprimer les copies | Seulement si la sauvegarde existe **et** si le cluster n'a aucune clé active |
| Comparer, puis appliquer le fichier | `kubectl diff`, puis `kubectl apply` | Application seulement si `diff` signale une différence (code 1) |
| Attendre le contrôleur | `kubectl rollout status`, jusqu'à 300 s | `changed_when: false` |
| **Sauvegarder la clé** (bloc) | Lire `tls.crt` et `tls.key` dans le cluster, créer le dossier de sauvegarde, y écrire les deux fichiers | Seulement si aucune sauvegarde n'existe |

Les points qui comptent :

- **L'ordre.** La restauration vient avant l'application du fichier : un contrôleur qui démarre sans clé active en crée une. La sauvegarde vient après l'attente du contrôleur : c'est lui qui crée la clé au premier passage.
- **`delegate_to: localhost` avec `become: false`.** Les tâches de sauvegarde s'exécutent dans WSL2, sous l'utilisateur courant, et non sur la machine virtuelle en administrateur.
- **`no_log: true`** sur la lecture et l'écriture de la clé. Ansible n'affiche pas son contenu, même en cas d'erreur ou en mode verbeux.
- **Les droits.** Le dossier de sauvegarde est en `0700`, les deux fichiers en `0600`. Les copies déposées sur `kube-control` pour la restauration sont supprimées aussitôt : la clé n'y reste que dans le `Secret` du cluster.
- **Le contenu des secrets est en base64.** La lecture passe par `jsonpath={.items[0].data.tls\.crt}`, avec le point protégé, comme dans le rôle `local_path`. L'écriture décode avec le filtre `b64decode`.

### Le play

Le rôle rejoint le quatrième play de `site.yml`, après `local_path` :

```yaml
- name: Installer les composants du cluster
  hosts: control_plane
  become: true

  roles:
    - local_path
    - sealed_secrets
```

Comme `local-path-provisioner`, le contrôleur est un pod ordinaire, qui ne peut pas tourner sur `kube-control`. Il a donc sa place après la jonction du Worker.

## 5. Valider sur le cluster existant

Dans WSL2, depuis `lab-local/ansible` :

```bash
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml
ansible-playbook site.yml
ls -l ~/.config/eshoponcontainer/sealed-secrets/
```

Résultats vérifiés le 18 octobre 2026 :

| Passage | `kube-control` | Tâches du rôle |
|---|---|---|
| Premier | `ok=45 changed=5 failed=0` | Téléchargement, renouvellement désactivé, application, dossier de sauvegarde créé, clé écrite. Restauration sautée : aucune sauvegarde n'existait |
| Second | `ok=41 changed=0 failed=0` | Restauration sautée : le cluster a une clé active. Sauvegarde sautée : elle existe |

```text
-rw------- 1 <utilisateur> <utilisateur> 1724 Oct 18 00:57 tls.crt
-rw------- 1 <utilisateur> <utilisateur> 3243 Oct 18 00:57 tls.key
```

### Vérifier la sauvegarde sans afficher la clé

La clé privée ne s'affiche jamais. Pour vérifier que la sauvegarde est bien la clé du cluster, on compare les **empreintes** des certificats :

```bash
CP="ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10"
B=~/.config/eshoponcontainer/sealed-secrets

# Empreinte de la sauvegarde
openssl x509 -in "$B/tls.crt" -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-29

# Empreinte de la clé active du cluster
$CP 'kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o jsonpath="{.items[0].data.tls\.crt}"' \
  | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-29

# La clé privée sauvegardée correspond-elle à son certificat ?
[ "$(openssl x509 -in "$B/tls.crt" -noout -pubkey)" = "$(openssl pkey -in "$B/tls.key" -pubout)" ] && echo oui || echo non
```

Seul le début de l'empreinte est affiché : il suffit à comparer.

Résultats vérifiés le 18 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Arguments du contrôleur | `["--key-renew-period=0"]`, `1/1` prêt, image `0.40.0` |
| Journal du contrôleur | `Searching for existing private keys`, puis `New key written` : premier déploiement, il a créé sa clé |
| Empreinte de la sauvegarde | `5C:0B:57:61:04:87:3A:25:B0:16` |
| Empreinte de la clé du cluster | `5C:0B:57:61:04:87:3A:25:B0:16`, la même |
| Clé privée et certificat de la sauvegarde assortis | Oui |
| Validité du certificat | Jusqu'au 14 octobre 2036 |
| Clé présente dans le dépôt | Non |

### La seconde copie

Le contenu de `tls.key` est ensuite enregistré dans un gestionnaire de mots de passe. Si WSL2 était perdu, ce serait la seule copie restante : sans elle, tous les fichiers chiffrés du dépôt devraient être recréés, avec une nouvelle clé.

## 6. Valider par une reconstruction

La validation précédente ne prouve pas que la restauration fonctionne : elle a été sautée aux deux passages. Le test décisif est une reconstruction complète, depuis PowerShell, à la racine du dépôt :

```powershell
powershell -ExecutionPolicy Bypass -File .\lab-local\scripts\rebuild.ps1 -Rebuild
```

Cette fois, la sauvegarde existe, et le cluster neuf n'a aucune clé : la restauration doit s'exécuter.

Résultats vérifiés le 18 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Durée de la reconstruction | 7 min 03 |
| Restauration | Exécutée : `Copier la clé sauvegardée`, `Créer le secret de la clé`, `Marquer la clé comme active`, `Supprimer les copies` |
| Sauvegarde | Sautée |
| Récapitulatif | `kube-control` : `ok=53 changed=37 failed=0` ; `kube-worker` : `ok=28 changed=22 failed=0` |
| Empreinte de la clé du cluster neuf | `5C:0B:57:61:04:87:3A:25:B0:16`, la même qu'avant |
| Nombre de clés dans le cluster | 1 : le contrôleur n'en a pas créé |
| Journal du contrôleur | `registered private key secretname=sealed-secrets-key` : il a adopté la clé restaurée |
| Secrets du dépôt | Déchiffrés sur le cluster neuf, sans rien ressaisir ([docs/03-kubernetes/04-secrets.md](../03-kubernetes/04-secrets.md), section 8) |

Si le contrôleur avait créé une nouvelle clé, les `SealedSecret` du dépôt seraient restés sans `Secret`, avec l'état `no key could decrypt secret`.

## 7. Les limites

| Limite | Conséquence | Traitement |
|---|---|---|
| Une seule clé, jamais renouvelée | Une clé volée déchiffre tous les secrets commités, passés et présents | Acceptable pour un laboratoire. En cas de fuite : nouvelle clé, nouveaux secrets **et** nouvelles valeurs, puisque l'historique Git garde les anciens fichiers |
| La sauvegarde vit sur le poste de contrôle | La perte de WSL2 sans seconde copie rend les fichiers chiffrés inutilisables | Copie dans un gestionnaire de mots de passe |
| La restauration suppose un cluster sans clé | Si une autre clé était déjà active, la sauvegarde ne serait pas restaurée | Ce cas n'arrive pas avec `rebuild.ps1 -Rebuild`, qui part de machines neuves |
| Le contrôleur n'existe que dans le laboratoire | Sur EKS, les secrets viendront d'AWS Secrets Manager | Voir [docs/03-kubernetes/04-secrets.md](../03-kubernetes/04-secrets.md), section 2 |

## 8. Tableau de validation

| Contrôle | Résultat au 18 octobre 2026 |
|---|---|
| Rôle `sealed_secrets`, quatrième play | Ajouté |
| Second passage du playbook | `changed=0` |
| Renouvellement de la clé | Désactivé |
| Sauvegarde identique à la clé du cluster | Oui, par empreinte |
| Reconstruction complète | Réussie, 7 min 03, restauration exécutée |
| Même clé après reconstruction | Oui |

## 9. Étape suivante

Le cluster sait déchiffrer les secrets du dépôt. Les chiffrer, et remplacer les secrets créés par commande, est décrit dans [docs/03-kubernetes/04-secrets.md](../03-kubernetes/04-secrets.md).

## 10. Commandes de référence

```bash
CP="ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10"

# Contrôleur
$CP kubectl -n kube-system get deploy sealed-secrets-controller
$CP kubectl -n kube-system logs deploy/sealed-secrets-controller

# Clés du contrôleur (noms seulement)
$CP kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key

# Empreinte de la sauvegarde
openssl x509 -in ~/.config/eshoponcontainer/sealed-secrets/tls.crt -noout -fingerprint -sha256
```

**Bilan :** le contrôleur Sealed Secrets est installé et figé par Ansible. Sa clé est sauvegardée hors du dépôt au premier passage, puis restaurée avant chaque démarrage sur un cluster neuf. Une reconstruction complète l'a prouvé : même clé, et secrets du dépôt déchiffrés sans rien ressaisir.
