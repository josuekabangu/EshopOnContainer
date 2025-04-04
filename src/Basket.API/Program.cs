using System.Net;
using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = WebApplication.CreateBuilder(args);

// Configure Kestrel to support both HTTP/1.x and HTTP/2
builder.WebHost.ConfigureKestrel(options =>
{
    options.Listen(IPAddress.Any, 8080, listenOptions =>
    {
        // Support both HTTP/1.x and HTTP/2
        listenOptions.Protocols = HttpProtocols.Http1AndHttp2;
    });
});

builder.AddBasicServiceDefaults();
builder.AddApplicationServices();

builder.Services.AddGrpc();

var app = builder.Build();

app.MapDefaultEndpoints();

app.MapGrpcService<BasketService>();

app.Run();
