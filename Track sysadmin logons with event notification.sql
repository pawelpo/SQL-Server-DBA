-- (0) Enable Service Broker if disabled
IF EXISTS (SELECT * FROM sys.databases WHERE name = N'msdb' AND is_broker_enabled = 0)
  ALTER DATABASE msdb SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
GO

-- (1) Pick msdb as it always exists on SQL Server
USE msdb;
GO

-- (2) Verify the objects do not exist
IF EXISTS (SELECT * FROM sys.server_event_notifications WHERE name = N'AuditSysadminLoginNotification')
  DROP EVENT NOTIFICATION AuditSysadminLoginNotification ON SERVER;
GO
IF EXISTS (SELECT * FROM sys.services WHERE name = N'AuditSysadminLoginService')
  DROP SERVICE AuditSysadminLoginService;
GO
IF EXISTS (SELECT * FROM sys.service_queues WHERE name = N'AuditSysadminLoginQueue' AND [schema_id] = 1)
  DROP QUEUE dbo.AuditSysadminLoginQueue;
GO

-- (3) Create a queue, a service and an event notification
CREATE QUEUE dbo.AuditSysadminLoginQueue WITH STATUS = OFF;
GO
CREATE SERVICE AuditSysadminLoginService
ON QUEUE AuditSysadminLoginQueue
(
[http://schemas.microsoft.com/SQL/Notifications/PostEventNotification]
);
GO
CREATE EVENT NOTIFICATION AuditSysadminLoginNotification
ON SERVER
FOR AUDIT_LOGIN
TO SERVICE 'AuditSysadminLoginService', 'current database';
GO

-- (4) Create a table for storing sysadmin logon event history
IF OBJECT_ID(N'dbo.SysadminLogins', N'U') IS NOT NULL
  DROP TABLE dbo.SysadminLogins;
GO
CREATE TABLE dbo.SysadminLogins (
  LoginID int NOT NULL IDENTITY(1,1) PRIMARY KEY,
  LoginName sysname NOT NULL,
  ApplicationName nvarchar(256) NULL,
  HostName nvarchar(128),
  LoginDate datetime NOT NULL DEFAULT(GETDATE())
);
GO

-- (5) Create a stored procedure for logging events
IF  OBJECT_ID(N'dbo.usp_LogSysadminLogin', N'P') IS NOT NULL
  DROP PROCEDURE dbo.usp_LogSysadminLogin
GO
CREATE PROC dbo.usp_LogSysadminLogin
AS
DECLARE
  @ErrorMessage nvarchar(4000),
  @EventData xml,
  @LoginName sysname,
  @ApplicationName nvarchar(256),
  @HostName nvarchar(128),
  @ConversationHandle uniqueidentifier;
WHILE (1=1)
BEGIN
  BEGIN TRAN;
  BEGIN TRY;
    RECEIVE TOP (1)
      @EventData = CAST(message_body AS xml),
      @ConversationHandle = [conversation_handle]
    FROM dbo.AuditSysadminLoginQueue;
    IF @@ROWCOUNT = 0
    BEGIN
      IF @@TRANCOUNT > 0
      BEGIN
          ROLLBACK;
      END;
      BREAK;
    END;
    SELECT
      @LoginName = @EventData.value('(/EVENT_INSTANCE/LoginName/text())[1]', 'sysname'),
      @ApplicationName = @EventData.value('(/EVENT_INSTANCE/ApplicationName/text())[1]', 'nvarchar(256)'),
      @HostName = @EventData.value('(/EVENT_INSTANCE/HostName/text())[1]', 'nvarchar(128)');
    IF IS_SRVROLEMEMBER(N'sysadmin', @LoginName) = 1 BEGIN
      INSERT INTO dbo.SysadminLogins (LoginName, ApplicationName, HostName)
      SELECT @LoginName, @ApplicationName, @HostName;
    END;
    IF @@TRANCOUNT > 0
      COMMIT;
  END TRY
  BEGIN CATCH;
    IF @@TRANCOUNT > 0
    BEGIN
        ROLLBACK;
        END CONVERSATION @ConversationHandle;
        BREAK;
    END;
  END CATCH;
END;
GO

-- (6) Assign stored procedure to the queue and enable queue
ALTER QUEUE dbo.AuditSysadminLoginQueue
  WITH STATUS = ON,
  RETENTION = OFF,
  ACTIVATION (
    STATUS = ON ,
    PROCEDURE_NAME = msdb.dbo.usp_LogSysadminLogin,
    MAX_QUEUE_READERS = 2,
    EXECUTE AS OWNER
  );
GO

-- (7) Test if anything has been logged
SELECT * FROM msdb.dbo.SysadminLogins;