-- Run as SYSTEM in a throwaway database (CI): the users the tests need.
--   DOCTOOLS   owns DOC_UTIL, and one table nobody else may see
--   DOCTEST    owns the fixture schema and runs the tests
--   DOCOTHER, DOCOTHER2   tables visible to DOCTEST in other schemas
--   DOCEMPTY   a schema with no tables
WHENEVER SQLERROR EXIT FAILURE
SET FEEDBACK OFF

CREATE USER doctools IDENTIFIED BY "Doctools_1" QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE PROCEDURE, CREATE TABLE TO doctools;

CREATE USER doctest IDENTIFIED BY "Doctest_1" QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SYNONYM TO doctest;

CREATE USER docother IDENTIFIED BY "Docother_1" QUOTA UNLIMITED ON users;
CREATE USER docother2 IDENTIFIED BY "Docother2_1" QUOTA UNLIMITED ON users;
CREATE USER docempty IDENTIFIED BY "Docempty_1";

-- the same name in two other schemas: ambiguous when unqualified
CREATE TABLE docother.shared (id NUMBER CONSTRAINT shared_pk PRIMARY KEY);
CREATE TABLE docother2.shared (id NUMBER CONSTRAINT shared2_pk PRIMARY KEY);
-- only in DOCOTHER: found when unqualified
CREATE TABLE docother.other_only (id NUMBER CONSTRAINT other_only_pk PRIMARY KEY, label VARCHAR2(20));
-- also in DOCTEST: the current schema wins when unqualified
CREATE TABLE docother.course (course_code CHAR(8) CONSTRAINT other_course_pk PRIMARY KEY);
GRANT SELECT ON docother.shared TO doctest;
GRANT SELECT ON docother2.shared TO doctest;
GRANT SELECT ON docother.other_only TO doctest;
GRANT SELECT ON docother.course TO doctest;

-- DOCTEST may not see this; with invoker's rights DOC_UTIL mustn't either
CREATE TABLE doctools.secret (id NUMBER);

PROMPT Test users created.
EXIT
