# 04 — Les secrets dans le dépôt, chiffrés

## 1. Objectif

Les guides [01](01-registre-images.md) et [03](03-postgres.md) ont créé deux secrets par commande : `ghcr-pull`, le jeton de lecture du registre, et `postgres-credentials`, le mot de passe de PostgreSQL. Cette méthode protégeait les valeurs, mais avait deux défauts :

- à chaque reconstruction du cluster, il fallait tout ressaisir ;
- le dépôt ne décrivait pas tout ce qui tourne sur le cluster.

Ce guide remplace ces deux secrets par des fichiers chiffrés, commités avec les autres manifestes. Les objectifs sont de :

- chiffrer un secret sans qu'aucune valeur en clair ne touche le disque ;
- remplacer les secrets créés par commande sans interrompre PostgreSQL ;
- prouver qu'un cluster neuf retrouve tous ses secrets depuis le dépôt seul.

Le contrôleur qui déchiffre, et la sauvegarde de sa clé, sont décrits dans [docs/01-lab-local/15-sealed-secrets.md](../01-lab-local/15-sealed-secrets.md).

**État au 18 octobre 2026 :** l'espace de noms `eshop` et les deux secrets sont décrits par des fichiers du dépôt. Après une reconstruction complète du cluster, ils ont été recréés à partir de ces fichiers seuls, et PostgreSQL a accepté le mot de passe déchiffré.

## 2. Les options, et ce qui se fait en entreprise

Un objet `Secret` n'est pas chiffré : ses valeurs sont encodées en base64, ce qui se décode en une commande. Le commiter dans un dépôt public revient à publier le mot de passe.

| Approche | Principe | Usage courant |
|---|---|---|
| **Sealed Secrets** | Le secret est chiffré avec la clé publique du cluster. Le fichier chiffré est commité ; un contrôleur le déchiffre dans le cluster | Clusters sans coffre-fort externe, démarches GitOps simples |
| SOPS (avec age, ou une clé KMS) | Le fichier YAML est chiffré valeur par valeur ; l'outil de déploiement (Flux, ou Argo CD avec un greffon) le déchiffre | Équipes qui veulent un seul format pour tous leurs fichiers chiffrés |
| **External Secrets Operator** | Les valeurs restent dans un coffre-fort externe : AWS Secrets Manager, HashiCorp Vault, Azure Key Vault. Le dépôt ne contient qu'une **référence** | Le plus courant en entreprise dans le cloud : rotation, audit et droits gérés par le coffre-fort |

Les décisions du projet :

| Environnement | Choix | Raison |
|---|---|---|
| Laboratoire | **Sealed Secrets** | Aucun coffre-fort à installer ; un seul contrôleur, léger ; le principe de la clé publique et de la clé privée reste visible |
| EKS | **External Secrets** avec **AWS Secrets Manager** | La pratique des entreprises sur AWS. Les droits passent par un rôle IAM, et Secrets Manager sait changer un mot de passe tout seul |

## 3. L'outil `kubeseal`

`kubeseal` chiffre un secret sur le poste de contrôle. Il est installé dans WSL2, à la version du contrôleur, en vérifiant l'empreinte du fichier téléchargé :

```bash
V=0.40.0
cd /tmp
curl -sLO "https://github.com/bitnami/sealed-secrets/releases/download/v$V/kubeseal-$V-linux-amd64.tar.gz"
curl -sLO "https://github.com/bitnami/sealed-secrets/releases/download/v$V/sealed-secrets_${V}_checksums.txt"
grep "kubeseal-$V-linux-amd64.tar.gz" "sealed-secrets_${V}_checksums.txt" | sha256sum -c -
tar -xzf "kubeseal-$V-linux-amd64.tar.gz" kubeseal
install -D -m 755 kubeseal ~/.local/bin/kubeseal
rm -f kubeseal "kubeseal-$V-linux-amd64.tar.gz" "sealed-secrets_${V}_checksums.txt"
cd - >/dev/null
kubeseal --version
```

- `sha256sum -c` compare l'empreinte du fichier téléchargé à celle que publie le projet. Une différence signalerait un fichier altéré.
- `install -D -m 755` place l'outil dans `~/.local/bin`, qu'Ubuntu ajoute au `PATH` à l'ouverture d'une session, sans droits d'administrateur.

Résultat vérifié le 18 octobre 2026 :

```text
kubeseal-0.40.0-linux-amd64.tar.gz: OK
kubeseal version: 0.40.0
```

### La clé publique, dans le dépôt

`kubeseal` a besoin de la clé publique du cluster. Il peut la demander au contrôleur, mais l'API du cluster n'est joignable que par SSH. La clé publique est donc copiée depuis la sauvegarde, et commitée :

```bash
cp ~/.config/eshoponcontainer/sealed-secrets/tls.crt kubernetes/sealed-secrets-cert.pem
openssl x509 -in kubernetes/sealed-secrets-cert.pem -noout -subject -enddate
```

```text
subject=
notAfter=Oct 14 22:56:38 2036 GMT
```

Le sujet vide est normal : le contrôleur ne nomme pas son certificat. Comme le rôle restaure la même clé à chaque reconstruction, ce fichier reste valable.

Avec l'option `--cert`, `kubeseal` chiffre **sans contacter le cluster**.

## 4. Le piège du `.gitignore`

Le `.gitignore` du dépôt exclut tous les fichiers `.pem`, sous la rubrique « Clés privées SSH ». La règle attrapait aussi la clé publique :

```text
$ git check-ignore -v kubernetes/sealed-secrets-cert.pem
.gitignore:9:*.pem	kubernetes/sealed-secrets-cert.pem
```

Le fichier n'aurait jamais été commité, sans aucun message, et personne n'aurait pu chiffrer un secret à partir du dépôt. Une exception est ajoutée **à la fin** du `.gitignore` :

```gitignore
# Clé publique de Sealed Secrets : elle sert seulement à chiffrer, et doit être dans le dépôt
!kubernetes/sealed-secrets-cert.pem
```

Le `!` annule une exclusion précédente pour ce seul fichier. Il doit venir après la règle `*.pem` : la dernière règle qui correspond l'emporte.

Pour vérifier, `git status` fait foi. `git check-ignore -v` affiche la règle trouvée même quand il s'agit d'une exception, et répond alors avec le code `0` :

```text
$ git check-ignore -v kubernetes/sealed-secrets-cert.pem
.gitignore:15:!kubernetes/sealed-secrets-cert.pem	kubernetes/sealed-secrets-cert.pem
$ git status --short kubernetes/
?? kubernetes/sealed-secrets-cert.pem
```

## 5. Le principe, sur un secret de test

Depuis WSL2, à la racine du dépôt. `kubectl` n'est configuré que sur `kube-control`. Une fonction du terminal l'appelle donc par SSH, pour la durée de la session :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

kubectl -n eshop create secret generic test-scelle --from-literal=valeur=bonjour --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml > /tmp/test-scelle.yaml
grep -A2 'encryptedData' /tmp/test-scelle.yaml

kubectl apply -f - < /tmp/test-scelle.yaml
sleep 3
kubectl -n eshop get secret test-scelle -o jsonpath='{.data.valeur}' | base64 -d; echo

kubectl -n eshop delete sealedsecret test-scelle
rm /tmp/test-scelle.yaml
```

| Étape | Ce qui se passe |
|---|---|
| `create secret ... --dry-run=client -o yaml` | `kubectl` met le secret en forme, **sans l'envoyer** à l'API du cluster |
| `kubeseal --cert` | Le chiffre avec la clé publique, sur le poste de contrôle |
| `kubectl apply` | Le cluster reçoit un `SealedSecret` ; le contrôleur le déchiffre et crée un `Secret` du même nom |
| `delete sealedsecret` | Le `Secret` disparaît avec lui : il appartient au `SealedSecret` |

Résultats vérifiés le 18 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| Sous `encryptedData` | Une longue chaîne commençant par `AgC…`, à la place de `bonjour` |
| Valeur lue dans le `Secret` créé par le contrôleur | `bonjour` |
| Après suppression du `SealedSecret` | Le `Secret` a disparu |

Un secret chiffré est lié à **son nom et à son espace de noms** : c'est la portée `strict`, utilisée par défaut, et le contrôleur refuse de le déchiffrer sous un autre nom. Copier un `SealedSecret` d'un espace de noms à l'autre ne permet donc pas de détourner un mot de passe. Ce comportement, documenté par le projet, n'a pas été testé dans le laboratoire.

## 6. Les fichiers du dépôt

```text
kubernetes/
├── sealed-secrets-cert.pem                    # clé publique, pour chiffrer
├── namespace-eshop.yaml                       # l'espace de noms de l'application
├── sealedsecret-ghcr-pull.yaml                # accès au registre, commun à tous les services
└── postgres/
    ├── sealedsecret-postgres-credentials.yaml
    ├── service-postgres.yaml
    └── statefulset-postgres.yaml
```

Chaque secret est rangé avec ce qui l'utilise. Celui du registre reste à la racine, puisque tous les services s'en serviront.

L'espace de noms, jusqu'ici créé par commande, a désormais son fichier :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: eshop
```

### Chiffrer les deux secrets

Les valeurs sont lues par une saisie masquée, comme dans les guides 01 et 03. Elles passent dans un tuyau, sont mises en forme par `kubectl` sans aller jusqu'à l'API, puis chiffrées par `kubeseal` avant d'être écrites. **Aucune valeur en clair ne touche le disque.**

Le secret du registre :

```bash
read -rs -p 'Jeton GitHub (read:packages) : ' GHCR_READ; echo
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$(printf 'josuekabangu:%s' "$GHCR_READ" | base64 -w0)" \
  | kubectl -n eshop create secret generic ghcr-pull \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
      --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/sealedsecret-ghcr-pull.yaml
unset GHCR_READ
```

Le secret de PostgreSQL, avec **le mot de passe déjà en place** : la base a été initialisée avec lui, et ne relit pas la variable par la suite (section 9) :

```bash
read -rs -p 'Mot de passe PostgreSQL : ' PG_PASS; echo
printf '%s' "$PG_PASS" \
  | kubectl -n eshop create secret generic postgres-credentials \
      --from-literal=POSTGRES_USER=postgres --from-file=POSTGRES_PASSWORD=/dev/stdin \
      --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml \
  > kubernetes/postgres/sealedsecret-postgres-credentials.yaml
unset PG_PASS
```

### Vérifier qu'aucune valeur ne figure en clair

```bash
grep -E '^kind:|^  name:|encryptedData|^    [A-Z.]' \
  kubernetes/sealedsecret-ghcr-pull.yaml kubernetes/postgres/sealedsecret-postgres-credentials.yaml | cut -c1-80
```

Résultat vérifié le 18 octobre 2026 :

| Fichier | Type | Clés chiffrées | Nom d'utilisateur en clair |
|---|---|---|---|
| `sealedsecret-ghcr-pull.yaml` | `SealedSecret` | `.dockerconfigjson` | Absent |
| `sealedsecret-postgres-credentials.yaml` | `SealedSecret` | `POSTGRES_PASSWORD`, `POSTGRES_USER` | Absent : `postgres` est chiffré lui aussi |

## 7. Remplacer les secrets créés par commande

Le contrôleur **refuse d'écraser** un `Secret` qu'il n'a pas créé : c'est une protection contre la perte d'un secret existant. Les deux anciens sont donc supprimés juste avant l'application des nouveaux :

```bash
kubectl apply -f - < kubernetes/namespace-eshop.yaml

kubectl -n eshop delete secret ghcr-pull postgres-credentials
kubectl apply -f - < kubernetes/sealedsecret-ghcr-pull.yaml
kubectl apply -f - < kubernetes/postgres/sealedsecret-postgres-credentials.yaml
sleep 3
kubectl -n eshop get sealedsecret,secret
```

Résultat vérifié le 18 octobre 2026 :

```text
Warning: resource namespaces/eshop is missing the kubectl.kubernetes.io/last-applied-configuration annotation ...
namespace/eshop configured
secret "ghcr-pull" deleted from eshop namespace
secret "postgres-credentials" deleted from eshop namespace
sealedsecret.bitnami.com/ghcr-pull created
sealedsecret.bitnami.com/postgres-credentials created

NAME                          TYPE                             DATA   AGE
secret/ghcr-pull              kubernetes.io/dockerconfigjson   1      4s
secret/postgres-credentials   Opaque                           2      4s
```

L'avertissement est sans conséquence. L'espace de noms avait été créé par `kubectl create`, qui ne laisse pas la trace qu'utilise `kubectl apply` pour comparer. Elle a été ajoutée automatiquement, et l'espace de noms est désormais géré depuis son fichier.

Pendant le remplacement, `postgres-0` a continué de fonctionner : un pod lit ses variables d'environnement à son démarrage, et ne les relit pas.

### Prouver que le nouveau secret est le bon

PostgreSQL a ensuite été redémarré, pour qu'il lise le secret déchiffré par le contrôleur :

```bash
kubectl -n eshop rollout restart statefulset/postgres
kubectl -n eshop rollout status statefulset/postgres --timeout=180s
```

Un redémarrage réussi ne prouve rien sur le mot de passe : la base ne relit pas la variable. Le test se fait donc **par TCP**, avec la valeur que le pod a reçue du secret :

```bash
kubectl -n eshop exec -i postgres-0 -- sh <<'EOF'
PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -At -c 'select current_user'
EOF
```

Par le socket local, sans `-h`, l'image PostgreSQL accepte toute connexion sans vérifier le mot de passe. Une faute de frappe à la saisie aurait passé ce test, puis fait échouer le premier service.

Résultats vérifiés le 18 octobre 2026 :

| Contrôle | Résultat |
|---|---|
| `postgres-0` après redémarrage | `1/1 Running` |
| Connexion par TCP avec le mot de passe déchiffré | Acceptée : `postgres` |
| Propriétaire des deux `Secret` | `SealedSecret` : ils sont créés et gérés par le contrôleur |

## 8. La preuve : un cluster neuf, depuis le dépôt seul

Le cluster a été reconstruit à partir de machines neuves (`rebuild.ps1 -Rebuild`, [docs/01-lab-local/15-sealed-secrets.md](../01-lab-local/15-sealed-secrets.md), section 6). Tout a ensuite été appliqué depuis les fichiers du dépôt, sans aucune saisie :

```bash
kubectl apply -f - < kubernetes/namespace-eshop.yaml
kubectl apply -f - < kubernetes/sealedsecret-ghcr-pull.yaml
for f in kubernetes/postgres/*.yaml; do echo '---'; cat "$f"; done | kubectl apply -f -
kubectl -n eshop rollout status statefulset/postgres --timeout=180s
kubectl -n eshop get sealedsecret,secret,pods,pvc
```

L'espace de noms doit exister avant les autres objets, d'où sa commande à part.

Résultat vérifié le 18 octobre 2026 :

```text
namespace/eshop created
sealedsecret.bitnami.com/ghcr-pull created
sealedsecret.bitnami.com/postgres-credentials created
service/postgres created
statefulset.apps/postgres created
partitioned roll out complete: 1 new pods have been updated...

NAME                          TYPE                             DATA   AGE
secret/ghcr-pull              kubernetes.io/dockerconfigjson   1      24s
secret/postgres-credentials   Opaque                           2      23s

NAME             READY   STATUS    RESTARTS   AGE
pod/postgres-0   1/1     Running   0          23s

NAME                                    STATUS   VOLUME                                     CAPACITY   STORAGECLASS
persistentvolumeclaim/data-postgres-0   Bound    pvc-9b5c6f26-87e7-4aba-a8db-2053d42b1977   2Gi        local-path
```

Le volume est neuf, puisque les disques ont été détruits avec les machines. PostgreSQL a donc initialisé une base neuve, avec le mot de passe du secret. La connexion par TCP de la section 7, rejouée, a répondu `postgres`.

**Plus aucune ressource de l'application n'est créée par commande.** Tout ce qui tourne dans `eshop` vient du dépôt. Seule la clé privée du contrôleur reste hors de Git.

## 9. Changer un mot de passe

Cette procédure est décrite ici pour référence. **Elle n'a pas encore été déroulée sur le cluster.**

### Ce qu'il faut savoir avant

L'image PostgreSQL ne lit `POSTGRES_PASSWORD` qu'une fois : quand elle initialise un volume vide. Ensuite, le mot de passe est stocké dans la base. **Changer le secret ne change donc pas le mot de passe.** Il faut changer deux choses, dans cet ordre : la base, puis le secret.

| Situation | Ce qui se passe |
|---|---|
| Seul le secret est changé | La base garde l'ancien mot de passe ; les clients qui utilisent le nouveau sont refusés |
| Seule la base est changée | Les pods utilisent toujours l'ancien ; la prochaine reconstruction remet l'ancien, sur un volume neuf |
| Entre le changement de la base et le redémarrage des clients | Les nouvelles connexions avec l'ancien mot de passe sont refusées |
| Après une reconstruction | Aucun problème : volume neuf, base initialisée avec la valeur du secret |

### 1. Changer le mot de passe dans la base

```bash
ssh -t -i ~/.ssh/vagrant/kube-control vagrant@192.168.57.10 \
  kubectl exec -it -n eshop postgres-0 -- psql -U postgres
```

Puis, dans `psql` :

```text
\password postgres
\q
```

`\password` demande le nouveau mot de passe deux fois, sans l'afficher, et le chiffre avant de l'envoyer au serveur. Il n'apparaît ni dans l'historique, ni dans les journaux. Un `ALTER USER ... PASSWORD '...'` l'aurait laissé en clair dans les deux.

### 2. Chiffrer le nouveau secret et l'appliquer

Avec le même mot de passe qu'à l'étape 1, par la commande de la section 6, puis :

```bash
kubectl apply -f - < kubernetes/postgres/sealedsecret-postgres-credentials.yaml
```

Le contrôleur met à jour le `Secret`, dont il est propriétaire.

### 3. Redémarrer les pods qui lisent le secret

```bash
kubectl -n eshop rollout restart statefulset/postgres
kubectl -n eshop rollout status statefulset/postgres --timeout=180s
```

Pour PostgreSQL, ce redémarrage ne sert qu'au contrôle de l'étape 4. Quand les services seront déployés, ce sont eux qu'il faudra redémarrer : ce sont eux qui se connectent avec ce mot de passe.

### 4. Vérifier

La connexion par TCP de la section 7 doit répondre `postgres`. `password authentication failed` signifierait que les deux saisies diffèrent : il faut reprendre l'étape 1 avec la valeur du secret.

Pour finir, commiter le nouveau fichier chiffré, et mettre à jour le gestionnaire de mots de passe.

### En entreprise

Deux pratiques évitent la coupure entre l'étape 1 et l'étape 3 :

- **la rotation par utilisateurs** : un second utilisateur reçoit le nouveau mot de passe, les applications basculent vers lui, puis l'ancien est supprimé. PostgreSQL n'accepte pas deux mots de passe pour un même utilisateur ;
- **la rotation automatique** : sur AWS, Secrets Manager change le mot de passe dans la base et dans le coffre-fort, et External Secrets met à jour le `Secret` du cluster.

## 10. Les limites

| Limite | Conséquence |
|---|---|
| Les fichiers chiffrés restent dans l'historique Git | Si la clé privée fuit, tous les anciens fichiers deviennent lisibles : il faut alors changer les **valeurs**, pas seulement les chiffrer à nouveau |
| Un secret chiffré dépend de la clé du laboratoire | Il ne servira pas tel quel sur EKS, où External Secrets prendra le relais |
| Changer une valeur reste manuel | Saisie, chiffrement, commit et redémarrage, comme en section 9 |
| Le jeton de lecture du registre expire | Il faudra en créer un nouveau, et chiffrer à nouveau `ghcr-pull` |

## 11. Tableau de validation

| Contrôle | Résultat au 18 octobre 2026 |
|---|---|
| `kubeseal` 0.40.0, empreinte du téléchargement | `OK` |
| Clé publique commitée, non ignorée par Git | Oui, après l'exception du `.gitignore` |
| Secret de test chiffré puis déchiffré | Oui, `bonjour` |
| Valeurs en clair dans les fichiers du dépôt | Aucune |
| Secrets créés par commande remplacés | Oui, sans interruption de PostgreSQL |
| Mot de passe déchiffré accepté par PostgreSQL, par TCP | Oui |
| Cluster neuf : secrets recréés depuis le dépôt seul | Oui |

## 12. Étape suivante

Déployer Redis et RabbitMQ sur le même modèle : un `StatefulSet` avec son volume, un `Service`, et un `SealedSecret` rangé avec eux.

## 13. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Chiffrer un secret générique, valeur lue sans écho
read -rs -p 'Valeur : ' V; echo
printf '%s' "$V" | kubectl -n eshop create secret generic <nom> --from-file=<CLE>=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert kubernetes/sealed-secrets-cert.pem --format yaml > kubernetes/<dossier>/sealedsecret-<nom>.yaml
unset V

# État des secrets chiffrés et de leurs Secret
kubectl -n eshop get sealedsecret,secret

# Un SealedSecret sans Secret : la raison est dans son état
kubectl -n eshop describe sealedsecret <nom>
```

**Bilan :** les secrets de l'application sont décrits dans le dépôt, chiffrés, sans qu'aucune valeur en clair n'ait touché le disque. Un cluster neuf les retrouve depuis les fichiers seuls, et PostgreSQL accepte le mot de passe déchiffré. Les limites, une clé unique et des valeurs à changer à la main, sont connues avant le passage à EKS.
