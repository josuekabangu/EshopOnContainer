# Étape 1 : restauration et publication
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src 

# Fichiers de configuration racine du dépôt .NET
COPY application/eShop/global.json ./
COPY application/eShop/Directory.Packages.props ./ 
COPY application/eShop/Directory.Build.props ./
COPY application/eShop/Directory.Build.targets ./
COPY application/eShop/nuget.config ./

# Sources et projets référencés 
COPY application/eShop/src/ ./src/ 

# Restauration des référencés 
RUN dotnet restore src/Catalog.API/Catalog.API.csproj

# Publication
RUN dotnet publish src/Catalog.API/Catalog.API.csproj \
    --configuration Release \
    --output /app/publish \
    --no-restore

# Étape 2 : Image d'exécution
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app

COPY --from=build /app/publish/ ./

ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# Exécution avec l'utilisateur non privilégié fourni par l'image de base
USER $APP_UID

ENTRYPOINT [ "dotnet", "Catalog.API.dll" ]
