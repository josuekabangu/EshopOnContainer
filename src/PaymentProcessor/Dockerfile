# Étape de build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /app

# Copie les scripts dans un dossier temporaire
COPY scripts/ /tmp/scripts/
RUN chmod +x /tmp/scripts/wait-for-it.sh


COPY . .   

WORKDIR /app/src/PaymentProcessor
RUN dotnet restore "PaymentProcessor.csproj"
RUN dotnet build "PaymentProcessor.csproj" -c Release -o /app/build
RUN dotnet publish "PaymentProcessor.csproj" -c Release -o /out --no-restore

# Étape runtime
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app

COPY --from=build /out .

# Copie les scripts depuis le dossier temporaire
COPY --from=build /tmp/scripts/wait-for-it.sh /app/wait-for-it.sh

RUN mkdir -p /app/keys && chown 1654 /app/keys
RUN chmod +x wait-for-it.sh && \
    apt-get update && apt-get install -y curl && apt-get clean && rm -rf /var/lib/apt/lists/*


EXPOSE 5226

ENTRYPOINT ["dotnet", "PaymentProcessor.dll"]
