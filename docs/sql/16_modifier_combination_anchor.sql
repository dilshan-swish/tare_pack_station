/* Adds an explicit "depends on" direction to a 2-modifier combination row.

   Until now a combination row was a symmetric, unordered pair: {A, B} -> W
   meant "when A and B are both selected, W replaces the sum of both their
   own weights." That's fine as long as a given modifier only ever
   participates in ONE active combination at a time on an order line — but
   it breaks down for the case that actually motivated this feature: a
   combo-SIZE choice (e.g. "Medium") can affect the fries-type portion AND,
   completely independently, the drink-type portion. Fries-at-Medium and
   Drink-at-Medium are two separate physical facts, not one fused 3-way
   number — forcing a single fused row for every (size, fries, drink) triple
   means filling in a full cross-product grid (sizes x fries x drinks) where
   two much smaller grids (size x fries, size x drink) would do, AND it
   makes "Medium" unable to belong to both pairings at once under the old
   symmetric/mutually-exclusive-claim resolution.

   AnchorModifierId names which of the two members is "context only" (its
   own standalone weight is added normally, completely unaffected — for a
   combo-size chip that's typically 0, since it's a label, not a physical
   component). WeightG then replaces ONLY the OTHER (dependent) member's own
   weight. Because the anchor's own weight is never touched, the SAME anchor
   value can be shared across as many independent dependent-group overrides
   as needed, simultaneously, with no double-counting — see
   lib/logic/modifier_pairing.dart's resolveSelectedModifiers for the
   matching runtime read of this column.

   AnchorModifierId is NULL for every row created before this migration
   (and remains valid/optional afterward) - a NULL anchor keeps the OLD
   symmetric "W replaces the sum of both" behavior, which was already
   correct for those rows (a combo-size chip's own weight was never
   configured, i.e. effectively 0, so symmetric and anchored total the same
   number). Nothing needs to be backfilled: the portal's interactive
   "Combine modifiers" tool now always saves an anchor going forward, so
   existing rows pick one up naturally the next time they're edited there.
   Anchoring only makes sense for a true 2-member pair - CK_ModifierCombination_Anchor
   requires ModifierId3/4 to be NULL whenever an anchor is set, leaving the
   rarer genuinely-inseparable 3-4 member combination (via Excel/API) as a
   single fused number exactly as before. Safe to re-run. */
IF DB_ID('SwishWeighing') IS NULL
    THROW 50000, 'Database SwishWeighing does not exist. Run 00 + 01 first.', 1;
GO
USE SwishWeighing;
GO

SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ModifierCombinationWeights') AND name = 'AnchorModifierId'
)
    ALTER TABLE dbo.ModifierCombinationWeights
        ADD AnchorModifierId INT NULL REFERENCES dbo.Modifiers(ModifierId);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints WHERE name = 'CK_ModifierCombination_Anchor'
)
    ALTER TABLE dbo.ModifierCombinationWeights
        ADD CONSTRAINT CK_ModifierCombination_Anchor CHECK (
            AnchorModifierId IS NULL
            OR (
                ModifierId3 IS NULL AND ModifierId4 IS NULL
                AND AnchorModifierId IN (ModifierId1, ModifierId2)
            )
        );
GO

PRINT 'ModifierCombinationWeights.AnchorModifierId ready.';
GO
