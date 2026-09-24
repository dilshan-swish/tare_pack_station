/* The delivery aggregator (Talabat, Keeta, Ordable, …) an order came through,
   plus that aggregator's own order number — captured at weigh time alongside
   OrderLabel, so the portal can show "Talabat #5070" the same way the tablet
   itself already does, instead of just the bare Foodics order number. Null
   for dine-in/walk-in orders (no aggregator) and for events reported before
   this existed. Safe to re-run. */
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

IF COL_LENGTH('dbo.WeighEvents', 'AggregatorName') IS NULL
    ALTER TABLE dbo.WeighEvents ADD AggregatorName NVARCHAR(64) NULL;
GO

IF COL_LENGTH('dbo.WeighEvents', 'AggregatorRef') IS NULL
    ALTER TABLE dbo.WeighEvents ADD AggregatorRef NVARCHAR(64) NULL;
GO

PRINT 'WeighEvents ready for AggregatorName/AggregatorRef.';
GO
