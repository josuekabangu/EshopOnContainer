# Étape de build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /app

# Copie les scripts dans un dossier temporaire
COPY scripts/ /tmp/scripts/
RUN chmod +x /tmp/scripts/init-db.sh \
    && chmod +x /tmp/scripts/wait-for-it.sh


COPY . .   

WORKDIR /app/src/Webhooks.API
RUN dotnet restore "Webhooks.API.csproj"
RUN dotnet build "Webhooks.API.csproj" -c Release -o /app/build
RUN dotnet publish "Webhooks.API.csproj" -c Release -o /out --no-restore

# Étape runtime
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app
COPY --from=build /out .

# Copie les scripts depuis le dossier temporaire
COPY --from=build /tmp/scripts/wait-for-it.sh /app/wait-for-it.sh
COPY --from=build /tmp/scripts/init-db.sh /app/init-db.sh

RUN apt-get update && apt-get install -y curl

RUN mkdir -p /app/keys && chown 1654 /app/keys

RUN chmod +x /app/wait-for-it.sh /app/init-db.sh

EXPOSE 5227

ENTRYPOINT ["dotnet", "Webhooks.API.dll"]