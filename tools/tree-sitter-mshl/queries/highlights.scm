; mshl highlights — the shapes the grammar names, mapped to the usual
; capture names (tree-sitter's conventions, as editors expect them).

[
  "let" "def" "fn" "if" "else" "for" "in" "while" "match" "try"
] @keyword

["ok" "err"] @keyword.operator
"not" @keyword.operator
["and" "or"] @keyword.operator

["==" "!=" "<" "<=" ">" ">=" "+" "-" "*" "/" "%" "=" "=>" "|"] @operator
(unwrap "?" @operator)
(unwrap_mark) @operator
(redirect ">" @operator)
(rest_pattern ".." @operator)

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
[";" ","] @punctuation.delimiter

(comment) @comment
(number) @number
(boolean) @boolean
(null) @constant.builtin
(string) @string
(escape_sequence) @string.escape
(interpolation (identifier) @variable)
(interpolation "$" @punctuation.special)

(variable (identifier) @variable)
(variable "$" @punctuation.special)
(let_statement name: (identifier) @variable)
(for_statement name: (identifier) @variable)
(parameters (identifier) @variable.parameter)
(bind_pattern (variable (identifier) @variable))
(wildcard_pattern) @variable.builtin

(def_statement name: (identifier) @function)
(command name: (identifier) @function.call)
(where_command "where" @function.call)
(call callee: (variable (identifier) @function))
(field_access field: (identifier) @property)
(record_key) @property
(record_field_pattern key: (record_key) @property)
(record_field_pattern key: (identifier) @property)

(bare_word (identifier) @string.special)
