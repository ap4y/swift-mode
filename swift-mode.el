;;; swift-mode.el --- Major-mode for Apple's Swift programming language. -*- lexical-binding: t -*-

;; Copyright (C) 2014-2016 Chris Barrett, Bozhidar Batsov, Arthur Evstifeev

;; Authors: Chris Barrett <chris.d.barrett@me.com>
;;       Bozhidar Batsov <bozhidar@batsov.com>
;;       Arthur Evstifeev <lod@pisem.net>
;; Version: 0.5.0-snapshot
;; Package-Requires: ((emacs "24.4"))
;; Keywords: languages swift

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Major-mode for Apple's Swift programming language.

;;; Code:

(require 'rx)
(require 'comint)
(require 'cl-lib)

(defgroup swift nil
  "Configuration for swift-mode."
  :group 'languages
  :prefix "swift-")

(defcustom swift-indent-offset 4
  "Defines the indentation offset for Swift code."
  :group 'swift
  :type 'integer)

(defcustom swift-indent-switch-case-offset 0
  "Defines the indentation offset for cases in a switch statement."
  :group 'swift
  :type 'integer)

(defcustom swift-indent-multiline-statement-offset 2
  "Defines the indentation offset for multiline statements."
  :group 'swift
  :type 'integer
  :package-version '(swift-mode "0.3.0"))

(defcustom swift-indent-hanging-comma-offset nil
  "Defines the indentation offset for hanging comma."
  :group 'swift
  :type '(choice (const :tag "Use default relative formatting" nil)
                 (integer :tag "Custom offset"))
  :package-version '(swift-mode "0.4.0"))

(defcustom swift-repl-executable
  "xcrun swift"
  "Path to the Swift CLI."
  :group 'swift)

;;; Indentation

(require 'smie)

(defconst swift-smie-grammar
  (smie-prec2->grammar
   (smie-merge-prec2s
    (smie-bnf->prec2
     '((id)
       (inst (if-clause)
             ("guard" exp "else" "{" insts "}")
             ("switch" exp "{" switch-body "}")
             ("enum" exp "{" insts "}")
             ("ecase" exps)
             ("for" for-head "{" insts "}")
             ("for-case" exp "{" insts "}")
             ("while" exp "{" insts "}")
             (repeat-clause)
             ("class" exps "{" insts "}")
             ("extension" exps "{" insts "}")
             ("func" exp "{" insts "}")
             ("func" exp "->" exps "{" insts "}")
             ("protocol" exp "{" insts "}")
             ("defer" "{" insts "}")
             (do-clause)
             (compiler-control)
             ("let" exp)
             ("var" exp)
             ("return" exp)
             (exp))
       (insts (insts ";" insts) (inst))
       (exp ("<T" exps "T>")
            (exp "." id)
            (id ":" exp)
            (exp "=" exp)
            (closure-arg)
            ("(" func-args ")"))
       (exps (exps "," exps) (exp))

       (if-clause (if-clause "elseif" exp "{" insts "}")
                  (if-clause "else" "{" insts "}")
                  (if-body))
       (if-body ("if" exp "{" insts "}") ("if-case" exp "{" insts "}"))

       (cc-body-else (insts) (cc-body-else "#else" insts))
       (cc-body (cc-body-else) (cc-body "#elseif" cc-body))
       (compiler-control ("#if" cc-body "#endif"))

       (switch-body (switch-body "case-;" switch-body)
                    ("case" exps "case-:" insts)
                    ("default" "case-:" insts))

       (enum-body (enum-body ";" enum-body) (inst) ("ecase" exps))

       (for-head (exp) (for-head ";" for-head) (exp "in" exp))

       (do-clause (do-clause "catch" exp "{" insts "}")
                  (do-body))
       (do-body ("do" "{" insts "}"))

       (repeat-clause (repeat-clause "r-while" exp)
                      (repeat-body))
       (repeate-body ("repeat" "{" insts "}"))

       (closure-arg ("closure-{" closure-exp "closure-}"))
       (closure-exp (insts) (closure-signature "closure-in" insts)
                    (closure-signature "->" id "closure-in" insts))
       (closure-signature (exp) ("closure-(" exps "closure-)") ("[" exps "]"))

       (func-args (func-args "," func-args)
                  (id ":" closure-arg)
                  (exp)))
     ;; Conflicts
     '((nonassoc "{") (assoc ";"))
     '((assoc ","))
     '((assoc "case-;"))
     '((assoc "#elseif"))
     '((right "=") (assoc ".") (assoc ":") (assoc ","))
     )

    (smie-precs->prec2
     '(
       (right "*=" "/=" "%=" "+=" "-=" "<<=" ">>=" "&="
              "^=" "|=" "&&=" "||=" "=")                       ;; Assignment (Right associative, precedence level 90)
       (right "?" ":")                                         ;; Ternary Conditional (Right associative, precedence level 100)
       (left "||")                                             ;; Disjunctive (Left associative, precedence level 110)
       (left "&&")                                             ;; Conjunctive (Left associative, precedence level 120)
       (right "??")                                            ;; Nil Coalescing (Right associativity, precedence level 120)
       (nonassoc "<" "<=" ">" ">=" "==" "!=" "===" "!==" "~=") ;; Comparative (No associativity, precedence level 130)
       (nonassoc "is" "as" "as!" "as?")                        ;; Cast (No associativity, precedence level 132)
       (nonassoc "..<" "...")                                  ;; Range (No associativity, precedence level 135)
       (left "+" "-" "&+" "&-" "|" "^")                        ;; Additive (Left associative, precedence level 140)
       (left "*" "/" "%" "&*" "&/" "&%" "&")                   ;; Multiplicative (Left associative, precedence level 150)
       (nonassoc "<<" ">>")                                    ;; Exponentiative (No associativity, precedence level 160)
       ))
    )))

(defun verbose-swift-smie-rules (kind token)
  (let ((value (swift-smie-rules kind token)))
    (message "%s '%s'; sibling-p:%s parent:%s hanging:%s == %s" kind token
             (ignore-errors (smie-rule-sibling-p))
             (ignore-errors smie--parent)
             (ignore-errors (smie-rule-hanging-p))
             value)
    value))

(defvar swift-smie--operators
  '("*=" "/=" "%=" "+=" "-=" "<<=" ">>=" "&=" "^=" "|=" "&&=" "||="
   "<" "<=" ">" ">=" "==" "!=" "===" "!==" "~=" "||" "&&"
   "is" "as" "as!" "as?" "..<" "..."
   "+" "-" "&+" "&-" "|" "^"
   "*" "/" "%" "&*" "&/" "&%" "&"
   "<<" ">>" "??"))

;; This regex is used for deriving implicit semicolon
;; in multi-line expressions. We want to exclude some operator
;; from the match when they are a part of the word,
;; for example isValid
(defvar swift-smie--operators-regexp
  (concat (regexp-opt swift-smie--operators) "\\($\\|[[:space:]]\\)"))


(defun swift-smie--implicit-semi-p ()
  (save-excursion
    (skip-chars-backward " \t")
    (not (or (bolp)
             (memq (char-before) '(?\{ ?\[ ?, ?. ?: ?= ?\())
             ;; Checking for operators form for "?" and "!",
             ;; they can be a part of the type.
             ;; Special case: is? and as? are operators.
             (looking-back "[[:space:]][?!]" (- (point) 2) t)
             ;; ??, is? and as? are operators
             (looking-back "[?][?]\\|as[?]\\|is[?]" (- (point) 3) t)
             ;; "in" operator in closure
             (looking-back "\\bin" (- (point) 3) t)
             ;; Characters placed on the second line in multi-line expression
             (save-excursion
               (forward-comment (buffer-size))
               (looking-at "[.?:]"))
             ;; Operators placed on the second line in multi-line expression
             ;; Should respect here possible comments strict before the linebreak
             (save-excursion
               (forward-comment (buffer-size))
               (looking-at swift-smie--operators-regexp))

             (and (looking-back swift-smie--operators-regexp (- (point) 3) t)
                  ;; Not a generic type
                  (not (looking-back "[[:upper:]]>" (- (point) 2) t)))
             ))))

(defun swift-smie--forward-token-debug ()
  (let ((op (point))
        (token (swift-smie--forward-token)))
    (message "forward: %s -> %s = %s" op (point) token)
    token
    ))

(defun swift-smie--backward-token-debug ()
  (let ((op (point))
        (token (swift-smie--backward-token)))
    (message "backward: %s -> %s = %s" op (point) token)
      token
    ))

(defvar swift-smie--case-exp-regexp
  "\\(case.*?[^{}:=]+\\|default[[:space:]]*\\):")

(defun swift-smie--case-signature-p ()
  (save-excursion
    (up-list 1) (backward-list 1)
    (not (looking-back "enum.*" (line-beginning-position -1)))))

(defun swift-smie--closure-signature-p ()
    (let ((tok (smie-default-forward-token)))
      (or (equal tok "in")
          (and (equal tok "->")
               (equal (smie-default-forward-token) "in")))))

(defvar swift-smie--clousure-exclude-keywords-regexp
  "\\(if\\|for\\|while\\|do\\|catch\\|func\\|switch\\).*")

(defun swift-smie--open-closure-brace-signature-p ()
  (or (looking-back "(\\|:" 1)
      (looking-back "^\s*\\..*" (line-beginning-position))
      (and (eq (char-before) ?\))
           (backward-list)
           (not (looking-back swift-smie--clousure-exclude-keywords-regexp
                              (line-beginning-position))))
      ))

(defun swift-smie--forward-token ()
  (skip-chars-forward " \t")
  (cond
   ((and (looking-at "\n\\|\/\/")
         (swift-smie--implicit-semi-p))
    (if (eolp) (forward-char 1) (forward-comment 1))
    (skip-chars-forward " \t")
    (if (looking-at swift-smie--case-exp-regexp)
        "case-;" ";"))
   (t
    (forward-comment (point-max))
    (cond
     ((and (looking-at "{")
           (save-excursion (forward-comment (- 1))
                           (swift-smie--open-closure-brace-signature-p)))
      (forward-char 1) "closure-{")
     ((looking-at "{") (forward-char 1) "{")

     ((looking-at "}") (forward-char 1)
      (if (save-excursion (backward-list) (forward-comment (- 1))
                          (swift-smie--open-closure-brace-signature-p))
          "closure-}" "}"))

     ((and (looking-at "(")
           (save-excursion (forward-list 1) (swift-smie--closure-signature-p)))
      (forward-char 1) "closure-(")
     ((and (looking-at ")")
           (save-excursion (forward-char 1) (swift-smie--closure-signature-p)))
      (forward-char 1) "closure-)")

     ((looking-at "->") (forward-char 2) "->")

     ((looking-at ":") (forward-char 1)
      (if (looking-back swift-smie--case-exp-regexp)
          "case-:" ":"))

     ((looking-at "[.]\\{2\\}<") (forward-char 3) "..<")

     ((looking-at "<") (forward-char 1)
      (if (looking-at "[[:upper:]]") "<T" "<"))

     ((looking-at ">[?!,]?")
      (goto-char (match-end 0))
      (if (looking-back "[[:space:]]>" 2 t) ">" "T>"))

     ((looking-at "else[[:space:]]+if")
      (goto-char (match-end 0)) "elseif")

     ((looking-at "for[[:space:]]+case")
      (goto-char (match-end 0)) "for-case")

     ((and (looking-at "while")
           (save-excursion (forward-comment (- (point))) (eq (char-before) ?})))
      (goto-char (match-end 0)) "r-while")

     ((looking-at "if[[:space:]]+case")
      (goto-char (match-end 0)) "if-case")

     (t (let ((tok (smie-default-forward-token)))
          (cond
           ((equal tok "case")
            (if (swift-smie--case-signature-p)
                "case" "ecase"))

           ((equal tok "class")
            (cond
             ((looking-at "[[:space:]]*func") "f-class")
             ((looking-back ":[[:space:]]*" 1 t) "p-class")
             (t "class")))

           ((equal tok "in")
            (if (looking-at "[[:space:]]*\\(\/\/.*\\)*\n")
                "closure-in" "in"))

           ;; Alter token for member access and argument labels with keywords
           ((member tok swift-mode--keywords)
            (save-excursion
              (smie-default-backward-token)
              (if (or (eq (char-before) ?\.)
                      (looking-at (concat tok "\s*[[:word:]]*:\s*[[:word:]]+.*?,")))
                  (concat "ma-" tok)
                tok)))

           (t tok))))
     ))))

(defun swift-smie--backward-token ()
  (let ((pos (point)))
    (forward-comment (- (point)))
    (cond
     ((and (> pos (line-end-position))
           (swift-smie--implicit-semi-p))
      (if (save-excursion
            (forward-comment 1)
            (looking-at swift-smie--case-exp-regexp))
          "case-;" ";"))

     ((eq (char-before) ?\{) (backward-char 1)
      (if (save-excursion (forward-comment (- 1))
                          (swift-smie--open-closure-brace-signature-p))
          "closure-{" "{"))

     ((and (eq (char-before) ?\})
           (save-excursion (backward-list) (forward-comment (- 1))
                           (swift-smie--open-closure-brace-signature-p)))
      (backward-char 1) "closure-}")
     ((eq (char-before) ?\}) (backward-char 1) "}")

     ((and (eq (char-before) ?\()
           (save-excursion (backward-char 1) (forward-list 1)
                           (swift-smie--closure-signature-p)))
      (backward-char 1)  "closure-(")
     ((and (eq (char-before) ?\))
           (save-excursion (swift-smie--closure-signature-p)))
      (backward-char 1) "closure-)")

     ((looking-back "->" (- (point) 2) t)
      (goto-char (match-beginning 0)) "->")

     ((eq (char-before) ?:) (backward-char 1)
      (if (looking-back (substring swift-smie--case-exp-regexp 0
                                   (- (length swift-smie--case-exp-regexp) 1)))
          "case-:" ":"))

     ((looking-back "[.]\\{2\\}<" (- (point) 3)) (backward-char 3) "..<")

     ((eq (char-before) ?<) (backward-char 1)
      (if (looking-at "<[[:upper:]]") "<T" "<"))
     ((looking-back ">[?!,]?" (- (point) 2) t)
      (goto-char (match-beginning 0))
      (if (looking-back "[[:space:]]" 1 t) ">" "T>"))

     ((looking-back "else[[:space:]]+if" (line-beginning-position) t)
      (goto-char (match-beginning 0)) "elseif")

     ((looking-back "for[[:space:]]+case" (line-beginning-position) t)
      (goto-char (match-beginning 0)) "for-case")

     ((looking-back "if[[:space:]]+case" (line-beginning-position) t)
      (goto-char (match-beginning 0)) "if-case")

     ((and (looking-back "while" (- (point) 5))
           (save-excursion
             (goto-char (match-beginning 0))
             (forward-comment (- (point))) (eq (char-before) ?})))
      (goto-char (match-beginning 0)) "r-while")

     (t (let ((tok (smie-default-backward-token)))
          (cond
           ((equal tok "case")
            (if (swift-smie--case-signature-p)
                "case" "ecase"))

           ((equal tok "class")
            (cond
             ((looking-at "[[:space:]]*func") "f-class")
             ((looking-back ":[[:space:]]*" 1 t) "p-class")
             (t "class")))

           ((equal tok "in")
            (if (looking-at "in[[:space:]]*\\(\/\/.*\\)*\n")
                "closure-in" "in"))

           ;; Alter token for member access and argument labels with keywords
           ((member tok swift-mode--keywords)
            (if (or (eq (char-before) ?\.)
                    (looking-at (concat tok "\s*[[:word:]]*:\s*[[:word:]]+.*?,")))
                (concat "ma-" tok)
              tok))

           (t tok))))
     )))

(defun swift-smie-rules (kind token)
  (pcase (cons kind token)
    (`(:elem . basic) swift-indent-offset)

    ;; Custom case offset
    (`(:before . ,(or "case" "default"))
     (if (smie-rule-parent-p "switch")
         (smie-rule-parent swift-indent-switch-case-offset)))

    ;; Custom comma offset
    (`(:before . ",")
     (cond
      ((and swift-indent-hanging-comma-offset (smie-rule-parent-p "class" "case"))
       (smie-rule-parent swift-indent-hanging-comma-offset))
      ;; Closure with return type bound to function argument
      ((smie-rule-parent-p "->") (smie-rule-parent))
      ;; Function calls with multiple closures
      ((smie-rule-parent-p "closure-{") (smie-rule-parent))))

    ;; Reset offset applied by modifiers
    (`(:before . ,(or "class" "func" "protocol" "enum"))
     (if (not (smie-rule-bolp)) (smie-rule-parent)))

    ;; Hanging collection declaration
    (`(:before . "[")
     (if (and (smie-rule-hanging-p)
              (smie-rule-parent-p "let" "var"))
         (smie-rule-parent)))

    ;; Nested code block or closures
    (`(:before . "{")
     (if (smie-rule-parent-p "{")
         (smie-rule-parent swift-indent-offset)))

    ;; Arguments indentation
    (`(:after . "(") (if (not (smie-rule-hanging-p)) 1))
    (`(:before . "(")
     (if (not (smie-rule-bolp))
         (if (smie-rule-parent-p "func")
             (smie-rule-parent (- swift-indent-offset))
           (smie-rule-parent))))

    ;; Multiple let, var optional binding
    (`(:before . ,(or "var" "let"))
     (if (smie-rule-parent-p "var" "let")
         (smie-rule-parent)))

    ;; Generic Type
    (`(:after . "T>") (smie-rule-parent))
    (`(:before . "<T") (smie-rule-parent))

    ;; Closure indentation
    (`(:before . "closure-{") (smie-rule-parent))
    (`(:before . "closure-in") (smie-rule-parent swift-indent-offset))

    (`(:before . ":")
     (cond
      ;; Rule for ternary operator in
      ;; assignment expression.
      ((and (smie-rule-parent-p "?") (smie-rule-bolp)) 0)
      ;; Rule for the class definition.
      ;; class Foo:
      ;;    Foo, Bar, Baz {
      ((smie-rule-parent-p "class") (smie-rule-parent swift-indent-offset))))

    ;; Apply swift-indent-multiline-statement-offset only if
    ;; - if is a first token on the line
    (`(:before . ".")
     (when (smie-rule-bolp)
       (if (smie-rule-parent-p "{")
           (+ swift-indent-offset swift-indent-multiline-statement-offset)
         swift-indent-multiline-statement-offset)))

    (`(:before . ";")
     (cond
      ;; Closure with return type bound to type or variable
      ((smie-rule-parent-p "->") (smie-rule-parent))
      ;; func declarations without body in protcol
      ((smie-rule-parent-p "func") 0)))

    ;; return type at the beginning of the line
    (`(:before . "->")
     (if (smie-rule-bolp) (smie-rule-parent swift-indent-offset)))

    ;; Compiler control statement
    (`(:before . ,(or "#elseif" "#else")) (smie-rule-parent))
    (`(:after . ";")
     (if (smie-rule-parent-p "#if" "#else" "#elseif")
         (smie-rule-parent)))

    ;; Multiline assignment
    (`(:after . "=")
     (if (and (smie-rule-hanging-p)
              (not (smie-rule-parent-p "var" "let")))
         swift-indent-multiline-statement-offset))

    ;; Apply swift-indent-multiline-statement-offset if
    ;; operator is the last symbol on the line
    (`(:after . ,(pred (lambda (token)
                         (member token swift-smie--operators))))
     (when (and (smie-rule-hanging-p)
                (not (apply 'smie-rule-parent-p
                            (append swift-smie--operators '("?" ":" "=" "," "(")))))
       swift-indent-multiline-statement-offset))
    ))

;;; Font lock

(defvar swift-mode--type-decl-keywords
  '("class" "enum" "protocol" "struct" "typealias"))

(defvar swift-mode--val-decl-keywords
  '("let" "var"))

(defvar swift-mode--context-variables-keywords
  '("self" "super"))

(defvar swift-mode--fn-decl-keywords
  '("deinit" "func" "init"))

(defvar swift-mode--misc-keywords
  '("import" "static" "subscript" "extension"))

(defvar swift-mode--statement-keywords
  '("break" "case" "continue" "default" "do" "else" "fallthrough"
    "if" "in" "for" "return" "switch" "where" "repeat" "while" "guard"
    "as" "is" "throws" "throw" "try" "catch" "defer" "indirect" "rethrows"))

(defvar swift-mode--contextual-keywords
  '("associativity" "didSet" "get" "infix" "inout" "left" "mutating" "none"
    "nonmutating" "operator" "override" "postfix" "precedence" "prefix" "right"
    "set" "unowned" "unowned(safe)" "unowned(unsafe)" "weak" "willSet" "convenience"
    "required" "dynamic" "final" "lazy" "optional" "private" "public" "internal"))

(defvar swift-mode--attribute-keywords
  '("class_protocol" "exported" "noreturn"
    "NSCopying" "NSManaged" "objc" "autoclosure"
    "available" "noescape" "nonobjc" "NSApplicationMain" "testable" "UIApplicationMain" "warn_unused_result" "convention"
    "IBAction" "IBDesignable" "IBInspectable" "IBOutlet"))

(defvar swift-mode--keywords
  (append swift-mode--type-decl-keywords
          swift-mode--val-decl-keywords
          swift-mode--context-variables-keywords
          swift-mode--fn-decl-keywords
          swift-mode--misc-keywords
          swift-mode--statement-keywords
          swift-mode--contextual-keywords)
  "Keywords used in the Swift language.")

(defvar swift-mode--constants
  '("true" "false" "nil"))

(defvar swift-font-lock-keywords
  `(
    ;; (concat tok "\s*[[:word:]]*:\s*[[:word:]]+.*?,")
    ;; Argument labels
    (,"\\<\\([[:word:]]+\\)\\>\s*[[:word:]]*:.*?[,)]"
     1 font-lock-constant-face)

    ;; Keywords
    ;;
    ;; Swift allows reserved words to be used as identifiers when enclosed
    ;; with backticks, in which case they should be highlighted as
    ;; identifiers, not keywords. Swift 2.3 allows keywords to be used
    ;; as argument labels without backticks, swift 3 similar rules to
    ;; member access
    (,(rx-to-string
       `(and (or bol (not (any "`" "."))) bow
             (group (or ,@swift-mode--keywords))
             eow)
       t)
     1 font-lock-keyword-face)

    ;; Keywords with number sign
    (,(rx-to-string
       `(and bow "#" (* word) eow)
       t)
     0 font-lock-keyword-face)

    ;; Attributes
    ;;
    ;; Highlight attributes with keyword face
    (,(rx-to-string
       `(and "@" bow (or ,@swift-mode--attribute-keywords) eow)
       t)
     0 font-lock-keyword-face)

    ;; Types
    ;;
    ;; Any token beginning with an uppercase character is highlighted as a
    ;; type.
    (,(rx bow upper (* word) eow)
     0 font-lock-type-face)

    ;; Enum member access
    ;;
    ;; Any token beginning with standalone dot is highlighted as a
    ;; type.
    (,(rx space "." (group bow (* word) eow))
     1 font-lock-type-face)

    ;; Function names
    ;;
    ;; Any token beginning after `func' is highlighted as a function name.
    (,(rx bow "func" eow (+ space) (group bow (+ word) eow))
     1 font-lock-function-name-face)

    ;; Value bindings
    ;;
    ;; Any token beginning after `let' or `var' is highlighted as an
    ;; identifier.
    (,(rx-to-string `(and bow
                           (or ,@swift-mode--val-decl-keywords)
                           eow
                           (+ space)
                           (? "(")
                           (group (+ (or (+ (? ?`) word (? ?`)) ?, space)))
                           (? ")"))
                     t)
       1 font-lock-variable-name-face)

    ;; Use high-visibility face for pattern match wildcards.
    (,(rx (not (any word digit)) (group "_") (or eol (not (any word digit))))
     1 font-lock-negation-char-face)

    ;; Constants
    ;;
    ;; Highlight nil and boolean literals.
    (,(rx-to-string `(and bow (or ,@swift-mode--constants) eow))
     0 font-lock-constant-face)

    ;; Attributes
    ;;
    ;; Use string face for attribute name.
    (,(rx (or bol space)(group "@" (+ word)) eow)
     1 font-lock-keyword-face)

    ;; Imported modules
    ;;
    ;; Highlight the names of imported modules. Use `font-lock-string-face' for
    ;; consistency with C modes.
    (,(rx bow "import" eow (+ space) (group (+ word)))
     1 font-lock-string-face)

    ;; String interpolation
    ;;
    ;; Highlight interpolation expression as identifier.
    (swift-match-interpolation 0 font-lock-variable-name-face t)
    ))

(defun swift-syntax-propertize-function (start end)
  "Syntactic keywords for Swift mode."
  (let (case-fold-search)
    (goto-char start)
    (remove-text-properties start end '(swift-interpolation-match-data))
    (funcall
     (syntax-propertize-rules
      ((rx (group "\\(" (* (any alnum " ()+-._/*[]!?<>&~!:|^%")) ")"))
       (0 (ignore (swift-syntax-propertize-interpolation)))))
     start end)))

(defun swift-syntax-propertize-interpolation ()
  (let* ((beg (match-beginning 0))
         (context (save-excursion (save-match-data (syntax-ppss beg)))))
    (put-text-property beg (1+ beg) 'swift-interpolation-match-data
                       (cons (nth 3 context) (match-data)))))

(defun swift-match-interpolation (limit)
  (let ((pos (next-single-char-property-change (point) 'swift-interpolation-match-data
                                               nil limit)))
    (when (and pos (> pos (point)))
      (goto-char pos)
      (let ((value (get-text-property pos 'swift-interpolation-match-data)))
        (if (eq (car value) ?\")
            (progn
              (set-match-data (cdr value))
              t)
          (swift-match-interpolation limit))))))

;;; Imenu

(defun swift-mode--mk-regex-for-def (keyword)
  "Make a regex matching the identifier introduced by KEYWORD."
  (let ((ident (rx (any word nonascii "_") (* (any word nonascii digit "_")))))
    (rx-to-string `(and bow ,keyword eow (+ space) (group (regexp ,ident)))
                  t)))

(defvar swift-mode--imenu-generic-expression
  (list
   (list "Functions" (swift-mode--mk-regex-for-def "func") 1)
   (list "Classes"   (swift-mode--mk-regex-for-def "class") 1)
   (list "Enums"     (swift-mode--mk-regex-for-def "enum") 1)
   (list "Protocols" (swift-mode--mk-regex-for-def "protocol") 1)
   (list "Structs"   (swift-mode--mk-regex-for-def "struct") 1)
   (list "Constants" (swift-mode--mk-regex-for-def "let") 1)
   (list "Variables" (swift-mode--mk-regex-for-def "var") 1))
  "Value for `imenu-generic-expression' in swift-mode.")

;;; REPL

(defvar swift-repl-buffer nil
  "Stores the name of the current swift REPL buffer, or nil.")

;;;###autoload
(defun swift-mode-run-repl (cmd &optional dont-switch-p)
  "Run a REPL process, input and output via buffer `*swift-repl*'.
If there is a process already running in `*swift-repl*', switch to that buffer.
With argument CMD allows you to edit the command line (default is value
of `swift-repl-executable').
With DONT-SWITCH-P cursor will stay in current buffer.
Runs the hook `swift-repl-mode-hook' \(after the `comint-mode-hook'
is run).
\(Type \\[describe-mode] in the process buffer for a list of commands.)"

  (interactive (list (if current-prefix-arg
                         (read-string "Run swift REPL: " swift-repl-executable)
                       swift-repl-executable)))
  (unless (comint-check-proc "*swift-repl*")
    (save-excursion (let ((cmdlist (split-string cmd)))
                      (set-buffer (apply 'make-comint "swift-repl" (car cmdlist)
                                         nil (cdr cmdlist)))
                      (swift-repl-mode))))
  (setq swift-repl-executable cmd)
  (setq swift-repl-buffer "*swift-repl*")
  (unless dont-switch-p
    (pop-to-buffer "*swift-repl*")))

(defun swift-mode-send-region (start end)
  "Send the current region to the inferior swift process.
START and END define region within current buffer"
  (interactive "r")
  (swift-mode-run-repl swift-repl-executable t)
  (comint-send-region swift-repl-buffer start end)
  (comint-send-string swift-repl-buffer "\n"))

(defun swift-mode-send-buffer ()
  "Send the buffer to the Swift REPL process."
  (interactive)
  (swift-mode-send-region (point-min) (point-max)))

(define-derived-mode swift-repl-mode comint-mode "Swift REPL"
  "Major mode for interacting with Swift REPL.

A REPL can be fired up with M-x swift-mode-run-repl.

Customization: Entry to this mode runs the hooks on comint-mode-hook and
swift-repl-mode-hook (in that order).

You can send text to the REPL process from other buffers containing source.
    swift-mode-send-region sends the current region to the REPL process,
    swift-mode-send-buffer sends the current buffer to the REPL process.
")

;;; Mode definition

(defvar swift-mode-syntax-table
  (let ((table (make-syntax-table)))

    ;; Operators
    (dolist (i '(?+ ?- ?* ?/ ?& ?| ?^ ?< ?> ?~))
      (modify-syntax-entry i "." table))

    ;; Strings
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\` "\"" table)
    (modify-syntax-entry ?\\ "\\" table)

    ;; Additional symbols
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?? "_" table)
    (modify-syntax-entry ?! "_" table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?# "w" table)
    (modify-syntax-entry ?@ "w" table)

    ;; Comments
    (modify-syntax-entry ?/  ". 124b" table)
    (modify-syntax-entry ?*  ". 23n"  table)
    (modify-syntax-entry ?\n "> b"    table)

    ;; Parenthesis, braces and brackets
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)

    table))

(defvar swift-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") 'swift-mode-run-repl)
    (define-key map (kbd "C-c C-f") 'swift-mode-send-buffer)
    (define-key map (kbd "C-c C-r") 'swift-mode-send-region)
    (easy-menu-define swift-menu map "Swift Mode menu"
      `("Swift"
        :help "Swift-specific Features"
        ["Run REPL" swift-mode-run-repl
         :help "Run Swift REPL"]
        ["Send buffer to REPL" swift-mode-send-buffer
         :help "Send the current buffer's contents to the REPL"]
        ["Send region to REPL" swift-mode-send-region
         :help "Send currently selected region to the REPL"]))
    map)
  "Key map for swift mode.")

;;;###autoload
(define-derived-mode swift-mode prog-mode "Swift"
  "Major mode for Apple's Swift programming language.

\\<swift-mode-map>"
  :group 'swift
  :syntax-table swift-mode-syntax-table
  (setq font-lock-defaults '((swift-font-lock-keywords) nil nil))
  (setq-local syntax-propertize-function #'swift-syntax-propertize-function)

  (setq-local imenu-generic-expression swift-mode--imenu-generic-expression)

  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local indent-tabs-mode nil)
  (setq-local electric-indent-chars
              (append '(?. ?, ?: ?\) ?\] ?\}) electric-indent-chars))
  (smie-setup swift-smie-grammar 'verbose-swift-smie-rules ;; 'verbose-swift-smie-rules
              :forward-token 'swift-smie--forward-token
              :backward-token 'swift-smie--backward-token))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.swift\\'" . swift-mode))

(provide 'swift-mode)

;;; swift-mode.el ends here
