var builder = WebApplication.CreateBuilder(args);

// Autoriser HTTP/1.1 + HTTP/2
builder.WebHost.ConfigureKestrel(options =>
{
    options.ConfigureEndpointDefaults(lo => lo.Protocols = Microsoft.AspNetCore.Server.Kestrel.Core.HttpProtocols.Http1AndHttp2);
});

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
