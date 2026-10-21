# 18 — Les noms du laboratoire dans les pods : CoreDNS

## 1. Objectif

Le navigateur de Windows et les pods doivent joindre les services d'eShop par les **mêmes noms** : `shop.eshop.lab`, `identity.eshop.lab`, `webhooks.eshop.lab`. Sans cela, l'émetteur des jetons d'`Identity.API`, déduit du nom demandé, diffère selon l'appelant, et les jetons sont refusés ([docs/03-kubernetes/14-point-entree.md](../03-kubernetes/14-point-entree.md)).

Windows apprend ces noms par son fichier `hosts`. Les pods, eux, interrogent CoreDNS, le DNS du cluster. Ce guide configure CoreDNS, par un rôle Ansible, pour qu'il renvoie ces noms vers le point d'entrée.

**État au 21 octobre 2026 :** le rôle `lab_dns` dépose la configuration de CoreDNS. Depuis un pod, `identity.eshop.lab` est résolu vers l'adresse interne du point d'entrée, avec le nom demandé dans la réponse, et le reste du DNS du cluster est inchangé.

## 2. Le principe

| Qui demande `identity.eshop.lab` | Qui répond | Adresse obtenue |
|---|---|---|
| Le navigateur, sous Windows | Le fichier `hosts` ([lab-local/scripts/add-hosts-entries.ps1](../../lab-local/scripts/add-hosts-entries.ps1)) | `192.168.57.20`, l'adresse attribuée par MetalLB au point d'entrée |
| Un pod du cluster | CoreDNS, qui réécrit la question en `eshop-gateway.envoy-gateway-system.svc.cluster.local` | L'adresse interne du `Service` `eshop-gateway` |

Les deux chemins mènent au même proxy, qui choisit la route selon le nom demandé. C'est l'équivalent de laboratoire d'un vrai DNS : sur EKS, un enregistrement Route 53 donnera la même adresse à tous, sans réécriture.

Le rôle connaît donc le nom du `Service` du point d'entrée, `eshop-gateway`, fixé par l'application dans `kubernetes/gateway/`. Ce lien est assumé, comme un enregistrement DNS connaît le serveur qu'il désigne.

## 3. La version de CoreDNS et la règle retenue

kubeadm 1.36.5 installe CoreDNS **v1.14.2** (constante `CoreDNSVersion` des sources de kubeadm). Son extension `rewrite` réécrit le nom demandé ; la question est de savoir si la réponse porte encore le nom d'origine, faute de quoi certains clients la rejettent.

La documentation de l'extension, pour cette version, ne le garantit que pour deux types de règles :

| Type de règle | Réponse |
|---|---|
| `exact` | Toujours réécrite vers le nom demandé |
| `suffix` avec `answer auto` | Réécrite en inversant le suffixe |
| `regex` | Pas de réécriture automatique garantie : plusieurs noms envoyés vers une seule cible ne peuvent pas être retrouvés |

Le rôle utilise donc **une règle `exact` par nom**. Il n'y en a que trois, et leur liste explicite reste lisible.

## 4. Le rôle `lab_dns`

### Les variables

À la fin de `group_vars/control_plane.yml` :

```yaml
# Noms de l'application résolus par CoreDNS vers le point d'entrée, comme le fichier hosts de Windows
lab_dns_names:
  - shop.eshop.lab
  - identity.eshop.lab
  - webhooks.eshop.lab
lab_dns_target: "eshop-gateway.envoy-gateway-system.svc.{{ cluster_dns_domain }}"
lab_dns_config_path: "/etc/kubernetes/coredns-configmap.yaml"
```

La même liste figure dans les scripts du fichier `hosts`, `lab-local/scripts/add-hosts-entries.ps1` et `.sh`. **Un nom ajouté doit l'être aux trois endroits.**

### Le modèle : `roles/lab_dns/templates/coredns-configmap.yaml.j2`

Le rôle dépose **toute** la `ConfigMap` `coredns` : le `Corefile` de kubeadm 1.36.5, recopié depuis ses sources, plus les règles. Insérer des lignes dans le fichier existant serait fragile.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  # Corefile de kubeadm 1.36.5, plus les règles rewrite des noms du laboratoire
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
{% for name in lab_dns_names %}
        rewrite name exact {{ name }} {{ lab_dns_target }}
{% endfor %}
        kubernetes {{ cluster_dns_domain }} in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30 {
           disable success {{ cluster_dns_domain }}
           disable denial {{ cluster_dns_domain }}
        }
        loop
        reload
        loadbalance
    }
```

L'ordre des lignes dans le `Corefile` n'a pas d'effet sur l'ordre d'exécution : CoreDNS applique ses extensions dans un ordre fixé à sa compilation, `rewrite` avant `kubernetes`.

### Les tâches

| Tâche | Garde |
|---|---|
| Déposer la configuration | `template` ne réécrit pas un fichier identique |
| La comparer avec le cluster | `kubectl diff`, `changed_when: false` |
| L'appliquer | Seulement si `diff` signale une différence |

Aucun redémarrage : l'extension `reload` de CoreDNS relit le `Corefile` de lui-même, en 30 à 45 secondes.

Le rôle termine le quatrième play de `site.yml`, après `envoy_gateway`.

## 5. Vérifier

Le rôle a été appliqué le 20 octobre 2026 par `ansible-playbook site.yml` ; les récapitulatifs de ce premier passage n'ont pas été relevés. Le 21 octobre 2026, le laboratoire a été reconstruit deux fois avec le rôle. Après la seconde reconstruction, un nouveau passage du playbook a répondu :

```text
kube-control               : ok=55   changed=0    unreachable=0    failed=0    skipped=19
kube-worker                : ok=23   changed=0    unreachable=0    failed=0    skipped=3
```

Lors de cette seconde reconstruction, le premier passage, lancé par `rebuild.ps1 -Rebuild` sur des machines neuves, avait exécuté les trois tâches du rôle : `Déposer la configuration de CoreDNS` (`changed`), `Comparer` (`ok`), `Appliquer` (`changed`). Récapitulatif complet de ce passage : `kube-control` `ok=73 changed=48 failed=0`, `kube-worker` `ok=28 changed=22 failed=0`, laboratoire prêt en 8 min 02.

Le rôle est donc idempotent, et il fonctionne sur des machines neuves : les noms ont été résolus par les pods sans aucune intervention après la reconstruction.

Depuis WSL2, à la racine du dépôt, une fois le `Corefile` relu :

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

kubectl -n kube-system logs -l k8s-app=kube-dns --tail=5 | grep -i -E 'reload|error'
kubectl -n envoy-gateway-system get service eshop-gateway -o jsonpath='{.spec.clusterIP}'; echo

kubectl apply -f - <<'Y'
apiVersion: v1
kind: Pod
metadata: { name: dnstest, namespace: eshop }
spec:
  restartPolicy: Never
  containers:
    - name: dnstest
      image: curlimages/curl:8.23.0
      command: ["sleep", "300"]
Y
kubectl -n eshop wait --for=condition=Ready pod/dnstest --timeout=120s
kubectl -n eshop exec -i dnstest -- sh <<'SH'
nslookup identity.eshop.lab
nslookup postgres
echo "point d'entrée : $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://identity.eshop.lab/)"
SH
kubectl -n eshop delete pod dnstest
```

Résultats vérifiés le 20 octobre 2026 :

```text
[INFO] plugin/reload: Running configuration SHA512 = 6de93365...
[INFO] Reloading complete
10.108.250.206

Name:   identity.eshop.lab
Address: 10.108.250.206

Name:   postgres.eshop.svc.cluster.local
Address: 10.103.105.97

point d'entrée : 404
```

| Contrôle | Résultat |
|---|---|
| CoreDNS a relu sa configuration | Oui, sur ses deux pods, sans erreur |
| `identity.eshop.lab`, depuis un pod | `10.108.250.206`, l'adresse d'`eshop-gateway` ; la réponse porte le nom demandé |
| `postgres`, depuis un pod | Toujours résolu : le reste du DNS n'est pas touché |
| Requête HTTP vers `identity.eshop.lab`, depuis un pod | `404` : le point d'entrée est atteint par son nom ; aucune route n'existait encore |

Les lignes `NXDOMAIN` qui suivent la réponse de `nslookup postgres` sont normales : l'outil essaie chaque suffixe de recherche du pod, et affiche aussi les échecs.

## 6. Les limites

| Limite | Conséquence |
|---|---|
| Le rôle remplace tout le `Corefile` | Une mise à jour de kubeadm qui modifierait le `Corefile` d'origine serait écrasée au passage suivant du rôle : le modèle est à comparer à celui de la nouvelle version |
| Liste des noms en trois endroits | Variables Ansible et deux scripts `hosts` |
| Le rôle dépend du nom `eshop-gateway` | Défini par l'application, dans `kubernetes/gateway/envoyproxy-eshop.yaml` |

## 7. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Configuration de CoreDNS en vigueur
kubectl -n kube-system get configmap coredns -o yaml

# Journal de CoreDNS
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20
```

**Bilan :** les pods résolvent les noms en `.eshop.lab` vers le point d'entrée, comme Windows par son fichier `hosts`. Le navigateur et les services joignent ainsi `Identity.API` par le même nom, condition d'un émetteur commun.
