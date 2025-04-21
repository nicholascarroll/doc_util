CREATE OR REPLACE PACKAGE doc_util AUTHID CURRENT_USER AS
  /*
  * DOC_UTIL - documentation from the data dictionary
  *
  * Documents tables, queries and whole schemas in Markdown (and Org mode for
  * tables), with Mermaid entity relationship diagrams.
  *
  * Every document is returned as a CLOB by a function; the print_ procedures
  * are thin wrappers that send the same text to DBMS_OUTPUT.
  *
  * The package runs with the caller's rights (AUTHID CURRENT_USER): it sees
  * exactly the tables the caller can see in the ALL_ views, and a NULL
  * schema means the caller's current schema.
  *
  * Table names are taken as given if such a table exists, and in upper case
  * otherwise.  Errors are raised, not printed:
  *   ORA-20001  table not found
  *   ORA-20002  unqualified table name found in more than one schema
  *   ORA-20003  no tables given
  *   ORA-20004  unknown format (use 'md' or 'org')
  */

  -- The rows of P_QUERY as a Markdown ('md') or Org-mode ('org') table.
  -- Columns that don't fit in P_MAX_WIDTH characters are replaced by a '?'
  -- column.  A query with no rows gives 'No rows returned by the query.'
  FUNCTION format_query(
    p_query     IN VARCHAR2,
    p_format    IN VARCHAR2 DEFAULT 'md',
    p_max_width IN NUMBER   DEFAULT 100
  ) RETURN CLOB;

  -- The table's comment, under a bold heading, wrapped at 100 characters
  FUNCTION table_comments(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2
  ) RETURN CLOB;

  -- The table's columns: name, data type, nullable, comment
  FUNCTION table_columns(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2,
    p_format     IN VARCHAR2 DEFAULT 'md'
  ) RETURN CLOB;

  -- The table's foreign keys: constraint, referenced table, column mappings
  FUNCTION table_foreign_keys(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2,
    p_format     IN VARCHAR2 DEFAULT 'md'
  ) RETURN CLOB;

  -- How much of a schema's tables and columns carry comments; with
  -- P_INCLUDE_DETAIL, which ones don't
  FUNCTION schema_comment_audit(
    p_schema         IN VARCHAR2 DEFAULT NULL,
    p_include_detail IN BOOLEAN  DEFAULT FALSE
  ) RETURN CLOB;

  -- A Mermaid ERD (in a ```mermaid fence) for a comma-separated list of
  -- tables, each optionally prefixed by its schema ('HR.EMPLOYEES,JOBS').
  -- An unqualified name is looked up in the current schema first, then in
  -- all schemas, where it must be unique.  Relationships are the foreign
  -- keys between the listed tables.  Without P_ALL_COLUMNS only key
  -- columns are shown.
  FUNCTION mermaid_erd(
    p_table_list  IN VARCHAR2,
    p_all_columns IN BOOLEAN DEFAULT TRUE
  ) RETURN CLOB;

  -- One Markdown data dictionary for a whole schema: contents, an ERD of
  -- all its tables (key columns only), then for each table its comment,
  -- primary key, columns and foreign keys.  The output has no timestamp,
  -- so it can be kept in version control and diffed.
  FUNCTION schema_dictionary(
    p_schema      IN VARCHAR2 DEFAULT NULL,
    p_include_erd IN BOOLEAN  DEFAULT TRUE
  ) RETURN CLOB;

  -- Print wrappers: the functions above, sent to DBMS_OUTPUT

  PROCEDURE format_query_as_table(
    p_query     IN VARCHAR2,
    p_format    IN VARCHAR2 DEFAULT 'md',
    p_max_width IN NUMBER   DEFAULT 100
  );

  PROCEDURE print_table_comments(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2
  );

  PROCEDURE print_table_columns(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2,
    p_format     IN VARCHAR2 DEFAULT 'md'
  );

  PROCEDURE print_table_foreign_keys(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2,
    p_format     IN VARCHAR2 DEFAULT 'md'
  );

  PROCEDURE audit_schema_comments(
    p_schema         IN VARCHAR2 DEFAULT NULL,
    p_include_detail IN BOOLEAN  DEFAULT FALSE
  );

  PROCEDURE generate_mermaid_erd(
    p_table_list  IN VARCHAR2,
    p_all_columns IN BOOLEAN DEFAULT TRUE
  );

  PROCEDURE print_schema_dictionary(
    p_schema      IN VARCHAR2 DEFAULT NULL,
    p_include_erd IN BOOLEAN  DEFAULT TRUE
  );

  -- Send a CLOB to DBMS_OUTPUT, one line per line
  PROCEDURE print_clob(p_text IN CLOB);

END doc_util;
/
