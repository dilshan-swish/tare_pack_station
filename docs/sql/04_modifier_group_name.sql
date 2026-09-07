/* Adds a display-only ModifierGroupName to dbo.Modifiers (e.g. "Choice of
   Fries" for the option "Curly Fries"), and repoints FoodicsModifierId to mean
   the individual, weighable modifier OPTION rather than its parent group.
   Existing group-level rows are deactivated automatically the next time
   "Sync from Foodics" runs (FoodicsService.cs) — no manual cleanup needed here.
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

IF COL_LENGTH('dbo.Modifiers', 'ModifierGroupName') IS NULL
    ALTER TABLE dbo.Modifiers ADD ModifierGroupName NVARCHAR(200) NULL;
GO

PRINT 'ModifierGroupName is ready on dbo.Modifiers.';
GO
