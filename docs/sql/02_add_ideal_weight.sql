/* Adds an Ideal (target) weight to menu items, alongside Min/Max.
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

IF COL_LENGTH('dbo.MenuItems', 'IdealWeightG') IS NULL
    ALTER TABLE dbo.MenuItems ADD IdealWeightG DECIMAL(8,2) NULL;
GO

PRINT 'IdealWeightG is ready on dbo.MenuItems.';
GO
