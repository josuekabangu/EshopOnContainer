# Étape 1 : Utiliser l'image de base .NET SDK pour la construction
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build

# Définir le répertoire de travail
WORKDIR /app

# Copier le fichier de projet et restaurer les dépendances
COPY src/Basket.API/Basket.API.csproj ./src/Basket.API/
RUN dotnet restore src/Basket.API/Basket.API.csproj

# Copier tous les fichiers nécessaires pour la compilation
COPY . .

# Télécharger le script wait-for-it.sh
RUN curl -o /app/wait-for-it.sh https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh && \
    chmod +x /app/wait-for-it.sh

# Construire et publier l'application en mode Release
RUN dotnet build src/Basket.API/Basket.API.csproj -c Release -o /app/build
RUN dotnet publish src/Basket.API/Basket.API.csproj -c Release -o /app/publish

# Étape 2 : Utiliser une image d'exécution .NET Runtime pour l'exécution
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS final

# Définir le répertoire de travail
WORKDIR /app

# Copier les fichiers publiés à partir de l'étape de construction
COPY --from=build /app/publish .

# Copier le script wait-for-it.sh depuis l'image de build
COPY --from=build /app/wait-for-it.sh /wait-for-it.sh

# Donner les permissions d'exécution (si pas déjà fait)
RUN chmod +x /wait-for-it.sh

# Exposer le port sur lequel l'application écoute
EXPOSE 5221

# Commande pour exécuter l'application après avoir attendu Redis et RabbitMQ
ENTRYPOINT ["/wait-for-it.sh", "redis:6379", "--", "/wait-for-it.sh", "rabbitmq:5672", "--", "dotnet", "Basket.API.dll"]
