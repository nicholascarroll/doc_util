-- Install DOC_UTIL into the current schema:  sqlplus user/password@db @install.sql
WHENEVER SQLERROR EXIT FAILURE
SET FEEDBACK OFF

@@src/doc_util.pks
SHOW ERRORS PACKAGE doc_util
@@src/doc_util.pkb
SHOW ERRORS PACKAGE BODY doc_util

-- CREATE PACKAGE succeeds even when the code doesn't compile: fail here instead
DECLARE
  l_errors PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_errors FROM user_errors WHERE name = 'DOC_UTIL';
  IF l_errors > 0 THEN
    RAISE_APPLICATION_ERROR(-20000, 'DOC_UTIL has ' || l_errors || ' compilation errors');
  END IF;
END;
/

PROMPT DOC_UTIL installed.
EXIT
