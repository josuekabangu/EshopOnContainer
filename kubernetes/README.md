# Manifestes Kubernetes

Ce répertoire contient les fichiers qui décrivent ce que le projet déploie sur le cluster du laboratoire.

## Cible

| Élément | Valeur |
|---|---|
| Cluster | Laboratoire local, construit par `lab-local/` : `kube-control` (192.168.57.10) et `kube-worker` (192.168.57.11) |
| Version de Kubernetes | v1.36.5, installée par kubeadm |
| Espace de noms de l'application | `eshop` |
| Registre d'images | `ghcr.io/josuekabangu`, privé |
| Version des images | Identifiant court du commit qui les a produites ; `87e28f8` au 16 octobre 2026 |
| Secret d'accès au registre | `ghcr-pull`, dans l'espace de noms `eshop` |

## Pourquoi des manifestes écrits à la main ?

Les ressources sont d'abord décrites en manifestes YAML, appliqués un par un et vérifiés à chaque étape, comme les services l'ont été un par un dans Docker Compose. Chaque objet Kubernetes est ainsi compris avant d'être factorisé.

Une fois l'application validée sur le cluster, ces manifestes serviront de base aux charts Helm du répertoire `helm/`.

## Règles

- **Aucun secret dans un fichier.** Mots de passe et jetons ne sont jamais écrits dans ce répertoire, ni ailleurs dans le dépôt, qui est public. Les objets `Secret` sont créés par commande, à partir d'une saisie masquée, comme `ghcr-pull`.
- **Des images à version fixe.** Une image est toujours désignée par son nom complet et l'identifiant du commit, jamais par `latest`.
- **Un fichier, une responsabilité.** Chaque manifeste décrit un composant, ou un test.
- **Un manifeste n'entre ici qu'une fois vérifié.** Il a été appliqué au cluster, et son résultat est documenté dans un guide.
- **Tenir à jour les tableaux ci-dessous**, y compris celui des ressources créées par commande, qui n'ont pas de fichier.

## Contenu

| Fichier | Rôle | Guide |
|---|---|---|
| Aucun manifeste à ce jour | | |

Le test du réseau du cluster, `network-test.yaml`, vérifie le laboratoire et non l'application. Il se trouve dans `lab-local/tests/`.

## Ressources créées par commande

Ces ressources existent sur le cluster sans fichier dans ce répertoire. Elles disparaissent à chaque reconstruction du cluster et doivent alors être recréées.

| Ressource | Espace de noms | Pourquoi sans fichier | Guide |
|---|---|---|---|
| Espace de noms `eshop` | — | Créé avec le secret, avant tout manifeste de l'application | [docs/03-kubernetes/01-registre-images.md](../docs/03-kubernetes/01-registre-images.md), section 6 |
| Secret `ghcr-pull` | `eshop` | Il contient le jeton de lecture du registre | Même guide, section 6 |

## Appliquer un manifeste

`kubectl` est configuré sur `kube-control`, et les fichiers du dépôt n'y sont pas. Depuis WSL2, à la racine du dépôt, le fichier est donc envoyé par SSH sur l'entrée de `kubectl` :

```bash
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl apply -f - < kubernetes/<fichier>.yaml
```

`-f -` indique à `kubectl` de lire le manifeste sur son entrée. La redirection `<` y envoie le fichier local.

Pour supprimer les ressources d'un manifeste :

```bash
ssh -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl delete -f - < kubernetes/<fichier>.yaml
```

## Reconstruction du cluster

`lab-local/scripts/rebuild.ps1 -Rebuild` reconstruit le cluster à partir de machines neuves (voir [lab-local/README.md](../lab-local/README.md), section 8). Tout ce qui a été déployé disparaît alors : les ressources créées par commande, listées plus haut, et celles des manifestes, à réappliquer.
