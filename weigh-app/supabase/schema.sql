-- =============================================================================
-- TARE Staff Weighing — Supabase schema
--
-- Run the whole file in the Supabase SQL editor. It is idempotent: running it
-- again (e.g. after pulling an update) changes nothing that already matches
-- and never duplicates seed rows.
--
-- Security model
--   * Every branch signs in with just its email (the weigh app's /api/login
--     issues the Supabase session server-side).
--   * A login is linked to a branch purely by that email (public.branches.email).
--   * Row-level security limits each branch to its own weigh entries; the
--     branch, the staff email, the business day and the size label are all
--     filled in server-side by a trigger — nothing the browser sends for those
--     is trusted.
--   * The portal reads and manages everything through the .NET API, which
--     talks to Supabase with the service-role key (never shipped to a browser).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Settings (exactly one row)
-- -----------------------------------------------------------------------------
create table if not exists public.app_settings (
  id                        boolean primary key default true check (id),
  target_samples            integer      not null default 200  check (target_samples between 1 and 100000),
  min_weight_g              numeric(8,1) not null default 1    check (min_weight_g > 0),
  max_weight_g              numeric(8,1) not null default 5000 check (max_weight_g <= 20000),
  -- Weighings before this local hour count toward the previous business day,
  -- so a 19:00–01:00 session stays one day.
  business_day_cutoff_hour  smallint     not null default 6    check (business_day_cutoff_hour between 0 and 23),
  timezone                  text         not null default 'Asia/Kuwait',
  -- How long staff can still correct or delete their own entries.
  edit_window_hours         integer      not null default 48   check (edit_window_hours between 0 and 720),
  -- Modifier option name (letters only, upper-case) -> canonical size label.
  size_aliases              jsonb        not null default
    '{"REGULAR":"REGULAR","MEDIUM":"MEDIUM","SUUUBER":"SUUUBER","SUUUBERT":"SUUUBER","SUUUBERTM":"SUUUBER"}'::jsonb
    check (jsonb_typeof(size_aliases) = 'object'),
  -- Order lines staff are NOT asked to weigh: whole Foodics categories…
  skip_categories           text[]       not null default
    array['Staff Meal','Beverages','Dine In Drinks','Merch','BBT X SAY SUCO MERCH'],
  -- …and near-free add-ons priced above 0 but at or below this (KD). Meal
  -- combos are priced 0 in Foodics (the price is on the size), so 0 is never skipped.
  skip_price_at_or_below    numeric(6,3) not null default 0.7 check (skip_price_at_or_below >= 0),
  updated_at                timestamptz  not null default now(),
  constraint app_settings_weight_range check (max_weight_g > min_weight_g)
);

insert into public.app_settings (id) values (true) on conflict (id) do nothing;

-- -----------------------------------------------------------------------------
-- 2. Branches (one row per branch login)
-- -----------------------------------------------------------------------------
create table if not exists public.branches (
  id                 uuid        primary key default gen_random_uuid(),
  brand_code         text        not null default 'BBT',
  code               text        not null,
  name               text        not null,
  email              text        not null,
  foodics_branch_id  text        not null,
  session_start      time,
  session_end        time,
  is_active          boolean     not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint branches_email_lowercase check (email = lower(btrim(email))),
  constraint branches_email_unique    unique (email),
  constraint branches_code_unique     unique (brand_code, code)
);

-- -----------------------------------------------------------------------------
-- 3. (Earlier versions had a public.app_admins table; the portal now uses the
--    service-role key via the API instead, so it's removed.)
-- -----------------------------------------------------------------------------
drop table if exists public.app_admins cascade;

-- -----------------------------------------------------------------------------
-- 4. Focus items — what staff should make a point of weighing
--    priority: higher = more urgent (seeded with the plan's estimated days).
--    branch_id null = applies to every branch.
--    product_id matches Foodics' product id; product_name is the fallback
--    match and the display label. size_label null = any size.
-- -----------------------------------------------------------------------------
create table if not exists public.focus_items (
  id            uuid        primary key default gen_random_uuid(),
  branch_id     uuid        references public.branches(id) on delete cascade,
  product_id    text,
  product_name  text        not null check (length(btrim(product_name)) > 0),
  size_label    text,
  priority      smallint    not null default 1 check (priority between 1 and 99),
  note          text        check (note is null or length(note) <= 300),
  is_active     boolean     not null default true,
  created_at    timestamptz not null default now()
);

create unique index if not exists focus_items_unique_idx
  on public.focus_items (
    coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid),
    lower(btrim(product_name)),
    coalesce(upper(size_label), '*')
  );

-- -----------------------------------------------------------------------------
-- 5. Weigh entries — one row per physical unit weighed
-- -----------------------------------------------------------------------------
create table if not exists public.weigh_entries (
  id                 uuid          primary key default gen_random_uuid(),
  branch_id          uuid          not null references public.branches(id),
  foodics_order_id   text          not null check (length(btrim(foodics_order_id)) > 0),
  order_number       integer,
  order_reference    text,
  check_number       integer,
  aggregator_name    text,
  aggregator_ref     text,
  order_type         smallint,
  order_status       smallint,
  order_opened_at    timestamptz,
  line_key           text          not null check (length(btrim(line_key)) > 0),
  unit_index         smallint      not null default 0 check (unit_index between 0 and 99),
  product_id         text          not null check (length(btrim(product_id)) > 0),
  product_name       text          not null check (length(btrim(product_name)) > 0),
  product_sku        text,
  product_category   text,
  unit_price         numeric(8,3),
  modifiers          jsonb         not null default '[]'::jsonb check (jsonb_typeof(modifiers) = 'array'),
  modifiers_label    text          not null default '',
  size_label         text,
  weight_g           numeric(8,1)  not null check (weight_g > 0 and weight_g <= 20000),
  note               text          check (note is null or length(note) <= 500),
  entered_by         uuid,
  entered_email      text,
  -- When the unit was actually weighed (the device's clock, clamped to the
  -- last 36 h so a wrong clock can't back- or future-date it). Differs from
  -- created_at only for entries that were queued offline and synced later.
  weighed_at         timestamptz   not null,
  business_date      date          not null,
  is_excluded        boolean       not null default false,
  exclude_reason     text          check (exclude_reason is null or length(exclude_reason) <= 300),
  client_created_at  timestamptz,
  created_at         timestamptz   not null default now(),
  updated_at         timestamptz   not null default now(),
  -- The same physical unit can only be weighed once; re-weighing updates it.
  constraint weigh_entries_unit_unique unique (foodics_order_id, line_key, unit_index)
);

create index if not exists weigh_entries_branch_day_idx on public.weigh_entries (branch_id, business_date);
create index if not exists weigh_entries_day_idx        on public.weigh_entries (business_date);
create index if not exists weigh_entries_product_idx    on public.weigh_entries (product_id, size_label);
create index if not exists weigh_entries_weighed_idx    on public.weigh_entries (weighed_at desc);

-- -----------------------------------------------------------------------------
-- 6. Helper functions (security definer: they read tables RLS would hide)
-- -----------------------------------------------------------------------------
create or replace function public.jwt_email()
returns text
language sql stable
set search_path = public
as $$
  select lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- "Admin" = the service-role key, used only server-side by the portal's API.
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(auth.jwt() ->> 'role', '') = 'service_role';
$$;

create or replace function public.current_branch_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select b.id from public.branches b
  where b.email = public.jwt_email() and b.is_active
  limit 1;
$$;

create or replace function public.edit_window_hours()
returns integer
language sql stable security definer
set search_path = public
as $$
  select coalesce((select s.edit_window_hours from public.app_settings s where s.id), 48);
$$;

-- The signed-in branch (empty for admins / unlinked logins).
create or replace function public.my_branch()
returns table (
  id uuid, brand_code text, code text, name text, email text,
  foodics_branch_id text, session_start time, session_end time
)
language sql stable security definer
set search_path = public
as $$
  select b.id, b.brand_code, b.code, b.name, b.email,
         b.foodics_branch_id, b.session_start, b.session_end
  from public.branches b
  where b.email = public.jwt_email() and b.is_active
  limit 1;
$$;

-- Company-wide sample count + typical weight per item/size, so staff can see
-- what's already at target and get warned about an implausible entry. Returns
-- nothing to a login that is neither a branch nor an admin.
create or replace function public.get_item_progress()
returns table (
  product_id text, product_name text, size_label text,
  samples bigint, median_g numeric, p10_g numeric, p90_g numeric
)
language sql stable security definer
set search_path = public
as $$
  select e.product_id,
         max(e.product_name),
         e.size_label,
         count(*),
         round((percentile_cont(0.5) within group (order by e.weight_g))::numeric, 1),
         round((percentile_cont(0.1) within group (order by e.weight_g))::numeric, 1),
         round((percentile_cont(0.9) within group (order by e.weight_g))::numeric, 1)
  from public.weigh_entries e
  where not e.is_excluded
    and (public.is_admin() or public.current_branch_id() is not null)
  group by e.product_id, e.size_label;
$$;

-- -----------------------------------------------------------------------------
-- 7. Triggers
-- -----------------------------------------------------------------------------
create or replace function public.weigh_entries_before_write()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  s        public.app_settings%rowtype;
  v_admin  boolean := public.is_admin();
  v_branch uuid;
begin
  select * into s from public.app_settings where id;
  if not found then
    raise exception 'App settings are missing — re-run the schema script.';
  end if;

  if tg_op = 'INSERT' then
    if v_admin then
      if new.branch_id is null then
        raise exception 'branch_id is required when an admin records an entry.' using errcode = '23502';
      end if;
    else
      v_branch := public.current_branch_id();
      if v_branch is null then
        raise exception 'This login is not linked to an active branch.' using errcode = '42501';
      end if;
      new.branch_id      := v_branch;
      new.is_excluded    := false;
      new.exclude_reason := null;
    end if;
    new.entered_by    := auth.uid();
    new.entered_email := nullif(public.jwt_email(), '');
    new.created_at    := now();
    new.weighed_at    := least(now(), greatest(coalesce(new.client_created_at, now()),
                                                now() - interval '36 hours'));
    new.business_date := ((new.weighed_at at time zone s.timezone)
                          - make_interval(hours => s.business_day_cutoff_hour))::date;
  else
    -- Only the weight and note can be corrected (plus exclusion, by admins);
    -- what was weighed, where and when never changes after it's recorded.
    new.id               := old.id;
    new.branch_id        := old.branch_id;
    new.foodics_order_id := old.foodics_order_id;
    new.order_number     := old.order_number;
    new.order_reference  := old.order_reference;
    new.check_number     := old.check_number;
    new.aggregator_name  := old.aggregator_name;
    new.aggregator_ref   := old.aggregator_ref;
    new.order_type       := old.order_type;
    new.order_status     := old.order_status;
    new.order_opened_at  := old.order_opened_at;
    new.line_key         := old.line_key;
    new.unit_index       := old.unit_index;
    new.product_id       := old.product_id;
    new.product_name     := old.product_name;
    new.product_sku      := old.product_sku;
    new.product_category := old.product_category;
    new.unit_price       := old.unit_price;
    new.modifiers        := old.modifiers;
    new.entered_by       := old.entered_by;
    new.entered_email    := old.entered_email;
    new.created_at       := old.created_at;
    new.client_created_at := old.client_created_at;
    new.weighed_at       := old.weighed_at;
    new.business_date    := old.business_date;
    if not v_admin then
      new.is_excluded    := old.is_excluded;
      new.exclude_reason := old.exclude_reason;
    end if;
  end if;

  if new.weight_g < s.min_weight_g or new.weight_g > s.max_weight_g then
    raise exception 'Weight must be between % g and % g.', s.min_weight_g, s.max_weight_g
      using errcode = '22003';
  end if;

  new.product_name := btrim(new.product_name);

  -- Keep only {id, name} modifier objects that actually have a name, sorted.
  select coalesce(
           jsonb_agg(jsonb_build_object('id', m ->> 'id', 'name', btrim(m ->> 'name'))
                     order by lower(btrim(m ->> 'name'))),
           '[]'::jsonb)
    into new.modifiers
  from jsonb_array_elements(coalesce(new.modifiers, '[]'::jsonb)) m
  where jsonb_typeof(m) = 'object'
    and nullif(btrim(m ->> 'name'), '') is not null;

  select coalesce(string_agg(x ->> 'name', ', ' order by lower(x ->> 'name')), '')
    into new.modifiers_label
  from jsonb_array_elements(new.modifiers) x;

  select s.size_aliases ->> upper(regexp_replace(x ->> 'name', '[^A-Za-z]', '', 'g'))
    into new.size_label
  from jsonb_array_elements(new.modifiers) x
  where s.size_aliases ? upper(regexp_replace(x ->> 'name', '[^A-Za-z]', '', 'g'))
  limit 1;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists weigh_entries_before_write on public.weigh_entries;
create trigger weigh_entries_before_write
  before insert or update on public.weigh_entries
  for each row execute function public.weigh_entries_before_write();

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.app_settings_validate()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  perform now() at time zone new.timezone;  -- raises on an unknown timezone
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists app_settings_validate on public.app_settings;
create trigger app_settings_validate
  before insert or update on public.app_settings
  for each row execute function public.app_settings_validate();

drop trigger if exists branches_touch on public.branches;
create trigger branches_touch
  before update on public.branches
  for each row execute function public.touch_updated_at();

create or replace function public.normalise_email()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.email := lower(btrim(new.email));
  return new;
end;
$$;

drop trigger if exists branches_normalise_email on public.branches;
create trigger branches_normalise_email
  before insert or update on public.branches
  for each row execute function public.normalise_email();

create or replace function public.focus_items_normalise()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.product_name := btrim(new.product_name);
  new.size_label   := nullif(upper(btrim(new.size_label)), '');
  new.product_id   := nullif(btrim(new.product_id), '');
  return new;
end;
$$;

drop trigger if exists focus_items_normalise on public.focus_items;
create trigger focus_items_normalise
  before insert or update on public.focus_items
  for each row execute function public.focus_items_normalise();

-- -----------------------------------------------------------------------------
-- 8. Row-level security
-- -----------------------------------------------------------------------------
alter table public.app_settings  enable row level security;
alter table public.branches      enable row level security;
alter table public.focus_items   enable row level security;
alter table public.weigh_entries enable row level security;

-- app_settings: every signed-in user reads; admins change.
drop policy if exists app_settings_select on public.app_settings;
create policy app_settings_select on public.app_settings
  for select to authenticated using (true);
drop policy if exists app_settings_update on public.app_settings;
create policy app_settings_update on public.app_settings
  for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- branches: a branch sees its own row; admins see and manage all.
drop policy if exists branches_select on public.branches;
create policy branches_select on public.branches
  for select to authenticated
  using ((select public.is_admin()) or email = (select public.jwt_email()));
drop policy if exists branches_admin_insert on public.branches;
create policy branches_admin_insert on public.branches
  for insert to authenticated with check ((select public.is_admin()));
drop policy if exists branches_admin_update on public.branches;
create policy branches_admin_update on public.branches
  for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
drop policy if exists branches_admin_delete on public.branches;
create policy branches_admin_delete on public.branches
  for delete to authenticated using ((select public.is_admin()));

-- focus_items: a branch sees global + its own; admins manage.
drop policy if exists focus_items_select on public.focus_items;
create policy focus_items_select on public.focus_items
  for select to authenticated
  using ((select public.is_admin())
         or branch_id is null
         or branch_id = (select public.current_branch_id()));
drop policy if exists focus_items_insert on public.focus_items;
create policy focus_items_insert on public.focus_items
  for insert to authenticated with check ((select public.is_admin()));
drop policy if exists focus_items_update on public.focus_items;
create policy focus_items_update on public.focus_items
  for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
drop policy if exists focus_items_delete on public.focus_items;
create policy focus_items_delete on public.focus_items
  for delete to authenticated using ((select public.is_admin()));

-- weigh_entries: a branch reads/writes only its own rows and can correct them
-- within the edit window; admins read/manage everything.
drop policy if exists weigh_entries_select on public.weigh_entries;
create policy weigh_entries_select on public.weigh_entries
  for select to authenticated
  using ((select public.is_admin()) or branch_id = (select public.current_branch_id()));
drop policy if exists weigh_entries_insert on public.weigh_entries;
create policy weigh_entries_insert on public.weigh_entries
  for insert to authenticated
  with check ((select public.is_admin()) or branch_id = (select public.current_branch_id()));
drop policy if exists weigh_entries_update on public.weigh_entries;
create policy weigh_entries_update on public.weigh_entries
  for update to authenticated
  using ((select public.is_admin())
         or (branch_id = (select public.current_branch_id())
             and created_at > now() - make_interval(hours => (select public.edit_window_hours()))))
  with check ((select public.is_admin()) or branch_id = (select public.current_branch_id()));
drop policy if exists weigh_entries_delete on public.weigh_entries;
create policy weigh_entries_delete on public.weigh_entries
  for delete to authenticated
  using ((select public.is_admin())
         or (branch_id = (select public.current_branch_id())
             and created_at > now() - make_interval(hours => (select public.edit_window_hours()))));

-- -----------------------------------------------------------------------------
-- 9. Reporting views (RLS applies: admins see all, a branch sees itself)
-- -----------------------------------------------------------------------------
create or replace view public.v_branch_daily with (security_invoker = true) as
select b.code                        as branch_code,
       b.name                        as branch_name,
       e.business_date,
       count(*)                      as units_weighed,
       count(distinct e.product_id)  as distinct_items,
       count(distinct e.foodics_order_id) as orders_touched,
       min(e.weighed_at)             as first_weighed_at,
       max(e.weighed_at)             as last_weighed_at
from public.weigh_entries e
join public.branches b on b.id = e.branch_id
where not e.is_excluded
group by b.code, b.name, e.business_date;

create or replace view public.v_item_stats with (security_invoker = true) as
select e.product_id,
       max(e.product_name)                                              as product_name,
       e.size_label,
       count(*)                                                         as samples,
       min(e.weight_g)                                                  as min_g,
       max(e.weight_g)                                                  as max_g,
       round(avg(e.weight_g), 1)                                        as mean_g,
       round((percentile_cont(0.5) within group (order by e.weight_g))::numeric, 1) as median_g,
       round(coalesce(stddev_samp(e.weight_g), 0), 1)                   as stddev_g,
       round((percentile_cont(0.1) within group (order by e.weight_g))::numeric, 1) as p10_g,
       round((percentile_cont(0.9) within group (order by e.weight_g))::numeric, 1) as p90_g,
       count(distinct e.branch_id)                                      as branches,
       max(e.weighed_at)                                                as last_weighed_at
from public.weigh_entries e
where not e.is_excluded
group by e.product_id, e.size_label;

create or replace view public.v_item_modifier_stats with (security_invoker = true) as
select e.product_id,
       max(e.product_name)                                              as product_name,
       e.modifiers_label,
       count(*)                                                         as samples,
       min(e.weight_g)                                                  as min_g,
       max(e.weight_g)                                                  as max_g,
       round(avg(e.weight_g), 1)                                        as mean_g,
       round((percentile_cont(0.5) within group (order by e.weight_g))::numeric, 1) as median_g,
       round(coalesce(stddev_samp(e.weight_g), 0), 1)                   as stddev_g
from public.weigh_entries e
where not e.is_excluded
group by e.product_id, e.modifiers_label;

-- -----------------------------------------------------------------------------
-- 10. Privileges (RLS does the row filtering; anon gets nothing)
-- -----------------------------------------------------------------------------
revoke all on public.app_settings, public.branches,
              public.focus_items, public.weigh_entries,
              public.v_branch_daily, public.v_item_stats, public.v_item_modifier_stats
  from anon;

grant select, update                 on public.app_settings  to authenticated;
grant select, insert, update, delete on public.branches      to authenticated;
grant select, insert, update, delete on public.focus_items   to authenticated;
grant select, insert, update, delete on public.weigh_entries to authenticated;
grant select on public.v_branch_daily, public.v_item_stats, public.v_item_modifier_stats to authenticated;

revoke execute on function public.jwt_email(), public.is_admin(), public.current_branch_id(),
                           public.edit_window_hours(), public.my_branch(), public.get_item_progress()
  from public, anon;
grant execute on function public.jwt_email(), public.is_admin(), public.current_branch_id(),
                          public.edit_window_hours(), public.my_branch(), public.get_item_progress()
  to authenticated;

-- -----------------------------------------------------------------------------
-- 11. Seed data
-- -----------------------------------------------------------------------------
-- Branch logins. Session windows come from the 14-day weighing plan; BYN gets
-- 45 extra minutes because its evening volume exceeds one scale's capacity.
insert into public.branches (code, name, email, foodics_branch_id, session_start, session_end) values
  ('KWT', 'Hilltop',          'bbthilltop@swishhh.net',       'a0005bb5-c1da-4d21-b8e7-225be5ef6d71', '18:00', '00:00'),
  ('KHR', 'Khairan',          'bbt-khairan@swishhh.net',      'a17045e6-8c3e-4599-bf6a-6c25a6d1445a', '18:00', '00:00'),
  ('SAD', 'Saad Al Abdullah', 'bbt-saadabdullah@swishhh.net', 'a1806d85-fcf3-4667-b05e-39a515355de8', '19:00', '01:00'),
  ('YRD', 'Yard',             'bbtyard@swishhh.net',          'a0005bb5-bd17-4604-86e0-74a61ee3f716', '18:00', '00:00'),
  ('MNF', 'Mangaf',           'bbt-mangaf@swishhh.net',       'a088d573-d5ac-4772-8d0e-3c9a4495a7e9', '19:00', '01:00'),
  ('BYN', 'Bayan',            'bbtbayan@swishhh.net',         'a086eb73-5dab-4c12-b1c4-b54fef6f6514', '18:00', '00:45'),
  ('ADL', 'Adaliya',          'bbt-adaliya@swishhh.net',      'a0005bb5-d24a-43cf-9807-8c51a18c9331', '18:00', '00:00'),
  ('SMY', 'Shamiya Park',     'bbtshamiya@swishhh.net',       'a0005bb5-d5a5-4629-9441-4e37ce726dd9', '18:00', '00:00'),
  ('SBA', 'Sabah Al Ahmad',   'bbt-sba@swishhh.net',          'a0a72430-959f-473e-8fc5-dbc2e1821de9', '19:00', '01:00'),
  ('ARD', 'Ardiya',           'bbt-ardiya@swishhh.net',       'a0005bb5-b7b0-4605-b590-f739968de578', '19:00', '01:00'),
  ('SHD', 'Shuhada',          'bbt-shuhada@swishhh.net',      'a0005bb5-dec6-4458-bd72-a02b1d853d23', '18:00', '00:00'),
  ('OMH', 'Um Al Haiman',     'bbt-umh@swishhh.net',          'a16e6544-6b8a-4003-9a3d-ec8d24780107', '19:00', '01:00')
on conflict (email) do update
  set code              = excluded.code,
      name              = excluded.name,
      foodics_branch_id = excluded.foodics_branch_id;
-- (Session windows are only set on first insert, so edits made later in the
--  portal aren't overwritten by re-running this script.)

-- Focus items from the 14-day plan: every item estimated to take 4+ days to
-- reach the target, for all branches. priority = estimated days.
insert into public.focus_items (branch_id, product_id, product_name, size_label, priority) values
  (null, 'a0128dc2-2225-41bf-9bcd-16f2d6f0a8ff', 'Southwest Meal',                  'MEDIUM',  14),
  (null, 'a0128dc0-a923-4331-b038-c23092aa761b', 'Chicken Nugget Meal',             'MEDIUM',  13),
  (null, 'a0128dc1-8cd9-4d74-baca-65bf29626f75', 'Little Wrap Fillaaa Meal',        'SUUUBER', 11),
  (null, 'a0128dc2-2225-41bf-9bcd-16f2d6f0a8ff', 'Southwest Meal',                  'SUUUBER', 10),
  (null, 'a0128dc0-e8ca-4e7d-95dd-15db28a12650', 'Classic Old Skool Meal',          'SUUUBER', 10),
  (null, 'a020a831-5cbc-477c-af89-376c5e08d7b6', 'Smokey Rolls Beef Meal',          'REGULAR', 10),
  (null, 'a020a048-78a3-4c6e-a4ff-40b68f471d81', 'Classic Rolls Beef Meal',         'REGULAR',  9),
  (null, 'a0128dc0-d0d2-455c-8fbb-5df673e5f6a8', 'Chilli Lime Supreme Meal',        'REGULAR',  9),
  (null, 'a0128dc0-e8ca-4e7d-95dd-15db28a12650', 'Classic Old Skool Meal',          'MEDIUM',   9),
  (null, 'a0128dc0-a923-4331-b038-c23092aa761b', 'Chicken Nugget Meal',             'REGULAR',  8),
  (null, 'a0128dc0-a068-46d1-8c74-a5fd74b9b430', 'Chicken Fillaaa Meal',            'SUUUBER',  8),
  (null, 'a0128dc2-78eb-497e-8968-eaeff5b681ba', 'XL Fillaaa Sauce',                null,       7),
  (null, 'a0128dc1-fa5f-4d5c-ada3-e19b4341f81e', 'Quarter Pounder Meal',            'SUUUBER',  7),
  (null, 'a0128dc1-fa5f-4d5c-ada3-e19b4341f81e', 'Quarter Pounder Meal',            'MEDIUM',   6),
  (null, 'a0128dc1-8cd9-4d74-baca-65bf29626f75', 'Little Wrap Fillaaa Meal',        'MEDIUM',   6),
  (null, 'a1b70f81-15ea-4cfc-8a3b-ec85befa938a', 'Corn Dynamite Stick',             null,       5),
  (null, 'a0128dc2-2225-41bf-9bcd-16f2d6f0a8ff', 'Southwest Meal',                  'REGULAR',  5),
  (null, 'a0f3d82e-5665-49ca-b180-2e8e51ac2937', 'SUUUBERT BEEF COMBO',             'SUUUBER',  5),
  (null, 'a0f3d82e-5665-49ca-b180-2e8e51ac2937', 'SUUUBERT BEEF COMBO',             'MEDIUM',   5),
  (null, 'a0128dc0-f892-4da9-8cc9-d0e05ee248ae', 'Classic Supreme Meal',            'REGULAR',  5),
  (null, 'a0128dc0-a068-46d1-8c74-a5fd74b9b430', 'Chicken Fillaaa Meal',            'MEDIUM',   5),
  (null, 'a108bf8e-2e20-483a-84f7-608b151a1e86', 'SUUUBERT Chicken Deal',           null,       4),
  (null, 'a23521b0-add9-4cb5-9a82-475ead65638f', 'Little Cheeseburger Duo',         null,       4),
  (null, 'a0f3d116-fa93-4829-909b-dfd819b2c982', 'SUUUBERT CHICKEN COMBO',          'REGULAR',  4),
  (null, 'a020a107-8f93-4b9a-a34e-bed74394c1c0', 'Smokey Rolls Beef',               null,       4),
  (null, 'a23521b0-b4d2-4a34-80a7-da8afb0c4bf3', 'Little Mix Duo',                  null,       4),
  (null, 'a02c508b-1a7c-41c5-8d0f-95f76df259b5', 'Salt n'' Vinegar Tenders Fillaaa', null,      4),
  (null, 'a23521b0-9b70-4d81-b319-ee22a705ab0a', 'Little Chicken Burger Duo',       null,       4),
  (null, 'a0128dc0-c807-4dd5-ace8-ca67883d1839', 'Chilli Lime Supreme',             null,       4),
  (null, 'a2c095c1-0489-4cff-9eab-5191bffd3220', 'Filla & Toast Combo',             null,       4)
on conflict do nothing;

-- =============================================================================
-- Handy queries (run individually in the SQL editor)
-- =============================================================================
-- Units weighed per branch per business day:
--   select * from public.v_branch_daily order by business_date desc, units_weighed desc;
-- Item stats (size-aware), slowest first:
--   select * from public.v_item_stats order by samples asc;
-- Item stats by full modifier combination:
--   select * from public.v_item_modifier_stats order by product_name, samples desc;
-- Progress toward the target per item/size:
--   select product_name, size_label, samples,
--          (select target_samples from public.app_settings) as target,
--          round(100.0 * samples / (select target_samples from public.app_settings), 1) as pct
--   from public.v_item_stats order by pct asc;
-- Exclude an obviously wrong entry from all stats:
--   update public.weigh_entries set is_excluded = true, exclude_reason = 'typo' where id = '...';
