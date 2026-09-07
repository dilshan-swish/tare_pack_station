/* Device event log — records WHY a scale had trouble (not just that it did),
   so the portal can show a real reason instead of just "last seen 2h ago".
   Reported by the tablet whenever a connectivity classification changes (not
   spammed on every failed poll), and read back by the portal per device.
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

IF OBJECT_ID('dbo.DeviceEvents','U') IS NULL
CREATE TABLE dbo.DeviceEvents (
    DeviceEventId INT IDENTITY(1,1) PRIMARY KEY,
    DeviceId      INT           NOT NULL REFERENCES dbo.Devices(DeviceId),
    EventType     NVARCHAR(32)  NOT NULL,   -- 'connection_error' / 'recovered'
    Reason        NVARCHAR(64)  NOT NULL,   -- short machine code, e.g. 'no_internet'
    Detail        NVARCHAR(400) NULL,       -- human-readable detail for the portal
    OccurredAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CreatedAt     DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DeviceEvents_Device_Date')
    CREATE INDEX IX_DeviceEvents_Device_Date ON dbo.DeviceEvents(DeviceId, OccurredAt DESC);
GO

PRINT 'DeviceEvents ready.';
GO
