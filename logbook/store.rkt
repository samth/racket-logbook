#lang racket/base

(require (prefix-in sql: (planet jaymccarthy/sqlite)))
(require racket/match)
(require (only-in racket/list filter-map))
(require (only-in racket/string string-join))
(require (only-in racket/port
		  call-with-output-bytes
		  call-with-input-bytes))

(provide (rename-out (struct-out logbook) [logbook <logbook>])
	 (except-out (struct-out logbook-entry) logbook-entry)
	 (except-out (struct-out logbook-table) logbook-table)
	 (rename-out (struct-out logbook-datum) [logbook-datum <logbook-datum>])
	 logbook-entry-fullname
	 logbook-table-fullname

	 default-logbook-name
	 default-logbook
	 open-logbook
	 close-logbook

	 (rename-out [logbook-entry <logbook-entry>] [get-logbook-entry logbook-entry])
	 (rename-out [logbook-table <logbook-table>] [get-logbook-table logbook-table])
	 latest-logbook-entry

	 logbook-entries
	 logbook-tables

	 raw-logbook-datum!
	 write-logbook-datum!

	 raw-logbook-data
	 read-logbook-data
	 read-logbook-data/labels
	 )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(struct logbook (db verbose?) #:transparent)
(struct logbook-entry (book id project name type created-time) #:transparent)
(struct logbook-table (book id entry name type column-spec created-time) #:transparent)
(struct logbook-datum (book id table label data created-time) #:transparent)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define ((do-sql book) sql . params)
  (apply sql:exec/ignore (logbook-db book) sql params))

(define-syntax-rule (exn-guard failure body ...)
  (with-handlers ([exn:fail? (lambda (e) failure)]
                  [sql:exn:sqlite? (lambda (e) failure)])
    body ...))

(define (simple-query db table-name fields-selected
		      #:order-by [order-by #f]
		      #:ascending? [ascending? #t]
		      #:limit [limit #f]
		      . constraints0)
  (define constraints (filter-map values constraints0))
  (define filter-names (map car constraints))
  (define filter-values (map cadr constraints))
  (define q (string-append "select "
			   (string-join fields-selected ",")
			   " from "
			   table-name
			   (if (null? constraints) "" " where ")
			   (string-join (map (lambda (n) (string-append "("n" = ?)"))
					     filter-names)
					" and ")
			   (if order-by
			       (string-append " order by "
					      (string-join order-by ",")
					      (if ascending? " asc" " desc"))
			       "")
			   (if limit (format " limit ~a" limit) "")
			   ))
  (log-debug "logbook Q:  ~a" q)
  (log-debug "logbook Ps: ~v" filter-values)
  (match (apply sql:select db q filter-values)
    ['() '()]
    [(list* _ rowvecs)
     (when (log-level? (current-logger) 'debug)
       (for ((r rowvecs)) (log-debug "logbook R:  ~v" r)))
     rowvecs]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (default-logbook-name)
  (or (getenv "RACKET_LOGBOOK")
      (error 'default-logbook-name "Environment variable RACKET_LOGBOOK not defined")))

(define (default-logbook #:verbose? [verbose? #f])
  (open-logbook (default-logbook-name) #:verbose? verbose?))

(define (open-logbook db-path #:verbose? [verbose? #f])
  (when (string? db-path) (set! db-path (string->path db-path)))
  (define book (logbook (sql:open db-path) verbose?))
  (initialize! book)
  book)

(define (close-logbook book)
  (sql:close (logbook-db book)))

;; Initializes the current (*db*) if it is not initialized.
;; Checks the schema version too.
(define (initialize! book)
  (define db (logbook-db book))

  (define (retry-after thunk)
    (sql:with-transaction (db fail) (thunk))
    (initialize! book))

  ;; Creates tables.
  ;; Does no safety checks.
  (define (initialize-schema!!)
    (for-each
     (do-sql book)
     (list "create table logbook_version (version varchar)"
	   "create table logbook_entry (id integer primary key, project varchar, entry_name varchar, entry_type varchar, created_time real, unique (project, entry_name, entry_type))"
	   "create table logbook_table (id integer primary key, entry_id integer, table_name varchar, table_type varchar, column_spec blob, created_time real, unique (entry_id, table_name, table_type))"
	   "create table logbook_datum (id integer primary key, table_id integer, label varchar, data blob, created_time real)"
	   )))

  (define (insert-bootstrap-data!!)
    (for-each
     (do-sql book)
     (list "insert into logbook_version values ('0')"
	   )))

  (match (exn-guard #f (sql:select db "select * from logbook_version"))
    [#f (retry-after initialize-schema!!)]
    ['() (retry-after insert-bootstrap-data!!)]
    ['(#("version") #("0")) #t]
    [other (error 'initialize! "Unknown logbook schema version: ~v" other)]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (get-logbook-entry book project name [type #f] #:create? [create? #t])
  (match (simple-query (logbook-db book)
		       "logbook_entry"
		       '("id" "entry_type" "created_time")
		       (list "project" project)
		       (list "entry_name" name)
		       (and type (list "entry_type" type)))
    ['()
     (cond
      [(not create?) #f]
      [else
       (when (not type)
	 (set! type ""))
       (when (logbook-verbose? book)
	 (printf "~a: Creating logbook entry ~a\n" project name)
	 (flush-output))
       (define stamp (current-seconds))
       (define id
	 (sql:insert (logbook-db book)
		     (string-append "insert into logbook_entry"
				    "(project,entry_name,entry_type,created_time)"
				    " values (?,?,?,?)")
		     project
		     name
		     type
		     stamp))
       (logbook-entry book id project name type (exact->inexact stamp))])]
    [(list (vector id type stamp))
     (logbook-entry book id project name type stamp)]))

(define (latest-logbook-entry book project #:type [type #f])
  (match (simple-query (logbook-db book)
		       "logbook_entry"
		       '("id" "entry_name" "entry_type" "created_time")
		       #:order-by '("created_time")
		       #:ascending? #f
		       #:limit 1
		       (list "project" project)
		       (and type (list "entry_type" type)))
    ['() #f]
    [(list (vector id name type stamp))
     (logbook-entry book id project name type stamp)]))

(define (value->written-bytes v)
  (call-with-output-bytes (lambda (p) (write v p))))

(define (written-bytes->value bs)
  (call-with-input-bytes bs read))

(define (logbook-entry-fullname entry)
  (format "~a/~a"
	  (logbook-entry-project entry)
	  (logbook-entry-name entry)))

(define (get-logbook-table entry name [type #f]
			   #:column-spec [column-spec #f]
			   #:create? [create? #t])
  (define column-spec-str (and column-spec
			       (value->written-bytes column-spec)))
  (define book (logbook-entry-book entry))
  (match (simple-query (logbook-db book)
		       "logbook_table"
		       '("id" "table_type" "column_spec" "created_time")
		       (list "entry_id" (logbook-entry-id entry))
		       (list "table_name" name)
		       (and type (list "table_type" type))
		       (and column-spec-str (list "column_spec" column-spec-str)))
    ['()
     (cond
      [(not create?) #f]
      [else
       (when (not type)
	 (set! type ""))
       (when (logbook-verbose? book)
	 (printf "~a: Creating logbook table ~a\n"
		 (logbook-entry-fullname entry)
		 name)
	 (flush-output))
       (define stamp (current-seconds))
       (define id
	 (sql:insert (logbook-db book)
		     (string-append "insert into logbook_table"
				    "(entry_id,table_name,table_type,column_spec,created_time)"
				    " values (?,?,?,?,?)")
		     (logbook-entry-id entry)
		     name
		     type
		     column-spec-str
		     stamp))
       (logbook-table book id entry name type column-spec (exact->inexact stamp))])]
    [(list (vector id type stored-spec stamp))
     (logbook-table book
		    id
		    entry
		    name
		    type
		    (and stored-spec (written-bytes->value stored-spec))
		    stamp)]))

(define (logbook-entries book
			 #:project [project #f]
			 #:name [name #f]
			 #:type [type #f])
  (for/list [(rowvec (in-list (simple-query
			       (logbook-db book)
			       "logbook_entry"
			       '("id" "project" "entry_name" "entry_type" "created_time")
			       (and project (list "project" project))
			       (and name (list "entry_name" name))
			       (and type (list "entry_type" type)))))]
    (match-define (vector id project name type stamp) rowvec)
    (logbook-entry book id project name type stamp)))

(define (logbook-tables entry
			#:name [name #f]
			#:type [type #f])
  (define book (logbook-entry-book entry))
  (for/list [(rowvec (in-list (simple-query
			       (logbook-db book)
			       "logbook_table"
			       '("id" "table_name" "table_type" "column_spec" "created_time")
			       (list "entry_id" (logbook-entry-id entry))
			       (and name (list "table_name" name))
			       (and type (list "table_type" type)))))]
    (match-define (vector id name type column-spec stamp) rowvec)
    (logbook-table book
		   id
		   entry
		   name
		   type
		   (and column-spec (written-bytes->value column-spec))
		   stamp)))

(define (raw-logbook-datum!* table data label)
  (define book (logbook-table-book table))
  (define stamp (current-seconds))
  (define id
    (sql:insert (logbook-db book)
		"insert into logbook_datum (table_id,label,data,created_time) values (?,?,?,?)"
		(logbook-table-id table)
		label
		data
		stamp))
  (logbook-datum book id table label data stamp))

(define (logbook-table-fullname table)
  (format "~a/~a"
	  (logbook-entry-fullname (logbook-table-entry table))
	  (logbook-table-name table)))

(define (echo-datum table data label)
  (printf "~a:~a:~v\n"
	  (logbook-table-fullname table)
	  label
	  data)
  (flush-output))

(define (raw-logbook-datum! table data #:label [label ""])
  (when (logbook-verbose? (logbook-table-book table)) (echo-datum table data label))
  (raw-logbook-datum!* table data label))

(define (write-logbook-datum! table data #:label [label ""])
  (when (logbook-verbose? (logbook-table-book table)) (echo-datum table data label))
  (raw-logbook-datum!* table (value->written-bytes data) label))

(define (raw-logbook-data table #:label [label #f])
  (define book (logbook-table-book table))
  (for/list [(rowvec (in-list (simple-query (logbook-db book)
					    "logbook_datum"
					    '("id" "label" "data" "created_time")
					    (list "table_id" (logbook-table-id table))
					    (and label (list "label" label)))))]
    (match-define (vector id label data stamp) rowvec)
    (logbook-datum book id table label data stamp)))

(define (read-logbook-data table #:label [label #f])
  (for/list [(d (in-list (raw-logbook-data table #:label label)))]
    (written-bytes->value (logbook-datum-data d))))

(define (read-logbook-data/labels table #:label [label #f])
  (for/list [(d (in-list (raw-logbook-data table #:label label)))]
    (list (logbook-datum-label d)
	  (written-bytes->value (logbook-datum-data d)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(module+ test
  (define L (open-logbook ':memory: #:verbose? #t))
  (define E
    (begin (get-logbook-entry L "project1" "entry1" "etype1")
	   (get-logbook-entry L "project1" "entry1" "etype1")))
  (define T
    (begin (get-logbook-table E "table1" "ttype1" #:column-spec 'spec1)
	   (get-logbook-table E "table1" "ttype1" #:column-spec 'spec1)))
  L
  E
  T
  (write-logbook-datum! T (list 'test "Hello1" 123.45 (hash 'a 'b 234 345) '(x y z)))
  (write-logbook-datum! T (list 'test "Hello2" 123.45 (hash 'a 'b 234 345) '(x y z)))
  (write-logbook-datum! T (list 'test "Hello3" 123.45 (hash 'a 'b 234 345) '(x y z)) #:label "x")
  (write-logbook-datum! T (list 'test "Hello4" 123.45 (hash 'a 'b 234 345) '(x y z)) #:label "x")
  (write-logbook-datum! T (list 'test "Hello5" 123.45 (hash 'a 'b 234 345) '(x y z)) #:label "y")
  (newline)
  (raw-logbook-data T)
  (newline)
  (raw-logbook-data T #:label "")
  (raw-logbook-data T #:label "x")
  (raw-logbook-data T #:label "y")
  (raw-logbook-data T #:label "z")
  (newline)
  (read-logbook-data T #:label "x")
  (logbook-entries L #:project "nonexistent")
  (logbook-entries L)
  (map logbook-tables (logbook-entries L))
  (map read-logbook-data (logbook-tables E))
  (latest-logbook-entry L "project1")
  )
