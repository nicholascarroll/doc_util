-- Run as DOCTEST after setup.sql, install.sql (as DOCTOOLS) and fixture.sql.
-- Prints one line per check, then fails (exit status 1) if any check failed.
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF
SET LINESIZE 32767
SET TRIMOUT ON
WHENEVER SQLERROR EXIT FAILURE

VARIABLE failed NUMBER

DECLARE
  c_nl CONSTANT VARCHAR2(1) := CHR(10);
  TYPE t_lines IS TABLE OF VARCHAR2(32767);
  g_report t_lines := t_lines();
  g_run    PLS_INTEGER := 0;
  g_failed PLS_INTEGER := 0;
  l        CLOB;
  l2       CLOB;

  PROCEDURE report(p_line IN VARCHAR2) IS
  BEGIN
    g_report.EXTEND;
    g_report(g_report.COUNT) := p_line;
  END report;

  -- On failure the document is reported too, so CI logs show what came out
  PROCEDURE assert_true(p_ok IN BOOLEAN, p_name IN VARCHAR2, p_detail IN VARCHAR2 DEFAULT NULL,
                        p_doc IN CLOB DEFAULT NULL) IS
  BEGIN
    g_run := g_run + 1;
    IF NVL(p_ok, FALSE) THEN
      report('ok   ' || p_name);
    ELSE
      g_failed := g_failed + 1;
      report('FAIL ' || p_name || CASE WHEN p_detail IS NOT NULL THEN ': ' || p_detail END);
      IF p_doc IS NOT NULL THEN
        report('---- output ----' || c_nl || DBMS_LOB.SUBSTR(p_doc, 4000, 1) || c_nl || '----------------');
      END IF;
    END IF;
  END assert_true;

  FUNCTION has_line(p_doc IN CLOB, p_line IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN DBMS_LOB.INSTR(c_nl || p_doc, c_nl || p_line || c_nl) > 0;
  END has_line;

  PROCEDURE assert_line(p_doc IN CLOB, p_line IN VARCHAR2, p_name IN VARCHAR2) IS
  BEGIN
    assert_true(has_line(p_doc, p_line), p_name, 'no line "' || p_line || '"', p_doc);
  END assert_line;

  PROCEDURE assert_contains(p_doc IN CLOB, p_text IN VARCHAR2, p_name IN VARCHAR2) IS
  BEGIN
    assert_true(DBMS_LOB.INSTR(p_doc, p_text) > 0, p_name, 'no "' || p_text || '"', p_doc);
  END assert_contains;

  PROCEDURE assert_lacks(p_doc IN CLOB, p_text IN VARCHAR2, p_name IN VARCHAR2) IS
  BEGIN
    assert_true(DBMS_LOB.INSTR(p_doc, p_text) = 0, p_name, 'unexpected "' || p_text || '"', p_doc);
  END assert_lacks;

  PROCEDURE assert_equals(p_doc IN CLOB, p_expected IN VARCHAR2, p_name IN VARCHAR2) IS
  BEGIN
    assert_true(DBMS_LOB.GETLENGTH(p_doc) = LENGTH(p_expected)
                AND DBMS_LOB.SUBSTR(p_doc, 32767, 1) = p_expected,
                p_name, 'expected' || c_nl || p_expected, p_doc);
  END assert_equals;

  PROCEDURE assert_starts(p_doc IN CLOB, p_expected IN VARCHAR2, p_name IN VARCHAR2) IS
  BEGIN
    assert_true(DBMS_LOB.SUBSTR(p_doc, LENGTH(p_expected), 1) = p_expected,
                p_name, 'expected to start with' || c_nl || p_expected, p_doc);
  END assert_starts;

  -- P_PATTERN is matched line by line (^ and $ are line ends)
  PROCEDURE assert_matches(p_doc IN CLOB, p_pattern IN VARCHAR2, p_name IN VARCHAR2) IS
  BEGIN
    assert_true(REGEXP_LIKE(p_doc, p_pattern, 'm'), p_name, 'nothing matches ' || p_pattern, p_doc);
  END assert_matches;

  -- True when P_FIRST occurs, and before P_SECOND
  FUNCTION before(p_doc IN CLOB, p_first IN VARCHAR2, p_second IN VARCHAR2) RETURN BOOLEAN IS
    l_a PLS_INTEGER := DBMS_LOB.INSTR(p_doc, p_first);
    l_b PLS_INTEGER := DBMS_LOB.INSTR(p_doc, p_second);
  BEGIN
    RETURN l_a > 0 AND l_b > l_a;
  END before;

  FUNCTION occurrences(p_doc IN CLOB, p_text IN VARCHAR2) RETURN PLS_INTEGER IS
    l_n PLS_INTEGER := 0;
  BEGIN
    WHILE DBMS_LOB.INSTR(p_doc, p_text, 1, l_n + 1) > 0 LOOP
      l_n := l_n + 1;
    END LOOP;
    RETURN l_n;
  END occurrences;

  -- The lengths of P_DOC's lines that start with '|' are all the same
  FUNCTION table_aligned(p_doc IN CLOB) RETURN BOOLEAN IS
    l_pos  PLS_INTEGER := 1;
    l_next PLS_INTEGER;
    l_line VARCHAR2(32767);
    l_len  PLS_INTEGER;
  BEGIN
    LOOP
      l_next := DBMS_LOB.INSTR(p_doc, c_nl, l_pos);
      EXIT WHEN l_next = 0;
      l_line := DBMS_LOB.SUBSTR(p_doc, l_next - l_pos, l_pos);
      IF l_line LIKE '|%' THEN
        IF l_len IS NULL THEN
          l_len := LENGTH(l_line);
        ELSIF LENGTH(l_line) <> l_len THEN
          RETURN FALSE;
        END IF;
      END IF;
      l_pos := l_next + 1;
    END LOOP;
    RETURN l_len IS NOT NULL;
  END table_aligned;

  FUNCTION longest_line(p_doc IN CLOB) RETURN PLS_INTEGER IS
    l_pos  PLS_INTEGER := 1;
    l_next PLS_INTEGER;
    l_max  PLS_INTEGER := 0;
  BEGIN
    LOOP
      l_next := DBMS_LOB.INSTR(p_doc, c_nl, l_pos);
      EXIT WHEN l_next = 0;
      l_max := GREATEST(l_max, l_next - l_pos);
      l_pos := l_next + 1;
    END LOOP;
    RETURN l_max;
  END longest_line;

  -- What a print_ procedure sent to DBMS_OUTPUT, as one text with newlines
  FUNCTION captured RETURN CLOB IS
    l_lines DBMSOUTPUT_LINESARRAY;
    l_count INTEGER := 100000;
    l_out   CLOB;
  BEGIN
    DBMS_LOB.CREATETEMPORARY(l_out, TRUE);
    DBMS_OUTPUT.GET_LINES(l_lines, l_count);
    FOR i IN 1 .. l_count LOOP
      DBMS_LOB.WRITEAPPEND(l_out, NVL(LENGTH(l_lines(i)), 0) + 1, l_lines(i) || c_nl);
    END LOOP;
    RETURN l_out;
  END captured;

  -- Called from an exception handler with its SQLCODE and SQLERRM
  PROCEDURE assert_error(p_sqlcode IN NUMBER, p_sqlerrm IN VARCHAR2, p_code IN NUMBER, p_name IN VARCHAR2) IS
  BEGIN
    assert_true(p_sqlcode = p_code, p_name, 'got ' || p_sqlerrm);
  END assert_error;

BEGIN
  ------------------------------------------------------------------------
  -- format_query

  l := doc_util.format_query('SELECT 1 AS n, ''a|b'' AS s, CAST(NULL AS VARCHAR2(1)) AS z FROM dual');
  assert_equals(l, '| N | S    | Z |' || c_nl || '|---|------|---|' || c_nl || '| 1 | a\|b |   |' || c_nl,
                'format_query: exact Markdown, pipes escaped, NULL blank');
  assert_true(table_aligned(l), 'format_query: lines aligned');

  l := doc_util.format_query('SELECT 1 AS n, 2 AS m FROM dual', 'org');
  assert_line(l, '|---+---|', 'format_query: Org separator');
  l := doc_util.format_query('SELECT 1 AS n FROM dual', 'ORG');
  assert_line(l, '|---|', 'format_query: format is case-insensitive');

  l := doc_util.format_query('SELECT 1 FROM dual WHERE 1 = 0');
  assert_equals(l, 'No rows returned by the query.' || c_nl, 'format_query: no rows');

  l := doc_util.format_query('SELECT level AS n FROM dual CONNECT BY level <= 3');
  assert_true(before(l, '| 1 |', '| 2 |') AND before(l, '| 2 |', '| 3 |'), 'format_query: rows in order', NULL, l);

  l := doc_util.format_query('SELECT ''a'' || CHR(10) || ''b'' AS s FROM dual');
  assert_line(l, '| a b |', 'format_query: newlines in values become spaces');

  l := doc_util.format_query('SELECT RPAD(''x'', 30, ''x'') AS a, RPAD(''y'', 30, ''y'') AS b, 1 AS c FROM dual', 'md', 50);
  assert_line(l, '| A                              | ? |', 'format_query: columns past the width become ?');
  assert_line(l, '|--------------------------------|---|', 'format_query: separator for ?');
  assert_lacks(l, 'yyy', 'format_query: hidden column not shown');

  l := doc_util.format_query('SELECT 1 AS a, 2 AS b FROM dual', 'md', 3);
  assert_line(l, '| A | ? |', 'format_query: at least one column');

  BEGIN
    l := doc_util.format_query('SELECT 1 FROM dual', 'html');
    assert_true(FALSE, 'format_query: unknown format raises ORA-20004', 'no error');
  EXCEPTION WHEN OTHERS THEN assert_error(SQLCODE, SQLERRM, -20004, 'format_query: unknown format raises ORA-20004');
  END;

  BEGIN
    l := doc_util.format_query('SELECT * FROM no_such_table');
    assert_true(FALSE, 'format_query: bad SQL raises', 'no error');
  EXCEPTION WHEN OTHERS THEN assert_error(SQLCODE, SQLERRM, -942, 'format_query: bad SQL raises its own error');
  END;

  ------------------------------------------------------------------------
  -- table_comments

  l := doc_util.table_comments(NULL, 'DEPARTMENT');
  assert_equals(l, '**Table Comments**' || c_nl || c_nl || 'Academic departments.' || c_nl,
                'table_comments: exact');
  l := doc_util.table_comments('doctest', 'department');
  assert_line(l, 'Academic departments.', 'table_comments: names in lower case');

  l := doc_util.table_comments(NULL, 'COURSE');
  assert_line(l, 'No comments available for this table.', 'table_comments: none');

  l := doc_util.table_comments(NULL, 'STUDENT');
  assert_line(l, 'People enrolled in at least one course. A student may belong to one department, and may have a',
              'table_comments: wrapped, first line');
  assert_line(l, 'mentor, who is another student in a later year.', 'table_comments: wrapped, second line');
  assert_true(longest_line(l) <= 100, 'table_comments: no line over 100', NULL, l);

  l := doc_util.table_comments(NULL, 'Mixed Case');
  assert_line(l, 'No comments available for this table.', 'table_comments: quoted mixed-case name');

  BEGIN
    l := doc_util.table_comments(NULL, 'NO_SUCH_TABLE');
    assert_true(FALSE, 'table_comments: missing table raises ORA-20001', 'no error');
  EXCEPTION WHEN OTHERS THEN
    assert_error(SQLCODE, SQLERRM, -20001, 'table_comments: missing table raises ORA-20001');
    assert_true(INSTR(SQLERRM, 'DOCTEST.NO_SUCH_TABLE') > 0, 'table_comments: the error names the table', SQLERRM);
  END;

  BEGIN
    l := doc_util.table_comments(NULL, 'STUDENT_VIEW');
    assert_true(FALSE, 'table_comments: a view is not a table', 'no error');
  EXCEPTION WHEN OTHERS THEN assert_error(SQLCODE, SQLERRM, -20001, 'table_comments: a view is not a table');
  END;

  ------------------------------------------------------------------------
  -- table_columns

  l := doc_util.table_columns(NULL, 'DEPARTMENT');
  assert_equals(l,
    '**Column Information**' || c_nl || c_nl ||
    '| Column Name | Data Type     | Nullable | Comments                      |' || c_nl ||
    '|-------------|---------------|----------|-------------------------------|' || c_nl ||
    '| DEPT_ID     | NUMBER(6)     | No       | Department number.            |' || c_nl ||
    '| NAME        | VARCHAR2(100) | No       | Name \| shown on transcripts. |' || c_nl ||
    '| BUDGET      | NUMBER(12,2)  | Yes      |                               |' || c_nl,
    'table_columns: exact Markdown');

  l := doc_util.table_columns(NULL, 'DEPARTMENT', 'org');
  assert_starts(l, '*Column Information*' || c_nl, 'table_columns: Org heading');
  assert_matches(l, '^\|-+\+-+\+-+\+-+\|$', 'table_columns: Org separator');
  assert_contains(l, 'Name \vert{} shown on transcripts.', 'table_columns: Org escapes pipes');
  assert_true(table_aligned(l), 'table_columns: Org lines aligned', NULL, l);

  l := doc_util.table_columns(NULL, 'STUDENT');
  assert_matches(l, '^\| GIVEN_NAME +\| VARCHAR2\(50 CHAR\) +\| No +\| Given name\. +\|$', 'table_columns: CHAR semantics');
  assert_matches(l, '^\| ENROLLED_AT +\| TIMESTAMP\(6\) WITH TIME ZONE +\| Yes +\| +\|$', 'table_columns: timestamp type');
  assert_true(before(l, '| STUDENT_ID', '| GIVEN_NAME') AND before(l, '| GIVEN_NAME', '| ENROLLED_AT'),
              'table_columns: in column order', NULL, l);
  assert_true(table_aligned(l), 'table_columns: lines aligned', NULL, l);

  l := doc_util.table_columns(NULL, 'COURSE');
  assert_matches(l, '^\| COURSE_CODE +\| CHAR\(8\) +\| No +\| +\|$', 'table_columns: CHAR');
  l := doc_util.table_columns(NULL, 'GRADE_APPEAL');
  assert_matches(l, '^\| APPEAL_ID +\| NUMBER +\| No +\| Appeal number\. +\|$', 'table_columns: NUMBER without precision');
  l := doc_util.table_columns(NULL, 'Mixed Case');
  assert_matches(l, '^\| odd name +\| VARCHAR2\(10\) +\| Yes +\| +\|$', 'table_columns: quoted column name');

  l := doc_util.table_columns('DOCOTHER', 'OTHER_ONLY');
  assert_matches(l, '^\| LABEL +\| VARCHAR2\(20\)', 'table_columns: another schema the caller can see');

  -- DOC_UTIL's owner has this table, but the caller can't see it
  BEGIN
    l := doc_util.table_columns('DOCTOOLS', 'SECRET');
    assert_true(FALSE, 'table_columns: invoker''s rights hide the owner''s tables', 'no error');
  EXCEPTION WHEN OTHERS THEN assert_error(SQLCODE, SQLERRM, -20001, 'table_columns: invoker''s rights hide the owner''s tables');
  END;

  ------------------------------------------------------------------------
  -- table_foreign_keys

  l := doc_util.table_foreign_keys(NULL, 'ENROLMENT');
  assert_starts(l, '**Foreign Key Relationships**' || c_nl || c_nl, 'table_foreign_keys: heading');
  assert_matches(l, '^\| ENROLMENT_COURSE_FK +\| DOCTEST\.COURSE +\| COURSE_CODE +\| COURSE_CODE +\|$',
                 'table_foreign_keys: one column');
  assert_matches(l, '^\| ENROLMENT_STUDENT_FK +\| DOCTEST\.STUDENT +\| STUDENT_ID +\| STUDENT_ID +\|$',
                 'table_foreign_keys: second key');
  assert_true(before(l, 'ENROLMENT_COURSE_FK', 'ENROLMENT_STUDENT_FK'), 'table_foreign_keys: by name', NULL, l);
  assert_true(table_aligned(l), 'table_foreign_keys: lines aligned', NULL, l);

  l := doc_util.table_foreign_keys(NULL, 'GRADE_APPEAL');
  assert_matches(l, '^\| GRADE_APPEAL_ENROLMENT_FK +\| DOCTEST\.ENROLMENT +\| STUDENT_ID, COURSE_CODE, TERM +\| STUDENT_ID, COURSE_CODE, TERM +\|$',
                 'table_foreign_keys: composite key in order');

  l := doc_util.table_foreign_keys(NULL, 'STUDENT');
  assert_matches(l, '^\| STUDENT_MENTOR_FK +\| DOCTEST\.STUDENT +\| MENTOR_ID +\| STUDENT_ID +\|$',
                 'table_foreign_keys: self-reference');

  l := doc_util.table_foreign_keys(NULL, 'DEPARTMENT');
  assert_equals(l, '**Foreign Key Relationships**' || c_nl || c_nl
                   || 'No foreign key constraints defined for this table.' || c_nl,
                'table_foreign_keys: none');
  l := doc_util.table_foreign_keys(NULL, 'COURSE', 'org');
  assert_starts(l, '*Foreign Key Relationships*' || c_nl, 'table_foreign_keys: Org heading');

  ------------------------------------------------------------------------
  -- schema_comment_audit

  l := doc_util.schema_comment_audit;
  assert_starts(l, '**Schema Documentation Audit: DOCTEST**' || c_nl, 'audit: the caller''s schema by default');
  assert_line(l, '| Tables with comments | 4 of 7 | 57.1% |', 'audit: tables (views excluded)');
  assert_line(l, '| Columns with comments | 10 of 25 | 40% |', 'audit: columns (views excluded)');
  assert_lacks(l, 'Tables Without Comments', 'audit: no detail by default');

  l := doc_util.schema_comment_audit('doctest', TRUE);
  assert_line(l, '### Tables Without Comments (3 tables)', 'audit detail: count');
  assert_line(l, '- COURSE', 'audit detail: COURSE');
  assert_line(l, '- Mixed Case', 'audit detail: Mixed Case');
  assert_line(l, '- NOTES_LOG', 'audit detail: NOTES_LOG');
  assert_line(l, '#### DEPARTMENT (2 of 3 columns documented, 66.7%)', 'audit detail: DEPARTMENT');
  assert_line(l, '- BUDGET', 'audit detail: BUDGET undocumented');
  assert_line(l, '#### STUDENT (3 of 6 columns documented, 50%)', 'audit detail: STUDENT');
  assert_line(l, '- MENTOR_ID', 'audit detail: MENTOR_ID undocumented');
  assert_line(l, '#### Mixed Case (0 of 2 columns documented, 0%)', 'audit detail: Mixed Case');
  assert_lacks(l, '#### GRADE_APPEAL', 'audit detail: fully documented table not listed');
  assert_lacks(l, 'STUDENT_VIEW', 'audit detail: no views');
  -- STUDENT's documented STUDENT_ID is not listed (ENROLMENT's undocumented one is)
  assert_contains(l, '#### STUDENT (3 of 6 columns documented, 50%)' || c_nl || c_nl
                     || '- DEPT_ID' || c_nl || '- MENTOR_ID' || c_nl || '- ENROLLED_AT' || c_nl,
                  'audit detail: documented columns not listed');

  l := doc_util.schema_comment_audit('DOCEMPTY', TRUE);
  assert_line(l, '| Tables with comments | 0 of 0 | 0% |', 'audit: empty schema');
  assert_true(occurrences(l, c_nl || 'None.' || c_nl) = 2, 'audit: empty schema lists None twice', NULL, l);

  ------------------------------------------------------------------------
  -- mermaid_erd

  l := doc_util.mermaid_erd('STUDENT,DEPARTMENT');
  assert_starts(l, '**Entity Relationship Diagram**' || c_nl || c_nl || '```mermaid' || c_nl || 'erDiagram' || c_nl,
                'erd: heading and fence');
  assert_line(l, '  STUDENT {', 'erd: entity');
  assert_line(l, '    NUMBER STUDENT_ID PK', 'erd: primary key');
  assert_line(l, '    VARCHAR2 GIVEN_NAME', 'erd: plain column');
  assert_line(l, '    NUMBER DEPT_ID FK', 'erd: foreign key column');
  assert_line(l, '    TIMESTAMP_WITH_TIME_ZONE ENROLLED_AT', 'erd: type made Mermaid-safe');
  assert_line(l, '  DEPARTMENT {', 'erd: second entity');
  assert_line(l, '  STUDENT }o--o| DEPARTMENT : "DEPT_ID"', 'erd: nullable key is zero-or-one');
  assert_line(l, '  STUDENT }o--o| STUDENT : "MENTOR_ID"', 'erd: self-reference');
  assert_true(before(l, '  STUDENT {', '  DEPARTMENT {'), 'erd: entities in list order', NULL, l);
  assert_lacks(l, 'COURSE', 'erd: unlisted tables left out');
  assert_true(DBMS_LOB.SUBSTR(l, 4, DBMS_LOB.GETLENGTH(l) - 3) = '```' || c_nl, 'erd: fence closed', NULL, l);

  l := doc_util.mermaid_erd('STUDENT,DEPARTMENT', FALSE);
  assert_lacks(l, 'GIVEN_NAME', 'erd keys only: no plain columns');
  assert_line(l, '    NUMBER DEPT_ID FK', 'erd keys only: foreign key column kept');
  assert_line(l, 'Note: Only primary and foreign key columns are shown in the diagram.', 'erd keys only: note');

  l := doc_util.mermaid_erd(' COURSE, ENROLMENT ,grade_appeal ');
  assert_line(l, '    CHAR COURSE_CODE PK, FK', 'erd: column both PK and FK');
  assert_line(l, '  ENROLMENT }o--|| COURSE : "COURSE_CODE"', 'erd: mandatory key is exactly one');
  assert_line(l, '  GRADE_APPEAL }o--|| ENROLMENT : "STUDENT_ID,COURSE_CODE,TERM"', 'erd: composite key');
  assert_line(l, '    NUMBER DEPT_ID FK', 'erd: FK to an unlisted table still marked');
  assert_lacks(l, '|| DEPARTMENT', 'erd: no line to an unlisted table');

  l := doc_util.mermaid_erd('doctest.department');
  assert_line(l, '  DEPARTMENT {', 'erd: qualified, lower case');
  l := doc_util.mermaid_erd('OTHER_ONLY');
  assert_line(l, '  OTHER_ONLY {', 'erd: unique match in another schema');
  assert_line(l, '    VARCHAR2 LABEL', 'erd: its columns');
  l := doc_util.mermaid_erd('COURSE');
  assert_line(l, '    NUMBER DEPT_ID FK', 'erd: the current schema wins');
  l := doc_util.mermaid_erd('STUDENT,student,DOCTEST.STUDENT');
  assert_true(occurrences(l, '  STUDENT {') = 1, 'erd: duplicates listed once', NULL, l);
  l := doc_util.mermaid_erd('DOCTEST.COURSE,DOCOTHER.COURSE');
  assert_line(l, '  DOCTEST_COURSE {', 'erd: same name in two schemas, qualified (1)');
  assert_line(l, '  DOCOTHER_COURSE {', 'erd: same name in two schemas, qualified (2)');
  l := doc_util.mermaid_erd('Mixed Case');
  assert_line(l, '  Mixed_Case {', 'erd: entity name made Mermaid-safe');
  assert_line(l, '    VARCHAR2 odd_name', 'erd: column name made Mermaid-safe');
  assert_line(l, '    NUMBER ID PK', 'erd: mixed-case table key');

  BEGIN
    l := doc_util.mermaid_erd('SHARED');
    assert_true(FALSE, 'erd: ambiguous name raises ORA-20002', 'no error');
  EXCEPTION WHEN OTHERS THEN
    assert_error(SQLCODE, SQLERRM, -20002, 'erd: ambiguous name raises ORA-20002');
    assert_true(INSTR(SQLERRM, 'DOCOTHER, DOCOTHER2') > 0, 'erd: the error names both schemas', SQLERRM);
  END;
  BEGIN
    l := doc_util.mermaid_erd('');
    assert_true(FALSE, 'erd: empty list raises ORA-20003', 'no error');
  EXCEPTION WHEN OTHERS THEN assert_error(SQLCODE, SQLERRM, -20003, 'erd: empty list raises ORA-20003');
  END;
  BEGIN
    l := doc_util.mermaid_erd(' , , ');
    assert_true(FALSE, 'erd: blank list raises ORA-20003', 'no error');
  EXCEPTION WHEN OTHERS THEN assert_error(SQLCODE, SQLERRM, -20003, 'erd: blank list raises ORA-20003');
  END;
  BEGIN
    l := doc_util.mermaid_erd('STUDENT,NO_SUCH_TABLE');
    assert_true(FALSE, 'erd: missing table raises ORA-20001', 'no error');
  EXCEPTION WHEN OTHERS THEN assert_error(SQLCODE, SQLERRM, -20001, 'erd: missing table raises ORA-20001');
  END;
  BEGIN
    l := doc_util.mermaid_erd('DOCTOOLS.SECRET');
    assert_true(FALSE, 'erd: invoker''s rights hide the owner''s tables', 'no error');
  EXCEPTION WHEN OTHERS THEN assert_error(SQLCODE, SQLERRM, -20001, 'erd: invoker''s rights hide the owner''s tables');
  END;

  ------------------------------------------------------------------------
  -- schema_dictionary

  l := doc_util.schema_dictionary;
  assert_starts(l, '# Data dictionary: DOCTEST' || c_nl || c_nl || '7 tables.' || c_nl || c_nl
                   || '## Contents' || c_nl || c_nl || '- [COURSE](#course)' || c_nl,
                'dictionary: title, count and contents');
  assert_line(l, '- [GRADE_APPEAL](#grade_appeal)', 'dictionary: contents link');
  assert_line(l, '- [Mixed Case](#mixed-case)', 'dictionary: GitHub anchor for a spaced name');
  assert_lacks(l, 'STUDENT_VIEW', 'dictionary: no views');
  assert_true(occurrences(l, '**Columns**') = 7, 'dictionary: one section per table', NULL, l);
  assert_true(before(l, c_nl || '## COURSE' || c_nl, c_nl || '## DEPARTMENT' || c_nl)
              AND before(l, c_nl || '## DEPARTMENT' || c_nl, c_nl || '## ENROLMENT' || c_nl)
              AND before(l, c_nl || '## Mixed Case' || c_nl, c_nl || '## NOTES_LOG' || c_nl)
              AND before(l, c_nl || '## NOTES_LOG' || c_nl, c_nl || '## STUDENT' || c_nl),
              'dictionary: sections in name order', NULL, l);
  assert_true(before(l, '## Entity relationship diagram', '## COURSE' || c_nl), 'dictionary: ERD first', NULL, l);
  assert_line(l, '```mermaid', 'dictionary: ERD fence');
  assert_line(l, '  GRADE_APPEAL }o--|| ENROLMENT : "STUDENT_ID,COURSE_CODE,TERM"', 'dictionary: ERD relationships');
  assert_line(l, '  COURSE }o--|| DEPARTMENT : "DEPT_ID"', 'dictionary: ERD covers all tables');
  assert_lacks(l, '    VARCHAR2 GIVEN_NAME', 'dictionary: ERD has key columns only');
  assert_line(l, 'Primary key: STUDENT_ID, COURSE_CODE, TERM.', 'dictionary: composite primary key');
  assert_line(l, 'No primary key.', 'dictionary: table without one');
  assert_line(l, '*No comment.*', 'dictionary: table without a comment');
  assert_line(l, 'mentor, who is another student in a later year.', 'dictionary: comment wrapped');
  assert_contains(l, '**Foreign keys**' || c_nl || c_nl || 'None.' || c_nl, 'dictionary: no foreign keys');
  assert_matches(l, '^\| ENROLMENT_COURSE_FK +\| DOCTEST\.COURSE', 'dictionary: foreign key rows');
  assert_matches(l, '^\| odd name +\| VARCHAR2\(10\)', 'dictionary: column rows');
  assert_line(l, 'Referenced by: DOCTEST.COURSE, DOCTEST.STUDENT.', 'dictionary: referenced by');
  assert_line(l, 'Referenced by: DOCTEST.ENROLMENT, DOCTEST.STUDENT.', 'dictionary: referenced by, self included');

  l := doc_util.schema_dictionary('doctest', FALSE);
  assert_lacks(l, '```mermaid', 'dictionary: ERD can be left out');
  assert_line(l, '## STUDENT', 'dictionary: still has the tables');

  l := doc_util.schema_dictionary('DOCEMPTY');
  assert_equals(l, '# Data dictionary: DOCEMPTY' || c_nl || c_nl || 'No tables.' || c_nl, 'dictionary: empty schema');

  ------------------------------------------------------------------------
  -- the print procedures send exactly what the functions return

  doc_util.print_table_comments(NULL, 'DEPARTMENT');
  assert_true(DBMS_LOB.COMPARE(captured, doc_util.table_comments(NULL, 'DEPARTMENT')) = 0, 'print_table_comments');
  doc_util.print_table_columns(NULL, 'STUDENT', 'org');
  assert_true(DBMS_LOB.COMPARE(captured, doc_util.table_columns(NULL, 'STUDENT', 'org')) = 0, 'print_table_columns');
  doc_util.print_table_foreign_keys(NULL, 'ENROLMENT');
  assert_true(DBMS_LOB.COMPARE(captured, doc_util.table_foreign_keys(NULL, 'ENROLMENT')) = 0, 'print_table_foreign_keys');
  doc_util.format_query_as_table('SELECT 1 AS n FROM dual');
  assert_true(DBMS_LOB.COMPARE(captured, doc_util.format_query('SELECT 1 AS n FROM dual')) = 0, 'format_query_as_table');
  doc_util.audit_schema_comments(NULL, TRUE);
  assert_true(DBMS_LOB.COMPARE(captured, doc_util.schema_comment_audit(NULL, TRUE)) = 0, 'audit_schema_comments');
  doc_util.generate_mermaid_erd('STUDENT,DEPARTMENT', FALSE);
  assert_true(DBMS_LOB.COMPARE(captured, doc_util.mermaid_erd('STUDENT,DEPARTMENT', FALSE)) = 0, 'generate_mermaid_erd');
  doc_util.print_schema_dictionary;
  l := captured;
  l2 := doc_util.schema_dictionary;
  assert_true(DBMS_LOB.COMPARE(l, l2) = 0, 'print_schema_dictionary',
              DBMS_LOB.GETLENGTH(l) || ' vs ' || DBMS_LOB.GETLENGTH(l2) || ' characters');

  doc_util.print_clob('a' || c_nl || c_nl || 'b');
  l := captured;
  assert_equals(l, 'a' || c_nl || c_nl || 'b' || c_nl, 'print_clob: blank lines kept, last line without newline printed');
  doc_util.print_clob(NULL);
  l := captured;
  assert_true(DBMS_LOB.GETLENGTH(l) = 0, 'print_clob: NULL prints nothing');

  BEGIN
    doc_util.print_table_columns(NULL, 'NO_SUCH_TABLE');
    assert_true(FALSE, 'print_table_columns: errors are raised, not printed', 'no error');
  EXCEPTION WHEN OTHERS THEN
    assert_error(SQLCODE, SQLERRM, -20001, 'print_table_columns: errors are raised, not printed');
    l := captured;
    assert_true(DBMS_LOB.GETLENGTH(l) = 0, 'print_table_columns: nothing printed on error', NULL, l);
  END;

  ------------------------------------------------------------------------

  FOR i IN 1 .. g_report.COUNT LOOP
    DBMS_OUTPUT.PUT_LINE(g_report(i));
  END LOOP;
  DBMS_OUTPUT.PUT_LINE(g_run - g_failed || ' of ' || g_run || ' checks passed.');
  :failed := g_failed;
END;
/

BEGIN
  IF :failed > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, :failed || ' checks failed');
  END IF;
END;
/
EXIT
