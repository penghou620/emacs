;;; windmove.el --- directional window-selection routines  -*- lexical-binding:t -*-
;;
;; Copyright (C) 1998-2019 Free Software Foundation, Inc.
;;
;; Author: Hovav Shacham (hovav@cs.stanford.edu)
;; Created: 17 October 1998
;; Keywords: window, movement, convenience
;;
;; This file is part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.
;;
;; --------------------------------------------------------------------

;;; Commentary:
;;
;; This package defines a set of routines, windmove-{left,up,right,
;; down}, for selection of windows in a frame geometrically.  For
;; example, `windmove-right' selects the window immediately to the
;; right of the currently-selected one.  This functionality is similar
;; to the window-selection controls of the BRIEF editor of yore.
;;
;; One subtle point is what happens when the window to the right has
;; been split vertically; for example, consider a call to
;; `windmove-right' in this setup:
;;
;;                    -------------
;;                    |      | A  |
;;                    |      |    |
;;                    |      |-----
;;                    | *    |    |    (* is point in the currently
;;                    |      | B  |     selected window)
;;                    |      |    |
;;                    -------------
;;
;; There are (at least) three reasonable things to do:
;; (1) Always move to the window to the right of the top edge of the
;;     selected window; in this case, this policy selects A.
;; (2) Always move to the window to the right of the bottom edge of
;;     the selected window; in this case, this policy selects B.
;; (3) Move to the window to the right of point in the selected
;;     window.  This may select either A or B, depending on the
;;     position of point; in the illustrated example, it would select
;;     B.
;;
;; Similar issues arise for all the movement functions.  Windmove
;; resolves this problem by allowing the user to specify behavior
;; through a prefix argument.  The cases are thus:
;; * if no argument is given to the movement functions, or the
;;   argument given is zero, movement is relative to point;
;; * if a positive argument is given, movement is relative to the top
;;   or left edge of the selected window, depending on whether the
;;   movement is to be horizontal or vertical;
;; * if a negative argument is given, movement is relative to the
;;   bottom or right edge of the selected window, depending on whether
;;   the movement is to be horizontal or vertical.
;;
;;
;; Another feature enables wrap-around mode when the variable
;; `windmove-wrap-around' is set to a non-nil value.  In this mode,
;; movement that falls off the edge of the frame will wrap around to
;; find the window on the opposite side of the frame.  Windmove does
;; the Right Thing about the minibuffer; for example, consider:
;;
;;                    -------------
;;                    |    *      |
;;                    |-----------|
;;                    |     A     |
;;                    |-----------|    (* is point in the currently
;;                    |  B   | C  |     selected window)
;;                    |      |    |
;;                    -------------
;;
;; With wraparound enabled, windmove-down will move to A, while
;; windmove-up will move to the minibuffer if it is active, or to
;; either B or C depending on the prefix argument.
;;
;;
;; A set of default keybindings is supplied: shift-{left,up,right,down}
;; invoke the corresponding Windmove function.  See the installation
;; section if you wish to use these keybindings.


;; Installation:
;;
;; Put the following line in your init file:
;;
;;     (windmove-default-keybindings)         ; shifted arrow keys
;;
;; or
;;
;;     (windmove-default-keybindings 'hyper)  ; etc.
;;
;; to use another modifier key.
;;
;;
;; If you wish to enable wrap-around, also add a line like:
;;
;;    (setq windmove-wrap-around t)
;;
;;
;; Note: If you have an Emacs that manifests a bug that sometimes
;; causes the occasional creation of a "lost column" between windows,
;; so that two adjacent windows do not actually touch, you may want to
;; increase the value of `windmove-window-distance-delta' to 2 or 3:
;;
;;     (setq windmove-window-distance-delta 2)
;;

;; Acknowledgments:
;;
;; Special thanks to Julian Assange (proff@iq.org), whose
;; change-windows-intuitively.el predates Windmove, and provided the
;; inspiration for it.  Kin Cho (kin@symmetrycomm.com) was the first
;; to suggest wrap-around behavior.  Thanks also to Gerd Moellmann
;; (gerd@gnu.org) for his comments and suggestions.

;;; Code:


;; User configurable variables:

;; For customize ...
(defgroup windmove nil
  "Directional selection of windows in a frame."
  :prefix "windmove-"
  :version "21.1"
  :group 'windows
  :group 'convenience)


(defcustom windmove-wrap-around nil
  "Whether movement off the edge of the frame wraps around.
If this variable is set to t, moving left from the leftmost window in
a frame will find the rightmost one, and similarly for the other
directions.  The minibuffer is skipped over in up/down movements if it
is inactive."
  :type 'boolean
  :group 'windmove)

(defcustom windmove-create-window nil
  "Whether movement off the edge of the frame creates a new window.
If this variable is set to t, moving left from the leftmost window in
a frame will create a new window on the left, and similarly for the other
directions."
  :type 'boolean
  :group 'windmove
  :version "27.1")

;; If your Emacs sometimes places an empty column between two adjacent
;; windows, you may wish to set this delta to 2.
(defcustom windmove-window-distance-delta 1
  "How far away from the current window to look for an adjacent window.
Measured in characters either horizontally or vertically; setting this
to a value larger than 1 may be useful in getting around window-
placement bugs in old versions of Emacs."
  :type 'number
  :group 'windmove)



;; Implementation overview:
;;
;; The conceptual framework behind this code is all fairly simple.  We
;; are on one window; we wish to move to another.  The correct window
;; to move to is determined by the position of point in the current
;; window as well as the overall window setup.
;;
;; Early on, I made the decision to base my implementation around the
;; built-in function `window-at'.  This function takes a frame-based
;; coordinate, and returns the window that contains it.  Using this
;; function, the job of the various top-level windmove functions can
;; be decomposed: first, find the current frame-based location of
;; point; second, manipulate it in some way to give a new location,
;; that hopefully falls in the window immediately at left (or right,
;; etc.); third, use `window-at' and `select-window' to select the
;; window at that new location.
;;
;; This is probably not the only possible architecture, and it turns
;; out to have some inherent cruftiness.  (Well, okay, the third step
;; is pretty clean....)  We will consider each step in turn.
;;
;; A quick digression about coordinate frames: most of the functions
;; in the windmove package deal with screen coordinates in one way or
;; another.  These coordinates are always relative to some reference
;; points.  Window-based coordinates have their reference point in the
;; upper-left-hand corner of whatever window is being talked about;
;; frame-based coordinates have their reference point in the
;; upper-left-hand corner of the entire frame (of which the current
;; window is a component).
;;
;; All coordinates are zero-based, which simply means that the
;; reference point (whatever it is) is assigned the value (x=0, y=0).
;; X-coordinates grow down the screen, and Y-coordinates grow towards
;; the right of the screen.
;;
;; Okay, back to work.  The first step is to gather information about
;; the frame-based coordinates of point, or rather, the reference
;; location.  The reference location can be point, or the upper-left,
;; or the lower-right corner of the window; the particular one used is
;; controlled by the prefix argument to `windmove-left' and all the
;; rest.
;;
;; This work is done by `windmove-reference-loc'.  It can figure out
;; the locations of the corners by calling `window-edges' combined
;; with the result of `posn-at-point'.
;;
;; The second step is more messy.  Conceptually, it is fairly simple:
;; if we know the reference location, and the coordinates of the
;; current window, we can "throw" our reference point just over the
;; appropriate edge of the window, and see what other window is
;; there.  More explicitly, consider this example from the user
;; documentation above.
;;
;;                    -------------
;;                    |      | A  |
;;                    |      |    |
;;                    |      |-----
;;                    | *    |    |    (* is point in the currently
;;                    |      | B  |     selected window)
;;                    |      |    |
;;                    -------------
;;
;; The asterisk marks the reference point; we wish to move right.
;; Since we are moving horizontally, the Y coordinate of the new
;; location will be the same.  The X coordinate can be such that it is
;; just past the edge of the present window.  Obviously, the new point
;; will be inside window B.  This in itself is fairly simple: using
;; the result of `windmove-reference-loc' and `window-edges', all the
;; necessary math can be performed.  (Having said that, there is a
;; good deal of room for off-by-one errors, and Emacs 19.34, at least,
;; sometimes manifests a bug where two windows don't actually touch,
;; so a larger skip is required.)  The actual math here is done by
;; `windmove-other-window-loc'.
;;
;; But we can't just pass the result of `windmove-other-window-loc' to
;; `window-at' directly.  Why not?  Suppose a move would take us off
;; the edge of the screen, say to the left.  We want to give a
;; descriptive error message to the user.  Or, suppose that a move
;; would place us in the minibuffer.  What if the minibuffer is
;; inactive?
;;
;; Actually, the whole subject of the minibuffer edge of the frame is
;; rather messy.  It turns out that with a sufficiently large delta,
;; we can fly off the bottom edge of the frame and miss the minibuffer
;; altogether.  This, I think, is never right: if there's a minibuffer
;; and you're not in it, and you move down, the minibuffer should be
;; in your way.
;;
;; (By the way, I'm not totally sure that the code does the right
;; thing in really weird cases, like a frame with no minibuffer.)
;;
;; So, what we need is some ways to do constraining and such.  The
;; early versions of windmove took a fairly simplistic approach to all
;; this.  When I added the wrap-around option, those internals had to
;; be rewritten.  After a *lot* of futzing around, I came up with a
;; two-step process that I think is general enough to cover the
;; relevant cases.  (I'm not totally happy with having to pass the
;; window variable as deep as I do, but we can't have everything.)
;;
;; In the first phase, we make sure that the new location is sane.
;; "Sane" means that we can only fall of the edge of the frame in the
;; direction we're moving in, and that we don't miss the minibuffer if
;; we're moving down and not already in the minibuffer.  The function
;; `windmove-constrain-loc-for-movement' takes care of all this.
;;
;; Then, we handle the wraparound, if it's enabled.  The function
;; `windmove-wrap-loc-for-movement' takes coordinate values (both X
;; and Y) that fall off the edge of the frame, and replaces them with
;; values on the other side of the frame.  It also has special
;; minibuffer-handling code again, because we want to wrap through the
;; minibuffer if it's not enabled.
;;
;; So, that's it.  Seems to work.  All of this work is done by the fun
;; function `windmove-find-other-window'.
;;
;; So, now we have a window to move to (or nil if something's gone
;; wrong).  The function `windmove-do-window-select' is the main
;; driver function: it actually does the `select-window'.  It is
;; called by four little convenience wrappers, `windmove-left',
;; `windmove-up', `windmove-right', and `windmove-down', which make
;; for convenient keybinding.


;; Quick & dirty utility function to add two (x . y) coords.
(defun windmove-coord-add (coord1 coord2)
  "Add the two coordinates.
Both COORD1 and COORD2 are coordinate cons pairs, (HPOS . VPOS).  The
result is another coordinate cons pair."
  (cons (+ (car coord1) (car coord2))
        (+ (cdr coord1) (cdr coord2))))


(defun windmove-constrain-to-range (n min-n max-n)
  "Ensure that N is between MIN-N and MAX-N inclusive by constraining.
If N is less than MIN-N, return MIN-N; if greater than MAX-N, return
MAX-N."
  (max min-n (min n max-n)))

(defun windmove-constrain-around-range (n min-n max-n)
  "Ensure that N is between MIN-N and MAX-N inclusive by wrapping.
If N is less than MIN-N, return MAX-N; if greater than MAX-N, return
MIN-N."
  (cond
   ((< n min-n) max-n)
   ((> n max-n) min-n)
   (t n)))

(defun windmove-frame-edges (window)
  "Return (X-MIN Y-MIN X-MAX Y-MAX) for the frame containing WINDOW.
If WINDOW is nil, return the edges for the selected frame.
\(X-MIN, Y-MIN) is the zero-based coordinate of the top-left corner
of the frame; (X-MAX, Y-MAX) is the zero-based coordinate of the
bottom-right corner of the frame.
For example, if a frame has 76 rows and 181 columns, the return value
from `windmove-frame-edges' will be the list (0 0 180 75)."
  (let* ((frame (if window
		    (window-frame window)
		  (selected-frame)))
	 (top-left (window-edges (frame-first-window frame)))
	 (x-min (nth 0 top-left))
	 (y-min (nth 1 top-left))
	 (x-max (1- (frame-width frame))) ; 1- for last row & col
	 (y-max (1- (frame-height frame))))
    (list x-min y-min x-max y-max)))

;; it turns out that constraining is always a good thing, even when
;; wrapping is going to happen.  this is because:
;; first, since we disallow exotic diagonal-around-a-corner type
;; movements, so we can always fix the unimportant direction (the one
;; we're not moving in).
;; second, if we're moving down and we're not in the minibuffer, then
;; constraining the y coordinate to max-y is okay, because if that
;; falls in the minibuffer and the minibuffer isn't active, that y
;; coordinate will still be off the bottom of the frame as the
;; wrapping function sees it and so will get wrapped around anyway.
(defun windmove-constrain-loc-for-movement (coord window dir)
  "Constrain COORD so that it is reasonable for the given movement.
This involves two things: first, make sure that the \"off\" coordinate
-- the one not being moved on, e.g., y for horizontal movement -- is
within frame boundaries; second, if the movement is down and we're not
moving from the minibuffer, make sure that the y coordinate does not
exceed the frame max-y, so that we don't overshoot the minibuffer
accidentally.  WINDOW is the window that movement is relative to; DIR
is the direction of the movement, one of `left', `up', `right',
or `down'.
Returns the constrained coordinate."
  (let ((frame-edges (windmove-frame-edges window))
        (in-minibuffer (window-minibuffer-p window)))
    (let ((min-x (nth 0 frame-edges))
          (min-y (nth 1 frame-edges))
          (max-x (nth 2 frame-edges))
          (max-y (nth 3 frame-edges)))
      (let ((new-x
             (if (memq dir '(up down))    ; vertical movement
                 (windmove-constrain-to-range (car coord) min-x max-x)
               (car coord)))
            (new-y
             (if (or (memq dir '(left right)) ; horizontal movement
                     (and (eq dir 'down)
                          (not in-minibuffer))) ; don't miss minibuffer
                 ;; (technically, we shouldn't constrain on min-y in the
                 ;; second case, but this shouldn't do any harm on a
                 ;; down movement.)
                 (windmove-constrain-to-range (cdr coord) min-y max-y)
               (cdr coord))))
        (cons new-x new-y)))))

;; having constrained in the limited sense of windmove-constrain-loc-
;; for-movement, the wrapping code is actually much simpler than it
;; otherwise would be.  the only complication is that we need to check
;; if the minibuffer is active, and, if not, pretend that it's not
;; even part of the frame.
(defun windmove-wrap-loc-for-movement (coord window)
  "Takes the constrained COORD and wraps it around for the movement.
This makes an out-of-range x or y coordinate and wraps it around the
frame, giving a coordinate (hopefully) in the window on the other edge
of the frame.  WINDOW is the window that movement is relative to (nil
means the currently selected window).  Returns the wrapped coordinate."
  (let* ((frame-edges (windmove-frame-edges window))
         (frame-minibuffer (minibuffer-window (if window
                                                  (window-frame window)
                                                (selected-frame))))
         (minibuffer-active (minibuffer-window-active-p
                               frame-minibuffer)))
    (let ((min-x (nth 0 frame-edges))
          (min-y (nth 1 frame-edges))
          (max-x (nth 2 frame-edges))
          (max-y (if (not minibuffer-active)
                     (- (nth 3 frame-edges)
                        (window-height frame-minibuffer))
                   (nth 3 frame-edges))))
      (cons
       (windmove-constrain-around-range (car coord) min-x max-x)
       (windmove-constrain-around-range (cdr coord) min-y max-y)))))


;; This calculates the reference location in the current window: the
;; frame-based (x . y) of either point, the top-left, or the
;; bottom-right of the window, depending on ARG.
(defun windmove-reference-loc (&optional arg window)
  "Return the reference location for directional window selection.
Return a coordinate (HPOS . VPOS) that is frame-based.  If ARG is nil
or not supplied, the reference point is the buffer's point in the
currently-selected window, or WINDOW if supplied; otherwise, it is the
top-left or bottom-right corner of the selected window, or WINDOW if
supplied, if ARG is greater or smaller than zero, respectively."
  (let ((effective-arg (if (null arg) 0 (prefix-numeric-value arg)))
        (edges (window-inside-edges window)))
    (let ((top-left (cons (nth 0 edges)
                          (nth 1 edges)))
	  ;; Subtracting 1 converts the edge to the last column or line
	  ;; within the window.
          (bottom-right (cons (- (nth 2 edges) 1)
                              (- (nth 3 edges) 1))))
      (cond
       ((> effective-arg 0)
	top-left)
       ((< effective-arg 0)
	bottom-right)
       ((= effective-arg 0)
	(windmove-coord-add
	 top-left
	 ;; Don't care whether window is horizontally scrolled -
	 ;; `posn-at-point' handles that already.  See also:
	 ;; https://lists.gnu.org/r/emacs-devel/2012-01/msg00638.html
	 (posn-col-row
	  (posn-at-point (window-point window) window))))))))

;; This uses the reference location in the current window (calculated
;; by `windmove-reference-loc' above) to find a reference location
;; that will hopefully be in the window we want to move to.
(defun windmove-other-window-loc (dir &optional arg window)
  "Return a location in the window to be moved to.
Return value is a frame-based (HPOS . VPOS) value that should be moved
to.  DIR is one of `left', `up', `right', or `down'; an optional ARG
is handled as by `windmove-reference-loc'; WINDOW is the window that
movement is relative to."
  (let ((edges (window-edges window))   ; edges: (x0, y0, x1, y1)
        (refpoint (windmove-reference-loc arg window))) ; (x . y)
    (cond
     ((eq dir 'left)
      (cons (- (nth 0 edges)
               windmove-window-distance-delta)
            (cdr refpoint)))            ; (x0-d, y)
     ((eq dir 'up)
      (cons (car refpoint)
            (- (nth 1 edges)
               windmove-window-distance-delta))) ; (x, y0-d)
     ((eq dir 'right)
      (cons (+ (1- (nth 2 edges))	; -1 to get actual max x
               windmove-window-distance-delta)
            (cdr refpoint)))            ; (x1+d-1, y)
     ((eq dir 'down)			; -1 to get actual max y
      (cons (car refpoint)
            (+ (1- (nth 3 edges))
               windmove-window-distance-delta))) ; (x, y1+d-1)
     (t (error "Invalid direction of movement: %s" dir)))))

;; Rewritten on 2013-12-13 using `window-in-direction'.  After the
;; pixelwise change the old approach didn't work any more.  martin
(defun windmove-find-other-window (dir &optional arg window)
  "Return the window object in direction DIR.
DIR, ARG, and WINDOW are handled as by `windmove-other-window-loc'."
  (window-in-direction dir window nil arg windmove-wrap-around t))

;; Selects the window that's hopefully at the location returned by
;; `windmove-other-window-loc', or screams if there's no window there.
(defun windmove-do-window-select (dir &optional arg window)
  "Move to the window at direction DIR.
DIR, ARG, and WINDOW are handled as by `windmove-other-window-loc'.
If no window is at direction DIR, an error is signaled.
If `windmove-create-window' is non-nil, try to create a new window
in direction DIR instead."
  (let ((other-window (windmove-find-other-window dir arg window)))
    (when (and windmove-create-window
               (or (null other-window)
                   (and (window-minibuffer-p other-window)
                        (not (minibuffer-window-active-p other-window)))))
      (setq other-window (split-window window nil dir)))
    (cond ((null other-window)
           (user-error "No window %s from selected window" dir))
          ((and (window-minibuffer-p other-window)
                (not (minibuffer-window-active-p other-window)))
           (user-error "Minibuffer is inactive"))
          (t
           (select-window other-window)))))


;;; end-user functions
;; these are all simple interactive wrappers to
;; `windmove-do-window-select', meant to be bound to keys.

;;;###autoload
(defun windmove-left (&optional arg)
  "Select the window to the left of the current one.
With no prefix argument, or with prefix argument equal to zero,
\"left\" is relative to the position of point in the window; otherwise
it is relative to the top edge (for positive ARG) or the bottom edge
\(for negative ARG) of the current window.
If no window is at the desired location, an error is signaled
unless `windmove-create-window' is non-nil and a new window is created."
  (interactive "P")
  (windmove-do-window-select 'left (and arg (prefix-numeric-value arg))))

;;;###autoload
(defun windmove-up (&optional arg)
  "Select the window above the current one.
With no prefix argument, or with prefix argument equal to zero, \"up\"
is relative to the position of point in the window; otherwise it is
relative to the left edge (for positive ARG) or the right edge (for
negative ARG) of the current window.
If no window is at the desired location, an error is signaled
unless `windmove-create-window' is non-nil and a new window is created."
  (interactive "P")
  (windmove-do-window-select 'up (and arg (prefix-numeric-value arg))))

;;;###autoload
(defun windmove-right (&optional arg)
  "Select the window to the right of the current one.
With no prefix argument, or with prefix argument equal to zero,
\"right\" is relative to the position of point in the window;
otherwise it is relative to the top edge (for positive ARG) or the
bottom edge (for negative ARG) of the current window.
If no window is at the desired location, an error is signaled
unless `windmove-create-window' is non-nil and a new window is created."
  (interactive "P")
  (windmove-do-window-select 'right (and arg (prefix-numeric-value arg))))

;;;###autoload
(defun windmove-down (&optional arg)
  "Select the window below the current one.
With no prefix argument, or with prefix argument equal to zero,
\"down\" is relative to the position of point in the window; otherwise
it is relative to the left edge (for positive ARG) or the right edge
\(for negative ARG) of the current window.
If no window is at the desired location, an error is signaled
unless `windmove-create-window' is non-nil and a new window is created."
  (interactive "P")
  (windmove-do-window-select 'down (and arg (prefix-numeric-value arg))))


;;; set up keybindings
;; Idea for this function is from iswitchb.el, by Stephen Eglen
;; (stephen@cns.ed.ac.uk).
;; I don't think these bindings will work on non-X terminals; you
;; probably want to use different bindings in that case.

;;;###autoload
(defun windmove-default-keybindings (&optional modifiers)
  "Set up keybindings for `windmove'.
Keybindings are of the form MODIFIERS-{left,right,up,down},
where MODIFIERS is either a list of modifiers or a single modifier.
Default value of MODIFIERS is `shift'."
  (interactive)
  (unless modifiers (setq modifiers 'shift))
  (unless (listp modifiers) (setq modifiers (list modifiers)))
  (global-set-key (vector (append modifiers '(left)))  'windmove-left)
  (global-set-key (vector (append modifiers '(right))) 'windmove-right)
  (global-set-key (vector (append modifiers '(up)))    'windmove-up)
  (global-set-key (vector (append modifiers '(down)))  'windmove-down))

;;; Directional window display and selection

(defcustom windmove-display-no-select nil
  "Whether the window should be selected after displaying the buffer in it."
  :type 'boolean
  :group 'windmove
  :version "27.1")

(defun windmove-display-in-direction (dir &optional arg)
  "Display the next buffer in the window at direction DIR.
The next buffer is the buffer displayed by the next command invoked
immediately after this command (ignoring reading from the minibuffer).
Create a new window if there is no window in that direction.
By default, select the window with a displayed buffer.
If prefix ARG is `C-u', reselect a previously selected window.
If `windmove-display-no-select' is non-nil, this command doesn't
select the window with a displayed buffer, and the meaning of
the prefix argument is reversed.
When `switch-to-buffer-obey-display-actions' is non-nil,
`switch-to-buffer' commands are also supported."
  (let* ((no-select (not (eq (consp arg) windmove-display-no-select))) ; xor
         (old-window (or (minibuffer-selected-window) (selected-window)))
         (new-window)
         (minibuffer-depth (minibuffer-depth))
         (action display-buffer-overriding-action)
         (command this-command)
         (clearfun (make-symbol "clear-display-buffer-overriding-action"))
         (exitfun
          (lambda ()
            (setq display-buffer-overriding-action action)
            (when (window-live-p (if no-select old-window new-window))
              (select-window (if no-select old-window new-window)))
            (remove-hook 'post-command-hook clearfun))))
    (fset clearfun
          (lambda ()
            (unless (or
		     ;; Remove the hook immediately
		     ;; after exiting the minibuffer.
		     (> (minibuffer-depth) minibuffer-depth)
		     ;; But don't remove immediately after
		     ;; adding the hook by the same command below.
		     (eq this-command command))
              (funcall exitfun))))
    (add-hook 'post-command-hook clearfun)
    (push (lambda (buffer alist)
	    (unless (> (minibuffer-depth) minibuffer-depth)
	      (let ((window (if (eq dir 'same-window)
			        (selected-window)
                              (window-in-direction
                               dir nil nil
                               (and arg (prefix-numeric-value arg))
                               windmove-wrap-around)))
                    (type 'reuse))
                (unless window
                  (setq window (split-window nil nil dir) type 'window))
		(setq new-window (window--display-buffer buffer window type alist)))))
          display-buffer-overriding-action)
    (message "[display-%s]" dir)))

;;;###autoload
(defun windmove-display-left (&optional arg)
  "Display the next buffer in window to the left of the current one.
See the logic of the prefix ARG in `windmove-display-in-direction'."
  (interactive "P")
  (windmove-display-in-direction 'left arg))

;;;###autoload
(defun windmove-display-up (&optional arg)
  "Display the next buffer in window above the current one.
See the logic of the prefix ARG in `windmove-display-in-direction'."
  (interactive "P")
  (windmove-display-in-direction 'up arg))

;;;###autoload
(defun windmove-display-right (&optional arg)
  "Display the next buffer in window to the right of the current one.
See the logic of the prefix ARG in `windmove-display-in-direction'."
  (interactive "P")
  (windmove-display-in-direction 'right arg))

;;;###autoload
(defun windmove-display-down (&optional arg)
  "Display the next buffer in window below the current one.
See the logic of the prefix ARG in `windmove-display-in-direction'."
  (interactive "P")
  (windmove-display-in-direction 'down arg))

;;;###autoload
(defun windmove-display-same-window (&optional arg)
  "Display the next buffer in the same window."
  (interactive "P")
  (windmove-display-in-direction 'same-window arg))

;;;###autoload
(defun windmove-display-default-keybindings (&optional modifiers)
  "Set up keybindings for directional buffer display.
Keys are bound to commands that display the next buffer in the specified
direction.  Keybindings are of the form MODIFIERS-{left,right,up,down},
where MODIFIERS is either a list of modifiers or a single modifier.
Default value of MODIFIERS is `shift-meta'."
  (interactive)
  (unless modifiers (setq modifiers '(shift meta)))
  (unless (listp modifiers) (setq modifiers (list modifiers)))
  (global-set-key (vector (append modifiers '(left)))  'windmove-display-left)
  (global-set-key (vector (append modifiers '(right))) 'windmove-display-right)
  (global-set-key (vector (append modifiers '(up)))    'windmove-display-up)
  (global-set-key (vector (append modifiers '(down)))  'windmove-display-down)
  (global-set-key (vector (append modifiers '(?0)))    'windmove-display-same-window))

;;; Directional window deletion

(defun windmove-delete-in-direction (dir &optional arg)
  "Delete the window at direction DIR.
If prefix ARG is `\\[universal-argument]', also kill the buffer in that window.
With `M-0' prefix, delete the selected window and
select the window at direction DIR.
When `windmove-wrap-around' is non-nil, takes the window
from the opposite side of the frame."
  (let ((other-window (window-in-direction dir nil nil arg
                                           windmove-wrap-around t)))
    (cond ((null other-window)
           (user-error "No window %s from selected window" dir))
          (t
           (when (equal arg '(4))
             (kill-buffer (window-buffer other-window)))
           (if (not (equal arg 0))
               (delete-window other-window)
             (delete-window (selected-window))
             (select-window other-window))))))

;;;###autoload
(defun windmove-delete-left (&optional arg)
  "Delete the window to the left of the current one.
If prefix ARG is `C-u', delete the selected window and
select the window that was to the left of the current one."
  (interactive "P")
  (windmove-delete-in-direction 'left arg))

;;;###autoload
(defun windmove-delete-up (&optional arg)
  "Delete the window above the current one.
If prefix ARG is `C-u', delete the selected window and
select the window that was above the current one."
  (interactive "P")
  (windmove-delete-in-direction 'up arg))

;;;###autoload
(defun windmove-delete-right (&optional arg)
  "Delete the window to the right of the current one.
If prefix ARG is `C-u', delete the selected window and
select the window that was to the right of the current one."
  (interactive "P")
  (windmove-delete-in-direction 'right arg))

;;;###autoload
(defun windmove-delete-down (&optional arg)
  "Delete the window below the current one.
If prefix ARG is `C-u', delete the selected window and
select the window that was below the current one."
  (interactive "P")
  (windmove-delete-in-direction 'down arg))

;;;###autoload
(defun windmove-delete-default-keybindings (&optional prefix modifiers)
  "Set up keybindings for directional window deletion.
Keys are bound to commands that delete windows in the specified
direction.  Keybindings are of the form PREFIX MODIFIERS-{left,right,up,down},
where PREFIX is a prefix key and MODIFIERS is either a list of modifiers or
a single modifier.  Default value of PREFIX is `C-x' and MODIFIERS is `shift'."
  (interactive)
  (unless prefix (setq prefix '(?\C-x)))
  (unless (listp prefix) (setq prefix (list prefix)))
  (unless modifiers (setq modifiers '(shift)))
  (unless (listp modifiers) (setq modifiers (list modifiers)))
  (global-set-key (vector prefix (append modifiers '(left)))  'windmove-delete-left)
  (global-set-key (vector prefix (append modifiers '(right))) 'windmove-delete-right)
  (global-set-key (vector prefix (append modifiers '(up)))    'windmove-delete-up)
  (global-set-key (vector prefix (append modifiers '(down)))  'windmove-delete-down))

(provide 'windmove)

;;; windmove.el ends here
