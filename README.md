# DOC_UTIL

A PL/SQL package useful for documenting Oracle database schemas. It can write Markdown or Org-mode tables and [Mermaid](https://mermaid.js.org/) entity relationship diagrams.

- **A whole-schema data dictionary** ERD, table comments, columns and foreign keys.
- **Per-table pieces**: comments, columns, foreign keys, and any query as a table.
- **A comment audit**: how much of a schema is documented in the DDL.
- **Functions returning CLOBs**, so that you can use the output in various ways. 

## Install

Into any schema with `CREATE PROCEDURE`:

```sh
sqlplus user/password@db @install.sql
```

The script stops with an error if the package doesn't compile. To let other
users run it:

```sql
GRANT EXECUTE ON doc_util TO some_user;
-- and, as some_user:
CREATE SYNONYM doc_util FOR owner.doc_util;
```

It is tested on Oracle Database Free 23ai and needs 19c or later
(`LISTAGG (DISTINCT …)`).

## Use

```sql
-- The current schema's data dictionary, as a CLOB…
SELECT doc_util.schema_dictionary FROM dual;

-- …or printed (SQL*Plus / SQLcl)
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 32767 TRIMOUT ON FEEDBACK OFF
EXEC doc_util.print_schema_dictionary('HR')
```

`FORMAT WRAPPED` keeps leading spaces, which the Mermaid diagrams need.

| Function | Print procedure | What it produces |
|---|---|---|
| `schema_dictionary(schema, include_erd)` | `print_schema_dictionary` | The whole schema as one Markdown document |
| `table_comments(schema, table)` | `print_table_comments` | The table's comment, wrapped at 100 characters |
| `table_columns(schema, table, format)` | `print_table_columns` | Name, data type, nullable and comment of each column |
| `table_foreign_keys(schema, table, format)` | `print_table_foreign_keys` | Each foreign key and the columns it maps |
| `schema_comment_audit(schema, include_detail)` | `audit_schema_comments` | The share of tables and columns with comments; with detail, the ones without |
| `mermaid_erd(table_list, all_columns)` | `generate_mermaid_erd` | A Mermaid ERD of the listed tables and the foreign keys between them |
| `format_query(query, format, max_width)` | `format_query_as_table` | Any query's rows as a table |

`print_clob(text)` prints any CLOB line by line.

- **Schemas and tables.** A `NULL` schema means the caller's current schema.
  Names are used as given when such an object exists, and in upper case
  otherwise, so `'hr'`, `'HR'` and a quoted `'Mixed Case'` table all work.
- **Formats.** `format` is `'md'` (Markdown, the default) or `'org'`. Pipes
  inside values are escaped, and line breaks become spaces.
- **Table lists.** `mermaid_erd` takes a comma-separated list such as
  `'HR.EMPLOYEES, DEPARTMENTS'`. An unqualified name is looked up in the
  current schema first, then in every schema the caller can see, where it must
  be unique.
- **ERD notation.** A foreign key is drawn as many-or-none children to one
  parent (`}o--||`), or to at most one parent (`}o--o|`) when a key column is
  nullable. Columns are marked `PK` and `FK`. With `all_columns => FALSE`, only
  key columns are shown.
- **Errors are raised, not printed.**

| Error | Meaning |
|---|---|
| `ORA-20001` | Table not found, or not visible to the caller |
| `ORA-20002` | An unqualified table name is in more than one schema |
| `ORA-20003` | `mermaid_erd` was given no tables |
| `ORA-20004` | Unknown format |

Example output for the test schema is attached to every CI run as the
`fixture-dictionary` artifact.

## Tests

`test/` holds a small synthetic schema (departments, students, courses,
enrolments) and about 130 checks with exact expected output. GitHub Actions
runs them on every push against a throwaway
[Oracle Database Free](https://hub.docker.com/r/gvenzl/oracle-free) container
(`.github/workflows/test.yml`). To run them against your own scratch database:

```sh
sqlplus system/…@db @test/setup.sql         # creates the DOC* test users
sqlplus doctools/Doctools_1@db @install.sql
echo 'GRANT EXECUTE ON doc_util TO doctest;' | sqlplus -s doctools/Doctools_1@db
sqlplus doctest/Doctest_1@db @test/fixture.sql
sqlplus doctest/Doctest_1@db @test/run_tests.sql
```

The tests are owned by `DOCTOOLS` and run as `DOCTEST`, which checks that the
package works through invoker's rights. Never run `setup.sql` against a production database.

## Licence

[MIT](LICENSE).
