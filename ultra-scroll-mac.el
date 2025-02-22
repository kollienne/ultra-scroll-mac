;;; ultra-scroll-mac.el --- Fast and smooth scrolling for emacs-mac -*- lexical-binding: t; -*-
;; Copyright (C) 2023  J.D. Smith

;; Author: J.D. Smith
;; Homepage: https://github.com/jdtsmith/ultra-scroll-mac
;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; Keywords: convenience
;; Prefix: ultra-scroll-mac
;; Separator: -

;; ultra-scroll-mac is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; ultra-scroll-mac is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; ultra-scroll-mac enables fast, smooth, jump-free scrolling for
;; emacs-mac (https://bitbucket.org/mituharu/emacs-mac), retaining the
;; swipe-to-scroll and pinch-out for tab overview capabilities of that
;; port.  It can scroll past images taller than the window without
;; problem.
;;
;; The strongly recommended scroll settings are:
;;  scroll-margin=0
;;  scroll-conservatively=101
;;
;; See also pixel-precision-scroll-mode in pixel-scroll.el.

;;; Code:
;;;; Requires
;;(require 'mac-win nil 'noerror)
(require 'pixel-scroll)
(require 'mwheel)
(require 'timer)

;;;; Customize
(defcustom ultra-scroll-mac-multiplier 1.
  "Multiplier for smooth scroll step for wheeled mice.
This multiplies the fractional delta-y values generated by
regular mouse wheels by the value returned by
`frame-char-height'.  Increase it to increase scrolling speed on
such mice.  Note that some mice drivers emulate trackpads, and so
will not be affected by this setting.  Adjust scrolling speed
directly with those drivers instead."
  :group 'mouse
  :type 'float)

(defcustom ultra-scroll-mac-gc-percentage 0.67
  "Value to temporarily set `gc-cons-percentage'.
This is set when a trackpad event registers :phase began, and
restored during idle time (see `ultra-scroll-mac-gc-idle-time')."
  :type '(choice (const :tag "Disable" nil) float)
  :group 'mouse)

(defcustom ultra-scroll-mac-gc-idle-time 0.5
  "Idle time in sec after which to restore `gc-cons-percentage'.
Operates only if `ultra-scroll-mac-gc-percentage' is non-nil."
  :type 'float
  :group 'mouse)

;;;; Event callback/scroll
(defun ultra-scroll-mac-down (delta)
  "Scroll the current window down by DELTA pixels.
DELTA should not be larger than the height of the current window."
  (let* ((initial (point))
	 (edges (window-edges nil t nil t))
	 (current-vs (window-vscroll nil t))
	 (off (+ (window-tab-line-height) (window-header-line-height)))
         (new-start (or (posn-point (posn-at-x-y 0 (+ delta off))) (window-start))))
    (goto-char new-start)
    (unless (zerop (window-hscroll))
      (setq new-start (beginning-of-visual-line)))
    (if (>= (line-pixel-height) (- (nth 3 edges) (nth 1 edges)))
	;; Jumbo line at top: just stay on it and increment vscroll
	(set-window-vscroll nil (+ current-vs delta) t t)
      (if (eq new-start (window-start))	; same start: just vscroll a bit more
	  (setq delta (+ current-vs delta))
	(setq delta (- delta (cdr (posn-x-y (posn-at-point new-start)))))
	(set-window-start nil new-start (not (zerop delta))))
      (set-window-vscroll nil delta t t)
      ;; Avoid recentering
      (goto-char (posn-point (posn-at-x-y 0 off))) ; window-start may be above
      (if (zerop (vertical-motion 1))	; move down 1 line from top
	  (signal 'end-of-buffer nil))
      (if (> initial (point)) (goto-char initial)))))

(defun ultra-scroll-mac-up (delta)
  "Scroll the current window up by DELTA pixels.
DELTA should be less than the window's height."
  (let* ((initial (point))
	 (edges (window-edges nil t nil t))
	 (win-height (- (nth 3 edges) (nth 1 edges)))
	 (win-start (window-start))
	 (current-vs (window-vscroll nil t))
	 (start win-start))
    (if (<= delta current-vs)	    ; simple case: just reduce vscroll
	(setq delta (- current-vs delta))
      ; Not enough vscroll: measure size above window-start
      (let* ((dims (window-text-pixel-size nil (cons start (- current-vs delta))
					   start nil nil nil t))
	     (pos (nth 2 dims))
	     (height (nth 1 dims)))
	(when (or (not pos) (eq pos (point-min)))
	  (signal 'beginning-of-buffer nil))
	(setq start (nth 2 dims)
	      delta (- (+ height current-vs) delta))) ; should be >= 0
      (unless (eq start win-start)
	(set-window-start nil start (not (zerop delta)))))
    (when (>= delta 0) (set-window-vscroll nil delta t t))
    
    ;; Position point to avoid recentering, moving up one line from
    ;; the bottom, if necessary.  "Jumbo" lines (taller than the
    ;; window height, usually due to images) must be handled
    ;; carefully.  Once they are within the window, point should stay
    ;; on the first tall object on the line until the top of the jumbo
    ;; line clears the top of the window, then immediately moved off
    ;; (above), via the full height character.  The is the only way to
    ;; avoid unwanted re-centering/motion trapping.
    (if (> (line-pixel-height) win-height) ; a jumbo on the line!
	(let ((end (max (point)
			(save-excursion
			  (end-of-visual-line)
			  (1- (point)))))) ; don't fall off
	  (when-let ((pv (pos-visible-in-window-p end nil t))
		     ((and (> (length pv) 2) ; falls outside window
			   (zerop (nth 2 pv))))) ; but not at the top
	    (goto-char end) ; eol is usually full height
	    (goto-char start))) ; now move up
      (when-let ((p (posn-at-x-y 0 (1- win-height))))
	(goto-char (posn-point p))
	(vertical-motion -1)
	(if (< initial (point)) (goto-char initial))))))

(defvar ultra-scroll-mac--gc-percentage-orig nil)
(defvar ultra-scroll-mac--gc-idle-timer nil)
(defun ultra-scroll-mac--restore-gc ()
  "Reset GC variable during idle time."
  (setq gc-cons-percentage
	(or ultra-scroll-mac--gc-percentage-orig 0.1)
	ultra-scroll-mac--gc-idle-timer nil))

(defun ultra-scroll-mac (event &optional arg)
  "Smooth scroll mac-style scroll EVENT.
Event and optional ARG are passed on to `mwheel-scroll', for any
events not handled here.  If swipe-tracking is enabled for
swipe-between-pages at the OS level, left-/right-swipe events
will be replayed.  If `ultra-scroll-mac-gc-percentage' is
non-nil, temporarily lift the garbage collection percentage to
avoid GC's during scroll."
  (interactive "e")
  (let ((ev-type (event-basic-type event))
	(plist (nth 1 event)))
    (if (not (memq ev-type '(wheel-up wheel-down)))
	(when (memq ev-type '(wheel-left wheel-right))
	  (if mouse-wheel-tilt-scroll
	      ;; (mac-forward-wheel-event t 'mwheel-scroll event arg)
	    (when (and ;; "Swipe between pages" enabled.
		   (plist-get plist :swipe-tracking-from-scroll-events-enabled-p)
		   (eq (plist-get plist :momentum-phase) 'began))
	      ;; Post a swipe event when left/right momentum phase begins
	      (push (cons (event-convert-list
			   (nconc (delq 'click
					(delq 'double
					      (delq 'triple
						    (event-modifiers event))))
				  (if (eq (event-basic-type event) 'wheel-left)
				      '(swipe-left) '(swipe-right))))
			  (cdr event))
		    unread-command-events))))
      ;;  Wheel events: smooth scrolling
      (when (and ultra-scroll-mac-gc-percentage
		 (not ultra-scroll-mac--gc-idle-timer))
	(setq gc-cons-percentage 	; reduce GC's during scroll
	      (max gc-cons-percentage ultra-scroll-mac-gc-percentage)
	      ultra-scroll-mac--gc-idle-timer
	      (run-with-idle-timer ultra-scroll-mac-gc-idle-time nil
				   #'ultra-scroll-mac--restore-gc)))
      (let ((dy 'nil)
	    (delta (cdr (car (last event))))
	    (window (mwheel-event-window event))
	    ignore)
	(if delta ; turn regular mouse wheel events into smooth scroll style
	    (setq delta (round delta)) ;pixel-scroll requires wholenum pixels
	  (setq delta (round (* dy ultra-scroll-mac-multiplier (frame-char-height)))))
	(unless (or (zerop delta)
		    (and (setq ignore (window-parameter window 'ultra-scroll--ignore))
			 (or (and (eq (point) (car ignore)) (eq (cdr ignore) (< delta 0)))
			     (set-window-parameter window 'ultra-scroll--ignore nil))))
	  (with-selected-window window
	    (condition-case err
		(if (< delta 0)
		    (ultra-scroll-mac-down (- delta))
		  (ultra-scroll-mac-up delta))
	      ;; Do not ding at buffer limits.  Show a message instead (once!).
	      ((beginning-of-buffer end-of-buffer)
	       (let* ((end (eq (car err) 'end-of-buffer))
		      (p (if end (point-max) (point-min))))
		 ;; (debug)
		 (goto-char p)
		 (set-window-start window p)
		 (set-window-vscroll window 0 t t)
		 (set-window-parameter window 'ultra-scroll--ignore
				       (cons (point) end))
		 (message (error-message-string
			   (if end '(end-of-buffer) '(beginning-of-buffer)))))))))))))

; scroll-isearch support
(put 'ultra-scroll-mac 'scroll-command t)

;;;; Mode
;;;###autoload
(define-minor-mode ultra-scroll-mac-mode
  "Toggle pixel precision scrolling for mac.
When enabled, this minor mode scrolls the display precisely using
full mac trackpad capabilities (and simulating them for regular
mouse).  Makes use of the underlying pixel-scrolling capabilities
of `ultra-scroll-mode', which see."
  :global t
  :group 'mouse
  :keymap pixel-scroll-precision-mode-map ; reuse
  (cond
   (ultra-scroll-mac-mode
    ;;(unless (featurep 'mac-win)
    ;;  (error "Precision Scroll Mac Mode works only with emacs-mac (not NS), you have:\n %s" (emacs-version)))
    (unless (> scroll-conservatively 0)
      (warn "ultra-scroll-mac: scroll-conservatively > 0 is required for smooth scrolling of large images; 101 recommended"))
    (unless (= scroll-margin 0)
      (warn "ultra-scroll-mac: scroll-margin = 0 is required for glitch-free smooth scrolling"))
    (define-key pixel-scroll-precision-mode-map [remap pixel-scroll-precision]
		#'ultra-scroll-mac)
    (setf (get 'ultra-scroll-use-momentum 'orig-value)
	  pixel-scroll-precision-use-momentum)
    (setq pixel-scroll-precision-use-momentum nil)
    (setq ultra-scroll-mac--gc-percentage-orig gc-cons-percentage))
   (t
    (define-key pixel-scroll-precision-mode-map [remap pixel-scroll-precision] nil)
    (setq pixel-scroll-precision-use-momentum
	  (get 'ultra-scroll-use-momentum 'orig-value))))
  (setq mwheel-coalesce-scroll-events
        (not ultra-scroll-mac-mode)))

(provide 'ultra-scroll-mac)
;;; ultra-scroll-mac.el ends here

