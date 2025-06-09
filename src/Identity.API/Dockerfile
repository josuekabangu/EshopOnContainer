# Étape de build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /app

# Copie les scripts dans un dossier temporaire
COPY scripts/ /tmp/scripts/
RUN chmod +x /tmp/scripts/wait-for-it.sh


COPY . .   

WORKDIR /app/src/Identity.API
RUN dotnet restore "Identity.API.csproj"
RUN dotnet tool install -g Microsoft.Web.LibraryManager.Cli  
ENV PATH="$PATH:/root/.dotnet/tools"  
RUN libman restore  
RUN dotnet publish "Identity.API.csproj" -c Release -o /out --no-restore

# Étape runtime
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app

COPY --from=build /out .

# Copie les scripts depuis le dossier temporaire
COPY --from=build /tmp/scripts/wait-for-it.sh /app/wait-for-it.sh
RUN chmod +x wait-for-it.sh && \
    apt-get update && apt-get install -y curl && apt-get clean && rm -rf /var/lib/apt/lists/*


EXPOSE 5243

ENTRYPOINT ["dotnet", "Identity.API.dll"]