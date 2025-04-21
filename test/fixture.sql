-- Run as DOCTEST: a small, synthetic schema to document.
WHENEVER SQLERROR EXIT FAILURE
SET FEEDBACK OFF

CREATE SYNONYM doc_util FOR doctools.doc_util;

CREATE TABLE department (
  dept_id NUMBER(6)     CONSTRAINT department_pk PRIMARY KEY,
  name    VARCHAR2(100) NOT NULL,
  budget  NUMBER(12,2)
);
COMMENT ON TABLE department IS 'Academic departments.';
COMMENT ON COLUMN department.dept_id IS 'Department number.';
COMMENT ON COLUMN department.name IS 'Name | shown on transcripts.';

CREATE TABLE student (
  student_id  NUMBER(9)    CONSTRAINT student_pk PRIMARY KEY,
  given_name  VARCHAR2(50 CHAR) NOT NULL,
  family_name VARCHAR2(50) NOT NULL,
  dept_id     NUMBER(6)    CONSTRAINT student_dept_fk REFERENCES department,
  mentor_id   NUMBER(9)    CONSTRAINT student_mentor_fk REFERENCES student,
  enrolled_at TIMESTAMP(6) WITH TIME ZONE
);
COMMENT ON TABLE student IS 'People enrolled in at least one course. A student may belong to one department, and may have a mentor, who is another student in a later year.';
COMMENT ON COLUMN student.student_id IS 'Student number, printed on the card.';
COMMENT ON COLUMN student.given_name IS 'Given name.';
COMMENT ON COLUMN student.family_name IS 'Family name.';

CREATE TABLE course (
  course_code CHAR(8)       CONSTRAINT course_pk PRIMARY KEY,
  dept_id     NUMBER(6)     NOT NULL CONSTRAINT course_dept_fk REFERENCES department,
  title       VARCHAR2(200) NOT NULL,
  credits     NUMBER(2)
);

CREATE TABLE enrolment (
  student_id  NUMBER(9),
  course_code CHAR(8),
  term        VARCHAR2(6),
  grade       VARCHAR2(2),
  CONSTRAINT enrolment_pk PRIMARY KEY (student_id, course_code, term),
  CONSTRAINT enrolment_student_fk FOREIGN KEY (student_id) REFERENCES student,
  CONSTRAINT enrolment_course_fk FOREIGN KEY (course_code) REFERENCES course
);
COMMENT ON TABLE enrolment IS 'A student taking a course in a term.';

CREATE TABLE grade_appeal (
  appeal_id   NUMBER        CONSTRAINT grade_appeal_pk PRIMARY KEY,
  student_id  NUMBER(9)     NOT NULL,
  course_code CHAR(8)       NOT NULL,
  term        VARCHAR2(6)   NOT NULL,
  reason      VARCHAR2(4000),
  CONSTRAINT grade_appeal_enrolment_fk FOREIGN KEY (student_id, course_code, term) REFERENCES enrolment
);
COMMENT ON TABLE grade_appeal IS 'Requests to review a grade.';
COMMENT ON COLUMN grade_appeal.appeal_id IS 'Appeal number.';
COMMENT ON COLUMN grade_appeal.student_id IS 'Who appeals.';
COMMENT ON COLUMN grade_appeal.course_code IS 'For which course.';
COMMENT ON COLUMN grade_appeal.term IS 'In which term.';
COMMENT ON COLUMN grade_appeal.reason IS 'Why, in their words.';

CREATE TABLE "Mixed Case" (
  id         NUMBER CONSTRAINT mixed_case_pk PRIMARY KEY,
  "odd name" VARCHAR2(10)
);

CREATE TABLE notes_log (
  note VARCHAR2(200)
);

-- views are not tables: never documented as one
CREATE VIEW student_view AS SELECT student_id, given_name FROM student;

PROMPT Fixture created.
EXIT
