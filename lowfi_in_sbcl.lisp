(defpackage :lowfi-in-sbcl
  (:use :cl))

(in-package :lowfi-in-sbcl)

(defparameter *song-local-dir*
  (merge-pathnames
   "lowfi/"
   (let* ((tmp (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
          (normalized (if (and (> (length tmp) 0)
                               (char= (char tmp (1- (length tmp))) #\/))
                          tmp
                          (concatenate 'string tmp "/"))))
     (pathname normalized))))

(defvar *song-counter* 0)

(defun trim-crlf (line)
  (string-right-trim '(#\Return) line))

(defun source-directory ()
  (make-pathname
   :name nil
   :type nil
   :defaults (or *load-truename* *compile-file-truename* *default-pathname-defaults*)))

(defun read-file-lines (pathname)
  (with-open-file (in pathname :direction :input :external-format :utf-8)
    (loop for line = (read-line in nil nil)
          while line
          collect (trim-crlf line))))

(defun split-song-line (line)
  (let ((bang (position #\! line)))
    (if bang
        (values (subseq line 0 bang)
                (subseq line (1+ bang)))
        (values line ""))))

(defstruct song
  url
  title
  number)

(defun new-song (line)
  (multiple-value-bind (url title) (split-song-line line)
    (make-song :url url :title title :number 0)))

(defun create-songs ()
  (let* ((lines (read-file-lines (merge-pathnames "chillhop.txt" (source-directory)))))
    (if (endp lines)
        nil
        (let ((baseurl (first lines)))
          (mapcar (lambda (line)
                    (new-song (concatenate 'string baseurl line)))
                  (rest lines))))))

(defparameter *songs* (coerce (create-songs) 'vector))

(defun fnv1a-64 (text)
  (let ((hash #xcbf29ce484222325)
        (prime #x100000001b3))
    (loop for ch across text do
      (setf hash (logand #xffffffffffffffff
                         (* (logxor hash (char-code ch)) prime))))
    hash))

(defun song-local-pathname (song)
  (make-pathname
   :name (format nil "~D" (logand (fnv1a-64 (song-url song)) #xffffffffffffffff))
   :type "mp3"
   :defaults *song-local-dir*))

(defun song-local-path (song)
  (namestring (song-local-pathname song)))

(defstruct app
  (downloaded-items nil)
  (items-semaphore (sb-thread:make-semaphore :count 0))
  (slots-semaphore (sb-thread:make-semaphore :count 5))
  (mutex (sb-thread:make-mutex :name "downloaded-queue")))

(defun queue-put (app song)
  (sb-thread:wait-on-semaphore (app-slots-semaphore app))
  (sb-thread:with-mutex ((app-mutex app))
    (setf (app-downloaded-items app)
          (nconc (app-downloaded-items app) (list song))))
  (sb-thread:signal-semaphore (app-items-semaphore app)))

(defun queue-get (app)
  (sb-thread:wait-on-semaphore (app-items-semaphore app))
  (let ((song nil))
    (sb-thread:with-mutex ((app-mutex app))
      (setf song (first (app-downloaded-items app))
            (app-downloaded-items app) (rest (app-downloaded-items app))))
    (sb-thread:signal-semaphore (app-slots-semaphore app))
    song))

(defun random-song ()
  (when (> (length *songs*) 0)
    (aref *songs* (random (length *songs*)))))

(defun run-program-exit-code (program args)
  (handler-case
      (let ((process (sb-ext:run-program program args
                                         :search t
                                         :wait t
                                         :input t
                                         :output t
                                         :error t)))
        (sb-ext:process-exit-code process))
    (error ()
      1)))

(defun wget (url output-path)
  (run-program-exit-code "wget"
                         (list "--quiet"
                               (concatenate 'string "--output-document=" output-path)
                               url)))

(defun download-local-file (osong counter app)
  (let* ((song (make-song :url (song-url osong)
                          :title (song-title osong)
                          :number counter))
         (lpath (song-local-path song)))
    (unless (probe-file lpath)
      (loop repeat 5 do
        (when (zerop (wget (song-url song) lpath))
          (return))
        (sleep 0.5)))
    (queue-put app song)))

(defun add-random-song (app)
  (let ((song (random-song)))
    (when song
      (let ((counter (incf *song-counter*)))
        (sb-thread:make-thread
         (lambda ()
           (download-local-file song counter app))
         :name (format nil "download-~D" counter))))))

(defun remove-song (song)
  (ignore-errors
    (delete-file (song-local-pathname song))))

(defun add-another (app song)
  (remove-song song)
  (add-random-song app))

(defun split-path (path)
  (let ((parts '())
        (start 0)
        (len (length path)))
    (loop for i from 0 to len do
      (when (or (= i len)
                (char= (char path i) #\:))
        (push (subseq path start i) parts)
        (setf start (1+ i))))
    (nreverse parts)))

(defun find-abs-path-of-executable (cmd)
  (let ((path (sb-ext:posix-getenv "PATH")))
    (when path
      (loop for dir in (split-path path)
            for candidate = (merge-pathnames cmd
                                             (pathname (if (string= dir "")
                                                           "./"
                                                           (if (char= (char dir (1- (length dir))) #\/)
                                                               dir
                                                               (concatenate 'string dir "/")))))
            when (probe-file candidate)
              do (return (namestring candidate))))))

(defun should-be-present (cmd)
  (unless (find-abs-path-of-executable cmd)
    (format *error-output* "This program needs ~A to work.~%" cmd)
    (finish-output *error-output*)
    (sb-ext:exit :code 1)))

(defun enqueue-random-songs (app count)
  (loop repeat count do
    (add-random-song app)))

(defun main ()
  (setf *random-state* (make-random-state t))
  (should-be-present "mpg321")
  (should-be-present "wget")
  (ensure-directories-exist (merge-pathnames "placeholder" *song-local-dir*))
  (format t "Local folder: ~A~%" (namestring *song-local-dir*))
  (finish-output)
  (let ((app (make-app)))
    (enqueue-random-songs app 5)
    (loop
      for song = (queue-get app) do
        (format t "Playing \"~A\" from URL: ~40A ...~%"
                (song-title song)
                (song-url song))
        (finish-output)
        (let ((res (run-program-exit-code "mpg321"
                                          (list "--quiet" (song-local-path song)))))
          (format t "res: ~D~%" res)
          (finish-output)
          (when (= res 4)
            (format *error-output* "mpg321 was interrupted by Ctrl-C. Good bye.~%")
            (finish-output *error-output*)
            (sb-ext:exit :code 1)))
        (add-another app song))))
