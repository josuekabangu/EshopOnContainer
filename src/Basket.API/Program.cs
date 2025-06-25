using Microsoft.AspNetCore.DataProtection;
using System.IO;

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

builder.Services.AddHealthChecks();

builder.AddBasicServiceDefaults();
builder.AddApplicationServices();

builder.Services.AddGrpc();

var app = builder.Build();

app.MapHealthChecks("/hc");
app.MapDefaultEndpoints();
app.MapGrpcService<BasketService>();

app.Run();
