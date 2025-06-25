using Microsoft.AspNetCore.DataProtection;
using System.IO;

var builder = WebApplication.CreateBuilder(args);

// Assure que le dossier de persistance des clés existe
var keysFolder = "/app/keys";
if (!Directory.Exists(keysFolder))
{
    Directory.CreateDirectory(keysFolder);
}

// Configurer Data Protection pour persister les clés dans /app/keys (monté via Docker volume)
builder.Services.AddDataProtection()
    .PersistKeysToFileSystem(new DirectoryInfo(keysFolder))
    .SetApplicationName("BasketAPI"); // optionnel, utile si tu as plusieurs apps qui partagent les clés

// Ajouter HealthChecks
builder.Services.AddHealthChecks();

// Ajouter la config de base et services métier
builder.AddBasicServiceDefaults();
builder.AddApplicationServices();

// Ajouter gRPC
builder.Services.AddGrpc();

var app = builder.Build();

// Exposer le health check sur /hc
app.MapHealthChecks("/hc");

// Exposer les endpoints par défaut
app.MapDefaultEndpoints();

// Exposer le service gRPC
app.MapGrpcService<BasketService>();

app.Run();
