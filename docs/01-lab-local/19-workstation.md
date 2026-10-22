# 19 — Le poste de contrôle : Helm, kubeseal et l'accès au cluster

## 1. Objectif

Jusqu'ici, toutes les commandes `kubectl` passaient par SSH vers `kube-control`, seule machine où `kubectl` était configuré. Helm ne fonctionne pas ainsi : il a besoin d'un accès direct à l'API du cluster, depuis le poste où se trouvent les charts.

Ce guide installe, par un rôle Ansible, les outils du poste de contrôle (WSL2) et le fichier d'accès au cluster.

**État au 22 octobre 2026 :** le rôle `workstation` installe Helm v4.3.1 et `kubeseal` v0.40.0 dans WSL2, et recopie le fichier d'accès au cluster à chaque passage. Après une reconstruction, Helm a joint le nouveau cluster sans aucune manipulation.

## 2. Pourquoi un rôle Ansible

La première idée était d'installer Helm à la main, comme `kubeseal` l'avait été ([docs/03-kubernetes/04-secrets.md](../03-kubernetes/04-secrets.md), section 3). Trois raisons l'ont écartée :

| Raison | Explication |
|---|---|
| Le fichier d'accès change à chaque reconstruction | `rebuild.ps1 -Rebuild` crée une nouvelle autorité de certification : un `~/.kube/config` recopié une fois deviendrait invalide à la reconstruction suivante. Le recopier à la main serait une étape facile à oublier |
| Ansible agit déjà sur le poste | Le rôle `sealed_secrets` y écrit la sauvegarde de sa clé (`delegate_to: localhost`) |
| La reproductibilité | Une réinstallation de WSL2 demanderait de retrouver les outils et leurs versions de mémoire |

En entreprise, Helm tourne surtout dans la chaîne d'intégration continue ou par un outil GitOps, et rarement depuis un poste ; les outils des postes sont décrits dans un environnement reproductible. Ici, cet outil est Ansible.

## 3. Le choix de Helm 4

Au 22 octobre 2026, deux séries sont maintenues : Helm 4.3.1 et 3.22.1, publiées le 15 octobre 2026. Helm 4 est la version majeure actuelle ; il applique les objets **côté serveur**, ce qui a eu une conséquence lors de la reprise des objets existants ([docs/04-helm/02-reprise.md](../04-helm/02-reprise.md)).

## 4. Le rôle `workstation`

### Les variables

À la fin de `group_vars/control_plane.yml` :

```yaml
# Outils du poste de contrôle (WSL2), installés dans ~/.local/bin
workstation_bin_dir: "{{ lookup('env', 'HOME') }}/.local/bin"
workstation_tmp_dir: "{{ lookup('env', 'HOME') }}/.cache/eshoponcontainer"
helm_version: "v4.3.1"
helm_archive_url: "https://get.helm.sh/helm-{{ helm_version }}-linux-amd64.tar.gz"
kubeseal_archive_url: "https://github.com/bitnami/sealed-secrets/releases/download/{{ sealed_secrets_version }}/kubeseal-{{ sealed_secrets_version | regex_replace('^v', '') }}-linux-amd64.tar.gz"
kubeseal_checksums_url: "https://github.com/bitnami/sealed-secrets/releases/download/{{ sealed_secrets_version }}/sealed-secrets_{{ sealed_secrets_version | regex_replace('^v', '') }}_checksums.txt"
# Accès administrateur au cluster, recopié à chaque passage : il change à chaque reconstruction
workstation_kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/config"
```

La version de `kubeseal` est déduite de `sealed_secrets_version` : l'outil et le contrôleur restent toujours à la même version.

### Les tâches

Toutes agissent sur le poste de contrôle (`delegate_to: localhost`, `become: false`), sauf la lecture du fichier d'accès sur `kube-control`.

| Tâche | Rôle | Garde |
|---|---|---|
| Créer `~/.local/bin` et `~/.cache/eshoponcontainer` | Dossiers des outils et des archives | `file` |
| Télécharger Helm et `kubeseal` | `get_url`, avec `checksum: "sha256:<adresse du fichier d'empreintes>"` | Pas de nouveau téléchargement si l'archive est là ; refus si l'empreinte ne correspond pas |
| Extraire | `unarchive`, le seul exécutable de chaque archive | `creates` |
| Installer | `copy` vers `~/.local/bin`, droits `0755` | Pas de copie d'un fichier identique |
| Créer `~/.kube` | Droits `0700` | `file` |
| Recopier le fichier d'accès | `fetch` de `/etc/kubernetes/admin.conf` | Réécrit seulement s'il a changé, donc après une reconstruction ; `no_log: true` |
| Restreindre ses droits | `0600` | `file` |

`get_url` lit le fichier d'empreintes publié par chaque projet, y cherche le nom de l'archive, et refuse un fichier qui ne correspond pas : c'est la vérification que faisait `sha256sum -c` lors de l'installation manuelle de `kubeseal`.

Le fichier d'accès donne les droits d'administrateur sur le cluster. Il n'est jamais affiché, et reste hors du dépôt, comme la clé de Sealed Secrets.

Le rôle termine le quatrième play de `site.yml`, après `lab_dns`.

## 5. Valider

Dans WSL2, depuis `lab-local/ansible` :

```bash
ansible-playbook site.yml
ansible-playbook site.yml | tail -4
ls -l ~/.local/bin/helm ~/.local/bin/kubeseal ~/.kube/config
helm version --short
kubeseal --version
helm list -A
```

Résultats vérifiés le 21 octobre 2026, sur le cluster existant :

| Contrôle | Résultat |
|---|---|
| Premier passage | `ok=63 changed=8 failed=0` : dossiers, téléchargements vérifiés, extraction, Helm installé, fichier d'accès recopié et restreint |
| `kubeseal`, déjà installé à la main | `ok` : le fichier était identique |
| Second passage | `ok=62 changed=0 skipped=20` |
| Fichier d'accès | `-rw-------` |
| Versions | `v4.3.1+gc0d08d0`, `kubeseal version: 0.40.0` |
| `helm list -A` | Sans erreur : Helm joint l'API du cluster directement, à `https://192.168.57.10:6443` |

Le 22 octobre 2026, une reconstruction complète a exécuté le rôle sur un cluster neuf : le fichier d'accès a été recopié (`changed`), le reste était déjà en place (`ok`). Récapitulatif : `kube-control` `ok=80 changed=49 failed=0`, `kube-worker` `ok=28 changed=22 failed=0`, en 17 min 46. Helm a déployé toute l'application juste après ([docs/04-helm/04-deploiement.md](../04-helm/04-deploiement.md)).

Cette reconstruction a pris 17 min 46, contre 8 min 02 la précédente, sans erreur. La cause n'a pas été établie ; un téléchargement plus lent est l'hypothèse la plus probable.

## 6. Les limites

| Limite | Conséquence |
|---|---|
| Le fichier d'accès est celui de l'administrateur | Tout ce qui tourne dans WSL2 sous ce compte a tous les droits sur le cluster. Un compte limité serait plus sûr |
| `kubectl` n'est pas installé dans WSL2 | Les commandes `kubectl` passent toujours par SSH ; seul Helm utilise le fichier d'accès |

## 7. Commandes de référence

```bash
helm version --short
kubeseal --version
helm list -A
```

**Bilan :** le poste de contrôle est décrit par Ansible, comme les machines du cluster. Helm et `kubeseal` y sont installés à version figée, empreinte vérifiée, et le fichier d'accès au cluster suit chaque reconstruction sans intervention.
