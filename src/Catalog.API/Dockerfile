# Étape de build avec .NET 9.0
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /app

COPY . .
RUN curl -o /app/wait-for-it.sh https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh \
    && chmod +x /app/wait-for-it.sh

WORKDIR /app/src/Catalog.API
RUN dotnet restore "Catalog.API.csproj"
RUN dotnet publish "Catalog.API.csproj" -c Release -o /out --no-restore

# Étape d'exécution
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app
RUN apt-get update && apt-get install -y curl  # Ajouter curl
COPY --from=build /out .
COPY --from=build /app/wait-for-it.sh /wait-for-it.sh
RUN chmod +x /wait-for-it.sh

EXPOSE 5100
ENTRYPOINT ["dotnet", "Catalog.API.dll"]