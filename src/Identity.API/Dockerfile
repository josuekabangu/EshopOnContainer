# Étape de build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /app
COPY . .
RUN curl -o /app/wait-for-it.sh https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh \
    && chmod +x /app/wait-for-it.sh
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
COPY --from=build /app/wait-for-it.sh /wait-for-it.sh
RUN apt-get update && apt-get install -y curl
RUN chmod +x /wait-for-it.sh

EXPOSE 5105
ENTRYPOINT ["dotnet", "Identity.API.dll"]