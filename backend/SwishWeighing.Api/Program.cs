using Microsoft.EntityFrameworkCore;
using Microsoft.OpenApi.Models;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Services;

var builder = WebApplication.CreateBuilder(args);

// Lets `dotnet SwishWeighing.Api.dll` run as a proper Windows Service under
// the Service Control Manager (see docs/PRODUCTION_DEPLOYMENT_GUIDE.md) —
// correct start/stop lifecycle handling and Windows Event Log logging when
// actually hosted as a service. A no-op everywhere else (dotnet run, IIS),
// so local dev and IIS hosting are both unaffected.
builder.Host.UseWindowsService();

// --- Services ---
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    // Adds the "Authorize" button in Swagger so you can enter the X-Api-Key once
    // and have it sent on every "Try it out" call.
    c.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Name = "X-Api-Key",
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Description = "Paste your API key (from Api:AdminKey), e.g. dev-change-me",
    });
    c.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "ApiKey",
                },
            },
            Array.Empty<string>()
        },
    });
});

builder.Services.AddDbContext<AppDbContext>(o =>
    o.UseSqlServer(builder.Configuration.GetConnectionString("Sql")));

builder.Services.Configure<FoodicsOptions>(builder.Configuration.GetSection("Foodics"));
builder.Services.AddHttpClient<FoodicsService>();
// Keeps every brand's synced catalog from drifting out of date with Foodics
// without relying on someone remembering to click "Sync Foodics" in the
// portal — see FoodicsAutoSyncHostedService for why this exists. The queue is
// a singleton shared between WebhooksController (writes) and the hosted
// service (reads) — it has to outlive any single request.
builder.Services.AddSingleton<IFoodicsSyncQueue, FoodicsSyncQueue>();
builder.Services.AddHostedService<FoodicsAutoSyncHostedService>();

var corsOrigins = builder.Configuration.GetSection("Cors:Origins").Get<string[]>() ?? Array.Empty<string>();
builder.Services.AddCors(o => o.AddDefaultPolicy(p =>
{
    if (corsOrigins.Length > 0)
        p.WithOrigins(corsOrigins).AllowAnyHeader().AllowAnyMethod();
}));

var app = builder.Build();

// --- Pipeline ---
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseCors();
app.UseMiddleware<ApiKeyMiddleware>();
app.MapControllers();

// A real, easy-to-hit production foot-gun: appsettings.Production.json
// deliberately carries no Api:AdminKey/Foodics secrets (they belong in
// environment variables, never in a checked-in file) — so a deploy that
// forgot to actually SET those env vars silently falls back to the
// insecure dev defaults instead of failing loudly. This can't safely be a
// hard failure (a fresh install legitimately starts with defaults before
// anyone's configured it), but it must never pass unnoticed either.
if (app.Environment.IsProduction())
{
    var log = app.Services.GetRequiredService<ILogger<Program>>();
    var adminKey = builder.Configuration["Api:AdminKey"];
    if (string.IsNullOrEmpty(adminKey) || adminKey == "dev-change-me")
        log.LogWarning(
            "Api:AdminKey is still the development default — set a real key via " +
            "the Api__AdminKey environment variable before real traffic reaches this server.");

    var brands = builder.Configuration.GetSection("Foodics:Brands").Get<List<FoodicsBrandToken>>() ?? [];
    if (brands.Count == 0 || brands.All(b => string.IsNullOrEmpty(b.Token)))
        log.LogWarning(
            "No Foodics brand tokens are configured — automatic catalog sync has nothing " +
            "to sync yet. Set Foodics__Brands__N__Code / Foodics__Brands__N__Token env vars.");
}

app.Run();
