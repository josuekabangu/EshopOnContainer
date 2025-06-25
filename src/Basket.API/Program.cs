var builder = WebApplication.CreateBuilder(args);

// Ajouter HealthChecks
builder.Services.AddHealthChecks();

builder.AddBasicServiceDefaults();
builder.AddApplicationServices();

builder.Services.AddGrpc();

var app = builder.Build();

// Exposer le health check sur /hc
app.MapHealthChecks("/hc");

// Exposer les endpoints par défaut
app.MapDefaultEndpoints();

// Exposer le service gRPC
app.MapGrpcService<BasketService>();

app.Run();
