;;; agent-shell-org-transcript.el --- Org-mode transcripts for agent-shell  -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Aleksei Korolev

;; Author: Aleksei Korolev <lllshamanlll@gmail.com>
;; URL: https://github.com/lllShamanlll/agent-shell-org-transcript
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.50.1"))
;; Keywords: tools outlines

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Provides org-mode transcript support for `agent-shell'.
;; Saves conversation transcripts as .org files in `org-roam-directory'
;; or a user-specified directory, with content converted from markdown
;; to org-mode format.
;;
;; Simply requiring the package enables org transcripts:
;;
;;   (require 'agent-shell-org-transcript)
;;
;; By default transcripts go into `org-roam-directory'.  To use a
;; different directory:
;;
;;   (setq agent-shell-org-transcript-directory "~/notes/agent-shell/")

;;; Code:

(require 'agent-shell)
(require 'map)
(require 'org-id)

(defcustom agent-shell-org-transcript-directory nil
  "Directory for org transcript files.
When nil, falls back to `org-roam-directory' if bound and non-nil."
  :type '(choice (const :tag "Use org-roam-directory" nil)
                 (directory :tag "Custom directory"))
  :group 'agent-shell)

(defun agent-shell-org-transcript-file-path ()
  "Generate an org transcript file path in the configured directory.

Uses `agent-shell-org-transcript-directory' if set, otherwise falls
back to `org-roam-directory'.  Returns nil if neither is available.

The filename includes the date, time, and agent name to avoid collisions
when multiple agents run simultaneously.

For example, when `org-roam-directory' is \"~/org\" and the agent is Claude Code:

  ~/org/2024-01-15-14-30-00-claude_code-a3f9.org"
  (when-let ((dir (or agent-shell-org-transcript-directory
                      (and (boundp 'org-roam-directory) org-roam-directory))))
    (let ((agent-slug (agent-shell--org-transcript-sanitize-tag
                       (or (map-nested-elt agent-shell--state '(:agent-config :mode-line-name))
                           (map-nested-elt agent-shell--state '(:agent-config :buffer-name))
                           "unknown"))))
      (expand-file-name
       (format "%s-%s-%04x.org" (format-time-string "%F-%H-%M-%S") agent-slug (random 65536))
       dir))))

(defun agent-shell--org-transcript-sanitize-tag (str)
  "Sanitize STR for use as an org-mode tag.

Lowercases the string and replaces characters outside [a-zA-Z0-9_@#%]
with underscores.

For example:

  (agent-shell--org-transcript-sanitize-tag \"My Project\")
    => \"my_project\"
  (agent-shell--org-transcript-sanitize-tag \"claude-code\")
    => \"claude_code\""
  (downcase
   (replace-regexp-in-string "[^a-zA-Z0-9_@#%]" "_" str)))

(defun agent-shell--org-transcript-project-tag ()
  "Return an org tag string for the current project or working directory.

Uses `project-current' when available, falling back to the last
component of `agent-shell-cwd'.

For example, when cwd is \"/home/user/projects/my-app\":

  => \"my_app\""
  (agent-shell--org-transcript-sanitize-tag
   (or (when-let* (((fboundp 'project-current))
                   (proj (project-current))
                   (root (project-root proj)))
         (file-name-nondirectory (directory-file-name root)))
       (file-name-nondirectory (directory-file-name (agent-shell-cwd))))))

(defun agent-shell--org-transcript-filetags ()
  "Return a #+FILETAGS string for the transcript.

Always includes :agent-shell:.  Also includes a tag for the agent
name and one for the current project so transcripts can be filtered
by either in org-roam.

For example:

  => \":agent-shell:claude_code:my_project:\""
  (let ((agent-tag (agent-shell--org-transcript-sanitize-tag
                    (or (map-nested-elt agent-shell--state '(:agent-config :mode-line-name))
                        (map-nested-elt agent-shell--state '(:agent-config :buffer-name))
                        "unknown")))
        (project-tag (agent-shell--org-transcript-project-tag)))
    (format ":agent-shell:%s:%s:" agent-tag project-tag)))

(defun agent-shell--org-transcript-header ()
  "Generate an org-mode header for a new transcript file."
  (let ((agent-name (or (map-nested-elt agent-shell--state '(:agent-config :mode-line-name))
                        (map-nested-elt agent-shell--state '(:agent-config :buffer-name))
                        "Unknown Agent")))
    (format ":PROPERTIES:
:ID:       %s
:END:
#+TITLE: Transcript: %s %s
#+DATE: %s
#+FILETAGS: %s
#+PROPERTY: Agent %s
#+PROPERTY: Working_Directory %s

"
            (org-id-new)
            agent-name
            (format-time-string "%F %T")
            (format-time-string "%F %T")
            (agent-shell--org-transcript-filetags)
            agent-name
            (agent-shell-cwd))))

(defun agent-shell--org-transcript-convert (text)
  "Convert markdown transcript TEXT to org-mode format.

Converts the structural markdown elements used in agent-shell transcripts:
- ATX headers (## Heading -> ** Heading)
- Block quotes (> text -> #+begin_quote/#+end_quote)
- Code fences (\\=`\\=`\\=`lang -> #+begin_src lang/#+end_src)
- Bold (**text** -> *text*)
- Horizontal rules (--- -> -----)

For example:

  (agent-shell--org-transcript-convert \"## Agent (2024-01-15)\\n\\n\")
    => \"** Agent (2024-01-15)\\n\\n\""
  (with-temp-buffer
    (insert text)
    ;; Convert ATX headers: ## Foo -> ** Foo, ### Foo -> *** Foo, etc.
    (goto-char (point-min))
    (while (re-search-forward "^\\(#+\\) " nil t)
      (replace-match (concat (make-string (length (match-string 1)) ?*) " ")))
    ;; Convert code fences: ```lang -> #+begin_src lang, ``` -> #+end_src
    (goto-char (point-min))
    (while (re-search-forward "^\\(`\\{3,\\}\\)\\(.*\\)$" nil t)
      (let ((lang (string-trim (match-string 2))))
        (if (string-empty-p lang)
            (replace-match "#+end_src")
          (replace-match (concat "#+begin_src " lang)))))
    ;; Convert block quotes: > text -> #+begin_quote\ntext\n#+end_quote
    (goto-char (point-min))
    (while (re-search-forward "^> \\(.*\\)$" nil t)
      (replace-match "#+begin_quote\n\\1\n#+end_quote"))
    ;; Convert **bold** to *bold*
    (goto-char (point-min))
    (while (re-search-forward "\\*\\*\\([^*\n]+\\)\\*\\*" nil t)
      (replace-match "*\\1*"))
    ;; Convert horizontal rules
    (goto-char (point-min))
    (while (re-search-forward "^---+$" nil t)
      (replace-match "-----"))
    (buffer-string)))

(defun agent-shell--org-transcript-p ()
  "Return non-nil when the current buffer uses an org transcript file."
  (when-let ((filepath agent-shell--transcript-file))
    (string-suffix-p ".org" filepath)))

(defun agent-shell--org-ensure-transcript-advice (orig-fun)
  "Around advice for `agent-shell--ensure-transcript-file'.
Writes an org header instead of the default markdown header when
the transcript file has a .org extension."
  (if (not (agent-shell--org-transcript-p))
      (funcall orig-fun)
    (unless (derived-mode-p 'agent-shell-mode)
      (user-error "Not in an agent-shell buffer"))
    (when-let* ((filepath agent-shell--transcript-file)
                (dir (file-name-directory filepath)))
      (unless (file-exists-p filepath)
        (condition-case err
            (progn
              (make-directory dir t)
              (write-region (agent-shell--org-transcript-header) nil filepath nil 'no-message)
              (message "Created %s" (agent-shell--shorten-paths filepath t)))
          (error
           (message "Failed to initialize org transcript: %S" err))))
      filepath)))

(defun agent-shell--org-append-transcript-advice (orig-fun &rest args)
  "Around advice for `agent-shell--append-transcript'.
Converts markdown TEXT to org format when writing to a .org file."
  (if (not (agent-shell--org-transcript-p))
      (apply orig-fun args)
    (let ((text (plist-get args :text))
          (file-path (plist-get args :file-path)))
      (when text
        (apply orig-fun (list :text (agent-shell--org-transcript-convert text)
                              :file-path file-path))))))

(advice-add 'agent-shell--ensure-transcript-file :around
            #'agent-shell--org-ensure-transcript-advice)
(advice-add 'agent-shell--append-transcript :around
            #'agent-shell--org-append-transcript-advice)

(setq agent-shell-transcript-file-path-function
      #'agent-shell-org-transcript-file-path)

;;; Migration

(defun agent-shell--org-transcript-parse-md (content)
  "Parse a markdown transcript CONTENT into metadata and body.

Returns an alist with keys :agent, :date, :working-dir, :body.

For example, given CONTENT starting with:

  # Agent Shell Transcript
  **Agent:** Claude Code
  **Started:** 2024-01-15 14:30:00
  **Working Directory:** /home/user/project

returns:

  ((:agent . \"Claude Code\") (:date . \"2024-01-15 14:30:00\") ...)"
  (let ((agent "Unknown Agent")
        (date "")
        (working-dir "")
        (body-start 0))
    (when (string-match "\\*\\*Agent:\\*\\* \\(.+\\)" content)
      (setq agent (string-trim (match-string 1 content))))
    (when (string-match "\\*\\*Started:\\*\\* \\(.+\\)" content)
      (setq date (string-trim (match-string 1 content))))
    (when (string-match "\\*\\*Working Directory:\\*\\* \\(.+\\)" content)
      (setq working-dir (string-trim (match-string 1 content))))
    (when (string-match "^---\n\n" content)
      (setq body-start (match-end 0)))
    (list (cons :agent agent)
          (cons :date date)
          (cons :working-dir working-dir)
          (cons :body (substring content body-start)))))

(defun agent-shell--org-transcript-migration-path (dest-dir agent date)
  "Return a destination .org path in DEST-DIR derived from AGENT and DATE.

DATE is expected in \"YYYY-MM-DD HH:MM:SS\" format.

For example:

  => \"/org/2024-01-15-14-30-00-claude_code-a3f9.org\""
  (let* ((agent-slug (agent-shell--org-transcript-sanitize-tag agent))
         (time-str (if (string-match
                        "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\) \\([0-9:]\\{8\\}\\)"
                        date)
                       (format "%s-%s"
                               (match-string 1 date)
                               (replace-regexp-in-string ":" "-" (match-string 2 date)))
                     (format-time-string "%F-%H-%M-%S"))))
    (expand-file-name
     (format "%s-%s-%04x.org" time-str agent-slug (random 65536))
     dest-dir)))

(defun agent-shell--org-transcript-migration-header (agent date working-dir)
  "Generate an org header for a transcript migrated from markdown.

AGENT, DATE, and WORKING-DIR are strings parsed from the original file."
  (let* ((agent-tag (agent-shell--org-transcript-sanitize-tag agent))
         (project-tag (agent-shell--org-transcript-sanitize-tag
                       (file-name-nondirectory (directory-file-name
                                                (if (string-empty-p working-dir)
                                                    "unknown"
                                                  working-dir))))))
    (format ":PROPERTIES:
:ID:       %s
:END:
#+TITLE: Transcript: %s %s
#+DATE: %s
#+FILETAGS: :agent-shell:%s:%s:
#+PROPERTY: Agent %s
#+PROPERTY: Working_Directory %s

"
            (org-id-new)
            agent date
            date
            agent-tag project-tag
            agent
            working-dir)))

(defun agent-shell--org-transcript-migrate-file (md-file dest-dir)
  "Convert MD-FILE to org and write it into DEST-DIR.
Returns the destination path on success, nil on failure."
  (condition-case err
      (let* ((content (with-temp-buffer
                        (insert-file-contents md-file)
                        (buffer-string)))
             (meta (agent-shell--org-transcript-parse-md content))
             (agent (map-elt meta :agent))
             (date (map-elt meta :date))
             (working-dir (map-elt meta :working-dir))
             (body (map-elt meta :body))
             (dest (agent-shell--org-transcript-migration-path dest-dir agent date)))
        (write-region
         (concat (agent-shell--org-transcript-migration-header agent date working-dir)
                 (agent-shell--org-transcript-convert body))
         nil dest nil 'no-message)
        dest)
    (error
     (message "Failed to migrate %s: %S" md-file err)
     nil)))

(defun agent-shell--org-transcript-show-plan (md-files dest-dir)
  "Display a migration plan buffer listing MD-FILES and DEST-DIR.
Groups files by their .agent-shell/ parent directory."
  (let ((buf (get-buffer-create "*Agent Shell Transcript Migration*")))
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (insert (format "Destination: %s\n\n" (abbreviate-file-name dest-dir)))
      (insert (format "Found %d transcript(s) to migrate:\n\n" (length md-files)))
      (let ((by-dir (seq-group-by #'file-name-directory md-files)))
        (dolist (group by-dir)
          (insert (format "  %s\n" (abbreviate-file-name (car group))))
          (dolist (f (cdr group))
            (insert (format "    %s\n" (file-name-nondirectory f))))
          (insert "\n")))
      (insert "Migrated files will be deleted. Empty .agent-shell/ dirs will be removed.\n")
      (read-only-mode 1))
    (display-buffer buf)
    buf))

(defun agent-shell-org-transcript-migrate (root)
  "Migrate markdown transcripts under ROOT to the configured org directory.

Recursively finds all .agent-shell/transcripts/*.md files under ROOT
and shows a preview.  Proceeds only after user confirmation.

Converts files to org format and writes them to
`agent-shell-org-transcript-directory' or `org-roam-directory'.

After migration:
- Migrated .md files are deleted.
- Empty transcripts/ directories are removed.
- .agent-shell/ directories that only contained transcripts/ are removed.
- .agent-shell/ directories with other remaining content are reported."
  (interactive "DRoot directory: ")
  (let ((dest-dir (or agent-shell-org-transcript-directory
                      (and (boundp 'org-roam-directory) org-roam-directory))))
    (unless dest-dir
      (user-error
       "No destination: set `agent-shell-org-transcript-directory' or `org-roam-directory'"))
    (let* ((md-files (seq-filter
                      (lambda (f)
                        (string-match-p "/\\.agent-shell/transcripts/[^/]+\\.md$" f))
                      (directory-files-recursively (expand-file-name root) "\\.md$"
                                                   nil #'file-readable-p)))
           (total (length md-files)))
      (if (zerop total)
          (message "No markdown transcripts found under %s" root)
        (agent-shell--org-transcript-show-plan md-files dest-dir)
        (when (yes-or-no-p (format "Migrate %d transcript(s) to %s? "
                                   total (abbreviate-file-name dest-dir)))
          (make-directory dest-dir t)
          (let ((migrated 0)
                (failed 0)
                (transcripts-dirs (seq-uniq (mapcar #'file-name-directory md-files))))
            (dolist (md-file md-files)
              (if (agent-shell--org-transcript-migrate-file md-file dest-dir)
                  (progn (delete-file md-file) (setq migrated (1+ migrated)))
                (setq failed (1+ failed))))
            ;; Remove empty transcripts/ dirs and their .agent-shell/ parents
            (dolist (transcripts-dir transcripts-dirs)
              (when (file-directory-p transcripts-dir)
                (let ((remaining (cddr (directory-files transcripts-dir))))
                  (if remaining
                      (message "Kept %s — still contains: %s"
                               (abbreviate-file-name transcripts-dir)
                               (mapconcat #'identity remaining ", "))
                    (condition-case nil
                        (progn
                          (delete-directory transcripts-dir)
                          (let* ((dot-dir (file-name-directory
                                           (directory-file-name transcripts-dir)))
                                 (dot-remaining (cddr (directory-files dot-dir))))
                            (if dot-remaining
                                (message "Kept %s — still contains: %s"
                                         (abbreviate-file-name dot-dir)
                                         (mapconcat #'identity dot-remaining ", "))
                              (condition-case nil
                                  (delete-directory dot-dir)
                                (error (message "Kept %s — could not remove"
                                                (abbreviate-file-name dot-dir)))))))
                      (error (message "Kept %s — could not remove"
                                      (abbreviate-file-name transcripts-dir))))))))
            (message "Migrated %d/%d transcripts to %s%s"
                     migrated total
                     (abbreviate-file-name dest-dir)
                     (if (zerop failed) "" (format " (%d failed)" failed)))))))))

(provide 'agent-shell-org-transcript)
;;; agent-shell-org-transcript.el ends here
