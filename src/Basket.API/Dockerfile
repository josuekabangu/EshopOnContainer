# Étape de build
FROM mcr.microsoft.com/dotnet/sdk:9.0.203 AS build
WORKDIR /app

# 💡 Copie les scripts dans un dossier temporaire
COPY scripts/ /tmp/scripts/
RUN chmod +x /tmp/scripts/wait-for-it.sh

# Copie le code de l'application 
COPY . .

WORKDIR /app/src/Basket.API
RUN dotnet restore "Basket.API.csproj"
RUN dotnet publish "Basket.API.csproj" -c Release -o /out --no-restore

# Étape d'exécution
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app

COPY --from=build /out .

# Copie les scripts depuis le dossier temporaire
COPY --from=build /tmp/scripts/wait-for-it.sh /app/wait-for-it.sh
RUN chmod +x wait-for-it.sh && \
    apt-get update && apt-get install -y curl && apt-get clean && rm -rf /var/lib/apt/lists/*

EXPOSE 5221

ENTRYPOINT ["dotnet", "Basket.API.dll"]

