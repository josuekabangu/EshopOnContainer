# 17 — L'ordre de démarrage : attendre RabbitMQ

## 1. Objectif

Avec Docker Compose, `depends_on: condition: service_healthy` faisait attendre chaque service jusqu'à ce que ses dépendances soient prêtes ([guide 02-docker/15](../02-docker/15-controles-de-sante.md)). Kubernetes n'a pas d'équivalent : tous les pods d'une application appliquée d'un coup démarrent en même temps.

Ce guide décrit l'incident que cette différence a provoqué lors d'une reconstruction du laboratoire, son diagnostic, et la correction retenue.

**État au 21 octobre 2026 :** les sept services qui utilisent RabbitMQ attendent qu'il accepte les connexions avant de démarrer, par un `initContainer`. Une reconstruction complète, avec toute l'application réappliquée d'un coup depuis le dépôt, a mené une commande jusqu'à l'état `Paid` et livré sa notification, sans aucune intervention.

## 2. L'incident

Le 21 octobre 2026, après une reconstruction du laboratoire et la réapplication de toute l'application ([kubernetes/README.md](../../kubernetes/README.md)), les 12 pods étaient `1/1 Running`, sans aucun redémarrage. Une commande passée depuis le navigateur est pourtant restée à l'état `StockConfirmed` : jamais payée.

### Le diagnostic

```bash
kubectl -n eshop logs deployment/ordering-api | grep -E 'Publishing integration event.*StockConfirmed|Error Publishing' | cut -c1-200 | tail -3
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers messages
SH
kubectl -n eshop logs deployment/payment-processor | grep -E '^(fail|crit|warn):|RabbitMQ' -A2 | head -30
kubectl -n eshop exec -i postgres-0 -- psql -U postgres -d orderingdb -At <<'SQL'
select "EventTypeName", "State", "TimesSent" from ordering."IntegrationEventLog" order by "CreationTime";
SQL
```

| Constat | Ce qu'il montre |
|---|---|
| `Ordering.API` : `Publishing integration event ... OrderStatusChangedToStockConfirmedIntegrationEvent` ; en base, l'événement à l'état `2` (publié) | L'événement « stock confirmé » a bien été publié |
| RabbitMQ : **3 files sur 7**, `OrderProcessor`, `Ordering` et `Catalog` | Les files de `PaymentProcessor`, `Basket.API`, `Webhooks.API` et `WebApp` (`Ordering.webapp`) n'existent pas |
| `PaymentProcessor` : `Error starting RabbitMQ connection ... Connection failed, host 10.102.212.19:5672 ... Connection refused` | Le service a tenté de joindre RabbitMQ avant qu'il accepte les connexions |

### La cause

Le bus d'événements d'eShop ouvre sa connexion à RabbitMQ au démarrage du service, fait quelques tentatives, puis **abandonne définitivement**. Le service continue de tourner, mais n'est abonné à rien.

Ses probes ne le voient pas. `/health` vérifie que RabbitMQ répond au moment de la vérification, pas que le service est abonné : une fois RabbitMQ prêt, le pod devient `Ready`, alors que sa fonction principale est morte.

L'événement « stock confirmé » est donc arrivé dans le point d'échange `eshop_event_bus`, où aucune file de `PaymentProcessor` n'était liée : RabbitMQ l'a jeté.

| Service sans abonnement | Conséquence |
|---|---|
| `PaymentProcessor` | Les commandes restent à `StockConfirmed` |
| `Basket.API` | Le panier n'est pas vidé à la création de la commande |
| `Webhooks.API` | Aucune notification livrée |
| `WebApp` | La boutique ne suit plus l'état des commandes |

Le problème ne s'était pas produit lors de la reconstruction du 19 octobre ([guide 04](04-secrets.md), section 8) : seules les dépendances avaient alors été réappliquées, et les services d'eShop ont été déployés ensuite, un par un, sur un RabbitMQ déjà prêt. C'est la première réapplication de toute l'application d'un coup qui l'a révélé.

## 3. La correction : un `initContainer`

### Les options

| Option | Évaluation |
|---|---|
| Rendre le bus d'événements capable de se reconnecter | La vraie solution, en entreprise : un service doit survivre à l'absence passagère d'une dépendance. Demande de modifier le code d'eShop |
| Une probe qui vérifierait l'abonnement | Le code d'eShop n'expose pas cet état |
| Appliquer les fichiers dans un ordre, en attendant RabbitMQ | Fragile : ne protège pas d'un redémarrage de RabbitMQ, ni d'un nœud redémarré |
| **Un `initContainer` qui attend RabbitMQ** | La pratique courante quand le code d'une application ne sait pas attendre ses dépendances. Sans modification du code |

Un `initContainer` s'exécute avant les conteneurs du pod, jusqu'à se terminer avec succès. Tant qu'il tourne, le service ne démarre pas.

### Le bloc ajouté

Aux sept `Deployment` des services qui utilisent RabbitMQ : `catalog-api`, `basket-api`, `ordering-api`, `order-processor`, `payment-processor`, `webhooks-api` et `webapp`. Il est placé juste avant `containers:` :

```yaml
      initContainers:
        # Équivalent de depends_on : le bus d'événements d'eShop abandonne si RabbitMQ n'est pas prêt
        - name: wait-for-rabbitmq
          image: busybox:1.36.1
          command: ["sh", "-c", "until nc -z -w 2 rabbitmq 5672; do echo 'RabbitMQ pas encore prêt'; sleep 2; done"]
```

| Élément | Rôle |
|---|---|
| `nc -z -w 2 rabbitmq 5672` | Tente d'ouvrir une connexion vers le port AMQP, sans rien envoyer, en 2 secondes au plus |
| La cible : le `Service` `rabbitmq` | Il n'envoie les connexions qu'à un pod **prêt**, au sens de sa probe `check_port_connectivity` ([guide 06](06-rabbitmq.md)). Une connexion réussie signifie donc que RabbitMQ accepte vraiment les connexions AMQP |
| `busybox:1.36.1` | Une image minuscule, à version figée, qui contient `nc` |

`Identity.API` et `WebhookClient` n'en ont pas besoin : ils n'utilisent pas RabbitMQ.

Le bloc a été inséré par une commande PowerShell, qui conserve les fins de ligne CRLF des fichiers.

## 4. La preuve

### Sur le cluster en place

L'application des sept `Deployment` a redémarré les services. RabbitMQ étant prêt, chacun s'est abonné, et les 7 files sont revenues. La commande bloquée a été débloquée en republiant son événement perdu, par la méthode du [guide 12](12-payment-processor.md) avec `{"OrderId":1}` : elle est passée à `Paid`, et `WebhookClient` a reçu deux notifications, une par abonnement.

Sur un cluster déjà démarré, l'`initContainer` ne prouve rien : son journal était vide, RabbitMQ répondant au premier essai.

### Par une reconstruction

Le laboratoire a été reconstruit, puis toute l'application réappliquée d'un coup, selon [kubernetes/README.md](../../kubernetes/README.md). Puis :

```bash
for d in catalog-api basket-api ordering-api order-processor payment-processor webhooks-api webapp; do
  echo "== $d : $(kubectl -n eshop logs deployment/$d -c wait-for-rabbitmq | grep -c 'pas encore prêt') attente(s)"
done
kubectl -n eshop exec -i rabbitmq-0 -- sh <<'SH'
rabbitmqctl -q list_queues name consumers
SH
```

Résultats vérifiés le 21 octobre 2026 :

```text
== catalog-api : 14 attente(s)
== basket-api : 14 attente(s)
== ordering-api : 14 attente(s)
== order-processor : 14 attente(s)
== payment-processor : 13 attente(s)
== webhooks-api : 13 attente(s)
== webapp : 13 attente(s)

OrderProcessor    1
Ordering          1
Ordering.webapp   1
Catalog           1
Webhooks          1
Basket            1
PaymentProcessor  1
```

| Contrôle | Résultat |
|---|---|
| Attente de chaque service | 13 à 14 tentatives, soit une trentaine de secondes : tous ont démarré avant que RabbitMQ soit prêt |
| Files RabbitMQ | Les 7, chacune avec 1 consommateur, dès le premier démarrage |
| Pods | Les 12 en `1/1 Running`, sans redémarrage |
| Commande passée depuis le navigateur | `Submitted`, `StockConfirmed`, puis `Paid`, sans intervention |
| Notification de `WebhookClient` | 1, pour un abonnement |

Sans l'`initContainer`, cette même situation aurait laissé quatre services sans abonnement.

## 5. Les limites

| Limite | Conséquence |
|---|---|
| L'attente ne vaut qu'au démarrage | Si RabbitMQ redémarre plus tard, la connexion d'eShop se rétablit-elle ? Non vérifié. Le bus utilise une connexion à reprise automatique (`AutorecoveringConnection`, dans la pile d'erreurs), mais ce cas n'a pas été testé |
| Un message publié sans file liée est perdu | Le bus d'eShop ne déclare pas les files de ses abonnés à la place de ceux-ci |
| PostgreSQL n'a pas d'attente équivalente | Les services qui l'utilisent n'ont montré aucune erreur : leurs migrations réessaient. À surveiller |

## 6. Commandes de référence

```bash
kubectl() { ssh -i $HOME/.ssh/vagrant/kube-control vagrant@192.168.57.10 kubectl "$@"; }

# Files et consommateurs : 7 attendues
kubectl -n eshop exec rabbitmq-0 -- rabbitmqctl -q list_queues name consumers

# Journal de l'attente d'un service
kubectl -n eshop logs deployment/payment-processor -c wait-for-rabbitmq
```

**Bilan :** l'absence de `depends_on` dans Kubernetes a laissé, lors d'une reconstruction, quatre services sans abonnement à RabbitMQ, sans qu'aucune probe ne le signale. Un `initContainer` qui attend RabbitMQ en tient lieu ; une nouvelle reconstruction l'a prouvé, chaque service ayant attendu une trentaine de secondes avant de démarrer.
