/* Adds an optional measured Min/Max weight range to dbo.Modifiers, matching
   the same idea already used for dbo.MenuItems — a modifier (extra sauce, a
   scoop of coleslaw, a handful of fries) can vary pack-to-pack just like a
   full item. WeightG remains the ideal/mean value; Min/Max are optional.
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

IF COL_LENGTH('dbo.Modifiers', 'MinWeightG') IS NULL
    ALTER TABLE dbo.Modifiers ADD MinWeightG DECIMAL(8,2) NULL;
GO

IF COL_LENGTH('dbo.Modifiers', 'MaxWeightG') IS NULL
    ALTER TABLE dbo.Modifiers ADD MaxWeightG DECIMAL(8,2) NULL;
GO

PRINT 'MinWeightG/MaxWeightG are ready on dbo.Modifiers.';
GO
