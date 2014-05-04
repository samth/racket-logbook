#lang racket/base

(require racket/date)
(require (only-in mzlib/os gethostname))
(require (only-in racket/system system))
(require (only-in racket/port with-output-to-string))
(require (only-in racket/file file->string))
(require (only-in racket/string string-trim))

(require "store.rkt")

(provide standard-logbook-entry
	 standard-logbook-entry-name
	 logbook-machine-info-recorded?
	 logbook-record-machine-info!)

(define (capture-system cmd)
  (string-trim (with-output-to-string (lambda () (system cmd)))))

(define (logbook-machine-info-recorded? entry)
  (and (logbook-table entry "machine-info" "machine-info" #:create? #f) #t))

(define (logbook-record-machine-info! entry)
  (define T (logbook-table entry "machine-info" "machine-info"))
  (write-logbook-datum! T #:label "hostname" (gethostname))
  (write-logbook-datum! T #:label "racket-version" (version))
  (for [(system-type-mode (in-list '(os word gc link machine so-suffix so-mode fs-change)))]
    (write-logbook-datum! T #:label (symbol->string system-type-mode)
			  (system-type system-type-mode)))
  (when (file-exists? "/proc/cpuinfo")
    (write-logbook-datum! T #:label "cpuinfo" (file->string "/proc/cpuinfo")))
  (case (system-type)
    [(unix)
     (write-logbook-datum! T #:label "vmstat" (capture-system "vmstat 2>&1"))]
    [(macosx)
     (write-logbook-datum! T #:label "vm_stat" (capture-system "vm_stat"))
     (write-logbook-datum! T #:label "sysctl" (capture-system "sysctl -a"))])
  T)

(define (standard-logbook-entry book project [type #f] #:name [name #f])
  (define E (logbook-entry book
			   project
			   (or name (standard-logbook-entry-name))
			   type
			   #:create? #t))
  (logbook-record-machine-info! E)
  E)

(define (standard-logbook-entry-name)
  (format "~a-~a"
	  (gethostname)
	  (parameterize ((date-display-format 'iso-8601))
	    (date->string (current-date) #t))))

(module+ test
  (require racket/pretty)
  (require racket/list)
  (define L (open-logbook ':memory: #:verbose? #t))
  (define E (standard-logbook-entry L "p"))
  (for ((T (logbook-tables E)))
    (for-each pretty-print (read-logbook-data/labels T))))
