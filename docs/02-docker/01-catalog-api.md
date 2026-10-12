# Dockeriser le microservice Catalog.API

## 1. Objectif

Cette étape consiste à construire et tester une image Docker du microservice `Catalog.API` de l’application eShop.

Les objectifs sont de :

- comprendre un Dockerfile multi-stage pour une application ASP.NET Core ;
- construire une image à partir du code source ;
- démarrer le conteneur dans un réseau Docker ;
- connecter l’API à PostgreSQL et RabbitMQ ;
- vérifier le démarrage de l’application et tester un endpoint HTTP.

**Périmètre :** cette étape porte sur le Dockerfile et le test de l’image. La configuration complète avec Docker Compose sera documentée séparément.

## 2. Architecture du test

L’environnement de test utilise trois conteneurs applicatifs ou techniques :

| Conteneur | Rôle | Port hôte |
|---|---|---|
| `catalog-api-test` | Ancienne instance de l’API | `8080` |
| `catalog-api-new-test` | Nouvelle image construite | `8081` |
| `catalog-postgres` | Base de données PostgreSQL | Selon la configuration existante |
| `catalog-rabbitmq` | Broker de messages RabbitMQ | Selon la configuration existante |

Les conteneurs communiquent sur le réseau Docker `eshop-test`. Les ports des dépendances ne sont pas nécessairement publiés sur l’hôte : leur accessibilité dépend de la configuration du réseau et des conteneurs.

```text
Navigateur / curl
       |
       | HTTP :8081
       v
catalog-api-new-test
       |
       +------> catalog-postgres
       |          PostgreSQL
       |
       +------> catalog-rabbitmq
                  RabbitMQ

       Réseau Docker : eshop-test
```

## 3. Emplacement du Dockerfile

Le Dockerfile se trouve à cet emplacement dans le dépôt principal :

```text
EshopOnContainer/
├── application/
│   └── eShop/
│       ├── global.json
│       ├── Directory.Packages.props
│       ├── Directory.Build.props
│       ├── Directory.Build.targets
│       ├── nuget.config
│       └── src/
│           └── Catalog.API/
└── docker/
    └── src/
        └── Catalog.API/
            └── Dockerfile
```

Le contexte de construction doit être la racine du dépôt principal, car les instructions `COPY` utilisent des chemins relatifs à ce contexte.

## 4. Comprendre le Dockerfile

Le Dockerfile utilise deux étapes : une étape de construction avec le SDK .NET, puis une étape d’exécution avec le runtime ASP.NET Core.

### Étape 1 — Construire et publier l’application

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY application/eShop/global.json ./
COPY application/eShop/Directory.Packages.props ./
COPY application/eShop/Directory.Build.props ./
COPY application/eShop/Directory.Build.targets ./
COPY application/eShop/nuget.config ./

COPY application/eShop/src/ ./src/

RUN dotnet restore src/Catalog.API/Catalog.API.csproj

RUN dotnet publish src/Catalog.API/Catalog.API.csproj \
    --configuration Release \
    --output /app/publish \
    --no-restore
```

**Explications :**

- `FROM ... sdk:10.0` fournit le SDK nécessaire à la restauration et à la compilation.
- `AS build` nomme cette étape pour pouvoir en récupérer les artefacts plus tard.
- `WORKDIR /src` définit le répertoire de travail.
- `COPY` transfère les fichiers de configuration .NET et les sources nécessaires.
- `dotnet restore` restaure les dépendances NuGet.
- `dotnet publish` produit les fichiers publiables en configuration `Release`.
- `--no-restore` évite de restaurer une seconde fois les dépendances après l’étape précédente.

Les fichiers de configuration racine sont copiés parce qu’ils peuvent définir les versions des packages, les propriétés communes de compilation et la configuration NuGet.

### Étape 2 — Créer l’image d’exécution

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app

COPY --from=build /app/publish/ ./

ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

ENTRYPOINT [ "dotnet", "Catalog.API.dll" ]
```

**Explications :**

- L’image `aspnet:10.0` contient le runtime nécessaire à l’exécution de l’application, sans le SDK complet.
- `COPY --from=build` récupère uniquement les fichiers publiés dans l’étape précédente.
- `ASPNETCORE_HTTP_PORTS=8080` configure le port HTTP écouté par l’application.
- `EXPOSE 8080` documente le port utilisé par le conteneur ; cette instruction ne publie pas le port sur l’hôte.
- `ENTRYPOINT` définit la commande exécutée au démarrage du conteneur.

Cette approche réduit le contenu de l’image finale en évitant d’y conserver les outils de compilation et l’ensemble du code source.

## 5. Construire l’image Docker

Depuis la racine du dépôt, dans Ubuntu sous WSL :

```bash
docker build --progress=plain \
  -f docker/src/Catalog.API/Dockerfile \
  -t eshop/catalog-api:dev \
  .
```

**À retenir :**

- `-f` indique le chemin du Dockerfile.
- `-t` attribue le nom et le tag `eshop/catalog-api:dev` à l’image.
- `.` définit la racine du dépôt comme contexte de construction.
- `--progress=plain` facilite la lecture des étapes et des erreurs.

Vérifier ensuite la présence de l’image :

```bash
docker image ls eshop/catalog-api
```

### Résultat observé

La construction a réussi et produit une image d’environ **381 Mo**.

L’image est alors prête à être exécutée. Cette réussite confirme que Docker a pu restaurer les dépendances, publier `Catalog.API` et assembler l’image finale. Elle ne prouve pas, à elle seule, que l’application fonctionnera correctement avec ses services externes.

## 6. Préparer les dépendances

L’API utilise notamment :

- PostgreSQL pour les données du catalogue ;
- RabbitMQ pour la messagerie.

Les conteneurs existants sont regroupés sur le réseau `eshop-test`.

Pour vérifier les conteneurs présents :

```bash
docker ps --filter name=catalog
```

Pour inspecter les membres du réseau :

```bash
docker network inspect eshop-test \
  --format '{{range .Containers}}{{println .Name}}{{end}}'
```

Le réseau permet aux conteneurs de communiquer en utilisant leurs noms DNS Docker. Dans une configuration de conteneurs, `localhost` désigne le conteneur lui-même, pas automatiquement PostgreSQL ou RabbitMQ.

Les chaînes de connexion doivent donc utiliser les noms des services appropriés et les ports internes configurés.

## 7. Démarrer la nouvelle image

Pour comparer la nouvelle image à l’ancienne instance, la nouvelle API est démarrée sur le port hôte `8081`, tandis que l’ancienne conserve le port `8080`.

Les variables de connexion de l’instance existante ont été récupérées dans un fichier temporaire local, puis transmises à la nouvelle instance au démarrage. Le fichier temporaire a été supprimé après son utilisation.

Exemple de lancement lorsque le fichier d’environnement sécurisé contient les deux variables nécessaires :

```bash
docker run -d \
  --name catalog-api-new-test \
  --network eshop-test \
  -p 8081:8080 \
  --env-file "$ENV_FILE" \
  eshop/catalog-api:dev
```

Dans cet exemple, `ENV_FILE` doit désigner un fichier local contenant les variables `ConnectionStrings__catalogdb` et `ConnectionStrings__eventbus`, avec leurs valeurs valides.

**Sécurité :** ne pas ajouter ce fichier au dépôt Git, ne pas publier ses valeurs dans les journaux ou dans la documentation, et ne pas inscrire les secrets directement dans une commande conservée dans l’historique du terminal. Pour un environnement durable, prévoir une gestion dédiée des secrets.

Vérifier l’état du conteneur :

```bash
docker ps --filter name=catalog-api-new-test
```

Consulter ensuite ses journaux :

```bash
docker logs --tail 60 catalog-api-new-test
```

## 8. Vérifier le fonctionnement de l’API

### Test HTTP

Exécuter :

```bash
curl -i \
  'http://localhost:8081/api/catalog/catalogTypes?api-version=1.0'
```

### Résultat observé

La requête a retourné :

```text
HTTP/1.1 200 OK
```

Le corps JSON contient huit types de catalogue, dont `Bags`, `Climbing`, `Cycling`, `Footwear`, `Jackets`, `Navigation`, `Ski/boarding` et `Trekking`.

Ce résultat confirme que :

1. le conteneur est démarré ;
2. l’application écoute sur le port attendu ;
3. le port `8081` de l’hôte est correctement redirigé vers le port `8080` du conteneur ;
4. l’endpoint testé répond avec succès et retourne les données attendues.

### Vérifier les journaux de démarrage

Les journaux ont montré notamment :

- le démarrage de l’application ASP.NET Core ;
- l’écoute sur `http://[::]:8080` ;
- la vérification des migrations de `CatalogContext` ;
- l’exécution de requêtes SQL ;
- le démarrage du mécanisme de connexion RabbitMQ en arrière-plan.

Un message indique que la bibliothèque `libgssapi_krb5.so.2` n’a pas pu être chargée. Il n’a pas empêché le test HTTP de réussir. Il faudra analyser ce message séparément si une fonctionnalité dépendante de cette bibliothèque échoue.

Le démarrage du mécanisme de connexion RabbitMQ ne suffit pas à démontrer que la connexion au broker est pleinement opérationnelle. Des tests complémentaires sont nécessaires pour confirmer la publication et la consommation de messages.

### À propos de `/health`

La requête vers `/health` a retourné `404 Not Found`.

Cela ne démontre pas que l’application est en panne : aucun endpoint de santé explicite n’a été identifié à ce stade. Il faudra vérifier les routes déclarées et, si nécessaire, ajouter un endpoint de santé adapté avant de configurer des probes Kubernetes.

## 9. Tableau de validation

| Contrôle | Résultat |
|---|---|
| Construction de l’image | Réussi |
| Image `eshop/catalog-api:dev` créée | Confirmé |
| Démarrage du nouveau conteneur | Réussi |
| Réseau Docker `eshop-test` | Utilisé |
| Endpoint `catalogTypes` | HTTP 200 |
| Données du catalogue retournées | Confirmé |
| Migrations PostgreSQL | Vérifiées au démarrage |
| Connexion complète à RabbitMQ | À confirmer |
| Endpoint `/health` | Non disponible sur cette route |
| Tests de charge et de résilience | Non réalisés |

## 10. Bonnes pratiques et améliorations

Les points suivants seront traités progressivement, sans compliquer inutilement le premier test :

1. **Optimiser le cache de construction.** Séparer la copie des fichiers de projet et la copie du code source afin d’éviter de restaurer toutes les dépendances à chaque modification du code.
2. **Vérifier l’exécution non privilégiée.** Confirmer l’identité utilisée par le runtime et adapter le Dockerfile si nécessaire.
3. **Fiabiliser la configuration.** Éviter les valeurs de connexion locales telles que `localhost` lorsqu’un service est exécuté dans un conteneur distinct.
4. **Ajouter un contrôle de santé.** Définir un endpoint et un test adaptés à l’application.
5. **Sécuriser les secrets.** Utiliser une solution adaptée à l’environnement au lieu de versionner les chaînes de connexion.
6. **Stabiliser les images.** Évaluer les stratégies de versionnement et de mise à jour des images de base.

Ces améliorations doivent être validées par des tests, et non appliquées toutes simultanément.

## 11. Étape suivante

La prochaine étape sera de préparer une configuration Docker Compose permettant de décrire et de démarrer ensemble l’API, PostgreSQL et RabbitMQ, avec un réseau commun et une configuration reproductible.

Avant cette étape, il faudra également clarifier la gestion du dépôt Git imbriqué `application/eShop` pour préserver son historique et éviter d’intégrer accidentellement ses fichiers Git dans le dépôt principal.

## 12. Commandes de référence

```bash
# Construire l'image
docker build --progress=plain \
  -f docker/src/Catalog.API/Dockerfile \
  -t eshop/catalog-api:dev \
  .

# Vérifier l'image
docker image ls eshop/catalog-api

# Vérifier les conteneurs
docker ps --filter name=catalog

# Consulter les journaux
docker logs --tail 60 catalog-api-new-test

# Tester l'API
curl -i \
  'http://localhost:8081/api/catalog/catalogTypes?api-version=1.0'
```

**Bilan :** le premier objectif Docker est atteint. Une nouvelle image de `Catalog.API` a été construite et exécutée, puis son endpoint de catalogue a répondu avec succès. La validation complète des dépendances et l’orchestration reproductible restent des étapes distinctes.
