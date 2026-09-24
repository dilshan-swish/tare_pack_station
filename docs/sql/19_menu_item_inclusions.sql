/* Adds dbo.MenuItemInclusions — components that ALWAYS come with a menu item
   but are not customer-selectable, so Foodics never reports them on the order
   and they can't be represented as a Modifier.

   Real case that motivated this: BBT's "Chilli Lime Tenders Fillaaa" always
   ships with a ranch dip (~87g) and a slaw (~88g). Neither is a Foodics
   modifier option, so before this table the only place their weight could
   live was folded into the item's own IdealWeightG. That blurs the item's
   measured variance across two different populations (bags that got the dips
   and bags that didn't), which widens its Min/Max band until a genuinely
   missing dip no longer trips the under-weight check at all — the exact
   failure this table exists to fix.

   Deliberately NOT stored in dbo.Modifiers: that table is owned by the
   Foodics catalog sync, which would have no matching upstream row for these
   and no basis for keeping them. This table is head-office-authored only and
   nothing ever syncs it away.

   Weights are nullable for the same reason a Modifier's is — an inclusion can
   be declared (so staff see it on the tablet) before anyone has weighed it.
   Until it has a weight the tablet reports the order as "unconfigured" rather
   than silently treating the inclusion as 0g.

   Safe to re-run. Run inside the SwishWeighing database. */
IF DB_ID('SwishWeighing') IS NULL
    THROW 50000, 'Database SwishWeighing does not exist. Run 00 + 01 first.', 1;
GO
USE SwishWeighing;
GO

SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('dbo.MenuItemInclusions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MenuItemInclusions
    (
        InclusionId   INT IDENTITY(1,1) NOT NULL,
        MenuItemId    INT            NOT NULL,
        Name          NVARCHAR(120)  NOT NULL,   -- e.g. 'Ranch', 'Slaw'
        IdealWeightG  DECIMAL(8,2)   NULL,       -- NULL = declared but not weighed yet
        MinWeightG    DECIMAL(8,2)   NULL,
        MaxWeightG    DECIMAL(8,2)   NULL,
        UpdatedBy     NVARCHAR(128)  NULL,
        UpdatedAt     DATETIME2(0)   NOT NULL CONSTRAINT DF_MenuItemInclusions_UpdatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_MenuItemInclusions PRIMARY KEY (InclusionId),
        CONSTRAINT FK_MenuItemInclusions_MenuItem FOREIGN KEY (MenuItemId)
            REFERENCES dbo.MenuItems(MenuItemId) ON DELETE CASCADE,
        -- One row per named component per item: re-adding "Ranch" to the same
        -- item is an edit, never a second silently-double-counted inclusion.
        CONSTRAINT UQ_MenuItemInclusions_Item_Name UNIQUE (MenuItemId, Name),
        CONSTRAINT CK_MenuItemInclusions_Range CHECK (
            MinWeightG IS NULL OR MaxWeightG IS NULL OR MaxWeightG >= MinWeightG)
    );

    CREATE INDEX IX_MenuItemInclusions_MenuItemId ON dbo.MenuItemInclusions(MenuItemId);
END
GO

PRINT 'dbo.MenuItemInclusions is ready.';
GO
