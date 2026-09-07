/* Branch localized name + opening hours (from Foodics). Safe to re-run. */
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

IF COL_LENGTH('dbo.Branches', 'NameLocalized') IS NULL
    ALTER TABLE dbo.Branches ADD NameLocalized NVARCHAR(128) NULL;
GO
IF COL_LENGTH('dbo.Branches', 'OpeningFrom') IS NULL
    ALTER TABLE dbo.Branches ADD OpeningFrom NVARCHAR(16) NULL;
GO
IF COL_LENGTH('dbo.Branches', 'OpeningTo') IS NULL
    ALTER TABLE dbo.Branches ADD OpeningTo NVARCHAR(16) NULL;
GO

PRINT 'Branches ready for localized name + opening hours.';
GO
