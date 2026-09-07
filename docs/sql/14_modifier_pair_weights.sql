/* Combined weight for TWO modifiers selected together on the same order line,
   when their combined weight genuinely isn't the sum of each one's own
   weight — e.g. "Choice Of Fries: Curly Fries" + "Combo Size: Medium" adds a
   different amount than "French Fries" + "Medium" does. Confirmed real for
   BBT: the Regular->Medium fries delta ranges from +15g to +32g depending on
   which fries were chosen — no single per-modifier weight can capture that
   with a simple item+modifiers sum.

   ModifierId1 is always the numerically smaller MenuItemId — a canonical
   order so the same real-world pair can never be stored as two different
   rows (A,B) and (B,A). The app enforces this before insert; the CHECK
   constraint below enforces it at the database level too, as a backstop.

   Only pairs that actually need an override live here. A pair with no row
   here just falls back to today's plain-addition behavior — this table is
   purely an exception list, not a replacement for the existing per-modifier
   WeightG column. Safe to re-run. */
IF DB_ID('SwishWeighing') IS NULL
    THROW 50000, 'Database SwishWeighing does not exist. Run 00 + 01 first.', 1;
GO
USE SwishWeighing;
GO

SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('dbo.ModifierPairWeights','U') IS NULL
CREATE TABLE dbo.ModifierPairWeights (
    PairId       INT IDENTITY(1,1) PRIMARY KEY,
    BrandId      INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    ModifierId1  INT           NOT NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierId2  INT           NOT NULL REFERENCES dbo.Modifiers(ModifierId),
    WeightG      DECIMAL(8,2)  NOT NULL,
    MinWeightG   DECIMAL(8,2)  NULL,
    MaxWeightG   DECIMAL(8,2)  NULL,
    UpdatedBy    NVARCHAR(128) NULL,
    UpdatedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ModifierPair UNIQUE (BrandId, ModifierId1, ModifierId2),
    CONSTRAINT CK_ModifierPair_Order CHECK (ModifierId1 < ModifierId2),
    CONSTRAINT CK_ModifierPair_Range
        CHECK (MinWeightG IS NULL OR MaxWeightG IS NULL OR MaxWeightG >= MinWeightG)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ModifierPairWeights_Brand')
    CREATE INDEX IX_ModifierPairWeights_Brand ON dbo.ModifierPairWeights(BrandId);
GO

PRINT 'ModifierPairWeights ready.';
GO
