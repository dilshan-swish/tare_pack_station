/* ============================================================
   Step 2 — create the tables INSIDE the SwishWeighing database.
   Safe to re-run: every object is guarded, so re-running never errors.

   Before running, make sure you are in the right database:
     - In SSMS, pick "SwishWeighing" in the database dropdown, OR
     - just run this file — the check below stops it if the DB is missing.
   ============================================================ */

IF DB_ID('SwishWeighing') IS NULL
    THROW 50000,
      'Database SwishWeighing does not exist. Run 00_create_database.sql first (needs admin rights).',
      1;
GO
USE SwishWeighing;
GO

-- Required so CREATE INDEX / constraints on this connection never hit error
-- 1934 — sqlcmd/isql default QUOTED_IDENTIFIER to OFF (SSMS defaults it ON).
SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
GO
PRINT 'Using database: ' + DB_NAME();
GO

-- Brands (one row per Foodics brand/account) -----------------
IF OBJECT_ID('dbo.Brands','U') IS NULL
CREATE TABLE dbo.Brands (
    BrandId          INT IDENTITY(1,1) PRIMARY KEY,
    Code             NVARCHAR(32)  NOT NULL UNIQUE,      -- e.g. 'BBT'
    Name             NVARCHAR(128) NOT NULL,
    FoodicsAccount   NVARCHAR(128) NULL,
    PublishedVersion INT           NOT NULL DEFAULT 0,   -- bumped on each publish
    IsActive         BIT           NOT NULL DEFAULT 1,
    CreatedAt        DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt        DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Branches / stores ------------------------------------------
IF OBJECT_ID('dbo.Branches','U') IS NULL
CREATE TABLE dbo.Branches (
    BranchId        INT IDENTITY(1,1) PRIMARY KEY,
    BrandId         INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    FoodicsBranchId NVARCHAR(64)  NULL,
    Code            NVARCHAR(64)  NULL,          -- optional short label (Foodics reference)
    Name            NVARCHAR(128) NOT NULL,
    IsActive        BIT           NOT NULL DEFAULT 1,
    CreatedAt       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
-- One row per Foodics branch, per brand.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Branch_Foodics')
    CREATE UNIQUE INDEX UX_Branch_Foodics
        ON dbo.Branches(BrandId, FoodicsBranchId)
        WHERE FoodicsBranchId IS NOT NULL;
GO

-- Tablets / devices ------------------------------------------
IF OBJECT_ID('dbo.Devices','U') IS NULL
CREATE TABLE dbo.Devices (
    DeviceId   INT IDENTITY(1,1) PRIMARY KEY,
    BranchId   INT           NOT NULL REFERENCES dbo.Branches(BranchId),
    Label      NVARCHAR(64)  NOT NULL,        -- 'Pack station 1'
    ApiKeyHash VARBINARY(64) NOT NULL,        -- store a hash, never the raw key
    AppVersion NVARCHAR(32)  NULL,
    LastSeenAt DATETIME2     NULL,
    IsActive   BIT           NOT NULL DEFAULT 1,
    CreatedAt  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Menu items (per brand; weights configured here) ------------
IF OBJECT_ID('dbo.MenuItems','U') IS NULL
CREATE TABLE dbo.MenuItems (
    MenuItemId       INT IDENTITY(1,1) PRIMARY KEY,
    BrandId          INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    FoodicsProductId NVARCHAR(64)  NOT NULL,
    Name             NVARCHAR(200) NOT NULL,
    CategoryName     NVARCHAR(128) NULL,
    MinWeightG       DECIMAL(8,2)  NULL,   -- NULL = not configured
    MaxWeightG       DECIMAL(8,2)  NULL,
    PackagingWeightG DECIMAL(8,2)  NULL,
    IsActive         BIT           NOT NULL DEFAULT 1,
    UpdatedBy        NVARCHAR(128) NULL,
    UpdatedAt        DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_MenuItem UNIQUE (BrandId, FoodicsProductId),
    CONSTRAINT CK_MenuItem_Range
        CHECK (MinWeightG IS NULL OR MaxWeightG IS NULL OR MaxWeightG >= MinWeightG)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_MenuItems_Brand')
    CREATE INDEX IX_MenuItems_Brand ON dbo.MenuItems(BrandId);
GO

-- Modifiers (per brand) --------------------------------------
IF OBJECT_ID('dbo.Modifiers','U') IS NULL
CREATE TABLE dbo.Modifiers (
    ModifierId        INT IDENTITY(1,1) PRIMARY KEY,
    BrandId           INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    FoodicsModifierId NVARCHAR(64)  NOT NULL,
    Name              NVARCHAR(200) NOT NULL,
    WeightG           DECIMAL(8,2)  NULL,   -- NULL = not configured
    IsActive          BIT           NOT NULL DEFAULT 1,
    UpdatedBy         NVARCHAR(128) NULL,
    UpdatedAt         DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Modifier UNIQUE (BrandId, FoodicsModifierId)
);
GO

-- Which modifiers apply to which item (for the admin UI) -----
IF OBJECT_ID('dbo.MenuItemModifiers','U') IS NULL
CREATE TABLE dbo.MenuItemModifiers (
    MenuItemId INT NOT NULL REFERENCES dbo.MenuItems(MenuItemId),
    ModifierId INT NOT NULL REFERENCES dbo.Modifiers(ModifierId),
    CONSTRAINT PK_MenuItemModifiers PRIMARY KEY (MenuItemId, ModifierId)
);
GO

-- Weigh events (telemetry + AI training) ---------------------
IF OBJECT_ID('dbo.WeighEvents','U') IS NULL
CREATE TABLE dbo.WeighEvents (
    EventId        BIGINT IDENTITY(1,1) PRIMARY KEY,
    DeviceId       INT           NULL REFERENCES dbo.Devices(DeviceId),
    BranchId       INT           NOT NULL REFERENCES dbo.Branches(BranchId),
    FoodicsOrderId NVARCHAR(64)  NULL,
    ExpectedMinG   DECIMAL(9,2)  NULL,
    ExpectedMaxG   DECIMAL(9,2)  NULL,
    MeasuredG      DECIMAL(9,2)  NULL,
    Verdict        NVARCHAR(16)  NOT NULL,   -- onweight / under / over / unconfigured
    OverrideReason NVARCHAR(128) NULL,
    ItemMissing    BIT           NULL,
    WeighedAt      DATETIME2     NOT NULL,
    CreatedAt      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_WeighEvents_Branch_Date')
    CREATE INDEX IX_WeighEvents_Branch_Date ON dbo.WeighEvents(BranchId, WeighedAt);
GO

-- Config publications (audit of each publish) ----------------
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

-- Admin users (optional — or use your AD/SSO) ----------------
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

-- Coverage view: how many items still need weights per brand -
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

-- Optional seed row so you can test straight away ------------
IF NOT EXISTS (SELECT 1 FROM dbo.Brands WHERE Code = 'BBT')
    INSERT INTO dbo.Brands (Code, Name) VALUES ('BBT', 'BBT');
GO

PRINT 'SwishWeighing schema is ready.';
GO
