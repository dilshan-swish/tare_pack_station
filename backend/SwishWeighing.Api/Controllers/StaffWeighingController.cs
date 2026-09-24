using Microsoft.AspNetCore.Mvc;

namespace SwishWeighing.Api.Controllers;

/// <summary>
/// Pass-through from the portal's Staff Weighing page to the Supabase project
/// the branch weigh app writes to. The portal already authenticates to this
/// API with its admin key (ApiKeyMiddleware guards every /api route), so it
/// gets the data without a separate login — and the Supabase service-role key
/// never leaves this server. Only the staff-weighing tables are reachable.
///
/// Config: Supabase:Url and Supabase:ServiceRoleKey (user-secrets locally,
/// environment variables Supabase__Url / Supabase__ServiceRoleKey in production).
/// </summary>
[ApiController]
[Route("api/staff-weighing/rest/v1")]
public class StaffWeighingController : ControllerBase
{
    private static readonly HashSet<string> AllowedPaths = new(StringComparer.Ordinal)
    {
        "weigh_entries",
        "branches",
        "app_settings",
        "focus_items",
        "rpc/get_item_progress",
    };

    // Request headers PostgREST needs to understand the query (count, upsert, ranges…).
    private static readonly string[] ForwardRequestHeaders = { "Accept", "Prefer", "Range", "Range-Unit", "Accept-Profile", "Content-Profile" };
    private static readonly string[] ForwardResponseHeaders = { "Content-Range", "Preference-Applied" };

    private readonly IHttpClientFactory _http;
    private readonly IConfiguration _cfg;
    private readonly ILogger<StaffWeighingController> _log;

    public StaffWeighingController(IHttpClientFactory http, IConfiguration cfg, ILogger<StaffWeighingController> log)
    {
        _http = http;
        _cfg = cfg;
        _log = log;
    }

    [HttpGet("{**path}")]
    [HttpPost("{**path}")]
    [HttpPatch("{**path}")]
    [HttpDelete("{**path}")]
    public async Task<IActionResult> Proxy(string path, CancellationToken ct)
    {
        var baseUrl = _cfg["Supabase:Url"]?.TrimEnd('/');
        var key = _cfg["Supabase:ServiceRoleKey"];
        if (string.IsNullOrWhiteSpace(baseUrl) || string.IsNullOrWhiteSpace(key))
        {
            return StatusCode(503, new
            {
                message = "The API isn't connected to Supabase yet. Set Supabase:Url and Supabase:ServiceRoleKey (see weigh-app/README.md) and restart the API.",
                code = "not_configured",
            });
        }

        path = (path ?? "").Trim('/');
        if (!AllowedPaths.Contains(path))
            return NotFound(new { message = $"'{path}' isn't available through this API.", code = "not_allowed" });

        var method = new HttpMethod(Request.Method);
        using var msg = new HttpRequestMessage(method, $"{baseUrl}/rest/v1/{path}{Request.QueryString}");
        msg.Headers.TryAddWithoutValidation("apikey", key);
        msg.Headers.TryAddWithoutValidation("Authorization", $"Bearer {key}");
        foreach (var h in ForwardRequestHeaders)
        {
            if (Request.Headers.TryGetValue(h, out var v)) msg.Headers.TryAddWithoutValidation(h, v.ToArray());
        }

        if (method == HttpMethod.Post || method == HttpMethod.Patch)
        {
            using var reader = new StreamReader(Request.Body);
            var body = await reader.ReadToEndAsync(ct);
            if (body.Length > 0)
            {
                msg.Content = new StringContent(body);
                msg.Content.Headers.ContentType =
                    System.Net.Http.Headers.MediaTypeHeaderValue.Parse(Request.ContentType ?? "application/json");
            }
        }

        HttpResponseMessage res;
        try
        {
            var client = _http.CreateClient("supabase");
            res = await client.SendAsync(msg, HttpCompletionOption.ResponseHeadersRead, ct);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            return StatusCode(504, new { message = "Supabase took too long to respond. Try again.", code = "timeout" });
        }
        catch (HttpRequestException ex)
        {
            _log.LogWarning(ex, "Supabase proxy request failed");
            return StatusCode(502, new { message = "Couldn't reach Supabase. Check the API's internet connection and Supabase:Url.", code = "unreachable" });
        }

        using (res)
        {
            foreach (var h in ForwardResponseHeaders)
            {
                if (res.Headers.TryGetValues(h, out var vals) || res.Content.Headers.TryGetValues(h, out vals))
                    Response.Headers[h] = vals.ToArray();
            }
            if (res.StatusCode == System.Net.HttpStatusCode.Unauthorized || res.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                // Never surface Supabase's auth details; this only happens when the configured key is wrong.
                return StatusCode(502, new { message = "Supabase rejected the API's key. Check Supabase:ServiceRoleKey.", code = "bad_key" });
            }
            var bytes = await res.Content.ReadAsByteArrayAsync(ct);
            var contentType = res.Content.Headers.ContentType?.ToString() ?? "application/json";
            return new UpstreamBytesResult(bytes, contentType, (int)res.StatusCode);
        }
    }
}

/// <summary>Relays Supabase's response body and status code (200, 201, 204, 400…) unchanged.</summary>
internal sealed class UpstreamBytesResult : IActionResult
{
    private readonly byte[] _bytes;
    private readonly string _contentType;
    private readonly int _status;

    public UpstreamBytesResult(byte[] bytes, string contentType, int status)
    {
        _bytes = bytes;
        _contentType = contentType;
        _status = status;
    }

    public async Task ExecuteResultAsync(ActionContext context)
    {
        var res = context.HttpContext.Response;
        res.StatusCode = _status;
        if (_status == 204 || _bytes.Length == 0) return;
        res.ContentType = _contentType;
        res.ContentLength = _bytes.Length;
        await res.Body.WriteAsync(_bytes);
    }
}
