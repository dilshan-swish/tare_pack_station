/* Exactly which item(s)/modifier(s) blocked the weight check for an
   "unconfigured" weigh event — a JSON array of plain strings (e.g. "Chilli
   Lime for Fillaa on Toast Duo Combo not weighed yet"), captured from the
   tablet at weigh time. Null for events reported before this existed, and
   for any event that isn't unconfigured in the first place. Safe to re-run. */
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

IF COL_LENGTH('dbo.WeighEvents', 'UnconfiguredReasonsJson') IS NULL
    ALTER TABLE dbo.WeighEvents ADD UnconfiguredReasonsJson NVARCHAR(MAX) NULL;
GO

PRINT 'WeighEvents ready for UnconfiguredReasonsJson.';
GO
