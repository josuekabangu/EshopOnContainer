# Utiliser l'image de base dotnet SDK
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build

# Installer les dépendances requises pour Android SDK et OpenJDK 17
RUN apt-get update && apt-get install -y \
    unzip \
    curl \
    git \
    openjdk-17-jdk \
    && apt-get clean

# Installer le SDK Android
RUN mkdir -p /opt/android-sdk-linux/cmdline-tools && \
    curl -sS https://dl.google.com/android/repository/commandlinetools-linux-6858069_latest.zip -o /opt/android-sdk-linux/cmdline-tools/tools.zip && \
    unzip /opt/android-sdk-linux/cmdline-tools/tools.zip -d /opt/android-sdk-linux/cmdline-tools && \
    rm /opt/android-sdk-linux/cmdline-tools/tools.zip && \
    mv /opt/android-sdk-linux/cmdline-tools/cmdline-tools /opt/android-sdk-linux/cmdline-tools/latest && \
    yes | /opt/android-sdk-linux/cmdline-tools/latest/bin/sdkmanager --licenses && \
    # Installer les dépendances requises, y compris les API 35
    /opt/android-sdk-linux/cmdline-tools/latest/bin/sdkmanager "platform-tools" "build-tools;30.0.3" "platforms;android-30" "platforms;android-35"

# Ajouter Android SDK au PATH
ENV ANDROID_HOME=/opt/android-sdk-linux
ENV PATH=$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin

# Installer le workload .NET MAUI pour Android
RUN dotnet workload install maui-android

# Définir le répertoire de travail pour les commandes suivantes
WORKDIR /app

# Copier le fichier de solution (.sln) dans le conteneur
COPY *.sln ./

# Copier les fichiers projet dans le conteneur
COPY src/ClientApp/*.csproj src/ClientApp/

# Restaurer les dépendances du projet .NET
RUN dotnet restore src/ClientApp/ClientApp.csproj

# Copier le reste des fichiers source dans le conteneur
COPY . .

# Construire le projet avec la configuration Release
RUN dotnet build src/ClientApp/ClientApp.csproj -c Release -o /app/build

# Publier l'application pour la plateforme Android
RUN dotnet publish src/ClientApp/ClientApp.csproj -c Release -o /app/publish -f net9.0-android /p:Platform="Android"

# Utiliser l'image de base ASP.NET pour l'exécution de l'application
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS base

# Définir le répertoire de travail pour l'exécution
WORKDIR /app

# Copier les fichiers publiés depuis le conteneur de build
COPY --from=build /app/publish .

# Exposer le port de l'application
EXPOSE 80

# Définir la commande pour démarrer l'application
ENTRYPOINT ["dotnet", "ClientApp.dll"]
