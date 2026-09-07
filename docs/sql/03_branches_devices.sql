/* Branch sync + device tracking adjustments. Safe to re-run.
   - Branches are keyed by their Foodics id (Code becomes an optional label).
   - Devices already exist in 01_schema.sql; nothing to change there. */
IF DB_ID('SwishWeighing') IS NULL
    THROW 50000, 'Database SwishWeighing does not exist. Run 00 + 01 first.', 1;
GO
USE SwishWeighing;
GO

-- Required for the filtered index below — sqlcmd/isql default
-- QUOTED_IDENTIFIER to OFF (SSMS defaults it ON), and SQL Server refuses to
-- create a filtered index under OFF (error 1934).
SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
GO

-- Drop the old "unique branch Code per brand" rule (Foodics id is the real key).
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'UQ_Branch_Code')
    ALTER TABLE dbo.Branches DROP CONSTRAINT UQ_Branch_Code;
GO

-- Code becomes an optional short label (Foodics "reference").
IF COL_LENGTH('dbo.Branches', 'Code') IS NOT NULL
    ALTER TABLE dbo.Branches ALTER COLUMN Code NVARCHAR(64) NULL;
GO

-- One row per Foodics branch, per brand.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Branch_Foodics')
    CREATE UNIQUE INDEX UX_Branch_Foodics
        ON dbo.Branches(BrandId, FoodicsBranchId)
        WHERE FoodicsBranchId IS NOT NULL;
GO

PRINT 'Branches ready for Foodics sync.';
GO
