# Étape de build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

# Copier les fichiers projet et restaurer les dépendances
COPY ["src/Mobile.Bff.Shopping/Mobile.Bff.Shopping.csproj", "Mobile.Bff.Shopping/"]
COPY ["src/eShop.ServiceDefaults/eShop.ServiceDefaults.csproj", "eShop.ServiceDefaults/"]
RUN dotnet restore "Mobile.Bff.Shopping/Mobile.Bff.Shopping.csproj" --runtime linux-x64 --verbosity detailed

# Copier tout le code source
COPY . .

# Build de l'application
WORKDIR "/src/Mobile.Bff.Shopping"
RUN dotnet build "Mobile.Bff.Shopping.csproj" -c Release -o /app/build

# Étape de publication
FROM build AS publish
RUN dotnet publish "Mobile.Bff.Shopping.csproj" -c Release -o /app/publish --runtime linux-x64 --self-contained false

# Étape d'exécution
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS final
WORKDIR /app
COPY --from=publish /app/publish .

# Exposer le port utilisé par l'application
EXPOSE 11632

ENTRYPOINT ["dotnet", "Mobile.Bff.Shopping.dll"]