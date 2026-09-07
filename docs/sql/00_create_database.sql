/* ============================================================
   Step 1 — create the dedicated database (run ONCE).
   Connect as an admin (sysadmin / sa) for this step.

   If you get "CREATE DATABASE permission denied in database 'master'",
   your login is not allowed to create databases. Either:
     • connect as 'sa' or a login in the sysadmin role, or
     • ask your DBA to create an empty database named SwishWeighing
       and grant your login db_owner on it, then skip this file.
   ============================================================ */
IF DB_ID('SwishWeighing') IS NULL
    CREATE DATABASE SwishWeighing;
GO
