/* ============================================================================
   Catalog data migration — pre-flight check and post-import verification
   ============================================================================
   Use alongside docs/PRODUCTION_DEPLOYMENT_GUIDE.md §3.3b "Bringing over
   your existing dev-database catalog". Run PART 1 on the PRODUCTION server
   BEFORE importing the file SSMS's Generate Scripts wizard produced. Run
   PART 2 on both the DEV database and the PRODUCTION database AFTER
   importing, and compare the two results — they must match exactly.
   ============================================================================ */

USE SwishWeighing;
GO

-- ---------------------------------------------------------------------------
-- PART 0 — use this instead of PART 1 when adding ONE MORE brand to a
-- production database that already has other brands on it (PART 1's "every
-- table must be empty" check would wrongly refuse in that case). Edit
-- @BrandCode below to the new brand's code, then run this on PRODUCTION
-- before importing that brand's exported rows.
-- ---------------------------------------------------------------------------
DECLARE @BrandCode NVARCHAR(32) = 'REPLACE-WITH-THE-NEW-BRAND-CODE';

IF EXISTS (SELECT 1 FROM dbo.Brands WHERE Code = @BrandCode)
    THROW 50002, 'A brand with this Code already exists on this database. Do not import on top of it.', 1;
ELSE
    PRINT 'No existing brand with this Code -- safe to import that one brand''s export now.';
GO

-- ---------------------------------------------------------------------------
-- PART 1 — run on PRODUCTION before importing. Refuses to continue if any of
-- the five target tables already has rows, since importing on top of
-- existing rows is exactly how an IDENTITY_INSERT conflict happens.
-- ---------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM dbo.Brands)
   OR EXISTS (SELECT 1 FROM dbo.Modifiers)
   OR EXISTS (SELECT 1 FROM dbo.MenuItems)
   OR EXISTS (SELECT 1 FROM dbo.MenuItemModifiers)
   OR EXISTS (SELECT 1 FROM dbo.ModifierCombinationWeights)
BEGIN
    THROW 50001,
      'One or more of Brands / Modifiers / MenuItems / MenuItemModifiers / ModifierCombinationWeights already has rows on THIS database. Do not import the dev export on top of it -- either this is the wrong database, or you already ran "Add your real brands" from the deployment guide (in which case, skip that step when using this migration instead, or clear these five tables first if you are certain nothing else depends on them yet).',
      1;
END
ELSE
    PRINT 'All five target tables are empty on this database -- safe to import the dev export now.';
GO

-- ---------------------------------------------------------------------------
-- PART 2 — row-count verification. Run this exact query on DEV (before you
-- export) and again on PRODUCTION (after you import), and compare the two
-- results side by side -- every row count must match exactly.
-- ---------------------------------------------------------------------------
SELECT 'Brands' AS TableName, COUNT(*) AS RowCount FROM dbo.Brands
UNION ALL
SELECT 'Modifiers', COUNT(*) FROM dbo.Modifiers
UNION ALL
SELECT 'MenuItems', COUNT(*) FROM dbo.MenuItems
UNION ALL
SELECT 'MenuItemModifiers', COUNT(*) FROM dbo.MenuItemModifiers
UNION ALL
SELECT 'ModifierCombinationWeights', COUNT(*) FROM dbo.ModifierCombinationWeights
ORDER BY TableName;
GO

-- ---------------------------------------------------------------------------
-- PART 3 (optional, extra confidence) — a spot-check that referential
-- integrity actually holds after the import: every MenuItem's BrandId
-- resolves to a real Brand, every Modifier referenced by
-- ModifierCombinationWeights resolves to a real Modifier, and so on. This
-- returns ZERO rows if everything is consistent -- any row it does return
-- names exactly which table/id is dangling.
-- ---------------------------------------------------------------------------
SELECT 'MenuItems -> Brands' AS Check_, mi.MenuItemId AS Id
FROM dbo.MenuItems mi
WHERE NOT EXISTS (SELECT 1 FROM dbo.Brands b WHERE b.BrandId = mi.BrandId)
UNION ALL
SELECT 'Modifiers -> Brands', m.ModifierId
FROM dbo.Modifiers m
WHERE NOT EXISTS (SELECT 1 FROM dbo.Brands b WHERE b.BrandId = m.BrandId)
UNION ALL
SELECT 'MenuItemModifiers -> MenuItems', mim.MenuItemId
FROM dbo.MenuItemModifiers mim
WHERE NOT EXISTS (SELECT 1 FROM dbo.MenuItems mi WHERE mi.MenuItemId = mim.MenuItemId)
UNION ALL
SELECT 'MenuItemModifiers -> Modifiers', mim.ModifierId
FROM dbo.MenuItemModifiers mim
WHERE NOT EXISTS (SELECT 1 FROM dbo.Modifiers m WHERE m.ModifierId = mim.ModifierId)
UNION ALL
SELECT 'ModifierCombinationWeights -> Brands', cw.CombinationId
FROM dbo.ModifierCombinationWeights cw
WHERE NOT EXISTS (SELECT 1 FROM dbo.Brands b WHERE b.BrandId = cw.BrandId);
GO
