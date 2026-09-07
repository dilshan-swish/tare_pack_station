using System.Security.Cryptography;
using Microsoft.AspNetCore.Mvc;
using SwishWeighing.Api.Data;
using SwishWeighing.Api.Dtos;
using SwishWeighing.Api.Models;

namespace SwishWeighing.Api.Controllers;

/// <summary>
/// Publishing/managing a brand's ML weight-prediction model from the portal —
/// the same "publish once, every tablet for that brand picks it up" shape as
/// the menu itself, just for a .tflite file instead of item weights.
/// Admin-only implicitly: this route isn't in ApiKeyMiddleware's
/// device-endpoint allowlist, so a device key can never authenticate here at
/// all — a tablet only ever reaches the read-only devices/me/model*
/// endpoints in DevicesController.
/// </summary>
[ApiController]
[Route("api/brands/{brandId:int}/model")]
public class WeightModelsController : ControllerBase
{
    private readonly AppDbContext _db;
    public WeightModelsController(AppDbContext db) => _db = db;

    private const long MaxModelBytes = 25 * 1024 * 1024; // 25MB — generous for a mobile-sized TFLite model

    /// <summary>
    /// Current model's metadata, or a 200 with a null body if this brand has
    /// none published yet — a normal, permanent state rather than an error,
    /// so it isn't reported as one (a 404 here would show as a red failed
    /// request in the browser console on every single portal page load for
    /// any brand without a model, despite being fully expected).
    /// </summary>
    [HttpGet]
    public async Task<ActionResult<ModelMetaDto?>> Meta(int brandId)
    {
        var model = await _db.BrandWeightModels.FindAsync(brandId);
        if (model is null) return Ok(null);
        return Ok(new ModelMetaDto(model.Version, model.FileName, model.SizeBytes, model.Sha256Hash, model.UploadedAt));
    }

    /// <summary>
    /// Publishes a new model for this brand, replacing whatever was there
    /// before (version increments). Every tablet on this brand picks it up on
    /// its next ~20s poll — same latency as a menu publish.
    /// </summary>
    [HttpPost]
    [RequestSizeLimit(MaxModelBytes + 4096)]
    public async Task<ActionResult<ModelMetaDto>> Upload(int brandId, IFormFile? file, [FromQuery] string? uploadedBy)
    {
        var brand = await _db.Brands.FindAsync(brandId);
        if (brand is null) return NotFound(new { error = "Brand not found." });

        if (file is null || file.Length == 0)
            return BadRequest(new { error = "A model file is required." });
        if (!file.FileName.EndsWith(".tflite", StringComparison.OrdinalIgnoreCase))
            return BadRequest(new { error = "Only .tflite files are accepted." });
        if (file.Length > MaxModelBytes)
            return BadRequest(new { error = $"Model must be {MaxModelBytes / (1024 * 1024)}MB or smaller." });
        if (uploadedBy is { Length: > 100 })
            return BadRequest(new { error = "uploadedBy must be 100 characters or fewer." });

        using var ms = new MemoryStream();
        await file.CopyToAsync(ms);
        var bytes = ms.ToArray();
        var hash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

        var existing = await _db.BrandWeightModels.FindAsync(brandId);
        var version = (existing?.Version ?? 0) + 1;

        if (existing is null)
        {
            _db.BrandWeightModels.Add(new BrandWeightModel
            {
                BrandId = brandId,
                Version = version,
                FileName = file.FileName,
                SizeBytes = bytes.LongLength,
                Sha256Hash = hash,
                ModelBytes = bytes,
                UploadedAt = DateTime.UtcNow,
                UploadedBy = uploadedBy,
            });
        }
        else
        {
            existing.Version = version;
            existing.FileName = file.FileName;
            existing.SizeBytes = bytes.LongLength;
            existing.Sha256Hash = hash;
            existing.ModelBytes = bytes;
            existing.UploadedAt = DateTime.UtcNow;
            existing.UploadedBy = uploadedBy;
        }
        await _db.SaveChangesAsync();

        return Ok(new ModelMetaDto(version, file.FileName, bytes.LongLength, hash, DateTime.UtcNow));
    }

    /// <summary>Removes this brand's published model — tablets fall back to the statistical evaluator on their next poll.</summary>
    [HttpDelete]
    public async Task<IActionResult> Delete(int brandId)
    {
        var model = await _db.BrandWeightModels.FindAsync(brandId);
        if (model is null) return NotFound();
        _db.BrandWeightModels.Remove(model);
        await _db.SaveChangesAsync();
        // A real (if small) JSON body, not a bare 200 — the portal's generic
        // request() helper always calls res.json() on anything that isn't a
        // 204, so an empty-bodied 200 here would throw a JSON parse error on
        // an otherwise-successful delete (exactly what happened before this
        // fix: the row was removed, but the portal reported "could not
        // remove the model" anyway).
        return Ok(new { brandId, removed = true });
    }
}
