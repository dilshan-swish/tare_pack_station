/* Per-weigh-event item/modifier composition, captured for the weighed-orders
   ML export. Safe to re-run. */
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

IF COL_LENGTH('dbo.WeighEvents', 'ItemsJson') IS NULL
    ALTER TABLE dbo.WeighEvents ADD ItemsJson NVARCHAR(MAX) NULL;
GO

PRINT 'WeighEvents ready for item/modifier composition (ItemsJson).';
GO
