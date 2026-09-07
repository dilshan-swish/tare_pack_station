/* Per-brand ML weight-prediction models, published from head office and
   downloaded by tablets (mirrors how the menu itself is versioned/synced).
   Safe to re-run. */
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

IF OBJECT_ID('dbo.BrandWeightModels', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BrandWeightModels (
        BrandId       INT NOT NULL PRIMARY KEY REFERENCES dbo.Brands(BrandId),
        Version       INT NOT NULL,
        FileName      NVARCHAR(200) NOT NULL,
        SizeBytes     BIGINT NOT NULL,
        Sha256Hash    CHAR(64) NOT NULL,
        ModelBytes    VARBINARY(MAX) NOT NULL,
        UploadedAt    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        UploadedBy    NVARCHAR(100) NULL
    );
END
GO

PRINT 'BrandWeightModels ready.';
GO
