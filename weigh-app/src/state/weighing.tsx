import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { describeError, isTransient, supabase } from "../lib/supabase";
import { loadOutbox, saveOutbox, type OutboxItem } from "../lib/outbox";
import { unitKey } from "../lib/rules";
import { businessDate } from "../lib/format";
import type { ApiOrder, EntryInsert, ErrorResponse, OrdersResponse, Unit, WeighedState } from "../lib/types";
import { useSession } from "./session";
import { useToast } from "./toast";

const POLL_MS = 20_000;
const FLUSH_MS = 15_000;
const FETCH_TIMEOUT_MS = 20_000;

export interface OrdersState {
  orders: ApiOrder[] | null;
  error: string | null;
  fetchedAt: string | null;
  refreshing: boolean;
}

interface WeighingValue {
  orders: OrdersState;
  refresh: () => void;
  weighed: Map<string, WeighedState>;
  pendingCount: number;
  online: boolean;
  storageWarning: boolean;
  todayCount: number | null;
  save: (unit: Unit, weight: number) => void;
  remove: (unit: Unit) => Promise<boolean>;
}

const Ctx = createContext<WeighingValue | null>(null);

export function useWeighing(): WeighingValue {
  const v = useContext(Ctx);
  if (!v) throw new Error("useWeighing must be used inside <WeighingProvider>");
  return v;
}

function uuid(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
  });
}

async function accessToken(): Promise<string | null> {
  const { data } = await supabase.auth.getSession();
  return data.session?.access_token ?? null;
}

export function WeighingProvider({ children }: { children: ReactNode }) {
  const { branch, settings, bumpProgress, signOut } = useSession();
  const toast = useToast();
  const branchId = branch?.id ?? "";

  const [orders, setOrders] = useState<OrdersState>({ orders: null, error: null, fetchedAt: null, refreshing: false });
  const [dbWeighed, setDbWeighed] = useState<Map<string, WeighedState>>(new Map());
  const [outbox, setOutbox] = useState<OutboxItem[]>(() => (branchId ? loadOutbox(branchId) : []));
  const [online, setOnline] = useState(() => (typeof navigator === "undefined" ? true : navigator.onLine));
  const [storageWarning, setStorageWarning] = useState(false);
  const [todayCount, setTodayCount] = useState<number | null>(null);

  const outboxRef = useRef(outbox);
  const flushingRef = useRef(false);
  const fetchingRef = useRef(false);
  const orderIdsRef = useRef<string[]>([]);

  const commitOutbox = useCallback(
    (items: OutboxItem[]) => {
      outboxRef.current = items;
      setOutbox(items);
      if (branchId) setStorageWarning(!saveOutbox(branchId, items));
    },
    [branchId],
  );

  // Reload the persisted queue when the branch changes (another login on this device).
  useEffect(() => {
    const items = branchId ? loadOutbox(branchId) : [];
    outboxRef.current = items;
    setOutbox(items);
  }, [branchId]);

  const today = businessDate(settings.timezone, settings.business_day_cutoff_hour);

  const loadTodayCount = useCallback(async () => {
    if (!branchId) return;
    const { count, error } = await supabase
      .from("weigh_entries")
      .select("id", { count: "exact", head: true })
      .eq("business_date", today);
    if (!error && typeof count === "number") setTodayCount(count);
  }, [branchId, today]);

  const loadWeighed = useCallback(async (ids: string[]) => {
    if (!ids.length) {
      setDbWeighed(new Map());
      return;
    }
    const { data, error } = await supabase
      .from("weigh_entries")
      .select("id, foodics_order_id, line_key, unit_index, weight_g")
      .in("foodics_order_id", ids);
    if (error) return; // keep what we had; next poll retries
    const map = new Map<string, WeighedState>();
    for (const r of data ?? []) {
      map.set(unitKey(r.foodics_order_id, r.line_key, r.unit_index), {
        entryId: r.id,
        weight: Number(r.weight_g),
        status: "synced",
      });
    }
    setDbWeighed(map);
  }, []);

  const fetchOrders = useCallback(
    async (allowRefreshRetry = true): Promise<void> => {
      if (!branchId || fetchingRef.current) return;
      fetchingRef.current = true;
      setOrders((s) => ({ ...s, refreshing: true }));
      const ctrl = new AbortController();
      const timer = window.setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
      try {
        const token = await accessToken();
        if (!token) {
          await signOut("Please sign in again.");
          return;
        }
        const res = await fetch("/api/orders", {
          headers: { Authorization: `Bearer ${token}` },
          cache: "no-store",
          signal: ctrl.signal,
        });
        const body = (await res.json().catch(() => null)) as OrdersResponse | ErrorResponse | null;
        if (res.status === 401) {
          if (allowRefreshRetry) {
            const { error } = await supabase.auth.refreshSession();
            fetchingRef.current = false;
            if (!error) return fetchOrders(false);
          }
          await signOut("Your session expired. Please sign in again.");
          return;
        }
        if (!res.ok || !body || !("orders" in body)) {
          const message =
            body && "error" in body ? body.error : `Couldn't load orders (HTTP ${res.status}). Retrying shortly.`;
          setOrders((s) => ({ ...s, error: message, refreshing: false }));
          return;
        }
        orderIdsRef.current = body.orders.map((o) => o.id);
        setOrders({ orders: body.orders, error: null, fetchedAt: body.fetchedAt, refreshing: false });
        await Promise.all([loadWeighed(orderIdsRef.current), loadTodayCount()]);
      } catch (e) {
        const message =
          (e as Error)?.name === "AbortError"
            ? "Loading orders is taking too long. Retrying shortly."
            : describeError(e, "Couldn't load orders. Retrying shortly.");
        setOrders((s) => ({ ...s, error: message, refreshing: false }));
      } finally {
        window.clearTimeout(timer);
        fetchingRef.current = false;
        setOrders((s) => (s.refreshing ? { ...s, refreshing: false } : s));
      }
    },
    [branchId, loadWeighed, loadTodayCount, signOut],
  );

  const flush = useCallback(async () => {
    if (flushingRef.current || !outboxRef.current.length) return;
    flushingRef.current = true;
    try {
      const queued = outboxRef.current;
      let items = [...queued];
      for (const item of queued) {
        const { data, error } = await supabase
          .from("weigh_entries")
          .upsert(item.row, { onConflict: "foodics_order_id,line_key,unit_index" })
          .select("id, weight_g")
          .single();
        if (!error && data) {
          items = items.filter((x) => x.unitKey !== item.unitKey || x.row.id !== item.row.id);
          setDbWeighed((prev) => {
            const next = new Map(prev);
            next.set(item.unitKey, { entryId: data.id, weight: Number(data.weight_g), status: "synced" });
            return next;
          });
          continue;
        }
        if (isTransient(error)) {
          if (/jwt|PGRST30/i.test(`${error?.code} ${error?.message}`)) await supabase.auth.refreshSession();
          items = items.map((x) =>
            x.unitKey === item.unitKey ? { ...x, attempts: x.attempts + 1, lastError: error?.message } : x,
          );
          break; // offline or server down: try the rest later, in order
        }
        // Permanent: the server will never accept this row as-is.
        items = items.filter((x) => x.unitKey !== item.unitKey);
        if (item.isNew) {
          bumpProgress(item.row.product_id, item.sizeLabel, -1);
          setTodayCount((c) => (c === null ? c : Math.max(0, c - 1)));
        }
        toast(`Couldn't save ${item.row.product_name}: ${describeError(error)}`, "bad");
      }
      commitOutbox(items);
    } finally {
      flushingRef.current = false;
    }
  }, [bumpProgress, commitOutbox, toast]);

  // Polling while the screen is visible; immediate refresh when it comes back.
  useEffect(() => {
    if (!branchId) return;
    void fetchOrders();
    void flush();
    const poll = window.setInterval(() => {
      if (document.visibilityState === "visible") void fetchOrders();
    }, POLL_MS);
    const flusher = window.setInterval(() => void flush(), FLUSH_MS);
    const onVisible = () => {
      if (document.visibilityState === "visible") {
        void fetchOrders();
        void flush();
      }
    };
    const onOnline = () => {
      setOnline(true);
      void flush();
      void fetchOrders();
    };
    const onOffline = () => setOnline(false);
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("online", onOnline);
    window.addEventListener("offline", onOffline);
    return () => {
      window.clearInterval(poll);
      window.clearInterval(flusher);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("online", onOnline);
      window.removeEventListener("offline", onOffline);
    };
  }, [branchId, fetchOrders, flush]);

  const weighed = useMemo(() => {
    const map = new Map(dbWeighed);
    for (const item of outbox) {
      map.set(item.unitKey, {
        entryId: map.get(item.unitKey)?.entryId ?? item.row.id,
        weight: item.row.weight_g,
        status: "pending",
      });
    }
    return map;
  }, [dbWeighed, outbox]);

  const save = useCallback(
    (unit: Unit, weight: number) => {
      const o = unit.order;
      const isNew = !weighed.has(unit.key);
      const row: EntryInsert = {
        id: uuid(),
        foodics_order_id: o.id,
        order_number: o.number,
        order_reference: o.reference,
        check_number: o.checkNumber,
        aggregator_name: o.aggregatorName,
        aggregator_ref: o.aggregatorRef,
        order_type: o.type,
        order_status: o.status,
        order_opened_at: o.openedAt,
        line_key: unit.line.key,
        unit_index: unit.unitIndex,
        product_id: unit.line.productId,
        product_name: unit.line.productName,
        product_sku: unit.line.sku,
        product_category: unit.line.category,
        unit_price: unit.line.price,
        modifiers: unit.line.modifiers,
        weight_g: weight,
        note: null,
        client_created_at: new Date().toISOString(),
      };
      const replaced = outboxRef.current.find((x) => x.unitKey === unit.key);
      const items = outboxRef.current.filter((x) => x.unitKey !== unit.key);
      items.push({
        unitKey: unit.key,
        row,
        sizeLabel: unit.sizeLabel,
        // A correction queued on top of a not-yet-synced first weighing is still that first weighing.
        isNew: isNew || !!replaced?.isNew,
        attempts: 0,
        queuedAt: Date.now(),
      });
      commitOutbox(items);
      if (isNew) {
        bumpProgress(unit.line.productId, unit.sizeLabel, 1);
        setTodayCount((c) => (c === null ? c : c + 1));
      }
      void flush();
    },
    [weighed, commitOutbox, bumpProgress, flush],
  );

  const remove = useCallback(
    async (unit: Unit): Promise<boolean> => {
      const key = unit.key;
      const pending = outboxRef.current.find((x) => x.unitKey === key);
      const synced = dbWeighed.get(key);
      const rollBackCounters = () => {
        bumpProgress(unit.line.productId, unit.sizeLabel, -1);
        setTodayCount((c) => (c === null ? c : Math.max(0, c - 1)));
      };
      if (pending && !synced) {
        commitOutbox(outboxRef.current.filter((x) => x.unitKey !== key));
        rollBackCounters();
        return true;
      }
      if (!synced) return true;
      const { data, error } = await supabase.from("weigh_entries").delete().eq("id", synced.entryId).select("id");
      if (error) {
        toast(`Couldn't undo: ${describeError(error)}`, "bad");
        return false;
      }
      if (!data?.length) {
        toast("This entry is too old to change here. Ask the admin to remove it.", "bad");
        return false;
      }
      if (pending) commitOutbox(outboxRef.current.filter((x) => x.unitKey !== key));
      setDbWeighed((prev) => {
        const next = new Map(prev);
        next.delete(key);
        return next;
      });
      rollBackCounters();
      return true;
    },
    [dbWeighed, commitOutbox, bumpProgress, toast],
  );

  const value = useMemo<WeighingValue>(
    () => ({
      orders,
      refresh: () => void fetchOrders(),
      weighed,
      pendingCount: outbox.length,
      online,
      storageWarning,
      todayCount,
      save,
      remove,
    }),
    [orders, fetchOrders, weighed, outbox.length, online, storageWarning, todayCount, save, remove],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
