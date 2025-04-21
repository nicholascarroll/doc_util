-- The fixture schema's data dictionary on standard output (CI keeps it as
-- an artifact, as an example of the output).
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF
SET LINESIZE 32767
SET TRIMOUT ON
SET PAGESIZE 0
WHENEVER SQLERROR EXIT FAILURE
EXEC doc_util.print_schema_dictionary
EXIT
