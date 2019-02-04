-- (0) Track open SQL Profiler sessions
SELECT id, path, file_position, reader_spid
FROM sys.traces
WHERE is_rowset = 1;

-- (1) Detect SQL Server instance configuration changes (or trace flags)

SELECT
  e.StartTime,
  e.SessionLoginName,
  e.TextData
FROM sys.traces AS t
CROSS APPLY sys.fn_trace_gettable(
  LEFT(t.path, LEN(t.path)-PATINDEX('%\%', REVERSE(t.path))) + '\log.trc',
  DEFAULT
) AS e
WHERE t.is_default = 1
AND (
  -- Error = 15457 - common sp_configure message
  (e.EventClass = 22 AND e.Error = 15457)
  OR
  -- DBCC event
  (e.EventClass = 116 AND e.TextData LIKE '%TRACEO%(%')
)
ORDER BY e.StartTime DESC;

-- (2) Detect automatic file growth

SELECT
  e.StartTime,
  CASE e.EventClass
    WHEN 92 THEN 'Data File Auto Grow'
    WHEN 93 THEN 'Log File Auto Grow'
    WHEN 94 THEN 'Data File Auto Shrink'
    WHEN 95 THEN 'Log File Auto Shrink'
  END AS EventDesc,
  e.DatabaseName,
  e.FileName
FROM sys.traces AS t
CROSS APPLY sys.fn_trace_gettable(
  LEFT(t.path, LEN(t.path)-PATINDEX('%\%', REVERSE(t.path))) + '\log.trc',
  DEFAULT
) AS e
WHERE t.is_default = 1
AND e.EventClass IN (92, 93, 94, 95)
ORDER BY e.StartTime DESC;

-- (3) Detect schema changes

SELECT
  e.StartTime,
  e.SessionLoginName,
  e.DatabaseName,
  e.ObjectName,
  v.subclass_name AS ObjectType,
  CASE e.EventClass
    WHEN 46 THEN 'CREATE'
    WHEN 47 THEN 'ALTER'
    WHEN 164 THEN 'DROP'
  END AS SchemaChange
FROM sys.traces AS t
CROSS APPLY sys.fn_trace_gettable(
  LEFT(t.path, LEN(t.path)-PATINDEX('%\%', REVERSE(t.path))) + '\log.trc',
  DEFAULT
) AS e
INNER JOIN sys.trace_subclass_values AS v
ON    v.trace_event_id = e.EventClass
  AND v.trace_column_id = 28
  AND v.subclass_value = e.ObjectType
WHERE t.is_default = 1
AND e.EventClass IN (46, 47, 164)
AND e.EventSubClass = 0 -- eliminate junk
AND e.DatabaseID <> 2 -- not tempdb
AND e.ObjectType <> 21587 -- not stats
ORDER BY e.StartTime DESC;