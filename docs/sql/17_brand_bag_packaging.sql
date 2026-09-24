/* Adds an optional one-bag packaging range to dbo.Brands — bag material,
   napkins, sauce cups, whatever a brand's own "bag and extras" typically
   weighs. Unlike a menu item's own weight, this is a property of the brand's
   packaging, not of any one item, so it lives on Brands rather than
   MenuItems. The tablet multiplies this by however many bags a worker
   actually captures for an order, rather than trying to predict bag count
   in advance. Safe to re-run. Run inside the SwishWeighing database. */
IF DB_ID('SwishWeighing') IS NULL
    THROW 50000, 'Database SwishWeighing does not exist. Run 00 + 01 first.', 1;
GO
USE SwishWeighing;
GO

SET QUOTED_IDENTIFIER ON;
GO
SET ANSI_NULLS ON;
GO

IF COL_LENGTH('dbo.Brands', 'BagIdealWeightG') IS NULL
    ALTER TABLE dbo.Brands ADD BagIdealWeightG DECIMAL(8,2) NULL;
GO

IF COL_LENGTH('dbo.Brands', 'BagMinWeightG') IS NULL
    ALTER TABLE dbo.Brands ADD BagMinWeightG DECIMAL(8,2) NULL;
GO

IF COL_LENGTH('dbo.Brands', 'BagMaxWeightG') IS NULL
    ALTER TABLE dbo.Brands ADD BagMaxWeightG DECIMAL(8,2) NULL;
GO

PRINT 'BagIdealWeightG/BagMinWeightG/BagMaxWeightG are ready on dbo.Brands.';
GO
