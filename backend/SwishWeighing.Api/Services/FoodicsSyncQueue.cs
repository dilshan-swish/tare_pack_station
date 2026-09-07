using System.Threading.Channels;

namespace SwishWeighing.Api.Services;

/// <summary>
/// Hands a brand id from the webhook controller (HTTP request scope) over to
/// <see cref="FoodicsAutoSyncHostedService"/> (its own long-lived scope) so an
/// inbound Foodics "menu.updated" event triggers a near-immediate re-sync of
/// just that brand, instead of waiting for the periodic sweep. A brand
/// already queued (or currently syncing) is deliberately not queued again —
/// Foodics can fire several events in quick succession for one bulk edit, and
/// one resulting sync already picks up everything, so piling up duplicates
/// would just be wasted work against the same table.
/// </summary>
public interface IFoodicsSyncQueue
{
    void Enqueue(int brandId);
    IAsyncEnumerable<int> ReadAllAsync(CancellationToken ct);
    void MarkDone(int brandId);
}

public class FoodicsSyncQueue : IFoodicsSyncQueue
{
    private readonly Channel<int> _channel = Channel.CreateUnbounded<int>();
    private readonly HashSet<int> _pending = new();
    private readonly object _lock = new();

    public void Enqueue(int brandId)
    {
        lock (_lock)
        {
            if (!_pending.Add(brandId)) return;
        }
        _channel.Writer.TryWrite(brandId);
    }

    public IAsyncEnumerable<int> ReadAllAsync(CancellationToken ct) => _channel.Reader.ReadAllAsync(ct);

    public void MarkDone(int brandId)
    {
        lock (_lock)
        {
            _pending.Remove(brandId);
        }
    }
}
