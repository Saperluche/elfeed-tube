;;; elfeed-tube.el --- Youtube integration for Elfeed  -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Karthik Chikmagalur

;; Author: Karthik Chikmagalur <karthikchikmagalur@gmail.com>
;; Keywords: news, hypermedia, convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:
(require 'elfeed)
(require 'cl-lib)
(require 'subr-x)
(require 'aio)

(defgroup elfeed-tube nil
  "Elfeed-tube: View youtube details in Elfeed"
  :group 'elfeed
  :prefix "elfeed-tube-")

(defcustom elfeed-tube-metadata-fields
  '(duration thumbnail description captions)
  "Metadata types to fetch for youtube entries in Elfeed.

This is a list of symbols. The ordering is not relevant.

The choices are
- duration for video length,
- thumbnail for video thumbnail,
- description for video description,
- captions for video transcript,
- comments for top video comments. (NOT YET IMPLEMENTED)

Other symbols are ignored.

To set the thumbnail size, see `elfeed-tube-thumbnail-size'.
To set caption language(s), see `elfeed-tube-captions-languages'."
  :group 'elfeed-tube
  :type '(repeat (choice (const duration :tag "Duration")
                         (const thumbnail :tag "Thumbnail")
                         (const description :tag "Description")
                         (const captions :tag "Transcript")))) ;TODO

(defcustom elfeed-tube-thumbnail-size 'small
  "Video thumbnail size to show in the Elfeed buffer.

Choices are LARGE, MEDIUM and SMALL.
Set this to NIL to disable showing thumbnails."
  :group 'elfeed-tube
  :type '(choice (const :tag "No thumbnails" nil)
                 (const :tag "Large thumbnails" large)
                 (const :tag "Medium thumbnails" medium)
                 (const :tag "Small thumbnails" small)))

(defcustom elfeed-tube-invidious-url nil
  "Invidious URL to use for retrieving data.

Setting this is optional: If left unset, elfeed-tube will locate
and use an Invidious URL at random. This should be set to a
string, for example \"https://invidio.us\". "
  :group 'elfeed-tube
  :type '(choice (string :tag "Custom URL")
                 (const :tag "Disabled (Auto)" nil)))

(defcustom elfeed-tube-youtube-regexps '("youtube\\.com" "youtu\\.be")
  "List of regular expressions to match Elfeed entry URLs against.

Only entries that match one of these regexps will be handled by
elfeed-tube when fetching information."
  :group 'elfeed-tube
  :type '(repeat string))

(defcustom elfeed-tube-captions-languages
  '("english" "english (auto generated)")
  "Caption language priority for elfeed-tube captions.

Captions in the first available langauge in this list will be fetched. Each entry (string) in the list can be a language (case-insensitive, \"english\") or language codes:
- \"en\" for English
- \"tr\" for Turkish
- \"ar\" for Arabic, etc

Example: (\"tr\" \"english\" \"arabic\" \"es\")
"
  :group 'elfeed-tube
  :type '(repeat string))

(defvar elfeed-tube--debug t)
(defvar elfeed-tube--api-videos-path "/api/v1/videos/")
(defvar elfeed-tube--info-table (make-hash-table :test #'equal))
(defvar elfeed-tube--invidious-servers nil)
(defvar elfeed-tube-save-to-db-p nil)
(defvar elfeed-tube--api-video-fields
  '("videoThumbnails" "descriptionHtml" "lengthSeconds"))
(defvar elfeed-tube--max-retries 2)

(defvar elfeed-tube--captions-db-directory
  (concat (file-name-as-directory
           elfeed-db-directory)
          "captions"))
(defvar elfeed-tube--captions-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] #'elfeed-tube--follow-captions-event)
    (define-key map (kbd "RET") #'elfeed-tube--follow-captions-link)
    (define-key map [follow-link] 'mouse-face)
    map))

;; Helpers
(defsubst elfeed-tube-include-p (field)
  (memq field elfeed-tube-metadata-fields))

(defsubst elfeed-tube--get-entries ()
  (pcase major-mode
    ('elfeed-search-mode
     (elfeed-search-selected))
    ('elfeed-show-mode
     (list elfeed-show-entry))))

(defsubst elfeed-tube--youtube-p (entry)
  (cl-some (lambda (regex) (string-match-p regex (elfeed-entry-link entry)))
           elfeed-tube-youtube-regexps))

(defsubst elfeed-tube--get-video-id (entry)
  (when (elfeed-tube--youtube-p entry)
    (thread-first (elfeed-entry-id entry)
                  cdr-safe
                  (substring 9))))

(defsubst elfeed-tube--random-elt (collection)
  (and collection
      (elt collection (cl-random (length collection)))))

(cl-defsubst elfeed-tube--message (str &optional attempts)
  (when elfeed-tube--debug
    (message
     (concat str
             (when (numberp attempts)
               (format " (%d/%d)"
                       (1+ (- elfeed-tube--max-retries
                              attempts))
                       elfeed-tube--max-retries))))
    nil))

(defsubst elfeed-tube--show-thumbnail (thumb)
  (when (and (elfeed-tube-include-p 'thumbnail) thumb)
    (concat "<img src=\"" thumb "\"></a><br><br>")))

(defsubst elfeed-tube--timestamp (time)
  (format "%d:%02d" (floor time 60) (mod time 60)))

(defsubst elfeed-tube--same-entry-p (entry1 entry2)
  (equal (elfeed-entry-id entry1)
         (elfeed-entry-id entry2)))

(defsubst elfeed-tube--match-captions-langs (lang el)
  (and (or (string-match-p
            lang
            (thread-first (plist-get el :name)
                          (plist-get :simpleText)))
           (string-match-p
            lang
            (plist-get el :languageCode)))
       el))

(defmacro elfeed-tube--debug (type &rest body)
  (declare (indent defun))
  `(let ((entry (pcase ,type
                  ('show (buffer-local-value
                          'elfeed-show-entry
                          (get-buffer "*elfeed-entry*")))
                  (_ (unless (buffer-live-p
                              (get-buffer "*elfeed-search*"))
                       (save-window-excursion (elfeed-search)))
                     (with-current-buffer (get-buffer "*elfeed-search*")
                       (elfeed-search-selected 'no-region))))))
     ,@body))

(defun elfeed-tube--extract-captions-urls ()
  (catch 'parse-error
    (if (not (search-forward "\"captions\":" nil t))
        (throw 'parse-error "captions section not found")
      (delete-region (point-min) (point))
      (if (not (search-forward ",\"videoDetails" nil t))
          (throw 'parse-error "video details not found")
        (goto-char (match-beginning 0))
        (delete-region (point) (point-max))
        (replace-string-in-region "\n" "" (point-min) (point-max))
        (goto-char (point-min))
        (condition-case error
            (json-parse-buffer :object-type 'plist
                               :array-type 'list)
          ('json-parse-error (throw 'parse-error "json-parse-error")))))))

;; Data structure
(cl-defstruct
    (elfeed-tube-item (:constructor elfeed-tube-item--create)
                      (:copier nil))
  "Struct to hold elfeed-tube metadata."
  length thumb desc caption error)

(defun elfeed-tube--parse-desc (api-data)
  "test"
  (let* ((length-seconds (plist-get api-data :lengthSeconds))
         (desc-html (replace-regexp-in-string
                     "\n" "<br>"
                     (plist-get api-data :descriptionHtml)))
         (thumb-alist '((large  . 2)
                        (medium . 3)
                        (small  . 4)))
         (thumb-size (cdr-safe (assoc elfeed-tube-thumbnail-size
                                      thumb-alist)))
         (thumb))
    (when (and (elfeed-tube-include-p 'thumbnail)
               thumb-size)
      (setq thumb (thread-first
                    (plist-get api-data :videoThumbnails)
                    (aref thumb-size)
                    (plist-get :url))))
    `(:length ,length-seconds :thumb ,thumb :desc ,desc-html)))

;; Persistence
(defun elfeed-tube--write-db (entry &optional data-item)
  (cl-assert (elfeed-entry-p entry))
  (when-let* ((data-item (or data-item (elfeed-tube--gethash entry))))
    (when (elfeed-tube-include-p 'description)
      (setf (elfeed-entry-content-type entry) 'html)
      (setf (elfeed-meta entry :duration)
            (elfeed-tube-item-length data-item))
      (setf (elfeed-entry-content entry)
            (when-let ((desc (elfeed-tube-item-desc data-item)))
              (elfeed-ref desc))))
    (when (elfeed-tube-include-p 'thumbnail)
      (setf (elfeed-meta entry :thumbnail)
            (elfeed-tube-item-thumb data-item)))
    (when (elfeed-tube-include-p 'captions)
      (setf (elfeed-meta entry :caption)
            (when-let ((caption (elfeed-tube-item-caption data-item))
                       (elfeed-db-directory
                        elfeed-tube--captions-db-directory))
              (elfeed-ref (prin1-to-string caption)))))
    t))

(defun elfeed-tube--gethash (entry)
  (cl-assert (elfeed-entry-p entry))
  (let ((video-id (elfeed-tube--get-video-id entry)))
    (gethash video-id elfeed-tube--info-table)))

(defun elfeed-tube--puthash (entry data-item &optional force)
  (cl-assert (elfeed-entry-p entry))
  (cl-assert (elfeed-tube-item-p data-item))
  (when-let* ((video-id (elfeed-tube--get-video-id entry))
              (_ (or force
                     (not (gethash video-id elfeed-tube--info-table)))))
    ;; (elfeed-tube--message
    ;;  (format "putting %s with data %S" video-id data-item))
    (puthash video-id data-item elfeed-tube--info-table)))

;; Content display
(defun elfeed-tube-show (&optional intended-entry)
  "Show extra video information in an elfeed-show buffer."
  (when-let* ((show-buf (get-buffer "*elfeed-entry*"))
              (entry (buffer-local-value 'elfeed-show-entry show-buf))
              (intended-entry (or intended-entry entry)))
    (when (elfeed-tube--same-entry-p entry intended-entry)
      (with-current-buffer show-buf
        (if-let* ((data-item (elfeed-tube--gethash entry)))
            ;; Load from cache, not db
            (progn
              (let* ((inhibit-read-only t)
                     (feed (elfeed-entry-feed elfeed-show-entry))
                     (base (and feed (elfeed-compute-base (elfeed-feed-url feed)))))
                (goto-char (point-max))
                (when (text-property-search-backward
                       'face 'message-header-name)
                  (beginning-of-line))
                (elfeed-tube--insert-duration
                 entry (elfeed-tube-item-length data-item))
                (if (or (and (elfeed-tube-item-desc data-item)
                             (not (elfeed-entry-content entry)))
                        (and (elfeed-tube-item-thumb data-item)
                             (not (elfeed-meta entry :thumbnail)))
                        (and (elfeed-tube-item-caption data-item)
                             (not (elfeed-meta entry :caption))))
                    (insert (propertize "[*NOT SAVED*]\n"
                                        'face
                                        '(:inherit message-cited-text-2
                                          :weight bold))))

                (when (or (elfeed-tube-item-thumb data-item)
                          (elfeed-tube-item-desc data-item)
                          (elfeed-tube-item-caption data-item))
                  (kill-region (point) (point-max))
                  (open-next-line 1))

                (elfeed-insert-html (elfeed-tube--show-desc data-item) base)
                (when (elfeed-tube-include-p 'captions)
                  (elfeed-tube--insert-captions (elfeed-tube-item-caption data-item)))))
          ;; not in cache, load from db with duration
          (when-let* ((entry elfeed-show-entry)
                      (duration (elfeed-meta elfeed-show-entry :duration))
                      (inhibit-read-only t))
            (elfeed-tube--insert-duration entry duration)

            (when-let ((_ (elfeed-tube-include-p 'thumbnail))
                       (thumb (elfeed-meta elfeed-show-entry :thumbnail)))
              (goto-char (point-max))
              (text-property-search-backward 'face 'message-header-name)
              (forward-line 2)
              (elfeed-insert-html (elfeed-tube--show-thumbnail thumb)))

            (when-let* ((_ (elfeed-tube-include-p 'captions))
                        (elfeed-db-directory elfeed-tube--captions-db-directory)
                        (capstr (elfeed-deref
                                 (elfeed-meta elfeed-show-entry :caption)))
                        (caption (read capstr)))
              (elfeed-tube--insert-captions caption))))
        (goto-char (point-min))))))

(defun elfeed-tube--insert-duration (entry duration)
  (if (not (integerp duration))
      (elfeed-tube--message
       (format "Duration not available for video \"%s\""
               (elfeed-entry-title entry)))
    (let ((inhibit-read-only t))
      (beginning-of-line)
      (if (looking-at "Duration:")
          (delete-region (point)
                         (save-excursion (end-of-line)
                                         (point)))
        (open-next-line 1))
      (insert (propertize "Duration: " 'face 'message-header-name)
              (propertize (elfeed-tube--timestamp duration)
                          'face 'message-header-other)
              "\n")
      t)))

(defun elfeed-tube--insert-captions (caption)
  (if  (and (listp caption)
            (eq (car-safe caption) 'transcript))
      (let ((caption-ordered
             (cl-loop for (_ (start dur) text) in (cddr caption)
                      with pstart = 0
                      for oldtime = 0 then time
                      for time = (string-to-number (cdr start))

                      if (< (mod (floor time) 30) (mod (floor oldtime) 30))
                      collect (list pstart time para) into result and
                      do (setq para nil pstart time)

                      collect (cons time (string-replace "\n" " " text)) into para
                      finally return (nconc result (list (list pstart time para)))))
            (inhibit-read-only t))
        (goto-char (point-max))
        (insert (propertize "\nTranscript:\n\n"
                            'face 'message-header-name))
        (cl-loop for (start end para) in caption-ordered
                 with beg = (point) do
                 (progn
                   (insert
                    (propertize
                     (format "[%s] - [%s]:\n"
                             (elfeed-tube--timestamp start)
                             (elfeed-tube--timestamp end))
                     'face 'message-header-other)
                    (propertize "\n" 'hard t)
                    (string-join
                     (mapcar (lambda (tx-cons)
                               (propertize (cdr tx-cons)
                                           'elfeed-tube-timestamp
                                           (car tx-cons)
                                           'face
                                           'variable-pitch
                                           'mouse-face
                                           'highlight
                                           'keymap
                                           elfeed-tube--captions-map))
                             para)
                     " ")
                    (propertize "\n\n" 'hard t)))
                 finally (when-let* ((w shr-width)
                                     (fill-column w)
                                     (use-hard-newlines t))
                           (fill-region beg (point) nil t)))
        (goto-char (point-min)))
    (elfeed-tube--message
     "elfeed-tube-captions--show: No captions available")))

(defun elfeed-tube--show-desc (data-item)
  (cl-assert (elfeed-tube-item-p data-item))
  (let ((desc     (elfeed-tube-item-desc data-item))
        (duration (elfeed-tube-item-length data-item))
        (thumb    (elfeed-tube-item-thumb data-item)))
    (concat
     (when (elfeed-tube-include-p 'thumbnail)
       (elfeed-tube--show-thumbnail thumb))
     (when (elfeed-tube-include-p 'description) desc))))

;; Setup
(defun elfeed-tube-setup (&optional db-insert-p)
  (defun elfeed-tube--auto-fetch (&optional entry)
    (elfeed-tube--fetch-1 (or entry elfeed-show-entry)
                          (when (or db-insert-p
                                    elfeed-tube-save-to-db-p)
                            '(4))))
  (advice-add elfeed-show-refresh-function :after #'elfeed-tube--auto-fetch)
  (add-hook 'elfeed-new-entry-hook #'elfeed-tube--auto-fetch)
  t)

;; (advice-add elfeed-show-refresh-function :after #'elfeed-tube-show)

(defun elfeed-tube-teardown ()
  (advice-remove elfeed-show-refresh-function #'elfeed-tube--auto-fetch)
  (remove-hook 'elfeed-new-entry-hook #'elfeed-tube--auto-fetch)
  t)

;; From aio-contrib.el: the workhorse
(defun elfeed-tube-curl-enqueue (url &rest args)
  "Like `elfeed-curl-enqueue' but delivered by a promise.

The result is a plist with the following keys:
:success -- the callback argument (t or nil)
:headers -- `elfeed-curl-headers'
:status-code -- `elfeed-curl-status-code'
:error-message -- `elfeed-curl-error-message'
:location -- `elfeed-curl-location'
:content -- (buffer-string)"
  (let* ((promise (aio-promise))
         (cb (lambda (success)
               (let ((result (list :success success
                                   :headers elfeed-curl-headers
                                   :status-code elfeed-curl-status-code
                                   :error-message elfeed-curl-error-message
                                   :location elfeed-curl-location
                                   :content (buffer-string))))
                 (aio-resolve promise (lambda () result))))))
    (prog1 promise
      (apply #'elfeed-curl-enqueue url cb args))))

;; Fetchers
(aio-defun elfeed-tube--get-invidious-servers ()
  (let* ((instances-url (concat "https://api.invidious.io/instances.json"
                                "?pretty=1&sort_by=type,users"))
         (result (aio-await (elfeed-tube-curl-enqueue instances-url :method "GET")))
         (status-code (plist-get result :status-code))
         (servers (plist-get result :content)))
    (when (= status-code 200)
      (thread-last
        (json-parse-string servers :object-type 'plist :array-type 'list)
        (cl-remove-if-not (lambda (s) (eq t (plist-get (cadr s) :api))))
        (mapcar #'car)))))

(aio-defun elfeed-tube--get-invidious-url ()
  (or elfeed-tube-invidious-url
      (let ((servers (or elfeed-tube--invidious-servers
                         (setq elfeed-tube--invidious-servers
                               (aio-await (elfeed-tube--get-invidious-servers))))))
        (elfeed-tube--random-elt servers))))

(aio-defun elfeed-tube--fetch-captions-tracks (entry)
  (let* ((video-id (elfeed-tube--get-video-id entry))
         (url (format "https://youtube.com/watch?v=%s" video-id))
         (response (aio-await (elfeed-tube-curl-enqueue url :method "GET")))
         (status-code (plist-get response :status-code)))
    (when-let*
        ((_ (= status-code 200))
         (data (with-temp-buffer
                 (save-excursion (insert (plist-get response :content)))
                 (elfeed-tube--extract-captions-urls))))
      ;; (message "%S" data)
      (thread-first
        data
        (plist-get :playerCaptionsTracklistRenderer)
        (plist-get :captionTracks)))))

(aio-defun elfeed-tube--fetch-captions-url (caption-plist)
  (let* ((case-fold-search t)
         (chosen-caption
          (cl-loop
           for lang in elfeed-tube-captions-languages
           for pick = (cl-some
                       (lambda (el) (elfeed-tube--match-captions-langs lang el))
                       caption-plist)
           until pick
           finally return pick))
         base-url language)
    (cond
     ((not caption-plist) (elfeed-tube--message "No captions found!"))
     ((not chosen-caption)
      (elfeed-tube--message
       (format "No captions found in %s!"
               (string-join elfeed-tube-captions-languages ", "))))
     (t (setq base-url (plist-get chosen-caption :baseUrl)
              language (thread-first (plist-get chosen-caption :name)
                                     (plist-get :simpleText)))
        (let* ((response (aio-await (elfeed-tube-curl-enqueue base-url :method "GET")))
               (captions (plist-get response :content))
               (status-code (plist-get response :status-code)))
          (if (= status-code 200)
              captions
            (elfeed-tube--message (plist-get response :error-message))
            (elfeed-tube--message (format "Fetching caption failed with %d" status-code))))))))

(aio-defun elfeed-tube--fetch-captions (entry)
  (when-let* ((urls (aio-await (elfeed-tube--fetch-captions-tracks entry)))
              (xmlcaps (aio-await (elfeed-tube--fetch-captions-url urls))))
    (with-temp-buffer
      (insert xmlcaps)
      (goto-char (point-min))
      (dolist (reps '(("&amp;#39;"  . "'")
                      ("&amp;quot;" . "\"")
                      ("\n"         . " ")
                      (" "          . "")))
        (save-excursion
          (while (search-forward (car reps) nil t)
            (replace-match (cdr reps) nil t))))
      (libxml-parse-xml-region (point-min) (point-max)))))

(aio-defun elfeed-tube--fetch-desc (entry &optional attempts)
  (let* ((attempts (or attempts (1+ elfeed-tube--max-retries)))
         (video-id (elfeed-tube--get-video-id entry)))
    (when (> attempts 0)
      (if-let ((invidious-url (aio-await (elfeed-tube--get-invidious-url))))
          (let* ((api-url (concat
                           invidious-url
                           elfeed-tube--api-videos-path
                           video-id
                           "?fields="
                           (string-join elfeed-tube--api-video-fields ",")))
                 (api-response (aio-await (elfeed-tube-curl-enqueue
                                           api-url
                                           :method "GET")))
                 (api-status (plist-get api-response :status-code))
                 (api-data (plist-get api-response :content))
                 (json-object-type (quote plist)))
            (if (= api-status 200)
                ;; Return data
                (condition-case error
                    (prog1
                        (elfeed-tube--parse-desc
                         (json-parse-string api-data :object-type 'plist)))
                  ('json-parse-error
                   (elfeed-tube--message "Malformed data, retrying fetch"
                                         attempts)
                   (aio-await
                    (elfeed-tube--fetch-desc entry (- attempts 1)))))
              ;; Retry #attempts times
              (elfeed-tube--message
               (format "Fetch failed with code %d, retrying fetch for \"%s\""
                       api-status
                       (elfeed-entry-title entry))
               attempts)
              (aio-await
               (elfeed-tube--fetch-desc entry (- attempts 1)))))

        (message
         "Could not find a valid Invidious url. Please cusomize `elfeed-tube-invidious-url'.")
        nil))))

(aio-defun elfeed-tube--fetch-1 (entry &optional force-fetch)
  (when (elfeed-tube--youtube-p entry)
    (let* ((existing (elfeed-tube--gethash entry))
           (data-item (or existing
                          (elfeed-tube-item--create))))

      ;; Record description
      (when (and (or (elfeed-tube-include-p 'thumbnail)
                     (elfeed-tube-include-p 'description))
                 (or force-fetch
                     (not (or existing
                              (elfeed-entry-content entry)))))
        (if-let ((api-data
                  (aio-await (elfeed-tube--fetch-desc entry))))
            (progn
              (when (elfeed-tube-include-p 'thumbnail)
                (setf (elfeed-tube-item-thumb data-item)
                      (plist-get api-data :thumb)))
              (when (elfeed-tube-include-p 'description)
                (setf (elfeed-tube-item-length data-item)
                      (plist-get api-data :length))
                (setf (elfeed-tube-item-desc data-item)
                      (plist-get api-data :desc))))
          (push 'desc (elfeed-tube-item-error data-item))))

      ;; Record captions
      (when (and (elfeed-tube-include-p 'captions)
                 (or force-fetch
                     (not (or existing
                              (elfeed-ref-p
                               (elfeed-meta entry :caption))))))
        (if-let ((caption (aio-await (elfeed-tube--fetch-captions entry))))
            (setf (elfeed-tube-item-caption data-item) caption)
          (push 'caption (elfeed-tube-item-error data-item))))

      (if elfeed-tube-save-to-db-p
          ;; Store in db
          (progn (elfeed-tube--write-db entry data-item)
                 (when (elfeed-tube--same-entry-p
                        entry elfeed-show-entry)
                   (elfeed-show-refresh))
                 (elfeed-tube--message
                  (format "Saved to elfeed-db: %s"
                          (elfeed-entry-title entry))))
        ;; Store in session cache
        (elfeed-tube--puthash entry data-item force-fetch)
        (elfeed-tube-show entry)))))

;; Interaction
(defun elfeed-tube--follow-captions-event (event)
  (interactive "e")
  (let ((pos (posn-point (event-end event))))
    (elfeed-tube--follow-captions-link pos)))

(defun elfeed-tube--follow-captions-link (pos &optional browser)
  (interactive "d")
  (when-let ((time (get-text-property pos 'elfeed-tube-timestamp))
             (browse-url-browser-function
              (or browser
                  'browse-url-default-browser)))
    (browse-url (concat "https://youtube.com/watch?v="
                        ;; "kaFF1n8ZzaU"
                        (elfeed-tube--get-video-id elfeed-show-entry)
                        "&t="
                        (number-to-string (floor time))))))

;; Entry points
;;;autoload(autoload 'elfeed-tube-fetch "elfeed-tube" "Fetch youtube metadata for Elfeed entries." t nil)
(aio-defun elfeed-tube-fetch (entries &optional force-fetch)
  "Fetch youtube metadata for Elfeed ENTRIES.

In elfeed-show buffers, ENTRIES is the entry being displayed.

In elfeed-search buffers, ENTRIES is the entry at point, or all
entries in the region when the region is active.

With optional prefix argument FORCE-FETCH, force refetching of
the metadata for ENTRIES.

If you want to always add this metadata to the database, consider
setting `elfeed-tube-save-to-db-p'. To customize what kinds of
metadata are fetched, customize TODO
`elfeed-tube-metadata-fields'."
  (interactive (list (elfeed-tube--get-entries)
                     current-prefix-arg))
  (if elfeed-tube-metadata-fields
    (aio-await
     (aio-all
      (cl-loop for entry in (ensure-list entries)
               collect (elfeed-tube--fetch-1 entry force-fetch))))
    (message "Nothing to fetch! Customize `elfeed-tube-metadata-fields'.")))

;;;###autoload
(defun elfeed-tube-save (entries)
  "Save elfeed-tube youtube metadata for ENTRIES to the elfeed database.

ENTRIES is the current elfeed entry in elfeed-show buffers. In
elfeed-search buffers it's the entry at point or the selected
entries when the region is active."
  (interactive (list (elfeed-tube--get-entries)))
  (dolist (entry entries)
    (if (elfeed-tube--write-db entry)
        (progn (message "Wrote to elfeed-db: \"%s\"" (elfeed-entry-title entry))
               (when (derived-mode-p 'elfeed-show-mode)
                 (elfeed-show-refresh)))
      (message "elfeed-db already contains: \"%s\"" (elfeed-entry-title entry)))))

(provide 'elfeed-tube)
;;; elfeed-tube.el ends here
