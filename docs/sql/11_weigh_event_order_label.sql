/* The order's short, staff-facing label ("Order 63", "#REF-123", or a
   customer name) at weigh time — so the portal never has to show the long
   Foodics order id as if it were the thing staff actually look at. Safe to
   re-run. */
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

IF COL_LENGTH('dbo.WeighEvents', 'OrderLabel') IS NULL
    ALTER TABLE dbo.WeighEvents ADD OrderLabel NVARCHAR(64) NULL;
GO

PRINT 'WeighEvents ready for OrderLabel.';
GO
