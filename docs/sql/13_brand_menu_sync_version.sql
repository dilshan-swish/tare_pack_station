/* A counter bumped every time a brand's catalog is actually pulled from
   Foodics and something changed — via the automatic background/webhook sync,
   NOT the admin's manual "Publish" action. Deliberately separate from
   Brands.PublishedVersion: Publish is a human's explicit "I've reviewed this,
   ship it" gesture (the portal warns "N items still have no weight, publish
   anyway?" before bumping it) and must keep meaning exactly that. This column
   is purely a fast, meaningless-to-humans propagation signal so the tablet's
   cheap ~20s version poll notices a newly-synced item (like a product added
   in Foodics) and refetches promptly — without waiting on someone to click
   Publish, and without the poll starting to look like a real
   review/release event. Safe to re-run. */
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

IF COL_LENGTH('dbo.Brands', 'MenuSyncedVersion') IS NULL
    ALTER TABLE dbo.Brands ADD MenuSyncedVersion INT NOT NULL DEFAULT 0;
GO

PRINT 'Brands ready for MenuSyncedVersion.';
GO
