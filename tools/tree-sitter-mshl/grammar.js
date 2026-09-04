/**
 * mshl — the moss shell language (lib/mshl.zig is the reference; the
 * grammar comment at its head is the source of truth for the shape).
 *
 * Newlines are statement separators, so they are not extras. A stage
 * that starts with a bare word is a command with arguments; one that
 * starts with a variable followed by arguments is a call of a function
 * value; anything else is an expression. Bare words are strings, keys
 * carry their colon, numbers take size units (a fraction or an exponent
 * makes a float), `?` unwraps a result. Shapes follow a `name:` in a
 * `let` or a parameter list, a `->` after the parameters, a `:` after a
 * match subject, or the word `shape`: type names, words, `[S]`,
 * `{ key: S }`, `ok S`, `S | S`, `$name`.
 */

const PREC = {
  or: 1,
  and: 2,
  not: 3,
  compare: 4,
  add: 5,
  mul: 6,
  unary: 7,
  postfix: 8,
};

const commaSep = (rule) => optional(seq(rule, repeat(seq(',', rule)), optional(',')));

module.exports = grammar({
  name: 'mshl',

  extras: ($) => [/[ \t\r]/, $.comment],

  word: ($) => $.identifier,

  conflicts: ($) => [
    [$.block, $.record],
    [$.command, $.bare_word],
    [$._callee, $._expression],
    [$._callee, $._primary],
    [$._postfix_argument, $._expression],
    [$._postfix_argument, $._primary],
    [$._primary, $.match_arm],
    [$.lambda_block, $._primary],
    [$._argument, $._primary],
    [$._separator, $.record],
    [$._argument, $._expression],
  ],

  rules: {
    source_file: ($) => optional($._statement_list),

    // Statements are separated by newlines or semicolons — never merely
    // adjacent (or a command's last argument would start a new one). The
    // list is never empty (tree-sitter's rule), so a block holds an
    // optional one.
    _statement_list: ($) =>
      choice(
        repeat1($._separator),
        seq(repeat($._separator), $._statement, repeat(seq(repeat1($._separator), $._statement)), repeat($._separator)),
      ),

    _separator: ($) => choice('\n', ';'),

    comment: ($) => token(seq('#', /[^\n]*/)),

    // ------------------------------------------------------------ statements

    _statement: ($) =>
      choice($.let_statement, $.def_statement, $.if_statement, $.for_statement, $.while_statement, $.pipeline),

    let_statement: ($) =>
      seq('let', choice(field('name', $.identifier), $.typed_name), '=', field('value', $._expression)),

    // `name: shape` — the name keeps its colon as one token, like a key.
    typed_name: ($) => seq(field('name', alias($.record_key, $.identifier)), field('shape', $._shape)),

    def_statement: ($) =>
      seq(
        'def',
        field('name', $.identifier),
        optional(field('parameters', $.parameters)),
        optional(seq('->', field('returns', $._shape))),
        field('body', $.block),
      ),

    parameters: ($) => seq('[', commaSep(choice($.identifier, $.typed_name)), ']'),

    if_statement: ($) =>
      seq(
        'if',
        field('condition', $._expression),
        field('consequence', $.block),
        optional(seq('else', field('alternative', choice($.block, $.if_statement)))),
      ),

    for_statement: ($) =>
      seq('for', field('name', $.identifier), 'in', field('iterable', $._expression), field('body', $.block)),

    while_statement: ($) => seq('while', field('condition', $._expression), field('body', $.block)),

    block: ($) => seq('{', optional($._statement_list), '}'),

    // -------------------------------------------------------------- pipelines

    pipeline: ($) => prec.right(seq($._stage, repeat(seq('|', $._stage)), optional($.redirect))),

    redirect: ($) => seq('>', field('path', $.identifier)),

    _stage: ($) => choice($.where_command, $.command, $.call, $._expression),

    // `where` takes one expression, in which a bare word names a column.
    where_command: ($) => prec.dynamic(20, seq('where', field('condition', $._expression))),

    // A command: a bare word and its arguments. Dynamic precedence wins
    // over reading the word as a string expression.
    command: ($) =>
      prec.dynamic(10, prec.right(seq(field('name', $.identifier), repeat(field('argument', $._argument)), optional($.unwrap_mark)))),

    // `$f args`, `$m.f args`: a function value applied.
    call: ($) =>
      prec.dynamic(5, prec.right(seq(field('callee', $._callee), repeat1(field('argument', $._argument)), optional($.unwrap_mark)))),

    _callee: ($) => choice($.variable, $.field_access),

    unwrap_mark: ($) => '?',

    _argument: ($) =>
      choice(
        $.bare_word,
        $.string,
        $.number,
        $.boolean,
        $.null,
        $._postfix_argument,
        $.list,
        $.record,
        $.lambda_block,
        $.shape_expression,
      ),

    // In argument position a variable or a parenthesized pipeline may
    // carry field access and a `?`, but no operators.
    _postfix_argument: ($) => choice($.variable, $.field_access, $.paren, $.unwrap),

    bare_word: ($) => $.identifier,

    // A block written as an argument is a function of `$it`.
    lambda_block: ($) => $.block,

    // ------------------------------------------------------------ expressions

    _expression: ($) =>
      choice(
        $.binary_expression,
        $.unary_expression,
        $.unwrap,
        $.field_access,
        $.fn_expression,
        $.match_expression,
        $.try_expression,
        $.shape_expression,
        $._primary,
      ),

    binary_expression: ($) =>
      choice(
        prec.left(PREC.or, seq($._expression, 'or', $._expression)),
        prec.left(PREC.and, seq($._expression, 'and', $._expression)),
        prec.left(PREC.compare, seq($._expression, choice('==', '!=', '<', '<=', '>', '>='), $._expression)),
        prec.left(PREC.add, seq($._expression, choice('+', '-'), $._expression)),
        prec.left(PREC.mul, seq($._expression, choice('*', '/', '%'), $._expression)),
      ),

    unary_expression: ($) =>
      choice(prec(PREC.not, seq('not', $._expression)), prec(PREC.unary, seq('-', $._expression))),

    // `.field` / `.index` glued to a primary; `?` glued after.
    // Glued to its primary, and preferred over reading `.field` as a word.
    field_access: ($) => prec.dynamic(30, prec.left(PREC.postfix, seq($._expression, token.immediate(prec(10, '.')), field('field', alias(token.immediate(/[A-Za-z0-9_-]+/), $.identifier))))),

    unwrap: ($) => prec.left(PREC.postfix, seq($._expression, token.immediate('?'))),

    _primary: ($) => choice($.number, $.string, $.variable, $.boolean, $.null, $.paren, $.list, $.record, $.block, $.bare_word),

    paren: ($) => seq('(', $.pipeline, ')'),

    list: ($) => seq('[', repeat(choice($._expression, ',', '\n')), ']'),

    record: ($) => seq('{', repeat(choice($.record_field, ',', '\n', ';')), '}'),

    record_field: ($) => seq(field('key', $.record_key), field('value', $._expression)),

    record_key: ($) => token(prec(2, /[A-Za-z_][A-Za-z0-9_-]*:/)),

    fn_expression: ($) =>
      seq('fn', optional(field('parameters', $.parameters)), optional(seq('->', field('returns', $._shape))), field('body', $.block)),

    // ---------------------------------------------------------------- shapes

    // `shape S`: a shape as a value. One term — a union is written
    // `shape (a | b)`, so a `|` after it is always the pipe.
    shape_expression: ($) => seq('shape', field('shape', $._shape_term)),

    _shape: ($) => choice($.shape_union, $._shape_term),

    shape_union: ($) => prec.left(seq($._shape, '|', $._shape)),

    _shape_term: ($) =>
      choice(
        $.shape_name,
        $.handle_shape,
        $.result_shape,
        $.list_shape,
        $.record_shape,
        $.paren_shape,
        $.string,
        $.variable,
        $.shape_word,
      ),

    shape_name: ($) =>
      choice('any', 'nothing', 'null', 'bool', 'int', 'float', 'string', 'bytes', 'list', 'record', 'table', 'function', 'result', 'shape'),

    // `handle`, or `handle socket`.
    handle_shape: ($) => prec.right(seq('handle', optional(field('kind', $.identifier)))),

    result_shape: ($) => prec.right(seq(choice('ok', 'err'), $._shape_term)),

    list_shape: ($) => seq('[', $._shape, ']'),

    record_shape: ($) => seq('{', repeat(choice($.shape_field, ',', '\n', ';')), '}'),

    shape_field: ($) => seq(field('key', $.record_key), field('shape', $._shape)),

    paren_shape: ($) => seq('(', $._shape, ')'),

    // A bare word in a shape: one member of an enumeration.
    shape_word: ($) => $.identifier,

    try_expression: ($) => prec(PREC.postfix + 1, seq('try', choice($.block, $._postfix_argument))),

    // --------------------------------------------------------------- match

    match_expression: ($) =>
      seq(
        'match',
        field('subject', $._expression),
        optional(seq(':', field('shape', $._shape))),
        '{',
        repeat(choice($.match_arm, $._separator, ',')),
        '}',
      ),

    match_arm: ($) =>
      seq(field('pattern', $._pattern), optional(seq('if', field('guard', $._expression))), '=>', field('body', choice($.block, $._statement))),

    _pattern: ($) =>
      choice($.wildcard_pattern, $.bind_pattern, $.result_pattern, $.list_pattern, $.record_pattern, $.number, $.string, $.boolean, $.null, $.bare_word),

    wildcard_pattern: ($) => '_',
    bind_pattern: ($) => $.variable,
    result_pattern: ($) => seq(choice('ok', 'err'), $._pattern),
    list_pattern: ($) => seq('[', repeat(choice($._pattern, $.rest_pattern, ',', '\n')), ']'),
    rest_pattern: ($) => prec.right(seq('..', optional($.variable))),
    record_pattern: ($) => seq('{', repeat(choice($.record_field_pattern, ',', '\n')), '}'),
    record_field_pattern: ($) => choice(seq(field('key', $.record_key), $._pattern), field('key', $.identifier)),

    // ---------------------------------------------------------------- tokens

    variable: ($) => seq('$', alias(token.immediate(/[A-Za-z0-9_]+/), $.identifier)),

    string: ($) => seq('"', repeat(choice($.string_text, $.escape_sequence, $.interpolation)), '"'),
    string_text: ($) => token.immediate(prec(1, /[^"\\$]+/)),
    escape_sequence: ($) => token.immediate(/\\./),
    interpolation: ($) => seq(token.immediate('$'), alias(token.immediate(/[A-Za-z_][A-Za-z0-9_]*/), $.identifier)),

    number: ($) => token(/[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?([kKmMgG][bB]|[bB])?/),

    boolean: ($) => choice('true', 'false'),
    null: ($) => 'null',

    // A word: anything that is not structure. Keywords are carved out of
    // this by `word`; paths, versions, flags and addresses stay whole.
    identifier: ($) => /[^\s()\[\]{}|;"$,><=!?][^\s()\[\]{}|;"$,><=!?]*/,
  },
});
