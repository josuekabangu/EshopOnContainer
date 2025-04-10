# Build stage
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /app

COPY . .
RUN curl -o /app/wait-for-it.sh https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh \
    && chmod +x /app/wait-for-it.sh

WORKDIR /app/src/WebApp
RUN dotnet restore "WebApp.csproj"
RUN dotnet publish "WebApp.csproj" -c Release -o /out --no-restore

# Étape d'exécution
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app
RUN apt-get update && apt-get install -y curl
COPY --from=build /out . 
COPY --from=build /app/wait-for-it.sh /wait-for-it.sh

EXPOSE 5103
ENTRYPOINT [ "dotnet", "WebApp.dll"]
