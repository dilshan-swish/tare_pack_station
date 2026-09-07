/* Adds catalog identifiers surfaced by the Foodics console so the admin
   portal can show/search on them: a product's SKU and category reference
   (e.g. "catbb-27"), and a modifier's own reference (e.g. "modbb-81") plus
   its option-level SKU. Also backs the "does this item have modifiers"
   filter via the existing dbo.MenuItemModifiers join table (created in
   01_schema.sql but never populated until now).
   Safe to re-run. Run inside the SwishWeighing database. */
IF DB_ID('SwishWeighing') IS NULL
    THROW 50000, 'Database SwishWeighing does not exist. Run 00 + 01 first.', 1;
GO
USE SwishWeighing;
GO

-- Required so CREATE INDEX / constraints on this connection never hit error
-- 1934 — sqlcmd/isql default QUOTED_IDENTIFIER to OFF (SSMS defaults it ON).
SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
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

IF COL_LENGTH('dbo.Modifiers', 'Sku') IS NULL
    ALTER TABLE dbo.Modifiers ADD Sku NVARCHAR(64) NULL;
GO
IF COL_LENGTH('dbo.Modifiers', 'FoodicsModifierGroupId') IS NULL
    ALTER TABLE dbo.Modifiers ADD FoodicsModifierGroupId NVARCHAR(64) NULL;
GO
IF COL_LENGTH('dbo.Modifiers', 'ModifierGroupReference') IS NULL
    ALTER TABLE dbo.Modifiers ADD ModifierGroupReference NVARCHAR(64) NULL;
GO

PRINT 'Catalog enrichment columns are ready (Sku/CategoryReference/ModifierGroupReference).';
GO
