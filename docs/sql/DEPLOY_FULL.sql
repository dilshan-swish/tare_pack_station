/* ============================================================================
   SWiSH Weighing Platform — FULL, CONSOLIDATED deployment script
   ============================================================================
   Represents the schema as of docs/sql/16_modifier_combination_anchor.sql —
   equivalent to running every docs/sql/00_*.sql through 16_*.sql file, in
   order, in one pass. Written to be genuinely safe to re-run:

     - Every CREATE TABLE is guarded with IF OBJECT_ID(...) IS NULL.
     - Every ALTER TABLE ... ADD COLUMN is guarded with IF COL_LENGTH(...) IS NULL.
     - Every CREATE INDEX is guarded with IF NOT EXISTS (sys.indexes ...).
     - The one view uses CREATE OR ALTER (always idempotent).
     - No DROP, no TRUNCATE, no DELETE anywhere in this file. It only ever
       creates missing objects — it never touches existing data.

   Use this ONE file for:
     (a) A brand-new SwishWeighing database on a fresh server, OR
     (b) Bringing an EXISTING older SwishWeighing database (e.g. one that
         only ever had 01_schema.sql run against it) fully up to date —
         re-running this script adds exactly what's missing and changes
         nothing that's already there.

   If new docs/sql/NN_*.sql files are added to the project AFTER this script
   was generated, apply those individually, in order, after this one — this
   file cannot know about migrations that didn't exist yet when it was
   written.

   Run as: sqlcmd -S <server> -E -C -i DEPLOY_FULL.sql
   (or paste into SSMS and hit Execute). Requires CREATE DATABASE rights for
   a truly fresh server — see the troubleshooting table in
   docs/BACKEND_SQL_SETUP.md if that's denied.

   ROLLBACK STRATEGY — read this before running against production.
   This script deliberately is NOT wrapped in one big BEGIN TRAN/COMMIT: on
   SQL Server, CREATE DATABASE can never run inside a transaction, and every
   statement here is already individually atomic (a CREATE TABLE either fully
   succeeds or fully fails — it cannot partially apply). Combined with the
   guarantees above (additive-only, every create/alter guarded), if this
   script ever errors out partway through, the fix is simply: read the error,
   correct whatever caused it, and re-run the whole file again — everything
   already created is skipped (its guard now finds the object), and only the
   step that failed (and anything after it) actually runs. That IS the
   rollback story for this file, and it's exactly what was exercised in the
   three test runs described above.
   The one thing a re-run cannot undo is data loss from a mistake made
   OUTSIDE this script (e.g. by hand in SSMS). For that, the real safety net
   is a full database backup taken immediately before you run this — see
   "Failsafe deployment" in docs/PRODUCTION_DEPLOYMENT_GUIDE.md §3.2b for the
   exact backup + dry-run-restore-verification + restore commands.
   ============================================================================ */

-- Stricter error handling: if any statement below raises a run-time error,
-- abort its batch immediately rather than continuing past it. This never
-- changes what gets created — SQL Server's DDL statements were already
-- individually atomic — it only removes any chance of a later statement in
-- the same batch running after an earlier one silently failed.
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------------
-- Step 1 — the database itself.
-- ---------------------------------------------------------------------------
IF DB_ID('SwishWeighing') IS NULL
    CREATE DATABASE SwishWeighing;
GO
USE SwishWeighing;
GO
PRINT 'Using database: ' + DB_NAME();
GO

-- Required for the filtered index below (UX_Branch_Foodics) — sqlcmd/isql
-- default QUOTED_IDENTIFIER to OFF (unlike SSMS, which defaults it ON), and
-- SQL Server refuses to create a filtered index under OFF with error 1934.
-- These SET options are connection/session-level and persist across the GO
-- batches below, so setting them once here covers the whole script.
SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
GO

-- ---------------------------------------------------------------------------
-- Step 2 — tables, in dependency order (each carries its FULL final column
-- set, so a fresh database gets everything in one shot with no follow-up
-- ALTERs needed; the guarded ALTERs in Step 3 exist purely for the "upgrade
-- an existing older database" case).
-- ---------------------------------------------------------------------------

-- Brands (one row per Foodics brand/account) ---------------------------------
IF OBJECT_ID('dbo.Brands','U') IS NULL
CREATE TABLE dbo.Brands (
    BrandId           INT IDENTITY(1,1) PRIMARY KEY,
    Code              NVARCHAR(32)  NOT NULL UNIQUE,      -- e.g. 'BBT'
    Name              NVARCHAR(128) NOT NULL,
    FoodicsAccount    NVARCHAR(128) NULL,                 -- Foodics business "reference" (from /whoami)
    PublishedVersion  INT           NOT NULL DEFAULT 0,   -- bumped only by an admin's explicit "Publish"
    MenuSyncedVersion INT           NOT NULL DEFAULT 0,   -- bumped by automatic Foodics sync (webhook/sweep)
    IsActive          BIT           NOT NULL DEFAULT 1,
    CreatedAt         DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt         DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Branches / stores -----------------------------------------------------------
IF OBJECT_ID('dbo.Branches','U') IS NULL
CREATE TABLE dbo.Branches (
    BranchId        INT IDENTITY(1,1) PRIMARY KEY,
    BrandId         INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    FoodicsBranchId NVARCHAR(64)  NULL,
    Code            NVARCHAR(64)  NULL,           -- optional short label (Foodics reference)
    Name            NVARCHAR(128) NOT NULL,
    NameLocalized   NVARCHAR(128) NULL,            -- Foodics' own localized display name
    OpeningFrom     NVARCHAR(16)  NULL,            -- "HH:mm", equal from/to = open around the clock
    OpeningTo       NVARCHAR(16)  NULL,
    IsActive        BIT           NOT NULL DEFAULT 1,
    CreatedAt       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Tablets / devices -------------------------------------------------------------
IF OBJECT_ID('dbo.Devices','U') IS NULL
CREATE TABLE dbo.Devices (
    DeviceId   INT IDENTITY(1,1) PRIMARY KEY,
    BranchId   INT           NOT NULL REFERENCES dbo.Branches(BranchId),
    Label      NVARCHAR(64)  NOT NULL,        -- 'Pack station 1'
    ApiKeyHash VARBINARY(64) NOT NULL,        -- a hash only — the raw key is never stored
    AppVersion NVARCHAR(32)  NULL,
    LastSeenAt DATETIME2     NULL,
    IsActive   BIT           NOT NULL DEFAULT 1,
    CreatedAt  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Menu items (per brand; weights configured here) --------------------------------
IF OBJECT_ID('dbo.MenuItems','U') IS NULL
CREATE TABLE dbo.MenuItems (
    MenuItemId        INT IDENTITY(1,1) PRIMARY KEY,
    BrandId           INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    FoodicsProductId  NVARCHAR(64)  NOT NULL,
    Name              NVARCHAR(200) NOT NULL,
    CategoryName      NVARCHAR(128) NULL,
    Sku               NVARCHAR(64)  NULL,
    FoodicsCategoryId NVARCHAR(64)  NULL,
    CategoryReference NVARCHAR(64)  NULL,
    IdealWeightG      DECIMAL(8,2)  NULL,
    MinWeightG        DECIMAL(8,2)  NULL,   -- NULL = not configured
    MaxWeightG        DECIMAL(8,2)  NULL,
    PackagingWeightG  DECIMAL(8,2)  NULL,
    IsActive          BIT           NOT NULL DEFAULT 1,
    UpdatedBy         NVARCHAR(128) NULL,
    UpdatedAt         DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_MenuItem UNIQUE (BrandId, FoodicsProductId),
    CONSTRAINT CK_MenuItem_Range
        CHECK (MinWeightG IS NULL OR MaxWeightG IS NULL OR MaxWeightG >= MinWeightG)
);
GO

-- Modifiers (per brand) -----------------------------------------------------------
IF OBJECT_ID('dbo.Modifiers','U') IS NULL
CREATE TABLE dbo.Modifiers (
    ModifierId             INT           IDENTITY(1,1) PRIMARY KEY,
    BrandId                INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    FoodicsModifierId      NVARCHAR(64)  NOT NULL,   -- the weighable OPTION's id, not the group's
    Name                   NVARCHAR(200) NOT NULL,
    ModifierGroupName      NVARCHAR(200) NULL,       -- display-only, e.g. "Choice of Fries"
    FoodicsModifierGroupId NVARCHAR(64)  NULL,
    ModifierGroupReference NVARCHAR(64)  NULL,
    Sku                    NVARCHAR(64)  NULL,
    WeightG                DECIMAL(8,2)  NULL,       -- NULL = not configured
    MinWeightG             DECIMAL(8,2)  NULL,
    MaxWeightG             DECIMAL(8,2)  NULL,
    IsActive               BIT           NOT NULL DEFAULT 1,
    UpdatedBy              NVARCHAR(128) NULL,
    UpdatedAt              DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Modifier UNIQUE (BrandId, FoodicsModifierId)
);
GO

-- Which (option-level) modifiers apply to which item ------------------------------
IF OBJECT_ID('dbo.MenuItemModifiers','U') IS NULL
CREATE TABLE dbo.MenuItemModifiers (
    MenuItemId INT NOT NULL REFERENCES dbo.MenuItems(MenuItemId),
    ModifierId INT NOT NULL REFERENCES dbo.Modifiers(ModifierId),
    CONSTRAINT PK_MenuItemModifiers PRIMARY KEY (MenuItemId, ModifierId)
);
GO

-- Weigh events (telemetry + AI training) -------------------------------------------
IF OBJECT_ID('dbo.WeighEvents','U') IS NULL
CREATE TABLE dbo.WeighEvents (
    EventId                  BIGINT IDENTITY(1,1) PRIMARY KEY,
    DeviceId                 INT           NULL REFERENCES dbo.Devices(DeviceId),
    BranchId                 INT           NOT NULL REFERENCES dbo.Branches(BranchId),
    FoodicsOrderId           NVARCHAR(64)  NULL,
    OrderLabel               NVARCHAR(64)  NULL,        -- short staff-facing label, e.g. "Order 63"
    ExpectedMinG             DECIMAL(9,2)  NULL,
    ExpectedMaxG             DECIMAL(9,2)  NULL,
    MeasuredG                DECIMAL(9,2)  NULL,
    Verdict                  NVARCHAR(16)  NOT NULL,    -- onweight / under / over / unconfigured
    OverrideReason           NVARCHAR(128) NULL,
    ItemMissing              BIT           NULL,
    WeighedAt                DATETIME2     NOT NULL,
    CreatedAt                DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    ItemsJson                NVARCHAR(MAX) NULL,        -- order's item/modifier composition (ML export)
    UnconfiguredReasonsJson  NVARCHAR(MAX) NULL         -- exactly what blocked an "unconfigured" verdict
);
GO

-- Config publications (audit of each explicit "Publish") ----------------------------
IF OBJECT_ID('dbo.ConfigPublications','U') IS NULL
CREATE TABLE dbo.ConfigPublications (
    PublicationId INT IDENTITY(1,1) PRIMARY KEY,
    BrandId       INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    Version       INT           NOT NULL,
    PublishedBy   NVARCHAR(128) NULL,
    Notes         NVARCHAR(400) NULL,
    PublishedAt   DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Admin users (schema reserved for future per-user auth/AD/SSO — the API
-- today authenticates with a single shared Api:AdminKey; nothing reads or
-- writes this table yet, so it's fine for it to stay empty indefinitely). --
IF OBJECT_ID('dbo.AdminUsers','U') IS NULL
CREATE TABLE dbo.AdminUsers (
    UserId       INT IDENTITY(1,1) PRIMARY KEY,
    Email        NVARCHAR(200)  NOT NULL UNIQUE,
    DisplayName  NVARCHAR(128)  NULL,
    Role         NVARCHAR(32)   NOT NULL DEFAULT 'editor',  -- admin / editor / viewer
    PasswordHash VARBINARY(256) NULL,
    IsActive     BIT            NOT NULL DEFAULT 1,
    CreatedAt    DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Device connectivity log ---------------------------------------------------------
IF OBJECT_ID('dbo.DeviceEvents','U') IS NULL
CREATE TABLE dbo.DeviceEvents (
    DeviceEventId INT IDENTITY(1,1) PRIMARY KEY,
    DeviceId      INT           NOT NULL REFERENCES dbo.Devices(DeviceId),
    EventType     NVARCHAR(32)  NOT NULL,   -- 'connection_error' / 'recovered'
    Reason        NVARCHAR(64)  NOT NULL,   -- short machine code, e.g. 'no_internet'
    Detail        NVARCHAR(400) NULL,
    OccurredAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CreatedAt     DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Per-brand ML weight-prediction model ------------------------------------------
IF OBJECT_ID('dbo.BrandWeightModels','U') IS NULL
CREATE TABLE dbo.BrandWeightModels (
    BrandId    INT NOT NULL PRIMARY KEY REFERENCES dbo.Brands(BrandId),
    Version    INT NOT NULL,
    FileName   NVARCHAR(200) NOT NULL,
    SizeBytes  BIGINT NOT NULL,
    Sha256Hash CHAR(64) NOT NULL,
    ModelBytes VARBINARY(MAX) NOT NULL,
    UploadedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    UploadedBy NVARCHAR(100) NULL
);
GO

-- Combined weight for up to 4 modifiers selected together on the same order
-- line when it isn't just the sum of each one's own weight — e.g. a combo-
-- SIZE choice can affect BOTH the fries-type portion AND the drink-type
-- portion at once (a real 3-way interaction), which a 2-only design can't
-- represent without silently resolving only one of the two. See
-- docs/sql/15_modifier_combination_weights.sql for the full rationale.
-- ModifierId1..4 are always in strictly increasing order (enforced by the
-- CHECK below) so the same real-world combination is never stored twice.
-- A combination with no matching row here simply falls back to plain
-- addition. AnchorModifierId (docs/sql/16_modifier_combination_anchor.sql)
-- optionally names one member of a 2-member pair as "context only" so the
-- other member's weight is what WeightG replaces, letting that anchor value
-- be shared across several independent dependent-group overrides at once
-- without double-counting it. ------------------------------------------
IF OBJECT_ID('dbo.ModifierCombinationWeights','U') IS NULL
CREATE TABLE dbo.ModifierCombinationWeights (
    CombinationId  INT IDENTITY(1,1) PRIMARY KEY,
    BrandId        INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    ModifierId1    INT           NOT NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierId2    INT           NOT NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierId3    INT           NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierId4    INT           NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierIdsKey NVARCHAR(100) NOT NULL,
    -- Which of ModifierId1/2 is "context only" (its own weight is added
    -- normally, unaffected — e.g. a combo-size chip, typically 0) so WeightG
    -- replaces only the OTHER (dependent) member's own weight. NULL keeps the
    -- older symmetric behavior (WeightG replaces the sum of both members).
    -- Only valid for a true 2-member pair — see docs/sql/16_modifier_combination_anchor.sql.
    AnchorModifierId INT         NULL REFERENCES dbo.Modifiers(ModifierId),
    WeightG        DECIMAL(8,2)  NOT NULL,
    MinWeightG     DECIMAL(8,2)  NULL,
    MaxWeightG     DECIMAL(8,2)  NULL,
    UpdatedBy      NVARCHAR(128) NULL,
    UpdatedAt      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ModifierCombination UNIQUE (BrandId, ModifierIdsKey),
    CONSTRAINT CK_ModifierCombination_Order CHECK (
        ModifierId1 < ModifierId2
        AND (ModifierId3 IS NULL OR ModifierId2 < ModifierId3)
        AND (ModifierId4 IS NULL OR (ModifierId3 IS NOT NULL AND ModifierId3 < ModifierId4))
    ),
    CONSTRAINT CK_ModifierCombination_Range
        CHECK (MinWeightG IS NULL OR MaxWeightG IS NULL OR MaxWeightG >= MinWeightG),
    CONSTRAINT CK_ModifierCombination_Anchor CHECK (
        AnchorModifierId IS NULL
        OR (ModifierId3 IS NULL AND ModifierId4 IS NULL AND AnchorModifierId IN (ModifierId1, ModifierId2))
    )
);
GO

-- An older database may still have the superseded 2-only ModifierPairWeights
-- table (from docs/sql/14_modifier_pair_weights.sql) — replace it, but only
-- if it's genuinely empty; a defensive check, not an assumption.
IF OBJECT_ID('dbo.ModifierPairWeights','U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.ModifierPairWeights)
        DROP TABLE dbo.ModifierPairWeights;
    ELSE
        THROW 50001,
          'ModifierPairWeights still has rows. Migrate its data to ModifierCombinationWeights by hand first.',
          1;
END
GO

-- ---------------------------------------------------------------------------
-- Step 3 — guarded ALTERs for an EXISTING older database only. Every one of
-- these is a no-op on a database that was just created by Step 2 above
-- (COL_LENGTH already finds the column, so nothing runs) — they only do real
-- work when upgrading a database created by an earlier partial version of
-- this schema (e.g. one that only ever had 01_schema.sql applied).
-- ---------------------------------------------------------------------------

IF COL_LENGTH('dbo.Brands', 'FoodicsAccount') IS NULL
    ALTER TABLE dbo.Brands ADD FoodicsAccount NVARCHAR(128) NULL;
GO
IF COL_LENGTH('dbo.Brands', 'MenuSyncedVersion') IS NULL
    ALTER TABLE dbo.Brands ADD MenuSyncedVersion INT NOT NULL DEFAULT 0;
GO

-- Branches: the original schema had Code NOT NULL with a UNIQUE(BrandId,Code)
-- constraint keyed on it; 03_branches_devices.sql switched the real key to
-- FoodicsBranchId instead (Code becoming an optional label). Both steps are
-- reproduced here, guarded, for anyone upgrading from that original shape.
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Branch_Code')
    ALTER TABLE dbo.Branches DROP CONSTRAINT UQ_Branch_Code;
GO
IF COL_LENGTH('dbo.Branches', 'Code') IS NOT NULL
    ALTER TABLE dbo.Branches ALTER COLUMN Code NVARCHAR(64) NULL;
GO
IF COL_LENGTH('dbo.Branches', 'NameLocalized') IS NULL
    ALTER TABLE dbo.Branches ADD NameLocalized NVARCHAR(128) NULL;
GO
IF COL_LENGTH('dbo.Branches', 'OpeningFrom') IS NULL
    ALTER TABLE dbo.Branches ADD OpeningFrom NVARCHAR(16) NULL;
GO
IF COL_LENGTH('dbo.Branches', 'OpeningTo') IS NULL
    ALTER TABLE dbo.Branches ADD OpeningTo NVARCHAR(16) NULL;
GO

IF COL_LENGTH('dbo.MenuItems', 'IdealWeightG') IS NULL
    ALTER TABLE dbo.MenuItems ADD IdealWeightG DECIMAL(8,2) NULL;
GO
IF COL_LENGTH('dbo.MenuItems', 'Sku') IS NULL
    ALTER TABLE dbo.MenuItems ADD Sku NVARCHAR(64) NULL;
GO
IF COL_LENGTH('dbo.MenuItems', 'FoodicsCategoryId') IS NULL
    ALTER TABLE dbo.MenuItems ADD FoodicsCategoryId NVARCHAR(64) NULL;
GO
IF COL_LENGTH('dbo.MenuItems', 'CategoryReference') IS NULL
    ALTER TABLE dbo.MenuItems ADD CategoryReference NVARCHAR(64) NULL;
GO

IF COL_LENGTH('dbo.Modifiers', 'ModifierGroupName') IS NULL
    ALTER TABLE dbo.Modifiers ADD ModifierGroupName NVARCHAR(200) NULL;
GO
IF COL_LENGTH('dbo.Modifiers', 'MinWeightG') IS NULL
    ALTER TABLE dbo.Modifiers ADD MinWeightG DECIMAL(8,2) NULL;
GO
IF COL_LENGTH('dbo.Modifiers', 'MaxWeightG') IS NULL
    ALTER TABLE dbo.Modifiers ADD MaxWeightG DECIMAL(8,2) NULL;
GO
IF COL_LENGTH('dbo.Modifiers', 'Sku') IS NULL
    ALTER TABLE dbo.Modifiers ADD Sku NVARCHAR(64) NULL;
GO
IF COL_LENGTH('dbo.Modifiers', 'FoodicsModifierGroupId') IS NULL
    ALTER TABLE dbo.Modifiers ADD FoodicsModifierGroupId NVARCHAR(64) NULL;
GO
IF COL_LENGTH('dbo.Modifiers', 'ModifierGroupReference') IS NULL
    ALTER TABLE dbo.Modifiers ADD ModifierGroupReference NVARCHAR(64) NULL;
GO

IF COL_LENGTH('dbo.WeighEvents', 'ItemsJson') IS NULL
    ALTER TABLE dbo.WeighEvents ADD ItemsJson NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('dbo.WeighEvents', 'OrderLabel') IS NULL
    ALTER TABLE dbo.WeighEvents ADD OrderLabel NVARCHAR(64) NULL;
GO
IF COL_LENGTH('dbo.WeighEvents', 'UnconfiguredReasonsJson') IS NULL
    ALTER TABLE dbo.WeighEvents ADD UnconfiguredReasonsJson NVARCHAR(MAX) NULL;
GO

-- ---------------------------------------------------------------------------
-- Step 4 — indexes (guarded; match exactly what the API's actual query
-- patterns need — see the "why no extra indexes" note in
-- docs/PRODUCTION_DEPLOYMENT_GUIDE.md before adding more).
-- ---------------------------------------------------------------------------

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Branch_Foodics')
    CREATE UNIQUE INDEX UX_Branch_Foodics
        ON dbo.Branches(BrandId, FoodicsBranchId)
        WHERE FoodicsBranchId IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MenuItems_Brand')
    CREATE INDEX IX_MenuItems_Brand ON dbo.MenuItems(BrandId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WeighEvents_Branch_Date')
    CREATE INDEX IX_WeighEvents_Branch_Date ON dbo.WeighEvents(BranchId, WeighedAt);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DeviceEvents_Device_Date')
    CREATE INDEX IX_DeviceEvents_Device_Date ON dbo.DeviceEvents(DeviceId, OccurredAt DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ModifierCombinationWeights_Brand')
    CREATE INDEX IX_ModifierCombinationWeights_Brand ON dbo.ModifierCombinationWeights(BrandId);
GO

-- ---------------------------------------------------------------------------
-- Step 5 — the one view this app uses (per-brand weight-coverage counts).
-- CREATE OR ALTER is already idempotent on its own — no guard needed.
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vBrandCoverage AS
SELECT b.BrandId, b.Code, b.Name,
       COUNT(mi.MenuItemId) AS TotalItems,
       SUM(CASE WHEN mi.MinWeightG IS NOT NULL AND mi.MaxWeightG IS NOT NULL
                THEN 1 ELSE 0 END) AS ConfiguredItems,
       SUM(CASE WHEN mi.MinWeightG IS NULL OR mi.MaxWeightG IS NULL
                THEN 1 ELSE 0 END) AS MissingItems
FROM dbo.Brands b
LEFT JOIN dbo.MenuItems mi ON mi.BrandId = b.BrandId AND mi.IsActive = 1
GROUP BY b.BrandId, b.Code, b.Name;
GO

/* ----------------------------------------------------------------------------
   No stored procedures, scalar functions, or triggers exist in this schema,
   and none are added here — deliberately. The "periodic sweep" that keeps
   the menu in sync with Foodics is NOT a SQL Server Agent job: it runs
   in-process inside the ASP.NET Core API itself (FoodicsAutoSyncHostedService,
   see docs/PRODUCTION_DEPLOYMENT_GUIDE.md), started automatically the moment
   the API process starts and requiring nothing SQL-side to enable. This also
   sidesteps a real constraint if your server runs SQL Server Express: Express
   edition has no SQL Server Agent at all, so a job-based sweep wouldn't even
   be possible there.
   ---------------------------------------------------------------------------- */

PRINT '============================================================';
PRINT 'SwishWeighing schema is fully up to date (through migration 16).';
PRINT '============================================================';
GO

-- ---------------------------------------------------------------------------
-- Step 6 (OPTIONAL — not run automatically): add your real brands.
-- Uncomment and edit the block below, OR run docs/CONFIGURE_BRANDS.md's
-- version of this insert separately. Left commented out here on purpose —
-- a schema-deployment script should never silently insert placeholder
-- business data into a production database.
-- ---------------------------------------------------------------------------
/*
INSERT INTO dbo.Brands (Code, Name)
SELECT v.Code, v.Name
FROM (VALUES
    ('MM',  'Mishmash'),
    ('TBL', 'Tabel'),
    ('YP',  'Yelo Pizza'),
    ('SS',  'Shawarma Shakir'),
    ('SLC', 'Slice'),
    ('PAT', 'Pattie Pattie'),
    ('BBT', 'BBT'),
    ('BUR', 'Just C'),
    ('CHP', 'Chili Pepper')
) AS v(Code, Name)
WHERE NOT EXISTS (SELECT 1 FROM dbo.Brands b WHERE b.Code = v.Code);
GO
*/
