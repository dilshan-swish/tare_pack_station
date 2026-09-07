using Microsoft.EntityFrameworkCore;
using SwishWeighing.Api.Models;

namespace SwishWeighing.Api.Data;

public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

    public DbSet<Brand> Brands => Set<Brand>();
    public DbSet<Branch> Branches => Set<Branch>();
    public DbSet<Device> Devices => Set<Device>();
    public DbSet<MenuItem> MenuItems => Set<MenuItem>();
    public DbSet<Modifier> Modifiers => Set<Modifier>();
    public DbSet<MenuItemModifier> MenuItemModifiers => Set<MenuItemModifier>();
    public DbSet<WeighEvent> WeighEvents => Set<WeighEvent>();
    public DbSet<ConfigPublication> ConfigPublications => Set<ConfigPublication>();
    public DbSet<DeviceEvent> DeviceEvents => Set<DeviceEvent>();
    public DbSet<BrandWeightModel> BrandWeightModels => Set<BrandWeightModel>();
    public DbSet<ModifierCombinationWeight> ModifierCombinationWeights => Set<ModifierCombinationWeight>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        // Computed helpers on the entities are not columns.
        b.Entity<MenuItem>().Ignore(x => x.IsConfigured);
        b.Entity<Modifier>().Ignore(x => x.IsConfigured);
        b.Entity<MenuItemModifier>().HasKey(x => new { x.MenuItemId, x.ModifierId });
    }
}
