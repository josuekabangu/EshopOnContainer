# Build stage
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /app

COPY src/OrderProcessor/OrderProcessor.csproj ./src/OrderProcessor/
RUN dotnet restore src/OrderProcessor/OrderProcessor.csproj
COPY . .
RUN curl -o /app/wait-for-it.sh https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh \
    && chmod +x /app/wait-for-it.sh
RUN dotnet build src/OrderProcessor/OrderProcessor.csproj -c Release -o /app/build
RUN dotnet publish src/OrderProcessor/OrderProcessor.csproj -c Release -o /app/publish

# Runtime stage
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS final
WORKDIR /app
RUN apt-get update && apt-get install -y curl  # Ajouter curl
RUN mkdir -p /app/keys && chown 1654 /app/keys
COPY --from=build /app/publish .
COPY --from=build /app/wait-for-it.sh /wait-for-it.sh
RUN chmod +x /wait-for-it.sh

EXPOSE 80
ENTRYPOINT ["dotnet", "OrderProcessor.dll"]