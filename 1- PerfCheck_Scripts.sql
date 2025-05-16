--1--Check what is running on server currently. Retrieves all sessions types including sleeping:
with SQLExec as
(SELECT
s.spid,db_name(s.dbid) as dbname,s.hostname, s.loginame, s.program_name,s.waittype,s.lastwaittype,s.cmd,s.blocked,s.status,e.text as SQL, s.cpu,s.memusage,s.physical_io,s.login_time,s.last_batch,s.net_library,s.sql_handle
,e.encrypted as IsSQLTextEncrypted
FROM 
sys.sysprocesses s
CROSS APPLY sys.dm_exec_sql_text(s.sql_handle) AS e)
select e.*,conn.auth_scheme,conn.client_net_address,conn.connect_time,conn.encrypt_option as IsSQLConnectionEncrypted,conn.net_transport from SQLExec e
join sys.dm_exec_connections conn with (nolock) on e.spid = conn.session_id

--2--More detailed one with exec plans:
SELECT getdate() as dt,
ss.session_id,
db_name(sysprocesses.dbid) as dbname,
er.status as req_status,
ss.login_name,
ss.original_login_name,
cs.client_net_address,
ss.program_name,
sysprocesses.open_tran,
er.blocking_session_id,
ss.host_name,
ss.client_interface_name,
[eqp].[query_plan] as qplan,
SUBSTRING(est.text,(er.statement_start_offset/2)+1,
CASE WHEN er.statement_end_offset=-1 OR er.statement_end_offset=0
THEN (DATALENGTH(est.Text)-er.statement_start_offset/2)+1
ELSE (er.statement_end_offset-er.statement_start_offset)/2+1
END) as req_query_text,
er.granted_query_memory,
er.logical_reads as req_logical_reads,
er.cpu_time as req_cpu_time,
er.reads as req_physical_reads,
er.row_count as req_row_count,
er.scheduler_id,
er.total_elapsed_time as req_elapsed_time,
er.start_time as req_start_time,
er.percent_complete,
er.wait_resource as wait_resource,
er.wait_type as req_waittype,
er.wait_time as req_wait_time,
wait.wait_duration_ms as blocking_time_ms,
lock.resource_associated_entity_id,
lock.request_status as lock_request_status,
lock.request_mode as lock_mode,
er.writes as req_writes,
sysprocesses.lastwaittype,
fn_sql.text as session_query,
ss.status as session_status,
ss.cpu_time as session_cpu_time,
ss.reads as session_reads,
ss.writes as session_writes,
ss.logical_reads as session_logical_reads,
ss.memory_usage as session_memory_usage,
ss.last_request_start_time,
ss.last_request_end_time,
ss.total_scheduled_time as session_scheduled_time,
ss.total_elapsed_time as session_elpased_time,
ss.row_count as session_rowcount
FROM sys.dm_exec_sessions ss
INNER JOIN sys.dm_exec_connections cs ON ss.session_id = cs.session_id
OUTER APPLY fn_get_sql(cs.most_recent_sql_handle) as fn_sql
INNER JOIN sys.sysprocesses ON sys.sysprocesses.spid = cs.session_id
LEFT OUTER JOIN sys.dm_exec_requests [er] ON er.session_id = ss.session_id
OUTER APPLY sys.dm_exec_sql_text ([er].[sql_handle]) [est]
OUTER APPLY sys.dm_exec_query_plan ([er].[plan_handle]) [eqp]
LEFT OUTER JOIN sys.dm_os_waiting_tasks wait ON er.session_id = wait.session_id
and wait.wait_type like 'LCK%' and
er.blocking_session_id = wait.blocking_session_id
LEFT OUTER JOIN sys.dm_tran_locks lock ON lock.lock_owner_address = wait.resource_address
                                      AND lock.request_session_id = er.blocking_session_id
WHERE ss.status != 'sleeping';


--Get Execution plans of running queries:
SELECT QP.query_plan as [Query Plan], 
       ST.text AS [Query Text]
FROM sys.dm_exec_requests AS R
   CROSS APPLY sys.dm_exec_query_plan(R.plan_handle) AS QP
   CROSS APPLY sys.dm_exec_sql_text(R.plan_handle) ST;


--3-- GET NUMBER OF SESSIONS CONNECTED TO THE SERVER. This number will be equal to the total number of sessions you see in the first query:
SELECT
    COUNT(*) AS TotalConnections
FROM
    sys.dm_exec_sessions AS s
INNER JOIN
    sys.dm_exec_connections AS c
ON
    s.session_id = c.session_id
WHERE
    s.is_user_process = 1;   


--4-- Get info about who is connected to the server, from where and what app they are using:
	SELECT ec.client_net_address, es.[program_name], es.[host_name], es.login_name, es.status
FROM sys.dm_exec_sessions AS es WITH (NOLOCK) 
INNER JOIN sys.dm_exec_connections AS ec WITH (NOLOCK) 
ON es.session_id = ec.session_id 
WHERE
    es.is_user_process = 1;


--5-- Check CPU USAGE PERCENTAGE. Recent CPU Utilization History for last 256 minutes (in one minute intervals):
DECLARE @ts_now bigint = (SELECT cpu_ticks/(cpu_ticks/ms_ticks) FROM sys.dm_os_sys_info WITH (NOLOCK)); 

SELECT TOP(256) SQLProcessUtilization AS [SQL Server Process CPU Utilization], 
               SystemIdle AS [System Idle Process], 
               100 - SystemIdle - SQLProcessUtilization AS [Other Process CPU Utilization], 
               DATEADD(ms, -1 * (@ts_now - [timestamp]), GETDATE()) AS [Event Time] 
FROM ( 
	  SELECT record.value('(./Record/@id)[1]', 'int') AS record_id, 
			record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') 
			AS [SystemIdle], 
			record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 
			'int') 
			AS [SQLProcessUtilization], [timestamp] 
	  FROM ( 
			SELECT [timestamp], CONVERT(xml, record) AS [record] 
			FROM sys.dm_os_ring_buffers WITH (NOLOCK)
			WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' 
			AND record LIKE N'%<SystemHealth>%') AS x 
	  ) AS y 
ORDER BY record_id DESC OPTION (RECOMPILE);



--6--CHECK MEMORY USAGE
-- In the results, last column "System Memory State", you want to see "Available physical memory is high"; This indicates that you are not under external memory pressure
SELECT total_physical_memory_kb/1024 AS [Physical Memory (MB)], 
       available_physical_memory_kb/1024 AS [Available Memory (MB)], 
       total_page_file_kb/1024 AS [Total Page File (MB)], 
	   available_page_file_kb/1024 AS [Available Page File (MB)], 
	   system_cache_kb/1024 AS [System Cache (MB)],
       system_memory_state_desc AS [System Memory State]
FROM sys.dm_os_sys_memory WITH (NOLOCK) OPTION (RECOMPILE);

--And following query as well to check internal memory pressure
-- In the results, last 2 columns, you want to see 0 for process_physical_memory_low and you want to see 0 for process_virtual_memory_low
-- This indicates that you are not under internal memory pressure
SELECT physical_memory_in_use_kb/1024 AS [SQL Server Memory Usage (MB)],
       large_page_allocations_kb, locked_page_allocations_kb, page_fault_count, 
	   memory_utilization_percentage, available_commit_limit_kb, 
	   process_physical_memory_low, process_virtual_memory_low
FROM sys.dm_os_process_memory WITH (NOLOCK) OPTION (RECOMPILE);



/*######################## TOP CONSUMERS ########################--
EXECUTE UNDER SPECIFIC DATABASE TO GET RESULTS ABOUT THAT DATABASE.
Top Cached SPs By Total Worker time. Worker time relates to CPU cost.
This helps you find the most expensive cached stored procedures from a CPU perspective.
You should look at this if you see signs of CPU pressure.*/
SELECT TOP(25) p.name AS [SP Name], qs.total_worker_time AS [TotalWorkerTime], 
qs.total_worker_time/qs.execution_count AS [AvgWorkerTime], qs.execution_count, 
ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
qs.total_elapsed_time, qs.total_elapsed_time/qs.execution_count 
AS [avg_elapsed_time], qs.cached_time
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
ON p.[object_id] = qs.[object_id]
WHERE qs.database_id = DB_ID()
ORDER BY qs.total_worker_time DESC OPTION (RECOMPILE);


-- Top Cached SPs By Execution Count (How many times executed).
-- Tells you which cached stored procedures are called the most often
-- This helps you characterize and baseline your workload
SELECT TOP(100) p.name AS [SP Name], qs.execution_count,
ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
qs.total_worker_time/qs.execution_count AS [AvgWorkerTime], qs.total_worker_time AS [TotalWorkerTime],  
qs.total_elapsed_time, qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time],
qs.cached_time
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
ON p.[object_id] = qs.[object_id]
WHERE qs.database_id = DB_ID()
ORDER BY qs.execution_count DESC OPTION (RECOMPILE);


-- Top cached queries by Execution Count. Same as above but retrieve queries only. No stored Procedures 
SELECT TOP (100) qs.execution_count, qs.total_rows, qs.last_rows, qs.min_rows, qs.max_rows,
qs.last_elapsed_time, qs.min_elapsed_time, qs.max_elapsed_time,
total_worker_time, total_logical_reads, 
SUBSTRING(qt.TEXT,qs.statement_start_offset/2 +1,
(CASE WHEN qs.statement_end_offset = -1
			THEN LEN(CONVERT(NVARCHAR(MAX), qt.TEXT)) * 2
	  ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) AS query_text 
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
ORDER BY qs.execution_count DESC OPTION (RECOMPILE);










