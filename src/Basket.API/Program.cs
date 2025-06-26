using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using System.IO;
using System.Linq;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

// Autoriser HTTP/1.1 et HTTP/2
builder.WebHost.ConfigureKestrel(options =>
{
    options.ConfigureEndpointDefaults(lo =>
    {
        lo.Protocols = Microsoft.AspNetCore.Server.Kestrel.Core.HttpProtocols.Http1AndHttp2;
    });
});

// Assure que le dossier de persistance des clés existe
var keysFolder = "/app/keys";
if (!Directory.Exists(keysFolder))
{
    Directory.CreateDirectory(keysFolder);
}

builder.Services.AddDataProtection()
    .PersistKeysToFileSystem(new DirectoryInfo(keysFolder))
    .SetApplicationName("BasketAPI");

// 🔐 Health checks pour Redis et RabbitMQ
var redisConnectionString = builder.Configuration["ConnectionStrings:Redis"];
var rabbitmqConnectionString = builder.Configuration["ConnectionStrings:EventBus"];

builder.Services.AddHealthChecks()
    .AddRedis(redisConnectionString, name: "Redis")
    .AddRabbitMQ(rabbitmqConnectionString, name: "RabbitMQ");

builder.AddBasicServiceDefaults();
builder.AddApplicationServices();
builder.Services.AddGrpc();

var app = builder.Build();

// ✅ Route /hc avec JSON détaillé
app.MapHealthChecks("/hc", new HealthCheckOptions
{
    ResponseWriter = async (context, report) =>
    {
        context.Response.ContentType = "application/json";
        var result = JsonSerializer.Serialize(new
        {
            status = report.Status.ToString(),
            checks = report.Entries.Select(e => new {
                name = e.Key,
                status = e.Value.Status.ToString(),
                error = e.Value.Exception?.Message
            })
        });
        await context.Response.WriteAsync(result);
    }
});

app.MapGrpcService<BasketService>();
app.MapGet("/", () => "Basket API is running");

app.Run();
