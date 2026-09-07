/* Replaces docs/sql/14_modifier_pair_weights.sql's ModifierPairWeights table
   (confirmed empty in production before this migration — nothing depends on
   the old 2-only shape) with a generalized N-way version, up to 4 modifiers
   selected together on the same order line whose combined weight isn't
   simply the sum of each one's own — e.g. a combo-SIZE choice can affect
   BOTH the fries-type portion AND the drink-type portion at once (a real
   3-way interaction: size x fries-type x drink-type), which a 2-only design
   cannot represent without silently resolving only one of the two pairings.

   ModifierId1..4 are always in strictly increasing order (enforced by the
   CHECK below, with later slots only usable once earlier ones are filled) —
   a canonical order so the same real-world combination is never stored
   twice regardless of selection order. ModifierIdsKey is a denormalized,
   redundant "id1,id2[,id3[,id4]]" string purely so a lookup can match on one
   indexed column instead of comparing four nullable columns.

   A combination with no matching override still falls back to plain
   addition — this table is an exception list, not a replacement for
   Modifier.WeightG. Safe to re-run. */
IF DB_ID('SwishWeighing') IS NULL
    THROW 50000, 'Database SwishWeighing does not exist. Run 00 + 01 first.', 1;
GO
USE SwishWeighing;
GO

SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
GO

-- Only drop the old table if it's genuinely empty — a defensive check, not
-- an assumption, in case this ever runs against a database where it wasn't.
IF OBJECT_ID('dbo.ModifierPairWeights','U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.ModifierPairWeights)
        DROP TABLE dbo.ModifierPairWeights;
    ELSE
        THROW 50001,
          'ModifierPairWeights still has rows. Migrate its data to ModifierCombinationWeights by hand first, then re-run.',
          1;
END
GO

IF OBJECT_ID('dbo.ModifierCombinationWeights','U') IS NULL
CREATE TABLE dbo.ModifierCombinationWeights (
    CombinationId  INT IDENTITY(1,1) PRIMARY KEY,
    BrandId        INT           NOT NULL REFERENCES dbo.Brands(BrandId),
    ModifierId1    INT           NOT NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierId2    INT           NOT NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierId3    INT           NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierId4    INT           NULL REFERENCES dbo.Modifiers(ModifierId),
    ModifierIdsKey NVARCHAR(100) NOT NULL,
    WeightG        DECIMAL(8,2)  NOT NULL,
    MinWeightG     DECIMAL(8,2)  NULL,
    MaxWeightG     DECIMAL(8,2)  NULL,
    UpdatedBy      NVARCHAR(128) NULL,
    UpdatedAt      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ModifierCombination UNIQUE (BrandId, ModifierIdsKey),
    CONSTRAINT CK_ModifierCombination_Order CHECK (
        ModifierId1 < ModifierId2
        AND (ModifierId3 IS NULL OR ModifierId2 < ModifierId3)
        AND (ModifierId4 IS NULL OR (ModifierId3 IS NOT NULL AND ModifierId3 < ModifierId4))
    ),
    CONSTRAINT CK_ModifierCombination_Range
        CHECK (MinWeightG IS NULL OR MaxWeightG IS NULL OR MaxWeightG >= MinWeightG)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ModifierCombinationWeights_Brand')
    CREATE INDEX IX_ModifierCombinationWeights_Brand ON dbo.ModifierCombinationWeights(BrandId);
GO

PRINT 'ModifierCombinationWeights ready (replaces ModifierPairWeights).';
GO
