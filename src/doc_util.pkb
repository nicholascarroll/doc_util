CREATE OR REPLACE PACKAGE BODY doc_util AS

  c_nl CONSTANT VARCHAR2(1) := CHR(10);

  TYPE t_table_ref IS RECORD (
    owner      VARCHAR2(128),
    table_name VARCHAR2(128)
  );
  TYPE t_table_refs IS TABLE OF t_table_ref;
  TYPE t_strings IS TABLE OF VARCHAR2(4000);

  -- the columns and foreign keys of table :o.:t, for render_table_query
  c_columns_sql CONSTANT VARCHAR2(4000) := q'[
    SELECT c.column_name "Column Name",
           c.data_type ||
             CASE
               WHEN c.data_type IN ('VARCHAR2', 'NVARCHAR2', 'CHAR', 'NCHAR') THEN
                 '(' || c.char_length || CASE WHEN c.char_used = 'C' AND c.data_type IN ('VARCHAR2', 'CHAR') THEN ' CHAR' END || ')'
               WHEN c.data_type = 'RAW' THEN '(' || c.data_length || ')'
               WHEN c.data_type = 'NUMBER' AND c.data_precision IS NOT NULL THEN
                 '(' || c.data_precision || CASE WHEN c.data_scale > 0 THEN ',' || c.data_scale END || ')'
             END "Data Type",
           CASE c.nullable WHEN 'Y' THEN 'Yes' ELSE 'No' END "Nullable",
           cc.comments "Comments"
    FROM all_tab_columns c
    LEFT JOIN all_col_comments cc
      ON cc.owner = c.owner AND cc.table_name = c.table_name AND cc.column_name = c.column_name
    WHERE c.owner = :o AND c.table_name = :t
    ORDER BY c.column_id]';

  c_foreign_keys_sql CONSTANT VARCHAR2(4000) := q'[
    SELECT c.constraint_name "Constraint Name",
           r.owner || '.' || r.table_name "Referenced Table",
           (SELECT LISTAGG(cc.column_name, ', ') WITHIN GROUP (ORDER BY cc.position)
            FROM all_cons_columns cc
            WHERE cc.owner = c.owner AND cc.constraint_name = c.constraint_name) "Columns",
           (SELECT LISTAGG(rc.column_name, ', ') WITHIN GROUP (ORDER BY rc.position)
            FROM all_cons_columns rc
            WHERE rc.owner = c.r_owner AND rc.constraint_name = c.r_constraint_name) "Referenced Columns"
    FROM all_constraints c
    JOIN all_constraints r ON r.owner = c.r_owner AND r.constraint_name = c.r_constraint_name
    WHERE c.owner = :o AND c.table_name = :t AND c.constraint_type = 'R'
    ORDER BY c.constraint_name]';

  ------------------------------------------------------------------------
  -- building documents

  FUNCTION new_doc RETURN CLOB IS
    l_out CLOB;
  BEGIN
    DBMS_LOB.CREATETEMPORARY(l_out, TRUE);
    RETURN l_out;
  END new_doc;

  -- Append one line (and a newline) to P_OUT
  PROCEDURE put(p_out IN OUT NOCOPY CLOB, p_line IN VARCHAR2 DEFAULT NULL) IS
    l_text VARCHAR2(32767) := p_line || c_nl;
  BEGIN
    DBMS_LOB.WRITEAPPEND(p_out, LENGTH(l_text), l_text);
  END put;

  -- Append a whole document to P_OUT
  PROCEDURE put_doc(p_out IN OUT NOCOPY CLOB, p_doc IN CLOB) IS
  BEGIN
    IF p_doc IS NOT NULL AND DBMS_LOB.GETLENGTH(p_doc) > 0 THEN
      DBMS_LOB.APPEND(p_out, p_doc);
    END IF;
  END put_doc;

  -- Append P_TEXT wrapped at P_WIDTH characters, breaking at spaces
  PROCEDURE put_wrapped(p_out IN OUT NOCOPY CLOB, p_text IN VARCHAR2, p_width IN NUMBER DEFAULT 100) IS
    l_text VARCHAR2(32767) := TRIM(REPLACE(REPLACE(p_text, CHR(13), ' '), c_nl, ' '));
    l_pos  PLS_INTEGER;
  BEGIN
    WHILE LENGTH(l_text) > 0 LOOP
      IF LENGTH(l_text) <= p_width THEN
        put(p_out, l_text);
        EXIT;
      END IF;
      l_pos := INSTR(SUBSTR(l_text, 1, p_width + 1), ' ', -1);
      IF l_pos <= 1 THEN
        l_pos := p_width + 1;               -- no space: break inside the word
        put(p_out, SUBSTR(l_text, 1, p_width));
      ELSE
        put(p_out, RTRIM(SUBSTR(l_text, 1, l_pos - 1)));
      END IF;
      l_text := LTRIM(SUBSTR(l_text, l_pos));
    END LOOP;
  END put_wrapped;

  ------------------------------------------------------------------------
  -- names

  FUNCTION check_format(p_format IN VARCHAR2) RETURN VARCHAR2 IS
    l_format VARCHAR2(10) := LOWER(NVL(p_format, 'md'));
  BEGIN
    IF l_format NOT IN ('md', 'org') THEN
      RAISE_APPLICATION_ERROR(-20004, 'Unknown format ' || p_format || ': use md or org');
    END IF;
    RETURN l_format;
  END check_format;

  FUNCTION table_visible(p_owner IN VARCHAR2, p_table_name IN VARCHAR2) RETURN BOOLEAN IS
    l_count PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_count
    FROM all_tables
    WHERE owner = p_owner AND table_name = p_table_name;
    RETURN l_count > 0;
  END table_visible;

  -- The schema P_SCHEMA names: the current schema when NULL, the name as
  -- given when such a user exists, otherwise in upper case
  FUNCTION resolve_schema(p_schema IN VARCHAR2) RETURN VARCHAR2 IS
    l_count PLS_INTEGER;
  BEGIN
    IF p_schema IS NULL THEN
      RETURN SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    END IF;
    SELECT COUNT(*) INTO l_count FROM all_users WHERE username = p_schema;
    RETURN CASE WHEN l_count > 0 THEN p_schema ELSE UPPER(p_schema) END;
  END resolve_schema;

  FUNCTION resolve_table(p_schema IN VARCHAR2, p_table_name IN VARCHAR2) RETURN t_table_ref IS
    l_ref t_table_ref;
  BEGIN
    l_ref.owner := resolve_schema(p_schema);
    IF table_visible(l_ref.owner, p_table_name) THEN
      l_ref.table_name := p_table_name;
    ELSIF table_visible(l_ref.owner, UPPER(p_table_name)) THEN
      l_ref.table_name := UPPER(p_table_name);
    ELSE
      RAISE_APPLICATION_ERROR(-20001, 'Table ' || l_ref.owner || '.' || p_table_name || ' not found');
    END IF;
    RETURN l_ref;
  END resolve_table;

  -- An unqualified name: the current schema first, then a unique match in
  -- any schema
  FUNCTION find_table(p_table_name IN VARCHAR2) RETURN t_table_ref IS
    l_ref     t_table_ref;
    l_current VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
    l_owners  t_strings;
  BEGIN
    FOR l_name IN (SELECT p_table_name AS n FROM dual UNION ALL SELECT UPPER(p_table_name) FROM dual) LOOP
      IF table_visible(l_current, l_name.n) THEN
        l_ref.owner := l_current;
        l_ref.table_name := l_name.n;
        RETURN l_ref;
      END IF;
    END LOOP;
    FOR l_name IN (SELECT p_table_name AS n FROM dual UNION ALL SELECT UPPER(p_table_name) FROM dual) LOOP
      SELECT owner BULK COLLECT INTO l_owners
      FROM all_tables WHERE table_name = l_name.n ORDER BY owner;
      IF l_owners.COUNT = 1 THEN
        l_ref.owner := l_owners(1);
        l_ref.table_name := l_name.n;
        RETURN l_ref;
      ELSIF l_owners.COUNT > 1 THEN
        DECLARE
          l_list VARCHAR2(4000);
        BEGIN
          FOR i IN 1 .. l_owners.COUNT LOOP
            l_list := l_list || CASE WHEN i > 1 THEN ', ' END || l_owners(i);
          END LOOP;
          RAISE_APPLICATION_ERROR(-20002, 'Table ' || l_name.n || ' exists in more than one schema: ' || l_list);
        END;
      END IF;
    END LOOP;
    RAISE_APPLICATION_ERROR(-20001, 'Table ' || p_table_name || ' not found');
  END find_table;

  -- The tables a whole-schema document covers: real tables only, no
  -- nested, overflow, secondary or dropped ones
  FUNCTION schema_tables(p_owner IN VARCHAR2) RETURN t_table_refs IS
    l_refs t_table_refs;
  BEGIN
    SELECT owner, table_name BULK COLLECT INTO l_refs
    FROM all_tables
    WHERE owner = p_owner
      AND nested = 'NO'
      AND secondary = 'N'
      AND dropped = 'NO'
      AND (iot_type IS NULL OR iot_type = 'IOT')
    ORDER BY table_name;
    RETURN l_refs;
  END schema_tables;

  FUNCTION pk_columns(p_ref IN t_table_ref) RETURN VARCHAR2 IS
    l_cols VARCHAR2(4000);
  BEGIN
    SELECT LISTAGG(cc.column_name, ', ') WITHIN GROUP (ORDER BY cc.position)
    INTO l_cols
    FROM all_constraints c
    JOIN all_cons_columns cc ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
    WHERE c.owner = p_ref.owner AND c.table_name = p_ref.table_name AND c.constraint_type = 'P';
    RETURN l_cols;
  END pk_columns;

  ------------------------------------------------------------------------
  -- tables of rows

  FUNCTION cell(p_value IN VARCHAR2, p_format IN VARCHAR2) RETURN VARCHAR2 IS
    l_value VARCHAR2(4000) := REPLACE(REPLACE(p_value, CHR(13), ' '), c_nl, ' ');
  BEGIN
    RETURN CASE p_format
             WHEN 'md' THEN REPLACE(l_value, '|', '\|')
             ELSE REPLACE(l_value, '|', '\vert{}')
           END;
  END cell;

  -- Execute the parsed (and bound) DBMS_SQL cursor P_CUR, render its rows,
  -- and close it
  FUNCTION render_cursor(
    p_cur       IN OUT INTEGER,
    p_format    IN VARCHAR2,
    p_max_width IN NUMBER
  ) RETURN CLOB IS
    TYPE t_widths IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;
    l_out       CLOB := new_doc;
    l_format    VARCHAR2(10) := check_format(p_format);
    l_desc      DBMS_SQL.DESC_TAB2;
    l_col_cnt   INTEGER;
    l_value     VARCHAR2(4000);
    l_cells     t_strings := t_strings();
    l_heads     t_strings := t_strings();
    l_widths    t_widths;
    l_rows      PLS_INTEGER := 0;
    l_visible   PLS_INTEGER := 0;
    l_total     PLS_INTEGER := 1;
    l_truncated BOOLEAN := FALSE;
    l_line      VARCHAR2(32767);
    l_ignore    INTEGER;
  BEGIN
    DBMS_SQL.DESCRIBE_COLUMNS2(p_cur, l_col_cnt, l_desc);
    FOR i IN 1 .. l_col_cnt LOOP
      DBMS_SQL.DEFINE_COLUMN(p_cur, i, l_value, 4000);
      l_heads.EXTEND;
      l_heads(i) := cell(l_desc(i).col_name, l_format);
      l_widths(i) := GREATEST(NVL(LENGTH(l_heads(i)), 0), 1);
    END LOOP;
    l_ignore := DBMS_SQL.EXECUTE(p_cur);
    WHILE DBMS_SQL.FETCH_ROWS(p_cur) > 0 LOOP
      l_rows := l_rows + 1;
      FOR i IN 1 .. l_col_cnt LOOP
        DBMS_SQL.COLUMN_VALUE(p_cur, i, l_value);
        l_cells.EXTEND;
        l_cells(l_cells.COUNT) := cell(l_value, l_format);
        l_widths(i) := GREATEST(l_widths(i), NVL(LENGTH(l_cells(l_cells.COUNT)), 0));
      END LOOP;
    END LOOP;
    DBMS_SQL.CLOSE_CURSOR(p_cur);

    IF l_rows = 0 THEN
      put(l_out, 'No rows returned by the query.');
      RETURN l_out;
    END IF;

    -- as many columns as fit, at least one; a '?' column marks the rest
    FOR i IN 1 .. l_col_cnt LOOP
      l_total := l_total + l_widths(i) + 3;
      EXIT WHEN l_total > p_max_width;
      l_visible := i;
    END LOOP;
    l_visible := GREATEST(l_visible, 1);
    l_truncated := l_visible < l_col_cnt;

    l_line := '|';
    FOR i IN 1 .. l_visible LOOP
      l_line := l_line || ' ' || RPAD(l_heads(i), l_widths(i)) || ' |';
    END LOOP;
    IF l_truncated THEN l_line := l_line || ' ? |'; END IF;
    put(l_out, l_line);

    l_line := '|';
    FOR i IN 1 .. l_visible LOOP
      l_line := l_line || RPAD('-', l_widths(i) + 2, '-')
                       || CASE WHEN l_format = 'org' AND (i < l_visible OR l_truncated) THEN '+' ELSE '|' END;
    END LOOP;
    IF l_truncated THEN l_line := l_line || '---|'; END IF;
    put(l_out, l_line);

    FOR r IN 0 .. l_rows - 1 LOOP
      l_line := '|';
      FOR i IN 1 .. l_visible LOOP
        l_line := l_line || ' ' || RPAD(NVL(l_cells(r * l_col_cnt + i), ' '), l_widths(i)) || ' |';
      END LOOP;
      IF l_truncated THEN l_line := l_line || ' ? |'; END IF;
      put(l_out, l_line);
    END LOOP;
    RETURN l_out;
  EXCEPTION
    WHEN OTHERS THEN
      IF DBMS_SQL.IS_OPEN(p_cur) THEN
        DBMS_SQL.CLOSE_CURSOR(p_cur);
      END IF;
      RAISE;
  END render_cursor;

  -- Render P_SQL with :o and :t bound to the table's owner and name
  FUNCTION render_table_query(
    p_sql    IN VARCHAR2,
    p_ref    IN t_table_ref,
    p_format IN VARCHAR2
  ) RETURN CLOB IS
    l_cur INTEGER := DBMS_SQL.OPEN_CURSOR;
  BEGIN
    DBMS_SQL.PARSE(l_cur, p_sql, DBMS_SQL.NATIVE);
    DBMS_SQL.BIND_VARIABLE(l_cur, ':o', p_ref.owner);
    DBMS_SQL.BIND_VARIABLE(l_cur, ':t', p_ref.table_name);
    RETURN render_cursor(l_cur, p_format, 32767);
  EXCEPTION
    WHEN OTHERS THEN
      IF DBMS_SQL.IS_OPEN(l_cur) THEN
        DBMS_SQL.CLOSE_CURSOR(l_cur);
      END IF;
      RAISE;
  END render_table_query;



  FUNCTION foreign_key_count(p_ref IN t_table_ref) RETURN PLS_INTEGER IS
    l_count PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO l_count
    FROM all_constraints
    WHERE owner = p_ref.owner AND table_name = p_ref.table_name AND constraint_type = 'R';
    RETURN l_count;
  END foreign_key_count;

  FUNCTION table_comment(p_ref IN t_table_ref) RETURN VARCHAR2 IS
    l_comment VARCHAR2(4000);
  BEGIN
    SELECT MAX(comments) INTO l_comment
    FROM all_tab_comments
    WHERE owner = p_ref.owner AND table_name = p_ref.table_name;
    RETURN TRIM(l_comment);
  END table_comment;

  FUNCTION heading(p_text IN VARCHAR2, p_format IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE p_format WHEN 'org' THEN '*' || p_text || '*' ELSE '**' || p_text || '**' END;
  END heading;

  ------------------------------------------------------------------------
  -- public functions

  FUNCTION format_query(
    p_query     IN VARCHAR2,
    p_format    IN VARCHAR2 DEFAULT 'md',
    p_max_width IN NUMBER   DEFAULT 100
  ) RETURN CLOB IS
    l_format VARCHAR2(10) := check_format(p_format);
    l_cur    INTEGER := DBMS_SQL.OPEN_CURSOR;
  BEGIN
    DBMS_SQL.PARSE(l_cur, p_query, DBMS_SQL.NATIVE);
    RETURN render_cursor(l_cur, l_format, p_max_width);
  EXCEPTION
    WHEN OTHERS THEN
      IF DBMS_SQL.IS_OPEN(l_cur) THEN
        DBMS_SQL.CLOSE_CURSOR(l_cur);
      END IF;
      RAISE;
  END format_query;

  FUNCTION table_comments(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2
  ) RETURN CLOB IS
    l_ref     t_table_ref := resolve_table(p_schema, p_table_name);
    l_out     CLOB := new_doc;
    l_comment VARCHAR2(4000) := table_comment(l_ref);
  BEGIN
    put(l_out, '**Table Comments**');
    put(l_out);
    IF l_comment IS NULL THEN
      put(l_out, 'No comments available for this table.');
    ELSE
      put_wrapped(l_out, l_comment);
    END IF;
    RETURN l_out;
  END table_comments;

  FUNCTION table_columns(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2,
    p_format     IN VARCHAR2 DEFAULT 'md'
  ) RETURN CLOB IS
    l_format VARCHAR2(10) := check_format(p_format);
    l_ref    t_table_ref := resolve_table(p_schema, p_table_name);
    l_out    CLOB := new_doc;
  BEGIN
    put(l_out, heading('Column Information', l_format));
    put(l_out);
    put_doc(l_out, render_table_query(c_columns_sql, l_ref, l_format));
    RETURN l_out;
  END table_columns;

  FUNCTION table_foreign_keys(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2,
    p_format     IN VARCHAR2 DEFAULT 'md'
  ) RETURN CLOB IS
    l_format VARCHAR2(10) := check_format(p_format);
    l_ref    t_table_ref := resolve_table(p_schema, p_table_name);
    l_out    CLOB := new_doc;
  BEGIN
    put(l_out, heading('Foreign Key Relationships', l_format));
    put(l_out);
    IF foreign_key_count(l_ref) = 0 THEN
      put(l_out, 'No foreign key constraints defined for this table.');
    ELSE
      put_doc(l_out, render_table_query(c_foreign_keys_sql, l_ref, l_format));
    END IF;
    RETURN l_out;
  END table_foreign_keys;

  FUNCTION pct(p_part IN NUMBER, p_whole IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(CASE WHEN p_whole > 0 THEN ROUND(p_part / p_whole * 100, 1) ELSE 0 END,
                   'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''') || '%';
  END pct;

  FUNCTION schema_comment_audit(
    p_schema         IN VARCHAR2 DEFAULT NULL,
    p_include_detail IN BOOLEAN  DEFAULT FALSE
  ) RETURN CLOB IS
    l_owner          VARCHAR2(128) := resolve_schema(p_schema);
    l_tables         t_table_refs := schema_tables(l_owner);
    l_out            CLOB := new_doc;
    l_commented      PLS_INTEGER := 0;
    l_columns        PLS_INTEGER := 0;
    l_cols_commented PLS_INTEGER := 0;
    l_n              PLS_INTEGER;
    l_c              PLS_INTEGER;
    l_any            BOOLEAN;
  BEGIN
    FOR i IN 1 .. l_tables.COUNT LOOP
      IF table_comment(l_tables(i)) IS NOT NULL THEN
        l_commented := l_commented + 1;
      END IF;
      SELECT COUNT(*), COUNT(TRIM(cc.comments)) INTO l_n, l_c
      FROM all_tab_columns c
      LEFT JOIN all_col_comments cc
        ON cc.owner = c.owner AND cc.table_name = c.table_name AND cc.column_name = c.column_name
      WHERE c.owner = l_tables(i).owner AND c.table_name = l_tables(i).table_name;
      l_columns := l_columns + l_n;
      l_cols_commented := l_cols_commented + l_c;
    END LOOP;

    put(l_out, '**Schema Documentation Audit: ' || l_owner || '**');
    put(l_out);
    put(l_out, '### Summary');
    put(l_out);
    put(l_out, '| Metric | Count | Percentage |');
    put(l_out, '|--------|-------|------------|');
    put(l_out, '| Tables with comments | ' || l_commented || ' of ' || l_tables.COUNT || ' | '
               || pct(l_commented, l_tables.COUNT) || ' |');
    put(l_out, '| Columns with comments | ' || l_cols_commented || ' of ' || l_columns || ' | '
               || pct(l_cols_commented, l_columns) || ' |');

    IF p_include_detail THEN
      put(l_out);
      put(l_out, '### Tables Without Comments (' || (l_tables.COUNT - l_commented) || ' tables)');
      put(l_out);
      l_any := FALSE;
      FOR i IN 1 .. l_tables.COUNT LOOP
        IF table_comment(l_tables(i)) IS NULL THEN
          put(l_out, '- ' || l_tables(i).table_name);
          l_any := TRUE;
        END IF;
      END LOOP;
      IF NOT l_any THEN put(l_out, 'None.'); END IF;

      put(l_out);
      put(l_out, '### Tables With Undocumented Columns');
      l_any := FALSE;
      FOR i IN 1 .. l_tables.COUNT LOOP
        SELECT COUNT(*), COUNT(TRIM(cc.comments)) INTO l_n, l_c
        FROM all_tab_columns c
        LEFT JOIN all_col_comments cc
          ON cc.owner = c.owner AND cc.table_name = c.table_name AND cc.column_name = c.column_name
        WHERE c.owner = l_tables(i).owner AND c.table_name = l_tables(i).table_name;
        IF l_c < l_n THEN
          l_any := TRUE;
          put(l_out);
          put(l_out, '#### ' || l_tables(i).table_name || ' (' || l_c || ' of ' || l_n
                     || ' columns documented, ' || pct(l_c, l_n) || ')');
          put(l_out);
          FOR c IN (SELECT c.column_name
                    FROM all_tab_columns c
                    LEFT JOIN all_col_comments cc
                      ON cc.owner = c.owner AND cc.table_name = c.table_name AND cc.column_name = c.column_name
                    WHERE c.owner = l_tables(i).owner AND c.table_name = l_tables(i).table_name
                      AND TRIM(cc.comments) IS NULL
                    ORDER BY c.column_id) LOOP
            put(l_out, '- ' || c.column_name);
          END LOOP;
        END IF;
      END LOOP;
      IF NOT l_any THEN
        put(l_out);
        put(l_out, 'None.');
      END IF;
    END IF;
    RETURN l_out;
  END schema_comment_audit;

  ------------------------------------------------------------------------
  -- Mermaid

  -- Mermaid names allow letters, digits and underscores
  FUNCTION mermaid_name(p_name IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN REGEXP_REPLACE(p_name, '[^A-Za-z0-9_]', '_');
  END mermaid_name;

  -- TIMESTAMP(6) WITH TIME ZONE -> TIMESTAMP_WITH_TIME_ZONE
  FUNCTION mermaid_type(p_type IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN mermaid_name(REGEXP_REPLACE(REGEXP_REPLACE(p_type, '\([^)]*\)', ''), ' +', ' '));
  END mermaid_type;

  FUNCTION entity_name(p_refs IN t_table_refs, i IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    -- qualify only when two listed tables share a name
    FOR j IN 1 .. p_refs.COUNT LOOP
      IF j <> i AND p_refs(j).table_name = p_refs(i).table_name THEN
        RETURN mermaid_name(p_refs(i).owner || '_' || p_refs(i).table_name);
      END IF;
    END LOOP;
    RETURN mermaid_name(p_refs(i).table_name);
  END entity_name;

  FUNCTION ref_index(p_refs IN t_table_refs, p_owner IN VARCHAR2, p_table_name IN VARCHAR2) RETURN PLS_INTEGER IS
  BEGIN
    FOR i IN 1 .. p_refs.COUNT LOOP
      IF p_refs(i).owner = p_owner AND p_refs(i).table_name = p_table_name THEN
        RETURN i;
      END IF;
    END LOOP;
    RETURN 0;
  END ref_index;

  -- The ```mermaid block for P_REFS
  PROCEDURE put_erd(p_out IN OUT NOCOPY CLOB, p_refs IN t_table_refs, p_all_columns IN BOOLEAN) IS
    l_target PLS_INTEGER;
  BEGIN
    put(p_out, '```mermaid');
    put(p_out, 'erDiagram');
    FOR i IN 1 .. p_refs.COUNT LOOP
      put(p_out, '  ' || entity_name(p_refs, i) || ' {');
      FOR c IN (
        SELECT c.column_name, c.data_type,
               (SELECT COUNT(*) FROM all_constraints k
                JOIN all_cons_columns kc ON kc.owner = k.owner AND kc.constraint_name = k.constraint_name
                WHERE k.owner = c.owner AND k.table_name = c.table_name AND k.constraint_type = 'P'
                  AND kc.column_name = c.column_name) AS is_pk,
               (SELECT COUNT(*) FROM all_constraints k
                JOIN all_cons_columns kc ON kc.owner = k.owner AND kc.constraint_name = k.constraint_name
                WHERE k.owner = c.owner AND k.table_name = c.table_name AND k.constraint_type = 'R'
                  AND kc.column_name = c.column_name) AS is_fk
        FROM all_tab_columns c
        WHERE c.owner = p_refs(i).owner AND c.table_name = p_refs(i).table_name
        ORDER BY c.column_id
      ) LOOP
        IF p_all_columns OR c.is_pk > 0 OR c.is_fk > 0 THEN
          put(p_out, '    ' || mermaid_type(c.data_type) || ' ' || mermaid_name(c.column_name)
                     || CASE
                          WHEN c.is_pk > 0 AND c.is_fk > 0 THEN ' PK, FK'
                          WHEN c.is_pk > 0 THEN ' PK'
                          WHEN c.is_fk > 0 THEN ' FK'
                        END);
        END IF;
      END LOOP;
      put(p_out, '  }');
    END LOOP;

    -- one line per foreign key between listed tables: many children (or
    -- none) to exactly one parent, or to at most one when a key column is
    -- nullable
    FOR i IN 1 .. p_refs.COUNT LOOP
      FOR k IN (
        SELECT c.constraint_name, r.owner AS r_owner, r.table_name AS r_table,
               (SELECT LISTAGG(cc.column_name, ',') WITHIN GROUP (ORDER BY cc.position)
                FROM all_cons_columns cc
                WHERE cc.owner = c.owner AND cc.constraint_name = c.constraint_name) AS cols,
               (SELECT COUNT(*) FROM all_cons_columns cc
                JOIN all_tab_columns tc
                  ON tc.owner = cc.owner AND tc.table_name = cc.table_name AND tc.column_name = cc.column_name
                WHERE cc.owner = c.owner AND cc.constraint_name = c.constraint_name
                  AND tc.nullable = 'Y') AS nullable_cols
        FROM all_constraints c
        JOIN all_constraints r ON r.owner = c.r_owner AND r.constraint_name = c.r_constraint_name
        WHERE c.owner = p_refs(i).owner AND c.table_name = p_refs(i).table_name
          AND c.constraint_type = 'R'
        ORDER BY c.constraint_name
      ) LOOP
        l_target := ref_index(p_refs, k.r_owner, k.r_table);
        IF l_target > 0 THEN
          put(p_out, '  ' || entity_name(p_refs, i)
                     || CASE WHEN k.nullable_cols > 0 THEN ' }o--o| ' ELSE ' }o--|| ' END
                     || entity_name(p_refs, l_target) || ' : "' || k.cols || '"');
        END IF;
      END LOOP;
    END LOOP;
    put(p_out, '```');
  END put_erd;

  FUNCTION mermaid_erd(
    p_table_list  IN VARCHAR2,
    p_all_columns IN BOOLEAN DEFAULT TRUE
  ) RETURN CLOB IS
    l_refs t_table_refs := t_table_refs();
    l_ref  t_table_ref;
    l_item VARCHAR2(400);
    l_dot  PLS_INTEGER;
    l_out  CLOB := new_doc;
  BEGIN
    FOR l_i IN 1 .. NVL(REGEXP_COUNT(p_table_list, '[^,]+'), 0) LOOP
      l_item := TRIM(REGEXP_SUBSTR(p_table_list, '[^,]+', 1, l_i));
      CONTINUE WHEN l_item IS NULL;
      l_dot := INSTR(l_item, '.');
      IF l_dot > 0 THEN
        l_ref := resolve_table(TRIM(SUBSTR(l_item, 1, l_dot - 1)), TRIM(SUBSTR(l_item, l_dot + 1)));
      ELSE
        l_ref := find_table(l_item);
      END IF;
      IF ref_index(l_refs, l_ref.owner, l_ref.table_name) = 0 THEN
        l_refs.EXTEND;
        l_refs(l_refs.COUNT) := l_ref;
      END IF;
    END LOOP;
    IF l_refs.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20003, 'No tables given');
    END IF;

    put(l_out, '**Entity Relationship Diagram**');
    put(l_out);
    put_erd(l_out, l_refs, p_all_columns);
    IF NOT p_all_columns THEN
      put(l_out);
      put(l_out, 'Note: Only primary and foreign key columns are shown in the diagram.');
    END IF;
    RETURN l_out;
  END mermaid_erd;

  ------------------------------------------------------------------------
  -- the whole schema

  -- GitHub's heading anchor for P_TEXT
  FUNCTION anchor(p_text IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN REPLACE(LOWER(REGEXP_REPLACE(p_text, '[^A-Za-z0-9_ -]', '')), ' ', '-');
  END anchor;

  FUNCTION schema_dictionary(
    p_schema      IN VARCHAR2 DEFAULT NULL,
    p_include_erd IN BOOLEAN  DEFAULT TRUE
  ) RETURN CLOB IS
    l_owner   VARCHAR2(128) := resolve_schema(p_schema);
    l_tables  t_table_refs := schema_tables(l_owner);
    l_out     CLOB := new_doc;
    l_comment VARCHAR2(4000);
    l_pk      VARCHAR2(4000);
    l_list    VARCHAR2(4000);
  BEGIN
    put(l_out, '# Data dictionary: ' || l_owner);
    put(l_out);
    IF l_tables.COUNT = 0 THEN
      put(l_out, 'No tables.');
      RETURN l_out;
    END IF;
    put(l_out, l_tables.COUNT || CASE WHEN l_tables.COUNT = 1 THEN ' table.' ELSE ' tables.' END);
    put(l_out);
    put(l_out, '## Contents');
    put(l_out);
    FOR i IN 1 .. l_tables.COUNT LOOP
      put(l_out, '- [' || l_tables(i).table_name || '](#' || anchor(l_tables(i).table_name) || ')');
    END LOOP;

    IF p_include_erd THEN
      put(l_out);
      put(l_out, '## Entity relationship diagram');
      put(l_out);
      put_erd(l_out, l_tables, FALSE);
      put(l_out);
      put(l_out, 'Key columns only; every table''s full column list is below.');
    END IF;

    FOR i IN 1 .. l_tables.COUNT LOOP
      put(l_out);
      put(l_out, '## ' || l_tables(i).table_name);
      put(l_out);
      l_comment := table_comment(l_tables(i));
      IF l_comment IS NULL THEN
        put(l_out, '*No comment.*');
      ELSE
        put_wrapped(l_out, l_comment);
      END IF;
      put(l_out);
      l_pk := pk_columns(l_tables(i));
      put(l_out, CASE WHEN l_pk IS NULL THEN 'No primary key.' ELSE 'Primary key: ' || l_pk || '.' END);
      put(l_out);
      put(l_out, '**Columns**');
      put(l_out);
      put_doc(l_out, render_table_query(c_columns_sql, l_tables(i), 'md'));
      put(l_out);
      put(l_out, '**Foreign keys**');
      put(l_out);
      IF foreign_key_count(l_tables(i)) = 0 THEN
        put(l_out, 'None.');
      ELSE
        put_doc(l_out, render_table_query(c_foreign_keys_sql, l_tables(i), 'md'));
      END IF;

      SELECT LISTAGG(DISTINCT c.owner || '.' || c.table_name, ', ')
               WITHIN GROUP (ORDER BY c.owner || '.' || c.table_name)
      INTO l_list
      FROM all_constraints c
      JOIN all_constraints r ON r.owner = c.r_owner AND r.constraint_name = c.r_constraint_name
      WHERE c.constraint_type = 'R'
        AND r.owner = l_tables(i).owner AND r.table_name = l_tables(i).table_name;
      IF l_list IS NOT NULL THEN
        put(l_out);
        put(l_out, 'Referenced by: ' || l_list || '.');
      END IF;
    END LOOP;
    RETURN l_out;
  END schema_dictionary;

  ------------------------------------------------------------------------
  -- printing

  PROCEDURE print_clob(p_text IN CLOB) IS
    l_len  PLS_INTEGER;
    l_pos  PLS_INTEGER := 1;
    l_next PLS_INTEGER;
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    l_len := DBMS_LOB.GETLENGTH(p_text);
    WHILE l_pos <= l_len LOOP
      l_next := DBMS_LOB.INSTR(p_text, c_nl, l_pos);
      IF l_next = 0 THEN
        DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(p_text, LEAST(l_len - l_pos + 1, 32767), l_pos));
        EXIT;
      END IF;
      DBMS_OUTPUT.PUT_LINE(CASE WHEN l_next > l_pos
                                THEN DBMS_LOB.SUBSTR(p_text, LEAST(l_next - l_pos, 32767), l_pos)
                           END);
      l_pos := l_next + 1;
    END LOOP;
  END print_clob;

  PROCEDURE format_query_as_table(
    p_query     IN VARCHAR2,
    p_format    IN VARCHAR2 DEFAULT 'md',
    p_max_width IN NUMBER   DEFAULT 100
  ) IS
  BEGIN
    print_clob(format_query(p_query, p_format, p_max_width));
  END format_query_as_table;

  PROCEDURE print_table_comments(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2
  ) IS
  BEGIN
    print_clob(table_comments(p_schema, p_table_name));
  END print_table_comments;

  PROCEDURE print_table_columns(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2,
    p_format     IN VARCHAR2 DEFAULT 'md'
  ) IS
  BEGIN
    print_clob(table_columns(p_schema, p_table_name, p_format));
  END print_table_columns;

  PROCEDURE print_table_foreign_keys(
    p_schema     IN VARCHAR2 DEFAULT NULL,
    p_table_name IN VARCHAR2,
    p_format     IN VARCHAR2 DEFAULT 'md'
  ) IS
  BEGIN
    print_clob(table_foreign_keys(p_schema, p_table_name, p_format));
  END print_table_foreign_keys;

  PROCEDURE audit_schema_comments(
    p_schema         IN VARCHAR2 DEFAULT NULL,
    p_include_detail IN BOOLEAN  DEFAULT FALSE
  ) IS
  BEGIN
    print_clob(schema_comment_audit(p_schema, p_include_detail));
  END audit_schema_comments;

  PROCEDURE generate_mermaid_erd(
    p_table_list  IN VARCHAR2,
    p_all_columns IN BOOLEAN DEFAULT TRUE
  ) IS
  BEGIN
    print_clob(mermaid_erd(p_table_list, p_all_columns));
  END generate_mermaid_erd;

  PROCEDURE print_schema_dictionary(
    p_schema      IN VARCHAR2 DEFAULT NULL,
    p_include_erd IN BOOLEAN  DEFAULT TRUE
  ) IS
  BEGIN
    print_clob(schema_dictionary(p_schema, p_include_erd));
  END print_schema_dictionary;

END doc_util;
/
