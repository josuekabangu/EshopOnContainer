var builder = WebApplication.CreateBuilder(args);

// Autoriser HTTP/1.1 + HTTP/2
builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(5221, listenOptions =>
    {
        listenOptions.Protocols = Microsoft.AspNetCore.Server.Kestrel.Core.HttpProtocols.Http1AndHttp2;
    });
});

// Ajouter HealthChecks avec au moins un check
builder.Services.AddHealthChecks()
    .AddCheck("self", () => HealthCheckResult.Healthy());

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
