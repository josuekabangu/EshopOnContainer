# Étape de build
FROM mcr.microsoft.com/dotnet/sdk:9.0.203 AS build
WORKDIR /app

# Copie les scripts
COPY scripts/ /tmp/scripts/
RUN chmod +x /tmp/scripts/wait-for-it.sh

# Copie tout le code
COPY . .

# Inclure fichiers de config si nécessaire (renforce la robustesse)
COPY src/Basket.API/appsettings*.json ./src/Basket.API/

WORKDIR /app/src/Basket.API
RUN dotnet restore "Basket.API.csproj"
RUN dotnet publish "Basket.API.csproj" -c Release -o /out --no-restore

# Étape runtime
FROM mcr.microsoft.com/dotnet/aspnet:9.0
WORKDIR /app

COPY --from=build /out .
COPY --from=build /tmp/scripts/wait-for-it.sh /app/wait-for-it.sh
RUN chmod +x wait-for-it.sh && \
    apt-get update && apt-get install -y curl && apt-get clean && rm -rf /var/lib/apt/lists/*

EXPOSE 5221

# Optionnel : rendre l'image autonome
ENTRYPOINT ["dotnet", "Basket.API.dll"]
