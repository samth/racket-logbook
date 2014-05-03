#lang racket/base

(require (only-in unstable/list group-by))
(require racket/match)
(require racket/date)
(require racket/runtime-path)
(require racket/port)
(require racket/string)
(require racket/list)
(require net/base64)
(require plot/no-gui)
(require web-server/servlet)
(require web-server/servlet-env)
(require web-server/dispatch)
(require web-server/templates)
(require xml)

(require "../main.rkt")
(require "../plot-utils.rkt")

(provide serve-logbook)

(define-runtime-path web-root "htdocs")
(define-runtime-path template-root ".")

(define plot-image-width 700)
(define plot-image-height 450)

;; Holy fuck this is stupid.
;; https://groups.google.com/d/msg/racket-users/-yVo3542Bew/6DzplG6UA4EJ
(define-namespace-anchor dynamic-template-anchor)
(define (dynamic-template* name bindings)
  (define p (path->string (build-path template-root name)))
  (define form #`(lambda (#,@(map car bindings)) (include-template (file #,p))))
  (apply (eval form (namespace-anchor->namespace dynamic-template-anchor))
	 (map cadr bindings)))

(define-syntax-rule (dynamic-template name (var val) ...)
  (dynamic-template* name `((var ,val) ...)))

(define-syntax-rule (static-template name (var val) ...)
  (let ((var val) ...)
    (include-template name)))

(define (page title
	      content
	      #:nav [nav '()]
	      #:page-class [page-class "default"])
  (response/output
   (lambda (p)
     (display (static-template "templates/page.html"
			       (title title)
			       (page-class page-class)
			       (nav nav)
			       (content content)) p))))

(define (value->string v)
  (call-with-output-string (lambda (p) (display v p))))

(define (value->xexpr v)
  (cond
   [(string? v)
    `(div ((class "racket-value"))
	  ,@(apply append
		   (for/list [(line (string-split v "\n"))]
		     (list line `(br)))))]
   [else
    `(span ((class "racket-value")) ,(value->string v))]))

(define (pretty-time t)
  (date->string (seconds->date t) #t))

(define (pretty-entry-type t)
  (if (string=? t "") "(blank)" t))

(define (serve-style req)
  (response/output
   #:mime-type #"text/css"
   (lambda (p)
     (display (static-template "templates/style.css"
			       (color1 "#4B4B61")
			       (color2 "#0ac")
			       (linkcolor "#ff8827")
			       (textfonts "'Lora', Georgia")
			       (headerfonts "'Bree Serif', Georgia"))
	      p))))

(define (link-buttons xexprs)
  `(div ((class "link-buttons-container"))
	(ul ((class "link-buttons"))
	    ,@(for/list [(x xexprs)]
		`(li ,x)))
	(div ((class "clear")))))

(define (serve-logbook L port)
  (define-values (logbook-dispatch logbook-url)
    (dispatch-rules
     [("") list-projects]
     [("style.css") serve-style]
     [("log" (string-arg)) project-page]
     [("log" (string-arg) (string-arg)) entry-type-page]
     [("log" (string-arg) (string-arg) (string-arg)) entry-page]
     [("log" (string-arg) (string-arg) (string-arg) (string-arg)) table-page]
     [("log" (string-arg) (string-arg) (string-arg) (string-arg)
       "plot" (integer-arg) (integer-arg) (integer-arg) ...) render-table-image]
     [("log" (string-arg) (string-arg) (string-arg) (string-arg)
       "defaultplot") default-render-table-image]))

  (define (list-projects req)
    (page "All Projects"
	  `(table
	    (thead
	     (tr ((class "ruled"))
		 (th "Project name")))
	    (tbody
	     ,@(for/list [(p (logbook-projects L))]
		 `(tr (td (a ((href ,(logbook-url project-page p))) ,p))))))
	  ))

  (define (project-page req project)
    (define Es (logbook-entries L #:project project))
    (define grouped-Es (group-by logbook-entry-type Es))
    (page (format "Project ~a" project)
	  `(div
	    (h2 "Latest entries by entry-type")
	    ,(link-buttons
	      (for/list [(group grouped-Es)]
		(define an-E (car group)) ;; we know the group is nonempty
		(define entry-type (logbook-entry-type an-E))
		`(a ((href ,(logbook-url entry-page project entry-type "--latest--")))
		    ,(pretty-entry-type entry-type))))
	    (h2 "All entries by entry-type")
	    ,@(for/list [(group grouped-Es)]
		(define an-E (car group)) ;; we know the group is nonempty
		(define entry-type (logbook-entry-type an-E))
		`(div
		  (h3 ,(pretty-entry-type entry-type))
		  ,(link-buttons
		    `((a ((href ,(logbook-url entry-type-page project entry-type)))
			 "Summary page")
		      (a ((href ,(logbook-url entry-page project entry-type "--latest--")))
			 "Latest entry")))
		  (table
		   (thead
		    (tr ((class "ruled"))
			(th "Entry name")
			(th "Created")))
		   (tbody
		    ,@(for/list [(E group)]
			(match-define (<logbook-entry> _ _ (== project) name type created-time) E)
			`(tr (td (a ((href ,(logbook-url entry-page project type name)))
				    ,name))
			     (td ,(pretty-time created-time)))))))))
	  ))

  (define (entry-type-page req project entry-type)
    (page (format "Entry type ~a" (pretty-entry-type entry-type))
	  `(div
	    ,(link-buttons
	      `((a ((href ,(logbook-url project-page project)))
		   ,(format "Project ~a" project))
		(a ((href ,(logbook-url entry-page project entry-type "--latest--")))
		   "Latest entry")))
	    (table
	     (thead
	      (tr ((class "ruled"))
		  (th "Entry name")
		  (th "Created")))
	     (tbody
	      ,@(for/list [(E (logbook-entries L #:project project #:type entry-type))]
		  (match-define (<logbook-entry> _ _ (== project) name type created-time) E)
		  `(tr (td (a ((href ,(logbook-url entry-page project type name)))
			      ,name))
		       (td ,(pretty-time created-time)))))))
	  ))

  (define (default-plot-columns T)
    (define E (logbook-table-entry T))
    (define prefs (logbook-prefs L (logbook-entry-project E)
				 #:entry_type (logbook-entry-type E)
				 #:table_type (logbook-table-type T)
				 #:table_name (logbook-table-name T)))
    (hash-ref prefs 'default-plot-columns (lambda () '(0 1))))

  (define (format-table entry0 T)
    (match-define (<logbook-table> _ _ (<logbook-entry> _ _ project entry entry-type _)
				   name type cols created-time) T)
    (match-define (list* xaxis yaxes) (default-plot-columns T))
    `(form ((name ,(format "table-~a" name)))
	   ,@(if cols
		 `((img ((class "display-none")
			 (width ,(number->string plot-image-width))
			 (height ,(number->string plot-image-height))
			 (src "")
			 (id ,(format "plot-~a" name)))))
		 '())
	   (table
	    (thead
	     (tr ((class "ruled"))
		 (th "Label")
		 ,@(if cols
		       (for/list [(c cols)] `(th ((class "rotate")) ,(value->xexpr c)))
		       `((th "Datum"))))
	     ,@(if cols
		   `((tr (th)
			 ,@(for/list [(i (in-naturals)) (c cols)]
			     `(th (input ((type "radio")
					  ,@(if (= xaxis i)
						`((checked "checked"))
						'())
					  (id ,(format "x-~a-~a" name i))
					  (name ,(format "x-~a" name))
					  (value ,(number->string i))))))))
		   '())
	     ,@(if cols
		   `((tr ((class "ruled"))
			 (th)
			 ,@(for/list [(i (in-naturals)) (c cols)]
			     `(th (input ((type "checkbox")
					  ,@(if (member i yaxes)
						`((checked "checked"))
						'())
					  (id ,(format "y-~a-~a" name i))
					  (name ,(format "y-~a" name))
					  (value ,(number->string i))))))))
		   '())
	     ,@(if cols
		   `((script ,(format "install_callbacks('~a','~a','~a','~a',~a);\n"
				      project
				      entry-type
				      entry0
				      name
				      (length cols))))
		   '()))
	    (tbody
	     ,@(for/list [(R (read-logbook-data/labels T))]
		 (match-define (list label data) R)
		 `(tr (td ,label)
		      ,@(if cols
			    (for/list [(c data)] `(td ,(value->xexpr c)))
			    (list `(td ,(value->xexpr data))))))))))

  (define (lookup-entry project name entry-type)
    (if (equal? name "--latest--")
	(latest-logbook-entry L project #:type entry-type)
	(logbook-entry L project name entry-type #:create? #f)))

  (define (entry-page req project entry-type entry0)
    (define E (lookup-entry project entry0 entry-type))
    (define entry (logbook-entry-name E))
    (page (format "~a" entry)
	  `(div
	    ,(link-buttons
	      `((a ((href ,(logbook-url project-page project)))
		   ,(format "Project ~a" project))
		(a ((href ,(logbook-url entry-type-page project entry-type)))
		   ,(format "Type ~a" (pretty-entry-type entry-type)))
		(a ((href ,(logbook-url entry-page project entry-type entry)))
		   "Permalink")))
	    ,@(for/list [(T (logbook-tables E))]
		(match-define (<logbook-table> _ _ _ name type cols created-time) T)
		`(div
		  (h2 ((class "table-name"))
		      (a ((href ,(logbook-url table-page project entry-type entry0 name))) ,name))
		  (h3 ((class "table-type")) ,type)
		  (h3 ((class "table-created-time")) ,(pretty-time created-time))
		  ,(format-table entry0 T))))
	  #:nav (list (list (logbook-url entry-page project entry-type "--latest--")
			    "latest entry of this type"))))

  (define (table-page req project entry-type entry0 table)
    (define E (lookup-entry project entry0 entry-type))
    (define entry (logbook-entry-name E))
    (define T (logbook-table E table #:create? #f))
    (match-define (<logbook-table> _ _ _ name type cols created-time) T)
    (page (format "~a" table)
	  `(div
	    ,(link-buttons
	      `((a ((href ,(logbook-url project-page project)))
		   ,(format "Project ~a" project))
		(a ((href ,(logbook-url entry-page project entry-type entry)))
		   ,(format "Entry ~a" entry))
		(a ((href ,(logbook-url table-page project entry-type entry table)))
		   "Permalink")))
	    (h2 ((class "table-type")) ,type)
	    (h2 ((class "table-created-time")) ,(pretty-time created-time))
	    ,(format-table entry0 T))
	  #:nav (list (list (logbook-url entry-page project entry-type "--latest--")
			    "latest entry of this type")
		      (list (logbook-url table-page project entry-type "--latest--" table)
			    (format "latest ~a table" table)))))

  (define (default-render-table-image req project entry-type entry0 table)
    (define E (lookup-entry project entry0 entry-type))
    (define entry (logbook-entry-name E))
    (define T (logbook-table E table #:create? #f))
    (match-define (list* xaxis yaxes) (default-plot-columns T))
    (render-table-image* E T xaxis yaxes))

  (define (render-table-image req project entry-type entry0 table xaxis yaxis0 yaxesN)
    (define E (lookup-entry project entry0 entry-type))
    (define entry (logbook-entry-name E))
    (define T (logbook-table E table #:create? #f))
    (define yaxes (cons yaxis0 yaxesN))
    (render-table-image* E T xaxis yaxes))

  (define (render-table-image* E T xaxis yaxes)
    (define-values (x-label y-label)
      (match (logbook-table-column-spec T)
	[#f (values (plot-x-label) (plot-y-label))]
	[ss
	 (values (format "~a" ((@ xaxis) ss))
		 (string-join (map (lambda (y) (value->string ((@ y) ss))) yaxes) " / "))]))

    (set-logbook-pref! L (logbook-entry-project E)
		       #:entry_type (logbook-entry-type E)
		       #:table_type (logbook-table-type T)
		       #:table_name (logbook-table-name T)
		       'default-plot-columns (cons xaxis yaxes))

    (response/output
     #:mime-type #"image/png"
     (lambda (p)
       (parameterize ((plot-width plot-image-width)
		      (plot-height plot-image-height))
	 (plot-file (for/list [(yaxis yaxes)]
		      (define ps (logbook-table->points T #:columns (list xaxis yaxis)))
		      (list (lines ps) (points ps)))
		    p
		    'png
		    #:x-label x-label #:y-label y-label)))))

  (serve/servlet logbook-dispatch
		 ;; #:command-line? #f
		 #:port port
		 #:server-root-path web-root
		 #:extra-files-paths (list web-root)
		 #:servlet-path "/"
		 #:servlet-regexp #px""
		 ;; #:server-root-path server-root-path
		 ;; #:extra-files-paths extra-files-paths
		 ))
