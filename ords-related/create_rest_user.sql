-- =====================================================
-- Script: create_rest_user.sql
-- Purpose: Create/configure a user/schema and enable ORDS
-- Notes:
--   * Interactive usage:
--       sqlplus /nolog
--       connect sys/<password>@//<host>:<port>/<service> as sysdba
--       @create_rest_user.sql
--   * Automation-friendly usage:
--       This script can also be driven over stdin by a wrapper shell script,
--       which is how the ORDS /ords-entrypoint.d startup hook can call it.
-- =====================================================

SET VERIFY OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

PROMPT Enter database account details:
ACCEPT target_user CHAR DEFAULT 'ORDSDEMO' PROMPT 'Enter target user name [ORDSDEMO]: '
ACCEPT ORDS_AUTO_REST_AUTH CHAR DEFAULT 'FALSE' PROMPT 'Enable ORDS auto REST auth? (TRUE/FALSE) [FALSE]: '
PROMPT Credentials captured for &&target_user.

COLUMN target_user_exists NEW_VALUE target_user_exists NOPRINT
SELECT CASE
         WHEN EXISTS (
           SELECT 1
             FROM dba_users
            WHERE username = UPPER('&&target_user')
         ) THEN 'Y'
         ELSE 'N'
       END AS target_user_exists
  FROM dual;

COLUMN target_user_status_message NEW_VALUE target_user_status_message NOPRINT
SELECT CASE
         WHEN '&&target_user_exists' = 'Y' THEN
           'User ' || UPPER('&&target_user') || ' already exists.'
         ELSE
           'User ' || UPPER('&&target_user') || ' does not exist. Proceeding with creation.'
       END AS target_user_status_message
  FROM dual;

PROMPT &target_user_status_message

COLUMN password_prompt_script NEW_VALUE password_prompt_script NOPRINT
SELECT CASE
         WHEN '&&target_user_exists' = 'N' THEN
           'prompt_target_user_password.sql'
         ELSE
           'skip_target_user_password.sql'
       END AS password_prompt_script
  FROM dual;

@@&password_prompt_script

COLUMN passwords_match NEW_VALUE passwords_match NOPRINT
SELECT CASE
         WHEN '&&target_user_exists' = 'Y' THEN 'Y'
         WHEN '&&target_password' = '&&target_password_confirm' THEN 'Y'
         ELSE 'N'
       END AS passwords_match
  FROM dual;

BEGIN
  IF '&&passwords_match' <> 'Y' THEN
    RAISE_APPLICATION_ERROR(-20001, 'Password entries did not match.');
  END IF;
END;
/

VARIABLE summary_user_action VARCHAR2(4000)
VARIABLE summary_password_action VARCHAR2(4000)
VARIABLE summary_ords_action VARCHAR2(4000)

BEGIN
  :summary_user_action := 'No user changes were made.';
  :summary_password_action := 'Password unchanged.';
  :summary_ords_action := 'ORDS enablement not attempted.';
END;
/

DECLARE
BEGIN
  IF '&&target_user_exists' = 'N' THEN
    DBMS_OUTPUT.PUT_LINE('Creating user ' || UPPER('&&target_user') || '...');
    EXECUTE IMMEDIATE 'CREATE USER &&target_user IDENTIFIED BY "&&target_password"';
    DBMS_OUTPUT.PUT_LINE('User created.');
    :summary_user_action := 'Created user ' || UPPER('&&target_user') || '.';
    :summary_password_action := 'Set password during user creation.';
  ELSE
    DBMS_OUTPUT.PUT_LINE('User ' || UPPER('&&target_user') || ' already exists. Appending grants and ORDS configuration.');
    :summary_user_action := 'Reused existing user ' || UPPER('&&target_user') || '.';
    :summary_password_action := 'Left the existing password unchanged.';
  END IF;
END;
/

-- -----------------------------------------------------
-- Grants / roles / privileges
-- -----------------------------------------------------

-- Storage
GRANT UNLIMITED TABLESPACE TO &&target_user;

-- Roles (grant what exists; skip gracefully if not present)
DECLARE
  PROCEDURE grant_role(p_role VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'GRANT ' || p_role || ' TO &&target_user';
    DBMS_OUTPUT.PUT_LINE('Granted role ' || p_role);
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Skipped role ' || p_role || ' (not granted): ' || SQLERRM);
  END;
BEGIN
  grant_role('CONNECT');
  grant_role('RESOURCE');
  grant_role('DB_DEVELOPER_ROLE');
  grant_role('GRAPH_DEVELOPER');
END;
/

-- DWROLE-equivalent system privileges (consolidated)
GRANT
  CREATE ANALYTIC VIEW,
  CREATE ATTRIBUTE DIMENSION,
  ALTER SESSION,
  CREATE HIERARCHY,
  CREATE JOB,
  CREATE MATERIALIZED VIEW,
  CREATE MINING MODEL,
  CREATE PROCEDURE,
  CREATE SEQUENCE,
  CREATE SESSION,
  CREATE SYNONYM,
  CREATE TABLE,
  CREATE TRIGGER,
  CREATE TYPE,
  CREATE VIEW
TO &&target_user;

-- NEW: Directory creation privilege (powerful; validate per security policy)
GRANT CREATE ANY DIRECTORY TO &&target_user;

-- Directory privileges (existing directory object access)
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO &&target_user;

-- Default roles for the user:
ALTER USER &&target_user DEFAULT ROLE ALL;

-- -----------------------------------------------------
-- Optional: grant EXECUTE on DBMS_CLOUD if present
-- -----------------------------------------------------
DECLARE
  v_owner VARCHAR2(128);
BEGIN
  SELECT owner
    INTO v_owner
    FROM dba_objects
   WHERE object_name = 'DBMS_CLOUD'
     AND object_type = 'PACKAGE'
     AND rownum = 1;

  EXECUTE IMMEDIATE 'GRANT EXECUTE ON ' || v_owner || '.DBMS_CLOUD TO &&target_user';
  DBMS_OUTPUT.PUT_LINE('Granted EXECUTE on ' || v_owner || '.DBMS_CLOUD');
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    DBMS_OUTPUT.PUT_LINE('DBMS_CLOUD package not found; skipping EXECUTE grant.');
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Could not grant EXECUTE on DBMS_CLOUD: ' || SQLERRM);
END;
/

-- -----------------------------------------------------
-- NEW: grant EXECUTE on DBMS_VECTOR and DBMS_DATA_MINING if present
-- -----------------------------------------------------
DECLARE
  PROCEDURE grant_pkg_if_exists(p_pkg VARCHAR2) IS
    v_owner VARCHAR2(128);
  BEGIN
    SELECT owner
      INTO v_owner
      FROM dba_objects
     WHERE object_name = UPPER(p_pkg)
       AND object_type = 'PACKAGE'
       AND rownum = 1;

    EXECUTE IMMEDIATE 'GRANT EXECUTE ON ' || v_owner || '.' || UPPER(p_pkg) || ' TO &&target_user';
    DBMS_OUTPUT.PUT_LINE('Granted EXECUTE on ' || v_owner || '.' || UPPER(p_pkg));
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      DBMS_OUTPUT.PUT_LINE(p_pkg || ' package not found; skipping EXECUTE grant.');
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Could not grant EXECUTE on ' || p_pkg || ': ' || SQLERRM);
  END;
BEGIN
  grant_pkg_if_exists('DBMS_VECTOR');
  grant_pkg_if_exists('DBMS_DATA_MINING');
  grant_pkg_if_exists('DBMS_VECTOR_DATABASE');
END;
/

-- -----------------------------------------------------
-- Optional: grant EXECUTE on OCI PL/SQL SDK packages if present
-- -----------------------------------------------------
BEGIN
  FOR r IN (
    SELECT owner, object_name
      FROM dba_objects
     WHERE object_type = 'PACKAGE'
       AND (object_name LIKE 'OCI%' OR object_name LIKE '%OCI%')
     ORDER BY owner, object_name
  ) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'GRANT EXECUTE ON ' || r.owner || '.' || r.object_name || ' TO &&target_user';
      DBMS_OUTPUT.PUT_LINE('Granted EXECUTE on ' || r.owner || '.' || r.object_name);
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Skipped ' || r.owner || '.' || r.object_name || ': ' || SQLERRM);
    END;
  END LOOP;
END;
/

-- -----------------------------------------------------
-- Enable ORDS via ORDS_ADMIN
-- -----------------------------------------------------
DECLARE
  v_ords_admin_callable NUMBER := 0;
  v_auto_rest_auth VARCHAR2(20) := UPPER(TRIM('&&ORDS_AUTO_REST_AUTH'));
  v_rest_auth_literal VARCHAR2(5);
BEGIN
  IF v_auto_rest_auth IN ('TRUE', 'Y', 'YES', '1') THEN
    v_rest_auth_literal := 'TRUE';
  ELSE
    v_rest_auth_literal := 'FALSE';
  END IF;

  BEGIN
    SELECT COUNT(*)
      INTO v_ords_admin_callable
      FROM dba_objects
     WHERE object_name = 'ORDS_ADMIN'
       AND object_type IN ('PACKAGE', 'SYNONYM', 'PUBLIC SYNONYM');
  EXCEPTION
    WHEN OTHERS THEN
      v_ords_admin_callable := 0;
  END;

  IF v_ords_admin_callable > 0 THEN
    BEGIN
      EXECUTE IMMEDIATE
        'begin ords_admin.enable_schema(' ||
        'p_enabled => TRUE, ' ||
        'p_schema => ' || DBMS_ASSERT.ENQUOTE_LITERAL(UPPER('&&target_user')) || ', ' ||
        q'[p_url_mapping_type => 'BASE_PATH', ]' ||
        'p_url_mapping_pattern => ' || DBMS_ASSERT.ENQUOTE_LITERAL(LOWER('&&target_user')) || ', ' ||
        'p_auto_rest_auth => ' || v_rest_auth_literal ||
        '); end;';
      DBMS_OUTPUT.PUT_LINE('ORDS_ADMIN enabled schema for ' || UPPER('&&target_user') || '.');
      :summary_ords_action := 'Enabled ORDS with ORDS_ADMIN.ENABLE_SCHEMA.';
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Could not enable ORDS via ORDS_ADMIN for ' || UPPER('&&target_user') || ': ' || SQLERRM);
        :summary_ords_action := 'Attempted ORDS enablement via ORDS_ADMIN but it failed: ' || SQLERRM;
    END;
  ELSE
    DBMS_OUTPUT.PUT_LINE('INFO: ORDS_ADMIN package not found. Skipping ORDS_ADMIN.ENABLE_SCHEMA.');
    :summary_ords_action := 'Skipped ORDS enablement because ORDS_ADMIN was not found.';
  END IF;
END;
/

BEGIN
  DBMS_OUTPUT.PUT_LINE(' ');
  DBMS_OUTPUT.PUT_LINE('Summary');
  DBMS_OUTPUT.PUT_LINE('Target user: ' || UPPER('&&target_user'));
  DBMS_OUTPUT.PUT_LINE('User action: ' || :summary_user_action);
  DBMS_OUTPUT.PUT_LINE('Password action: ' || :summary_password_action);
  DBMS_OUTPUT.PUT_LINE('Roles and privileges: Granted UNLIMITED TABLESPACE, CONNECT, RESOURCE, DB_DEVELOPER_ROLE, GRAPH_DEVELOPER, CREATE ANALYTIC VIEW, CREATE ATTRIBUTE DIMENSION, ALTER SESSION, CREATE HIERARCHY, CREATE JOB, CREATE MATERIALIZED VIEW, CREATE MINING MODEL, CREATE PROCEDURE, CREATE SEQUENCE, CREATE SESSION, CREATE SYNONYM, CREATE TABLE, CREATE TRIGGER, CREATE TYPE, CREATE VIEW, CREATE ANY DIRECTORY, READ/WRITE on DATA_PUMP_DIR, and set default role ALL.');
  DBMS_OUTPUT.PUT_LINE('Optional package grants: Attempted EXECUTE grants for DBMS_CLOUD, DBMS_VECTOR, DBMS_DATA_MINING, DBMS_VECTOR_DATABASE, and OCI-related packages when present.');
  DBMS_OUTPUT.PUT_LINE('ORDS: ' || :summary_ords_action);
  DBMS_OUTPUT.PUT_LINE('Script completed successfully.');
END;
/

EXIT SUCCESS
