# Étape de build avec .NET 9.0
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /app

# Copier tous les fichiers sources avant la restauration des dépendances
COPY . .

# Restaurer les dépendances du projet
WORKDIR /app/src/Catalog.API
RUN dotnet restore "Catalog.API.csproj"

# Compiler et publier l'application
RUN dotnet publish "Catalog.API.csproj" -c Release -o /out --no-restore

# Étape d'exécution avec .NET 9.0 (runtime uniquement)
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app
COPY --from=build /out .
ENTRYPOINT ["dotnet", "Catalog.API.dll"]
