# 01 — Dockeriser le microservice Catalog.API

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

L’environnement de test utilise trois conteneurs :

| Conteneur | Image | Rôle | Port hôte |
|---|---|---|---|
| `catalog-api-new-test` | `eshop/catalog-api:dev` | Image construite dans ce guide | `8081` |
| `catalog-postgres` | `ankane/pgvector:latest` | Base de données PostgreSQL avec l’extension `vector` | Non publié |
| `catalog-rabbitmq` | `rabbitmq:4-management` | Broker de messages RabbitMQ | Non publié |

Les conteneurs communiquent sur le réseau Docker `eshop-test`. Les ports de PostgreSQL et de RabbitMQ ne sont pas publiés sur l’hôte : seule l’API est joignable de l’extérieur, les dépendances ne le sont que depuis le réseau Docker.

Pendant la mise au point, une première instance nommée `catalog-api-test` a servi de point de comparaison sur le port `8080`. Elle a été supprimée et n’est pas nécessaire pour refaire le test.

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

### Prérequis

| Prérequis | Vérification | Valeur constatée le 12 octobre 2026 |
|---|---|---|
| Docker Engine dans Ubuntu sous WSL2 | `docker version` | Client et serveur `29.9.0` |
| Sources d’eShop présentes dans `application/eShop` | `ls application/eShop/src/Catalog.API` | Présentes |

Les sources proviennent du dépôt `https://github.com/dotnet/eShop`, au commit `dc7ea49` (« Update to Aspire 13.6.0 »). Le Dockerfile cible .NET 10, la version déclarée par le projet `Catalog.API`.

Ces sources sont commitées dans le dépôt. Leur intégration, et le défaut qu’il a fallu corriger pour y parvenir, sont décrits en section 11.

### Construction

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

### Pourquoi une image PostgreSQL particulière ?

Une image PostgreSQL standard ne suffit pas. `Catalog.API` déclare l’extension PostgreSQL `vector` dans son modèle de données (`CatalogContext`), et ses migrations en dépendent. La base doit donc fournir cette extension.

Le test utilise l’image `ankane/pgvector:latest`, qui est aussi celle que le projet eShop déclare dans son propre fichier d’orchestration (`eShop.AppHost`).

### Création du réseau et des dépendances

Les commandes ci-dessous sont équivalentes à la configuration des conteneurs en place. Elles ont été reconstituées à partir de cette configuration, et non relevées au moment de la création.

Les mots de passe sont lus au clavier dans des variables du shell, sans s’afficher et sans être écrits dans un fichier :

```bash
read -rs -p "Mot de passe PostgreSQL : " POSTGRES_PASSWORD; echo
read -rs -p "Mot de passe RabbitMQ : " RABBITMQ_PASSWORD; echo
```

L’option `-s` de `read` masque la saisie.

```bash
docker network create eshop-test
```

Cette commande crée le réseau sur lequel les trois conteneurs se joignent par leur nom.

```bash
docker run -d \
  --name catalog-postgres \
  --network eshop-test \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e POSTGRES_DB=CatalogDB \
  ankane/pgvector:latest
```

Cette commande démarre PostgreSQL et crée la base `CatalogDB`. Aucun port n’est publié.

```bash
docker run -d \
  --name catalog-rabbitmq \
  --network eshop-test \
  -e RABBITMQ_DEFAULT_USER=guest \
  -e RABBITMQ_DEFAULT_PASS="$RABBITMQ_PASSWORD" \
  rabbitmq:4-management
```

Cette commande démarre RabbitMQ avec son interface d’administration. Aucun port n’est publié.

### Vérification des dépendances

Les conteneurs sont regroupés sur le réseau `eshop-test`.

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

Résultat vérifié le 12 octobre 2026 : le réseau `eshop-test` compte trois membres, `catalog-api-new-test`, `catalog-rabbitmq` et `catalog-postgres`.

L’état de la base a également été contrôlé, depuis le conteneur PostgreSQL :

| Élément | Valeur constatée |
|---|---|
| Version de PostgreSQL | `15.4` |
| Extension `vector` dans `CatalogDB` | Installée, version `0.5.1` |
| Tables créées par les migrations | `Catalog`, `CatalogBrand`, `CatalogType`, `IntegrationEventLog`, `__EFMigrationsHistory` |
| Articles dans la table `Catalog` | `101` |

Les tables et les données sont créées par l’API à son premier démarrage, décrit dans la section suivante.

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

Le fichier a la forme suivante. Les mots de passe y sont remplacés ici par un texte de substitution :

```text
ConnectionStrings__catalogdb=Host=catalog-postgres;Port=5432;Database=CatalogDB;Username=postgres;Password=<MOT_DE_PASSE_POSTGRES>
ConnectionStrings__eventbus=amqp://guest:<MOT_DE_PASSE_RABBITMQ>@catalog-rabbitmq:5672
```

Trois éléments sont à remarquer :

- `catalogdb` et `eventbus` sont les noms que le code de `Catalog.API` attend pour ses deux chaînes de connexion ;
- le double tiret bas `__` représente, dans une variable d’environnement, le séparateur `:` de la configuration .NET : `ConnectionStrings__catalogdb` correspond à la clé `ConnectionStrings:catalogdb` ;
- les hôtes sont les noms des conteneurs, `catalog-postgres` et `catalog-rabbitmq`, résolus par le réseau Docker.

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

Un second endpoint, qui lit la table des articles, a été testé le 12 octobre 2026 :

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  'http://localhost:8081/api/catalog/items?api-version=1.0&pageSize=1'
```

Cette commande n’affiche que le code HTTP de la réponse.

Résultat vérifié : `200`. L’API lit donc bien les données de la base, et pas seulement une liste statique.

### Vérifier les journaux de démarrage

Les journaux ont montré notamment :

- le démarrage de l’application ASP.NET Core ;
- l’écoute sur `http://[::]:8080` ;
- la vérification des migrations de `CatalogContext` ;
- l’exécution de requêtes SQL ;
- le démarrage du mécanisme de connexion RabbitMQ en arrière-plan.

Un message indique que la bibliothèque `libgssapi_krb5.so.2` n’a pas pu être chargée. Il n’a pas empêché le test HTTP de réussir. Il faudra analyser ce message séparément si une fonctionnalité dépendante de cette bibliothèque échoue.

Les journaux indiquent aussi l’environnement d’exécution :

```text
Hosting environment: Production
```

Aucune variable `ASPNETCORE_ENVIRONMENT` n’est transmise au conteneur. ASP.NET Core retient alors `Production` par défaut. Ce point explique le comportement de `/health`, décrit plus bas.

### Connexion à RabbitMQ

Le message de démarrage du mécanisme de connexion, dans les journaux de l’API, ne prouve pas que la connexion a abouti. Elle a donc été vérifiée du côté du broker :

```bash
docker exec catalog-rabbitmq rabbitmqctl list_connections name user state
docker exec catalog-rabbitmq rabbitmqctl list_exchanges name type
```

La première commande liste les connexions ouvertes sur le broker. La seconde liste les points d’échange de messages qui y sont déclarés.

Résultat vérifié le 12 octobre 2026 :

- une connexion à l’état `running`, ouverte par l’utilisateur `guest` depuis l’adresse du conteneur de l’API vers le port `5672` ;
- un point d’échange `eshop_event_bus`, de type `direct`, créé par l’API.

La connexion entre l’API et RabbitMQ est donc établie. La publication et la consommation de messages n’ont pas été testées : elles demandent un second service qui échange des événements avec `Catalog.API`.

### À propos de `/health`

Les requêtes vers `/health` et `/alive` retournent `404 Not Found`.

Cela ne signifie pas que l’application est en panne. La cause se trouve dans le code d’eShop, dans `src/eShop.ServiceDefaults/Extensions.cs` : les deux routes de santé ne sont déclarées que lorsque l’environnement d’exécution est `Development`.

```csharp
if (app.Environment.IsDevelopment())
{
    app.MapHealthChecks("/health");
    app.MapHealthChecks("/alive", ...);
}
```

Le conteneur s’exécutant en `Production`, ces routes n’existent pas.

Ce point devra être tranché avant de configurer des probes Kubernetes. Deux pistes existent, aucune n’est retenue à ce stade :

| Piste | Conséquence |
|---|---|
| Exécuter le conteneur avec `ASPNETCORE_ENVIRONMENT=Development` | Active les routes de santé, mais aussi tous les comportements réservés au développement |
| Modifier le code pour déclarer ces routes dans tous les environnements | Introduit un écart avec le code d’origine d’eShop, à tracer |

## 9. Tableau de validation

| Contrôle | Résultat |
|---|---|
| Construction de l’image | Réussi |
| Image `eshop/catalog-api:dev` créée | Confirmé |
| Démarrage du nouveau conteneur | Réussi |
| Réseau Docker `eshop-test` | Utilisé |
| Endpoint `catalogTypes` | HTTP 200 |
| Endpoint `items`, lu depuis la base | HTTP 200 |
| Données du catalogue retournées | Confirmé |
| Migrations PostgreSQL | Appliquées : 5 tables, 101 articles, extension `vector` |
| Connexion à RabbitMQ | Établie, vérifiée côté broker |
| Publication et consommation de messages | Non testées |
| Endpoints `/health` et `/alive` | Absents en `Production`, cause identifiée |
| Exécution non privilégiée | Non : le conteneur s’exécute en `root` |
| Sources complètes dans un clone du dépôt | Vérifié, voir section 11 |
| Construction de l’image à partir d’un clone neuf | Non rejouée |
| Tests de charge et de résilience | Non réalisés |

## 10. Bonnes pratiques et améliorations

Les points suivants seront traités progressivement, sans compliquer inutilement le premier test :

1. **Optimiser le cache de construction.** Séparer la copie des fichiers de projet et la copie du code source afin d’éviter de restaurer toutes les dépendances à chaque modification du code.
2. **Exécuter le conteneur sans privilèges.** L’identité a été vérifiée avec `docker run --rm --entrypoint id eshop/catalog-api:dev` : le conteneur s’exécute en `uid=0(root)`. L’image de base fournit pourtant un utilisateur non privilégié, désigné par la variable `APP_UID`. Une instruction `USER $APP_UID` placée avant l’`ENTRYPOINT` suffirait, le port `8080` ne demandant aucun privilège. Cette correction n’est pas encore appliquée.
3. **Fiabiliser la configuration.** Éviter les valeurs de connexion locales telles que `localhost` lorsqu’un service est exécuté dans un conteneur distinct.
4. **Ajouter un contrôle de santé.** Définir un endpoint et un test adaptés à l’application.
5. **Sécuriser les secrets.** Utiliser une solution adaptée à l’environnement au lieu de versionner les chaînes de connexion.
6. **Stabiliser les images.** Évaluer les stratégies de versionnement et de mise à jour des images de base. L’image `ankane/pgvector:latest` a été publiée il y a trois ans et porte l’étiquette `latest` : elle fournit PostgreSQL `15.4` et ne garantit pas une version stable dans le temps.
7. **Ajouter un fichier `.dockerignore`.** Le contexte de construction est la racine du dépôt, qui contient aussi `.git`, la documentation et les fichiers du laboratoire, dont les disques des machines virtuelles. Le constructeur utilisé ne transfère que les chemins désignés par les instructions `COPY`, mais un fichier `.dockerignore` rendrait ce comportement explicite et indépendant du constructeur.

Ces améliorations doivent être validées par des tests, et non appliquées toutes simultanément.

## 11. Étape suivante

La prochaine étape consiste à préparer une configuration Docker Compose permettant de décrire et de démarrer ensemble l’API, PostgreSQL et RabbitMQ, avec un réseau commun et une configuration reproductible.

### Intégration des sources d’eShop au dépôt

Les sources d’eShop sont commitées dans le dépôt, sous `application/eShop`. Leur provenance est décrite dans `application/README.md`.

Cette situation résulte de la correction d’un défaut. Il est décrit ici parce qu’il est silencieux et facile à reproduire.

#### Le défaut

Les sources ont d’abord été obtenues en clonant le dépôt d’eShop dans `application/eShop`. Ce répertoire contenait donc son propre dépôt Git. Lors du commit, Git n’a pas enregistré ses fichiers : il a enregistré une simple référence vers un commit du dépôt d’eShop.

```bash
git ls-files -s application
```

Cette commande affiche ce que Git suit réellement sous `application`, avec le type de chaque entrée.

Résultat constaté avant correction :

```text
160000 dc7ea499cd356924fb6689b3702964a5869dbae9 0	application/eShop
```

Le mode `160000` désigne une référence vers un autre dépôt, et non des fichiers. Le dépôt ne contenait aucun fichier `.gitmodules` qui aurait indiqué où trouver cet autre dépôt.

| Constat avant correction | Valeur |
|---|---|
| Fichiers présents sur le disque sous `application/` | 1145 |
| Fichiers suivis par Git sous `application/` | Aucun, une seule référence |
| Résultat de `git status` | Aucun changement signalé |

Une personne qui aurait cloné le dépôt aurait obtenu un répertoire `application/eShop` vide, et la construction aurait échoué à la première instruction `COPY`. Il en serait allé de même dans une chaîne d’intégration continue. Le problème était silencieux, puisque `git status` ne signalait rien.

Supprimer le répertoire `.git` imbriqué ne suffisait pas : la référence restait enregistrée dans le dépôt principal.

#### Les deux solutions possibles

| Solution | Principe | Avantage | Contrepartie |
|---|---|---|---|
| Sous-module Git | Le dépôt référence officiellement celui d’eShop, à un commit précis | Dépôt léger, version d’eShop explicite | Le clone et l’intégration continue doivent récupérer le sous-module ; le code d’eShop ne peut pas être modifié sans passer par une copie personnelle du dépôt |
| Copie des sources | Les fichiers d’eShop sont commités dans le dépôt | Un simple clone suffit ; le code peut être adapté | Dépôt plus lourd ; la version d’origine doit être notée, et les mises à jour sont manuelles |

La copie des sources a été retenue. Un simple clone suffit alors à tout le monde, intégration continue comprise, et le code pourra être adapté si nécessaire, par exemple pour les routes de santé décrites en section 8.

#### La correction

```bash
git rm --cached application/eShop
git add application/eShop
git commit -m "[App] - Import des sources dotnet/eShop (commit dc7ea49)"
```

La première commande retire la référence du dépôt, sans toucher aux fichiers présents sur le disque. La deuxième ajoute les fichiers eux-mêmes. La troisième les enregistre.

L’import a été commité seul, sans aucune modification du code. Les adaptations éventuelles feront l’objet de commits distincts, ce qui permettra de les comparer au code d’origine.

#### Vérification

Les vérifications suivantes ont été réalisées le 12 octobre 2026.

| Contrôle | Résultat |
|---|---|
| Entrées de type référence sous `application/` | Aucune |
| Fichiers suivis par Git sous `application/` | 1145, autant que sur le disque |
| Contenu du commit d’import | Uniquement des fichiers sous `application/` |
| Clone du dépôt dans un répertoire vide | 1145 fichiers sous `application/`, aucun changement signalé |
| Fichiers désignés par les instructions `COPY` du Dockerfile | Tous présents dans le clone |
| Comparaison avec le dépôt d’eShop au commit `dc7ea49` | 1145 fichiers de part et d’autre, 1144 identiques à l’octet près |

Le seul fichier différent est `.github/workflows/pr-validation-maui.yml`. Son contenu est identique : seules ses fins de ligne diffèrent, Git les ayant normalisées lors de l’ajout.

La construction de l’image à partir d’un clone neuf n’a pas été rejouée. Seule la présence de tous les fichiers nécessaires a été vérifiée.

#### Deux points à connaître

**Chemins longs sous Windows.** Le chemin le plus long du dépôt compte 146 caractères. Sous Windows, un clone placé dans un répertoire profond peut dépasser la limite de 260 caractères, et Git échoue alors à créer certains fichiers. Ce cas a été rencontré pendant la vérification. Deux remèdes : cloner dans un répertoire proche de la racine du disque, ou autoriser les chemins longs.

```bash
git config --global core.longpaths true
```

Cette commande autorise Git à créer des chemins de plus de 260 caractères. Le problème ne se pose ni sous Linux, ni dans WSL2.

**Fichiers d’automatisation d’eShop.** Le répertoire `application/eShop/.github/workflows` contient les fichiers d’intégration continue du projet eShop. GitHub ne les exécute pas : seuls les fichiers placés dans le répertoire `.github` situé à la racine du dépôt sont pris en compte.

---

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
