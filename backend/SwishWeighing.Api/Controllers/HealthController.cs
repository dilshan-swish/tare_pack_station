using Microsoft.AspNetCore.Mvc;
using SwishWeighing.Api.Data;

namespace SwishWeighing.Api.Controllers;

[ApiController]
[Route("health")]
public class HealthController : ControllerBase
{
    private readonly AppDbContext _db;
    public HealthController(AppDbContext db) => _db = db;

    [HttpGet]
    public async Task<IActionResult> Get()
    {
        bool db = false;
        string? error = null;
        try { db = await _db.Database.CanConnectAsync(); }
        catch (Exception ex) { error = ex.Message; }
        return Ok(new { status = "ok", database = db, error, timeUtc = DateTime.UtcNow });
    }
}
