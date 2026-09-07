using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Data;

namespace SwishWeighing.Api.Services;

/// <summary>
/// Auth gate for /api/**:
///  • Portal/admin calls need the admin key (<c>X-Api-Key</c>).
///  • Tablet calls (<c>/api/devices/heartbeat</c>, <c>/api/devices/me/*</c>,
///    <c>/api/devices/events</c>, <c>/api/weigh-events</c>) may instead present
///    their own <c>X-Device-Key</c>; the validated device id is stashed in
///    <c>HttpContext.Items</c> for the controller.
///  • <c>/api/webhooks/foodics/*</c> is called by Foodics itself, which sends
///    neither header — it carries its own secret in the URL path instead
///    (see WebhooksController), so it's exempt from this gate entirely.
/// /health and /swagger stay open; CORS preflight passes through.
/// </summary>
public class ApiKeyMiddleware
{
    private readonly RequestDelegate _next;
    private readonly string _adminKey;

    public ApiKeyMiddleware(RequestDelegate next, IConfiguration cfg)
    {
        _next = next;
        _adminKey = cfg["Api:AdminKey"] ?? "";
    }

    public async Task Invoke(HttpContext ctx)
    {
        var path = ctx.Request.Path.Value ?? "";
        if (!path.StartsWith("/api", StringComparison.OrdinalIgnoreCase) ||
            HttpMethods.IsOptions(ctx.Request.Method) ||
            path.StartsWith("/api/webhooks/foodics", StringComparison.OrdinalIgnoreCase))
        {
            await _next(ctx);
            return;
        }

        // Admin key unlocks everything.
        var apiKey = ctx.Request.Headers["X-Api-Key"].FirstOrDefault();
        if (!string.IsNullOrEmpty(_adminKey) && string.Equals(apiKey, _adminKey, StringComparison.Ordinal))
        {
            await _next(ctx);
            return;
        }

        // Tablet endpoints also accept a per-device key.
        var isDeviceEndpoint =
            path.StartsWith("/api/devices/heartbeat", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith("/api/devices/me", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith("/api/devices/events", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith("/api/weigh-events", StringComparison.OrdinalIgnoreCase);

        if (isDeviceEndpoint)
        {
            var deviceKey = ctx.Request.Headers["X-Device-Key"].FirstOrDefault();
            if (!string.IsNullOrEmpty(deviceKey))
            {
                var db = ctx.RequestServices.GetRequiredService<AppDbContext>();
                var hash = DeviceKeys.Hash(deviceKey);
                // Few devices per install; compare in memory to avoid byte[] SQL quirks.
                var devices = await db.Devices.Where(d => d.IsActive).ToListAsync();
                var device = devices.FirstOrDefault(d => d.ApiKeyHash.SequenceEqual(hash));
                if (device != null)
                {
                    ctx.Items["DeviceId"] = device.DeviceId;
                    ctx.Items["BranchId"] = device.BranchId;
                    await _next(ctx);
                    return;
                }
            }
        }

        ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await ctx.Response.WriteAsJsonAsync(new { error = "Invalid or missing key." });
    }
}
