# Application eShop

Ce répertoire contient le code source de l'application déployée par le projet.

## Provenance

| Élément | Valeur |
|---|---|
| Projet | eShop, application de référence de Microsoft |
| Dépôt d'origine | https://github.com/dotnet/eShop |
| Commit importé | `dc7ea499cd356924fb6689b3702964a5869dbae9` (« Update to Aspire 13.6.0 ») |
| Date de l'import | 12 octobre 2026 |
| Licence | MIT, voir `eShop/LICENSE` |

Le code se trouve dans `eShop/`. Il a été importé tel quel, sans modification, dans un commit dédié.

## Pourquoi une copie ?

Les sources sont copiées dans ce dépôt, plutôt que référencées par un sous-module Git. Un simple clone suffit ainsi à construire les images, y compris dans une chaîne d'intégration continue, et le code peut être adapté si le déploiement l'exige.

Le raisonnement et la correction du défaut qui a précédé ce choix sont décrits dans
[docs/02-docker/01-catalog-api.md](../docs/02-docker/01-catalog-api.md), section 11.

## Règles

- **Ne pas modifier ce code sans nécessité.** Le projet porte sur l'infrastructure et le déploiement, pas sur l'application.
- **Une adaptation, un commit.** Toute modification du code d'eShop fait l'objet d'un commit distinct, qui explique pourquoi elle est nécessaire. Les écarts avec le code d'origine restent ainsi identifiables.
- **Lister ici les adaptations.** Le tableau ci-dessous doit être tenu à jour.

## Adaptations par rapport au code d'origine

| Fichier | Modification | Raison | Commit |
|---|---|---|---|
| `eShop/src/eShop.ServiceDefaults/Extensions.cs` | Les routes `/health` et `/alive` sont aussi déclarées hors `Development` quand le réglage `HealthChecks:Expose` vaut `true` ; ajout de `using Microsoft.Extensions.Configuration;`, nécessaire à `GetValue` | Les contrôles de santé de Docker Compose et les probes de Kubernetes en ont besoin ; sans le réglage, le comportement d'origine est conservé | `ae2f77b` |
| `eShop/src/WebApp/Extensions/Extensions.cs` | Les cookies de corrélation et de nonce d'OpenID Connect passent en `SameSite=Lax`, sans attribut `Secure`, et la réponse de connexion revient dans l'adresse (`ResponseMode = "query"`), quand le réglage `Authentication:AllowInsecureCookies` vaut `true` | Permettre la connexion en HTTP par une adresse autre que `localhost`, par exemple celle d'un nœud du cluster ; sans le réglage, le comportement d'origine est conservé | `72ee8fa` |
| `eShop/src/WebhookClient/Extensions/Extensions.cs` | La même adaptation que pour `WebApp`, activée par le même réglage `Authentication:AllowInsecureCookies` | Sur le cluster, `WebhookClient` est ouvert en HTTP par `webhooks.eshop.lab` : sans elle, la connexion échoue sur `Correlation failed`, le navigateur ne renvoyant pas le cookie de corrélation ; sans le réglage, le comportement d'origine est conservé | `a6647c9` |

Jusqu'au 15 octobre 2026, la modification de `WebApp` était appliquée en dehors de ce répertoire, par un fichier de remplacement copié pendant la construction de l'image (`docker/src/WebApp/Extensions.cs`, supprimé depuis). Voir [docs/02-docker/02-autres-services.md](../docs/02-docker/02-autres-services.md), sections 8 et 8 bis.

Le commit `72ee8fa` contient aussi la ligne du tableau qui décrit l'adaptation `ae2f77b` : les deux commits ont été faits dans l'ordre inverse de celui prévu. Le code de chaque adaptation est bien dans son propre commit.

L'image de `WebhookClient` publiée sur le registre porte l'étiquette `a6647c9`, celle du commit de son adaptation ; les autres images portent toujours `87e28f8`.

Une différence existe avec le dépôt d'origine sans être une adaptation : le fichier `eShop/.github/workflows/pr-validation-maui.yml` a les mêmes lignes, mais ses fins de ligne ont été normalisées par Git lors de l'import.

## Mettre à jour le code

La mise à jour vers une version plus récente d'eShop est manuelle : remplacer le contenu de `eShop/` par celui du nouveau commit, réappliquer les adaptations listées ci-dessus, puis mettre à jour le tableau de provenance.

## Fichiers d'automatisation

Le répertoire `eShop/.github/workflows` contient l'intégration continue du projet eShop. GitHub ne l'exécute pas : seul le répertoire `.github` situé à la racine du dépôt est pris en compte.
