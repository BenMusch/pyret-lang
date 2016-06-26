#lang pyret

provide *
import ast as A
import file("ast-anf.arr") as N
import file("js-ast.arr") as J
import file("gensym.arr") as G
import file("compile-structs.arr") as CS
import file("concat-lists.arr") as CL
import file("js-dag-utils.arr") as DAG
import file("ast-util.arr") as AU
import file("type-structs.arr") as T
import string-dict as D
import srcloc as SL
import sets as S

string-dict = D.string-dict
mutable-string-dict = D.mutable-string-dict

type Loc = SL.Srcloc
type CList = CL.ConcatList
clist = CL.clist

fun get-exp(o): o.exp end
fun get-id(o): o.id end
fun get-name(o): o.name end
fun get-l(o): o.l end
fun get-bind(o): o.bind end
fun o-get-field(o): o.field end

cl-empty = CL.concat-empty
cl-sing = CL.concat-singleton
cl-append = CL.concat-append
cl-cons = CL.concat-cons
cl-snoc = CL.concat-snoc

fun type-name(str):
  "$type$" + str
end

j-fun = J.j-fun
j-var = J.j-var
j-id = J.j-id
j-method = J.j-method
j-block = J.j-block
j-block1 = J.j-block1
j-true = J.j-true
j-false = J.j-false
j-num = J.j-num
j-str = J.j-str
j-return = J.j-return
j-assign = J.j-assign
j-if = J.j-if
j-if1 = J.j-if1
j-new = J.j-new
j-app = J.j-app
j-list = J.j-list
j-obj = J.j-obj
j-dot = J.j-dot
j-bracket = J.j-bracket
j-field = J.j-field
j-dot-assign = J.j-dot-assign
j-bracket-assign = J.j-bracket-assign
j-try-catch = J.j-try-catch
j-throw = J.j-throw
j-expr = J.j-expr
j-binop = J.j-binop
j-and = J.j-and
j-lt = J.j-lt
j-eq = J.j-eq
j-neq = J.j-neq
j-geq = J.j-geq
j-unop = J.j-unop
j-decr = J.j-decr
j-incr = J.j-incr
j-not = J.j-not
j-instanceof = J.j-instanceof
j-ternary = J.j-ternary
j-null = J.j-null
j-parens = J.j-parens
j-switch = J.j-switch
j-case = J.j-case
j-default = J.j-default
j-label = J.j-label
j-break = J.j-break
j-while = J.j-while
j-for = J.j-for
make-label-sequence = J.make-label-sequence

is-t-data = T.is-t-data

data BindType:
  | b-let(value :: N.ABind)
  | b-array(value :: N.ABind, idx :: Number)
end

js-names = A.MakeName(0)
js-ids = D.make-mutable-string-dict()
effective-ids = D.make-mutable-string-dict()
fun fresh-id(id :: A.Name) -> A.Name:
  base-name = if A.is-s-type-global(id): id.tosourcestring() else: id.toname() end
  no-hyphens = string-replace(base-name, "-", "$")
  n = js-names.make-atom(no-hyphens)
  if effective-ids.has-key-now(n.tosourcestring()) block: #awkward name collision!
    fresh-id(id)
  else:
    effective-ids.set-now(n.tosourcestring(), true)
    n
  end
end
fun js-id-of(id :: A.Name) -> A.Name:
  s = id.key()
  if js-ids.has-key-now(s) block:
    js-ids.get-value-now(s)
  else:
    safe-id = fresh-id(id)
    js-ids.set-now(s, safe-id)
    safe-id
  end
end

fun const-id(name :: String):
  A.s-name(A.dummy-loc, name)
end

fun compiler-name(id):
  const-id("$" + id)
end

fun formal-shadow-name(id :: A.Name) -> A.Name:
  js-id = js-id-of(id)
  A.s-name(A.dummy-loc, "$" + js-id.tosourcestring())
end

get-field-loc = j-id(const-id("G"))
throw-uninitialized = j-id(const-id("U"))
source-name = j-id(const-id("M"))
undefined = j-id(const-id("D"))
RUNTIME = j-id(const-id("R"))
NAMESPACE = j-id(const-id("NAMESPACE"))
THIS = j-id(const-id("this"))
ARGUMENTS = j-id(const-id("arguments"))

j-bool = lam(b):
  if b: j-true else: j-false end
end

fun obj-of-loc(l):
  cases(Loc) l:
    | builtin(name) => j-list(false, [clist: j-str(name)])
    | srcloc(_, start-line, start-col, start-char, end-line, end-col, end-char) =>
      j-list(false, [clist:
          j-id(const-id("M")),
          j-num(start-line),
          j-num(start-col),
          j-num(start-char),
          j-num(end-line),
          j-num(end-col),
          j-num(end-char)
        ])
  end
end

fun get-dict-field(obj, field):
  j-bracket(j-dot(obj, "dict"), field)
end

fun get-field(obj :: J.JExpr, field :: J.JExpr, loc :: J.JExpr):
  j-app(get-field-loc, [clist: obj, field, loc])
end

fun get-field-ref(obj :: J.JExpr, field :: J.JExpr, loc :: J.JExpr):
  rt-method("getFieldRef", [clist: obj, field, loc])
end

fun raise-id-exn(loc, name):
  j-app(throw-uninitialized, [clist: loc, j-str(name)])
end

fun add-stack-frame(exn-id, loc):
  j-method(j-dot(j-id(exn-id), "pyretStack"), "push", [clist: loc])
end

fun rt-field(name): j-dot(RUNTIME, name) end
fun rt-method(name, args): j-method(RUNTIME, name, args) end

fun app(l, f, args):
  j-method(f, "app", args)
end

fun check-fun(l, f):
  j-if1(j-unop(j-parens(rt-method("isFunction", [clist: f])), j-not),
    j-block1(j-expr(j-method(rt-field("ffi"), "throwNonFunApp", [clist: l, f]))))
end

fun thunk-app(block):
  j-app(j-parens(j-fun(cl-empty, block)), cl-empty)
end

fun thunk-app-stmt(stmt):
  thunk-app(j-block1(stmt))
end

c-exp = DAG.c-exp
c-field = DAG.c-field
c-block = DAG.c-block
is-c-exp = DAG.is-c-exp
is-c-field = DAG.is-c-field
is-c-block = DAG.is-c-block


fun compile-ann(ann :: A.Ann, visitor) -> DAG.CaseResults%(is-c-exp):
  cases(A.Ann) ann:
    | a-name(_, n) => c-exp(j-id(js-id-of(n)), cl-empty)
    | a-type-var(_, _) => c-exp(rt-field("Any"), cl-empty)
    | a-arrow(_, _, _, _) => c-exp(rt-field("Function"), cl-empty)
    | a-method(_, _, _) => c-exp(rt-field("Method"), cl-empty)
    | a-app(l, base, _) => compile-ann(base, visitor)
    | a-record(l, fields) =>
      comp-fields =
        for fold(acc from {names: cl-empty, locs: cl-empty, fields: cl-empty, others: cl-empty},
            field from fields):
          compiled = compile-ann(field.ann, visitor)
          {
            names: cl-snoc(acc.names, j-str(field.name)),
            locs: cl-snoc(acc.locs, visitor.get-loc(field.l)),
            fields: cl-snoc(acc.fields, j-field(field.name, compiled.exp)),
            others: acc.others + compiled.other-stmts
          }
        end
      c-exp(
        rt-method("makeRecordAnn", [clist:
            j-list(false, comp-fields.names),
            j-list(false, comp-fields.locs),
            j-obj(comp-fields.fields)
          ]),
        comp-fields.others
        )
    | a-tuple(l, tuple-fields) =>
      comp-fields = for fold(acc from {locs: cl-empty, fields: cl-empty, others: cl-empty},
         field from tuple-fields):
       compiled = compile-ann(field, visitor)
       {
          locs: cl-snoc(acc.locs, visitor.get-loc(field.l)),
          fields: cl-snoc(acc.fields, compiled.exp),
          others: acc.others + compiled.other-stmts
       }
       end
     c-exp(
       rt-method("makeTupleAnn", [clist:
           j-list(false, comp-fields.locs),
           j-list(false, comp-fields.fields)
        ]),
       comp-fields.others
      )
    | a-pred(l, base, exp) =>
      name = cases(A.Expr) exp:
        | s-id(_, id) => id.toname()
        | s-id-letrec(_, id, _) => id.toname()
      end
      expr-to-compile = cases(A.Expr) exp:
        | s-id(l2, id) => N.a-id(l2, id)
        | s-id-letrec(l2, id, ok) => N.a-id-letrec(l2, id, ok)
      end
      compiled-base = compile-ann(base, visitor)
      compiled-exp = expr-to-compile.visit(visitor)
      c-exp(
        rt-method("makePredAnn", [clist: compiled-base.exp, compiled-exp.exp, j-str(name)]),
        compiled-base.other-stmts +
        compiled-exp.other-stmts
        )
    | a-dot(l, m, field) =>
      c-exp(
        rt-method("getDotAnn", [clist:
            visitor.get-loc(l),
            j-str(m.toname()),
            j-id(js-id-of(m)),
            j-str(field)]),
        cl-empty)
    | a-blank => c-exp(rt-field("Any"), cl-empty)
    | a-any(l) => c-exp(rt-field("Any"), cl-empty)
  end
end

fun arity-check(loc-expr, arity :: Number):
  #|[list:
    j-if1(j-binop(j-dot(ARGUMENTS, "length"), j-neq, j-num(arity)),
      j-block([list:
          j-expr(rt-method("checkArityC", [list: loc-expr, j-num(arity), j-method(rt-field("cloneArgs"), "apply", [list: j-null, ARGUMENTS])]))
      ]))]|#
  len = j-id(compiler-name("l"))
  iter = j-id(compiler-name("i"))
  t = j-id(compiler-name("t"))
  [clist:
    j-var(len.id, j-dot(ARGUMENTS, "length")),
    j-if1(j-binop(len, j-neq, j-num(arity)),
      j-block([clist:
          j-var(t.id, j-new(j-id(const-id("Array")), [clist: len])),
          j-for(true, j-assign(iter.id, j-num(0)), j-binop(iter, j-lt, len), j-unop(iter, j-incr),
            j-block1(j-expr(j-bracket-assign(t, iter, j-bracket(ARGUMENTS, iter))))),
          j-expr(rt-method("checkArityC", [clist: loc-expr, j-num(arity), t]))]))]
end

no-vars = D.make-mutable-string-dict

fun local-bound-vars(kase :: J.JCase, vars) block:
  fun e(expr):
    cases(J.JExpr) expr block:
      | j-parens(exp) => e(exp)
      | j-raw-code(_) => nothing
      | j-unop(exp, _) => e(exp)
      | j-binop(left, _, right) =>
        e(left)
        e(right)
      | j-fun(_, _) =>
        # the body of a function contributes no *locally* bound vars
        nothing
      | j-new(func, args) =>
        e(func)
        args.each(e)
      | j-app(func, args) =>
        e(func)
        args.each(e)
      | j-method(_, _, _) =>
        # the body of a method contributes no *locally* bound vars
        nothing
      | j-ternary(test, consq, alt) =>
        e(test)
        e(consq)
        e(alt)
      | j-assign(_, rhs) => e(rhs)
      | j-bracket-assign(obj, field, rhs) =>
        e(obj)
        e(field)
        e(rhs)
      | j-dot-assign(obj, _, rhs) =>
        e(obj)
        e(rhs)
      | j-dot(obj, _) => e(obj)
      | j-bracket(obj, field)  =>
        e(obj)
        e(field)
      | j-list(_, elts) =>
        elts.each(e)
      | j-obj(fields) =>
        fields.each(f)
      | j-id(_) => nothing
      | j-str(_) => nothing
      | j-num(_) => nothing
      | j-true => nothing
      | j-false => nothing
      | j-null => nothing
      | j-undefined => nothing
      | j-label(_) => nothing
    end
  end
  fun c(shadow kase):
    cases(J.JCase) kase block:
      | j-case(exp, body) =>
        e(exp)
        b(body)
      | j-default(body) => b(body)
    end
  end
  fun f(field):
    e(field.value)
  end
  fun s(stmt):
    cases(J.JStmt) stmt block:
      | j-var(name, rhs) =>
        # Ignore all variables named $underscore#####
        if A.is-s-atom(name) and (name.base == "$underscore") block:
          e(rhs)
        else:
          e(rhs)
          vars.set-now(name.key(), name)
        end
      | j-if1(cond, consq) =>
        e(cond)
        b(consq)
      | j-if(cond, consq, alt) =>
        e(cond)
        b(consq)
        b(alt)
      | j-return(exp) => e(exp)
      | j-try-catch(body, exn, catch) =>
        b(body)
        # ignoring the exn name, because it's not a Pyret variable
        b(catch)
      | j-throw(exp) => e(exp)
      | j-expr(exp) => e(exp)
      | j-break => nothing
      | j-continue => nothing
      | j-switch(exp, branches) =>
        e(exp)
        branches.each(c)
      | j-while(cond, body) =>
        e(cond)
        b(body)
      | j-for(_, init, cond, update, body) =>
        e(init)
        e(cond)
        e(update)
        b(body)
    end
  end
  fun b(blk):
    cases(J.JBlock) blk:
      | j-block1(stmt) => s(stmt)
      | j-block(stmts) => stmts.each(s)
    end
  end
  c(kase)
  vars
end

fun copy-mutable-dict(s :: D.MutableStringDict<A>) -> D.MutableStringDict<A>:
  s.freeze().unfreeze()
end

show-stack-trace = false
fun compile-fun-body(l :: Loc, step :: A.Name, fun-name :: A.Name, compiler, args :: List<N.ABind>, opt-arity :: Option<Number>, body :: N.AExpr, should-report-error-frame :: Boolean) -> J.JBlock block:
  make-label = make-label-sequence(0)
  ret-label = make-label()
  ans = fresh-id(compiler-name("ans"))
  apploc = fresh-id(compiler-name("al"))
  local-compiler = compiler.{make-label: make-label, cur-target: ret-label, cur-step: step, cur-ans: ans, cur-apploc: apploc}
  visited-body = body.visit(local-compiler)
  # To avoid penalty for assigning to formal parameters and also using the arguments object,
  # we create a shadow set of formal arguments, and immediately assign them to the "real" ones
  # in the normal entry case.  This expands the function preamble, but might enable JS optimizations,
  # so it should be worth it
  formal-args = for map(arg from args):
    N.a-bind(arg.l, formal-shadow-name(arg.id), arg.ann)
  end
  no-real-args = (args.first.id == compiler.resumer)
  copy-formals-to-args =
    if no-real-args: cl-empty
    else:
      for CL.map_list2(formal-arg from formal-args, arg from args):
        j-var(js-id-of(arg.id), j-id(formal-arg.id))
      end
    end
  ann-cases = compile-anns(local-compiler, step, args, local-compiler.make-label())
  main-body-cases =
    cl-empty
  ^ cl-append(_, ann-cases.new-cases)
  ^ cl-snoc(_, j-case(ann-cases.new-label, visited-body.block))
  ^ cl-append(_, visited-body.new-cases)
  # Initialize the case numbers, for more legible output...
  main-body-cases.each(lam(c): when J.is-j-case(c): c.exp.label.get() end end)
  main-body-cases-and-dead-vars = DAG.simplify(main-body-cases, step)
  shadow main-body-cases = main-body-cases-and-dead-vars.body
  all-vars = D.make-mutable-string-dict()
  for CL.each(case-expr from main-body-cases):
    local-bound-vars(case-expr, all-vars)
  end
  all-needed-vars = copy-mutable-dict(all-vars)
  for each(d from main-body-cases-and-dead-vars.discardable-vars.keys-list()):
    all-needed-vars.remove-now(d)
  end
  vars = all-needed-vars.keys-list-now().map(all-needed-vars.get-value-now(_))
  switch-cases =
    main-body-cases
  ^ cl-snoc(_, j-case(local-compiler.cur-target, j-block(
        if show-stack-trace:
          [clist: j-expr(rt-method("traceExit", [clist: j-str(tostring(l)), j-num(vars.length())]))]
        else:
          cl-empty
        end + [clist:
          j-expr(j-unop(rt-field("GAS"), j-incr)),
          j-return(j-id(local-compiler.cur-ans))])))
  ^ cl-snoc(_, j-default(j-block1(
          j-throw(j-binop(j-binop(j-str("No case numbered "), J.j-plus, j-id(step)), J.j-plus,
              j-str(" in " + fun-name.tosourcestring()))))))
  # fun check-no-dups(seen, kases):
  #   cases(List) kases:
  #     | empty => nothing
  #     | link(hd, tl) =>
  #       lbl = if J.is-j-case(hd): hd.exp.label.get() else: -1 end
  #       when seen.member(lbl):
  #         raise("Duplicate case found: " + hd.to-ugly-source())
  #       end
  #       check-no-dups(seen.add(lbl), tl)
  #   end
  # end
  # check-no-dups(sets.empty-tree-set, switch-cases.to-list())
  act-record = rt-method("makeActivationRecord", [clist:
      j-id(apploc),
      j-id(fun-name),
      j-id(step),
      j-list(false, if no-real-args: cl-empty else: CL.map_list(lam(a): j-id(js-id-of(a.id)) end, args) end),
      j-list(false, CL.map_list(lam(v): j-id(v) end, vars))
    ])
  e = fresh-id(compiler-name("e"))
  first-arg = formal-args.first.id
  entryExit = [clist:
    j-str(tostring(l)),
    j-num(vars.length())
  ]
  preamble = block:
    restorer =
      j-block(
        [clist:
          j-expr(j-assign(step, j-dot(j-id(first-arg), "step"))),
          j-expr(j-assign(apploc, j-dot(j-id(first-arg), "from"))),
          j-expr(j-assign(local-compiler.cur-ans, j-dot(j-id(first-arg), "ans")))
        ] +
        for CL.map_list_n(i from 0, arg from args):
          j-expr(j-assign(js-id-of(arg.id), j-bracket(j-dot(j-id(first-arg), "args"), j-num(i))))
        end +
        for CL.map_list_n(i from 0, v from vars):
          j-expr(j-assign(v, j-bracket(j-dot(j-id(first-arg), "vars"), j-num(i))))
        end)
    cases(Option) opt-arity:
      | some(arity) =>
        j-if(rt-method("isActivationRecord", [clist: j-id(first-arg)]),
          restorer,
          j-block(
            arity-check(local-compiler.get-loc(l), arity) +
            copy-formals-to-args +
            if show-stack-trace:
              [clist: rt-method("traceEnter", entryExit)]
            else:
              cl-empty
            end))
      | none =>
        if show-stack-trace:
          j-if(rt-method("isActivationRecord", [clist: j-id(first-arg)]),
            restorer,
            j-block([clist: rt-method("traceEnter", entryExit)] + copy-formals-to-args))
        else if no-real-args:
          j-if1(rt-method("isActivationRecord", [clist: j-id(first-arg)]), restorer)
        else:
          j-if(rt-method("isActivationRecord", [clist: j-id(first-arg)]),
            restorer, j-block(copy-formals-to-args))
        end
    end
  end
  stack-attach-guard =
    if compiler.options.proper-tail-calls:
      j-binop(rt-method("isCont", [clist: j-id(e)]),
        j-and,
        j-parens(j-binop(j-id(step), j-neq, ret-label)))
    else:
      rt-method("isCont", [clist: j-id(e)])
    end


  j-block([clist:
      j-var(step, j-num(0)),
      j-var(local-compiler.cur-ans, undefined),
      j-var(apploc, local-compiler.get-loc(l)),
      j-try-catch(
        j-block([clist:
            preamble,
            j-if1(j-binop(j-unop(rt-field("GAS"), j-decr), J.j-leq, j-num(0)),
              j-block([clist: j-expr(j-dot-assign(RUNTIME, "EXN_STACKHEIGHT", j-num(0))),
                  # j-expr(j-app(j-id("console.log"), [list: j-str("Out of gas in " + fun-name)])),
                  # j-expr(j-app(j-id("console.log"), [list: j-str("GAS is "), rt-field("GAS")])),
                  j-throw(rt-method("makeCont", cl-empty))])),
            j-while(j-true,
              j-block1(j-switch(j-id(step), switch-cases)))]),
        e,
        j-block(
          [clist:
            j-if1(stack-attach-guard,
              j-block1(
                j-expr(j-bracket-assign(j-dot(j-id(e), "stack"),
                    j-unop(rt-field("EXN_STACKHEIGHT"), J.j-postincr), act-record))
              ))] +
          if should-report-error-frame:
            add-frame = j-expr(add-stack-frame(e, j-id(apploc)))
            [clist:
              j-if1(rt-method("isPyretException", [clist: j-id(e)]),
                if show-stack-trace:
                  j-block([clist: add-frame, j-expr(rt-method("traceErrExit", entryExit))])
                else:
                  j-block1(add-frame)
                end
                )]
          else if show-stack-trace:
            [clist:
              j-if1(rt-method("isPyretException", [clist: j-id(e)]),
                j-block1(j-expr(add-stack-frame(e, j-id(apploc)))
                  ))]
          else:
            cl-empty
          end +
          [clist: j-throw(j-id(e))]))
  ])
end

fun compile-anns(visitor, step, binds :: List<N.ABind>, entry-label):
  var cur-target = entry-label
  new-cases = for lists.fold(acc from cl-empty, b from binds):
    if A.is-a-blank(b.ann) or A.is-a-any(b.ann) block:
      acc
    else:
      compiled-ann = compile-ann(b.ann, visitor)
      new-label = visitor.make-label()
      new-case = j-case(cur-target,
        j-block(compiled-ann.other-stmts +
          [clist:
            j-expr(j-assign(step, new-label)),
            j-expr(j-assign(visitor.cur-apploc, visitor.get-loc(b.ann.l))),
            j-expr(rt-method("_checkAnn",
              [clist: visitor.get-loc(b.ann.l), compiled-ann.exp, j-id(js-id-of(b.id))])),
            j-break]))
      cur-target := new-label
      cl-snoc(acc, new-case)
    end
  end
  { new-cases: new-cases, new-label: cur-target }
end

fun compile-annotated-let(visitor, b :: BindType, compiled-e :: DAG.CaseResults%(is-c-exp), compiled-body :: DAG.CaseResults%(is-c-block)) -> DAG.CaseResults%(is-c-block):
  id-assign = if is-b-let(b):
      cl-sing(j-var(js-id-of(b.value.id), compiled-e.exp))
    else if is-b-array(b):
      cl-sing(j-expr(j-bracket-assign(j-id(js-id-of(b.value.id)), j-num(b.idx), compiled-e.exp)))
    else:
      raise("Unknown " + b.value.label() + " in compile-annotated-let")
    end
  shadow b = b.value
  if A.is-a-blank(b.ann) or A.is-a-any(b.ann):
    c-block(
      j-block(
        compiled-e.other-stmts +
        id-assign +
        compiled-body.block.stmts
        ),
      compiled-body.new-cases
      )
  else:
    step = visitor.cur-step
    after-ann = visitor.make-label()
    after-ann-case = j-case(after-ann, j-block(compiled-body.block.stmts))
    compiled-ann = compile-ann(b.ann, visitor)
    c-block(
      j-block(
        compiled-e.other-stmts +
        id-assign +
        compiled-ann.other-stmts +
        [clist:
          j-expr(j-assign(step, after-ann)),
          j-expr(j-assign(visitor.cur-apploc, visitor.get-loc(b.ann.l))),
          j-expr(rt-method("_checkAnn", [clist:
                visitor.get-loc(b.ann.l),
                compiled-ann.exp,
                j-id(js-id-of(b.id))])),
          j-break
        ]),
      cl-cons(after-ann-case, compiled-body.new-cases))
  end
end

fun get-new-cases(compiler, opt-dest, opt-body, after-label, ans):
  opt-compiled-body = opt-body.and-then(lam(b): b.visit(compiler) end)
  cases(Option) opt-dest:
    | some(dest) =>
      cases(Option) opt-compiled-body:
        | some(compiled-body) =>
          compiled-binding = compile-annotated-let(compiler, dest, c-exp(j-id(ans), cl-empty), compiled-body)
          cl-cons(
            j-case(after-label, compiled-binding.block),
            compiled-binding.new-cases)
        | none => raise("Impossible: compile-split-app can't have a dest without a body")
      end
    | none =>
      cases(Option) opt-compiled-body:
        | some(compiled-body) =>
          cl-cons(j-case(after-label, compiled-body.block), compiled-body.new-cases)
        | none => cl-empty
      end
  end
end

fun compile-split-method-app(l, compiler, opt-dest, obj, methname, args, opt-body):
  ans = compiler.cur-ans
  step = compiler.cur-step
  compiled-obj = obj.visit(compiler).exp
  compiled-args = CL.map_list(lam(a): a.visit(compiler).exp end, args)
  num-args = args.length()

  if J.is-j-id(compiled-obj):
    colon-field = rt-method("getColonFieldLoc", [clist: compiled-obj, j-str(methname), compiler.get-loc(l)])
    colon-field-id = j-id(fresh-id(compiler-name("field")))
    check-method = rt-method("isMethod", [clist: colon-field-id])
    after-app-label = if is-none(opt-body): compiler.cur-target else: compiler.make-label() end
    new-cases = get-new-cases(compiler, opt-dest, opt-body, after-app-label, ans)
    c-block(
      j-block([clist:
          # Update step before the call, so that if it runs out of gas, the resumer goes to the right step
          j-expr(j-assign(step,  after-app-label)),
          j-expr(j-assign(compiler.cur-apploc, compiler.get-loc(l))),
          j-expr(j-assign(colon-field-id.id, colon-field)),
          # if num-args < 6:
          #   j-expr(j-assign(ans, rt-method("callIfPossible" + tostring(num-args),
          #         link(compiler.get-loc(l), link(j-id(colon-field-id), link(compiled-obj, compiled-args))))))
          # else:
          j-if(check-method,
            j-block1(
              j-expr(j-assign(ans, j-app(j-dot(colon-field-id, "full_meth"),
                    cl-cons(compiled-obj, compiled-args))))
              ),
            j-block([clist:
                check-fun(compiler.get-loc(l), colon-field-id),
                j-expr(j-assign(ans, app(compiler.get-loc(l), colon-field-id, compiled-args)))
              ]))
          # end
          ,
          j-break]),
      new-cases)
  else:
    obj-id = j-id(fresh-id(compiler-name("obj")))
    colon-field = rt-method("getColonFieldLoc", [clist: obj-id, j-str(methname), compiler.get-loc(l)])
    colon-field-id = j-id(fresh-id(compiler-name("field")))
    check-method = rt-method("isMethod", [clist: colon-field-id])
    after-app-label = if is-none(opt-body): compiler.cur-target else: compiler.make-label() end
    new-cases = get-new-cases(compiler, opt-dest, opt-body, after-app-label, ans)
    c-block(
      j-block([clist:
          # Update step before the call, so that if it runs out of gas, the resumer goes to the right step
          j-expr(j-assign(step,  after-app-label)),
          j-expr(j-assign(compiler.cur-apploc, compiler.get-loc(l))),
          j-var(obj-id.id, compiled-obj),
          j-var(colon-field-id.id, colon-field),
          # if num-args < 6:
          #   j-expr(j-assign(ans, rt-method("callIfPossible" + tostring(num-args),
          #         link(compiler.get-loc(l), link(colon-field-id, link(obj-id, compiled-args))))))
          # else:
          j-if(check-method,
            j-block1(
              j-expr(j-assign(ans, j-app(j-dot(colon-field-id, "full_meth"),
                    cl-cons(obj-id, compiled-args))))
              ),
            j-block([clist:
                check-fun(compiler.get-loc(l), colon-field-id),
                j-expr(j-assign(ans, app(compiler.get-loc(l), colon-field-id, compiled-args)))
              ]))
          # end
          ,
          j-break]),
      new-cases)
  end
end

fun compile-split-app(l, compiler, opt-dest, f, args, opt-body):
  ans = compiler.cur-ans
  step = compiler.cur-step
  compiled-f = f.visit(compiler).exp
  compiled-args = CL.map_list(lam(a): a.visit(compiler).exp end, args)
  after-app-label = if is-none(opt-body): compiler.cur-target else: compiler.make-label() end
  new-cases = get-new-cases(compiler, opt-dest, opt-body, after-app-label, ans)
  c-block(
    j-block([clist:
        # Update step before the call, so that if it runs out of gas, the resumer goes to the right step
        j-expr(j-assign(step, after-app-label)),
        j-expr(j-assign(compiler.cur-apploc, compiler.get-loc(l))),
        check-fun(j-id(compiler.cur-apploc), compiled-f),
        j-expr(j-assign(ans, app(compiler.get-loc(l), compiled-f, compiled-args))),
        j-break]),
    new-cases)
end

fun compile-split-if(compiler, opt-dest, cond, consq, alt, opt-body):
  consq-label = compiler.make-label()
  alt-label = compiler.make-label()
  after-if-label = if is-none(opt-body): compiler.cur-target else: compiler.make-label() end
  ans = compiler.cur-ans
  compiler-after-if = compiler.{cur-target: after-if-label}
  compiled-consq = consq.visit(compiler-after-if)
  compiled-alt = alt.visit(compiler-after-if)
  new-cases =
    cl-cons(j-case(consq-label, compiled-consq.block), compiled-consq.new-cases)
    + cl-cons(j-case(alt-label, compiled-alt.block), compiled-alt.new-cases)
    + get-new-cases(compiler, opt-dest, opt-body, after-if-label, ans)
  c-block(
    j-block([clist:
        j-expr(j-assign(compiler.cur-step,
            j-ternary(rt-method("isPyretTrue", [clist: cond.visit(compiler).exp]),
              consq-label, alt-label))),
        j-break
      ]),
    new-cases)
end
fun compile-cases-branch(compiler, compiled-val, branch :: N.ACasesBranch, cases-loc):
  compiled-body = branch.body.visit(compiler)
  if compiled-body.new-cases.length() < 5:
    compile-inline-cases-branch(compiler, compiled-val, branch, compiled-body, cases-loc)
  else:
    temp-branch = fresh-id(compiler-name("temp_branch"))
    branch-args =
      if N.is-a-cases-branch(branch) and (branch.args.length() > 0): branch.args.map(get-bind)
      else: [list: N.a-bind(branch.body.l, compiler.resumer, A.a-blank)]
      end
    step = fresh-id(compiler-name("step"))
    ref-binds-mask = if N.is-a-cases-branch(branch):
      j-list(false, for CL.map_list(cb from branch.args):
          j-bool(A.is-s-cases-bind-ref(cb.field-type))
        end)
    else:
      j-list(false, cl-empty)
    end
    compiled-branch-fun =
      compile-fun-body(branch.body.l, step, temp-branch, compiler, branch-args, none, branch.body, true)
    preamble = cases-preamble(compiler, compiled-val, branch, cases-loc)
    deref-fields = j-expr(j-assign(compiler.cur-ans, j-method(compiled-val, "$app_fields", [clist: j-id(temp-branch), ref-binds-mask])))
    actual-app =
      [clist:
        j-expr(j-assign(compiler.cur-step, compiler.cur-target)),
        j-expr(j-assign(compiler.cur-apploc, compiler.get-loc(branch.l))),
        j-var(temp-branch,
          j-fun(CL.map_list(lam(arg): formal-shadow-name(arg.id) end, branch-args), compiled-branch-fun)),
        deref-fields,
        j-break]

    c-block(
      j-block(preamble + actual-app),
      cl-empty)
  end
end
fun cases-preamble(compiler, compiled-val, branch, cases-loc):
  cases(N.ACasesBranch) branch:
    | a-cases-branch(_, pat-loc, name, args, body) =>
      branch-given-arity = j-num(args.length())
      obj-expected-arity = j-dot(compiled-val, "$arity")
      checker =
        j-if1(j-binop(obj-expected-arity, j-neq, branch-given-arity),
          j-block1(
            j-if(j-binop(obj-expected-arity, j-geq, j-num(0)),
              j-block1(
                j-expr(j-method(rt-field("ffi"), "throwCasesArityErrorC",
                    [clist: compiler.get-loc(pat-loc), branch-given-arity,
                      obj-expected-arity, compiler.get-loc(cases-loc)]))),
              j-block1(
                j-expr(j-method(rt-field("ffi"), "throwCasesSingletonErrorC",
                    [clist: compiler.get-loc(pat-loc), j-true, compiler.get-loc(cases-loc)]))))))
      [clist: checker]
    | a-singleton-cases-branch(_, pat-loc, _, _) =>
      checker =
        j-if1(j-binop(j-dot(compiled-val, "$arity"), j-neq, j-num(-1)),
          j-block1(
            j-expr(j-method(rt-field("ffi"), "throwCasesSingletonErrorC",
                [clist: compiler.get-loc(pat-loc), j-false, compiler.get-loc(cases-loc)]))))
      [clist: checker]
  end
end
fun compile-inline-cases-branch(compiler, compiled-val, branch, compiled-body, cases-loc):
  preamble = cases-preamble(compiler, compiled-val, branch, cases-loc)
  if N.is-a-cases-branch(branch):
    entry-label = compiler.make-label()
    ann-cases = compile-anns(compiler, compiler.cur-step, branch.args.map(get-bind), entry-label)
    field-names = j-id(js-id-of(compiler-name("fn")))
    get-field-names = j-var(field-names.id, j-dot(j-dot(compiled-val, "$constructor"), "$fieldNames"))
    deref-fields =
      for CL.map_list_n(i from 0, arg from branch.args):
        mask = j-bracket(j-dot(compiled-val, "$mut_fields_mask"), j-num(i))
        field = get-dict-field(compiled-val, j-bracket(field-names, j-num(i)))
        j-var(js-id-of(arg.bind.id),
          rt-method("derefField", [clist: field, mask, j-bool(A.is-s-cases-bind-ref(arg.field-type))]))
      end
    if ann-cases.new-cases == cl-empty:
      c-block(j-block(preamble
            ^ cl-snoc(_, get-field-names)
            ^ cl-append(_, deref-fields)
            ^ cl-append(_, compiled-body.block.stmts)),
        compiled-body.new-cases)
    else:
      c-block(j-block(
          preamble
            ^ cl-snoc(_, get-field-names)
            ^ cl-append(_, deref-fields)
            ^ cl-snoc(_, j-expr(j-assign(compiler.cur-step, entry-label)))
            ^ cl-snoc(_, j-break)),
        ann-cases.new-cases
          ^ cl-append(_, compiled-body.new-cases)
          ^ cl-snoc(_, j-case(ann-cases.new-label, compiled-body.block)))
    end
  else:
    c-block(j-block(preamble + compiled-body.block.stmts), compiled-body.new-cases)
  end
end
fun compile-split-cases(compiler, cases-loc, opt-dest, typ, val :: N.AVal, branches :: List<N.ACasesBranch>, _else :: N.AExpr, opt-body :: Option<N.AExpr>):
  compiled-val = val.visit(compiler).exp
  after-cases-label = if is-none(opt-body): compiler.cur-target else: compiler.make-label() end
  compiler-after-cases = compiler.{cur-target: after-cases-label}
  compiled-branches = branches.map(compile-cases-branch(compiler-after-cases, compiled-val, _, cases-loc))
  compiled-else = _else.visit(compiler-after-cases)
  branch-labels = branches.map(lam(_): compiler.make-label() end)
  else-label = compiler.make-label()
  branch-cases = for fold2(acc from cl-empty, label from branch-labels, branch from compiled-branches):
    acc
    ^ cl-snoc(_, j-case(label, branch.block))
    ^ cl-append(_, branch.new-cases)
  end
  branch-else-cases =
    (branch-cases
      ^ cl-snoc(_, j-case(else-label, compiled-else.block))
      ^ cl-append(_, compiled-else.new-cases))
  dispatch-table = j-obj(for CL.map_list2(branch from branches, label from branch-labels): j-field(branch.name, label) end)
  dispatch = j-id(fresh-id(compiler-name("cases_dispatch")))
  # NOTE: Ignoring typ for the moment!
  new-cases =
    branch-else-cases
    + get-new-cases(compiler, opt-dest, opt-body, after-cases-label, compiler.cur-ans)
  c-block(
    j-block([clist:
        j-var(dispatch.id, dispatch-table),
        # j-expr(j-app(j-dot(j-id("console"), "log"),
        #     [list: j-str("$name is "), j-dot(compiled-val, "$name"),
        #       j-str("val is "), compiled-val,
        #       j-str("dispatch is "), dispatch])),
        j-expr(j-assign(compiler.cur-apploc, compiler.get-loc(cases-loc))),
        j-expr(j-assign(compiler.cur-step,
            j-binop(j-bracket(dispatch, j-dot(compiled-val, "$name")), J.j-or, else-label))),
        j-break]),
    new-cases)
end

fun compile-split-update(compiler, loc, opt-dest, obj :: N.AVal, fields :: List<N.AField>, opt-body :: Option<N.AExpr>):
  ans = compiler.cur-ans
  step = compiler.cur-step
  compiled-obj = obj.visit(compiler).exp
  compiled-field-vals = CL.map_list(lam(a): a.value.visit(compiler).exp end, fields)
  field-names = CL.map_list(lam(f): j-str(f.name) end, fields)
  field-locs = CL.map_list(lam(f): compiler.get-loc(f.l) end, fields)
  after-update-label = if is-none(opt-body): compiler.cur-target else: compiler.make-label() end
  new-cases = get-new-cases(compiler, opt-dest, opt-body, after-update-label, ans)
  c-block(
    j-block([clist:
        # Update step before the call, so that if it runs out of gas, the resumer goes to the right step
        j-expr(j-assign(step, after-update-label)),
        j-expr(j-assign(ans, rt-method("checkRefAnns",
          [clist:
            compiled-obj,
            j-list(false, field-names),
            j-list(false, compiled-field-vals),
            j-list(false, field-locs),
            compiler.get-loc(loc),
            compiler.get-loc(obj.l)]))),
        j-break]),
    new-cases)

end

fun compile-lettable(compiler, b :: Option<BindType>, e :: N.ALettable, opt-body :: Option<N.AExpr>, else-case :: ( -> DAG.CaseResults)):
  cases(N.ALettable) e:
    | a-app(l2, f, args) =>
      compile-split-app(l2, compiler, b, f, args, opt-body)
    | a-method-app(l2, obj, m, args) =>
      compile-split-method-app(l2, compiler, b, obj, m, args, opt-body)
    | a-if(l2, cond, then, els) =>
      compile-split-if(compiler, b, cond, then, els, opt-body)
    | a-cases(l2, typ, val, branches, _else) =>
      compile-split-cases(compiler, l2, b, typ, val, branches, _else, opt-body)
    | a-update(l2, obj, fields) =>
      compile-split-update(compiler, l2, b, obj, fields, opt-body)
    | else => else-case()
  end
end

compiler-visitor = {
  method a-module(self, l, answer, dvs, dts, provides, types, checks):
    types-obj-fields = for fold(acc from {fields: cl-empty, others: cl-empty}, ann from types):
      compiled = compile-ann(ann.ann, self)
      {
        fields: cl-snoc(acc.fields, j-field(ann.name, compiled.exp)),
        others: acc.others + compiled.other-stmts
      }
    end

    compiled-provides = provides.visit(self)
    compiled-answer = answer.visit(self)
    compiled-checks = checks.visit(self)
    c-exp(
      rt-method("makeObject", [clist:
          j-obj([clist:
              j-field("answer", compiled-answer.exp),
              j-field("namespace", NAMESPACE),
              j-field("defined-values",
                j-obj(
                  for CL.map_list(dv from dvs):
                    compiled-val = dv.value.visit(self).exp
                    j-field(dv.name, compiled-val)
                  end)),
              j-field("defined-types",
                j-obj(
                  for CL.map_list(dt from dts):
                    compiled-ann = compile-ann(dt.typ, self).exp
                    j-field(dt.name, compiled-ann)
                  end)),
              j-field("provide-plus-types",
                rt-method("makeObject", [clist: j-obj([clist:
                        j-field("values", compiled-provides.exp),
                        j-field("types", j-obj(types-obj-fields.fields))
                    ])])),
              j-field("checks", compiled-checks.exp)])]),
      types-obj-fields.others
        + compiled-provides.other-stmts + compiled-answer.other-stmts + compiled-checks.other-stmts)
  end,
  method a-type-let(self, l, bind, body):
    cases(N.ATypeBind) bind:
      | a-type-bind(l2, name, ann) =>
        visited-body = body.visit(self)
        compiled-ann = compile-ann(ann, self)
        c-block(
          j-block(
            compiled-ann.other-stmts +
            [clist: j-var(js-id-of(name), compiled-ann.exp)] +
            visited-body.block.stmts
            ),
          visited-body.new-cases)
      | a-newtype-bind(l2, name, nameb) =>
        brander-id = js-id-of(nameb)
        visited-body = body.visit(self)
        c-block(
          j-block(
            [clist:
              j-var(brander-id, rt-method("namedBrander", [clist: j-str(name.toname()), self.get-loc(l2)])),
              j-var(js-id-of(name), rt-method("makeBranderAnn", [clist: j-id(brander-id), j-str(name.toname())]))
            ] +
            visited-body.block.stmts),
          visited-body.new-cases)
    end
  end,
  method a-let(self, _, b :: N.ABind, e :: N.ALettable, body :: N.AExpr):
    compile-lettable(self, some(b-let(b)), e, some(body), lam():
      compiled-e = e.visit(self)
      compiled-body = body.visit(self)
      compile-annotated-let(self, b-let(b), compiled-e, compiled-body)
    end)
  end,
  method a-arr-let(self, _, b :: N.ABind, idx :: Number, e :: N.ALettable, body :: N.AExpr):
    compile-lettable(self, some(b-array(b, idx)), e, some(body), lam():
      compiled-e = e.visit(self)
      compiled-body = body.visit(self)
      compile-annotated-let(self, b-array(b, idx), compiled-e, compiled-body)
    end)
  end,
  method a-var(self, l :: Loc, b :: N.ABind, e :: N.ALettable, body :: N.AExpr):
    compiled-body = body.visit(self)
    compiled-e = e.visit(self)
    # TODO: annotations here?
    c-block(
      j-block(
        j-var(js-id-of(b.id),
          j-obj([clist: j-field("$var", compiled-e.exp)
              # NOTE(joe): This can be useful to turn on for debugging
              #                     , j-field("$name", j-str(b.id.toname()))
            ]))
        ^ cl-cons(_, compiled-body.block.stmts)),
      compiled-body.new-cases)
  end,
  method a-seq(self, _, e1, e2):
    compile-lettable(self, none, e1, some(e2), lam():
      e1-visit = e1.visit(self)
      e2-visit = e2.visit(self)
      first-stmt = if J.is-JStmt(e1-visit.exp): e1-visit.exp else: j-expr(e1-visit.exp) end
      c-block(
        j-block(e1-visit.other-stmts + cl-cons(first-stmt, e2-visit.block.stmts)),
        e2-visit.new-cases)
    end)
  end,
  method a-if(self, l :: Loc, cond :: N.AVal, consq :: N.AExpr, alt :: N.AExpr):
    raise("Impossible: a-if directly in compiler-visitor should never happen")
  end,
  method a-cases(self, l :: Loc, typ :: A.Ann, val :: N.AVal, branches :: List<N.ACasesBranch>, _else :: N.AExpr):
    raise("Impossible: a-cases directly in compiler-visitor should never happen")
  end,
  method a-update(self, l, obj, fields):
    raise("Impossible: a-update directly in compiler-visitor should never happen")
  end,
  method a-lettable(self, _, e :: N.ALettable):
    compile-lettable(self, none, e, none, lam():
      visit-e = e.visit(self)
      c-block(
          j-block(
          cl-sing(j-expr(j-assign(self.cur-step, self.cur-target)))
            + visit-e.other-stmts
              + [clist:
              j-expr(j-assign(self.cur-ans, visit-e.exp)),
              j-break]),
        cl-empty)
    end)
  end,
  method a-assign(self, l :: Loc, id :: A.Name, value :: N.AVal):
    visit-value = value.visit(self)
    c-exp(j-dot-assign(j-id(js-id-of(id)), "$var", visit-value.exp), visit-value.other-stmts)
  end,
  method a-app(self, l :: Loc, f :: N.AVal, args :: List<N.AVal>):
    raise("Impossible: a-app directly in compiler-visitor should never happen")
  end,
  method a-prim-app(self, l :: Loc, f :: String, args :: List<N.AVal>):
    visit-args = args.map(_.visit(self))
    set-loc = [clist:
      j-expr(j-assign(self.cur-apploc, self.get-loc(l)))
    ]
    c-exp(rt-method(f, CL.map_list(get-exp, visit-args)), set-loc)
  end,

  method a-ref(self, l, maybe-ann):
    cases(Option) maybe-ann:
      | none => c-exp(rt-method("makeGraphableRef", cl-empty), cl-empty)
      | some(ann) => raise("Cannot handle annotations in refs yet")
    end
  end,
  method a-obj(self, l :: Loc, fields :: List<N.AField>):
    visit-fields = fields.map(lam(f): f.visit(self) end)
    c-exp(rt-method("makeObject", [clist: j-obj(CL.map_list(o-get-field, visit-fields))]), cl-empty)
  end,
  method a-get-bang(self, l :: Loc, obj :: N.AVal, field :: String):
    visit-obj = obj.visit(self)
    c-exp(rt-method("getFieldRef", [clist: visit-obj.exp, j-str(field), self.get-loc(l)]), visit-obj.other-stmts)
  end,
  method a-extend(self, l :: Loc, obj :: N.AVal, fields :: List<N.AField>):
    visit-obj = obj.visit(self)
    visit-fields = fields.map(lam(f): f.visit(self) end)
    c-exp(rt-method("extendObj", [clist: self.get-loc(l), visit-obj.exp, j-obj(CL.map_list(o-get-field, visit-fields))]),
      cl-empty)
  end,
  method a-dot(self, l :: Loc, obj :: N.AVal, field :: String):
    visit-obj = obj.visit(self)
    c-exp(get-field(visit-obj.exp, j-str(field), self.get-loc(l)), visit-obj.other-stmts + [clist: j-expr(j-assign(self.cur-apploc, self.get-loc(l)))])
  end,
  method a-colon(self, l :: Loc, obj :: N.AVal, field :: String):
    visit-obj = obj.visit(self)
    c-exp(rt-method("getColonFieldLoc", [clist: visit-obj.exp, j-str(field), self.get-loc(l)]),
      visit-obj.other-stmts)
  end,
  method a-lam(self, l :: Loc, args :: List<N.ABind>, ret :: A.Ann, body :: N.AExpr):
    new-step = fresh-id(compiler-name("step"))
    temp = fresh-id(compiler-name("temp_lam"))
    len = args.length()
    # NOTE: args may be empty, so we need at least one name ("resumer") for the stack convention
    effective-args =
      if len > 0: args
      else: [list: N.a-bind(l, self.resumer, A.a-blank)]
      end
    c-exp(
      rt-method("makeFunction", [clist: j-id(temp)]),
      [clist:
        j-var(temp,
          j-fun(CL.map_list(lam(arg): formal-shadow-name(arg.id) end, effective-args),
                compile-fun-body(l, new-step, temp, self, effective-args, some(len), body, true)))])
  end,
  method a-method(self, l :: Loc, args :: List<N.ABind>, ret :: A.Ann, body :: N.AExpr):
    step = fresh-id(compiler-name("step"))
    temp-full = fresh-id(compiler-name("temp_full"))
    len = args.length()
    full-var =
      j-var(temp-full,
        j-fun(CL.map_list(lam(a): formal-shadow-name(a.id) end, args),
          compile-fun-body(l, step, temp-full, self, args, some(len), body, true)
        ))
    method-expr = if len < 9:
      rt-method("makeMethod" + tostring(len - 1), [clist: j-id(temp-full)])
    else:
      rt-method("makeMethodN", [clist: j-id(temp-full)])
    end
    c-exp(method-expr, [clist: full-var])
  end,
  method a-val(self, l :: Loc, v :: N.AVal):
    v.visit(self)
  end,
  method a-field(self, l :: Loc, name :: String, value :: N.AVal):
    visit-v = value.visit(self)
    c-field(j-field(name, visit-v.exp), visit-v.other-stmts)
  end,
  method a-tuple(self, l, values):
    visit-vals = values.map(_.visit(self)) 
    c-exp(rt-method("makeTuple", [clist: j-list(false, CL.map_list(get-exp, visit-vals))]), cl-empty)
  end,
  method a-tuple-get(self, l, tup, index):
   visit-name = tup.visit(self)
    c-exp(rt-method("getTuple", [clist: visit-name.exp, j-num(index), self.get-loc(l)]), cl-empty)
  end,
  method a-array(self, l, values):
    visit-vals = values.map(_.visit(self))
    other-stmts = visit-vals.foldr(lam(v, acc): v.other-stmts + acc end, cl-empty)
    c-exp(j-list(false, CL.map_list(get-exp, visit-vals)), other-stmts)
  end,
  method a-srcloc(self, l, loc):
    c-exp(self.get-loc(loc), cl-empty)
  end,
  method a-num(self, l :: Loc, n :: Number):
    if num-is-fixnum(n):
      c-exp(j-parens(j-num(n)), cl-empty)
    else:
      c-exp(rt-method("makeNumberFromString", [clist: j-str(tostring(n))]), cl-empty)
    end
  end,
  method a-str(self, l :: Loc, s :: String):
    c-exp(j-parens(j-str(s)), cl-empty)
  end,
  method a-bool(self, l :: Loc, b :: Boolean):
    c-exp(j-parens(if b: j-true else: j-false end), cl-empty)
  end,
  method a-undefined(self, l :: Loc):
    c-exp(undefined, cl-empty)
  end,
  method a-id(self, l :: Loc, id :: A.Name):
    c-exp(j-id(js-id-of(id)), cl-empty)
  end,
  method a-id-var(self, l :: Loc, id :: A.Name):
    c-exp(j-dot(j-id(js-id-of(id)), "$var"), cl-empty)
  end,
  method a-id-letrec(self, l :: Loc, id :: A.Name, safe :: Boolean):
    s = j-id(js-id-of(id))
    if safe:
      c-exp(j-dot(s, "$var"), cl-empty)
    else:
      c-exp(
        j-ternary(
          j-binop(j-dot(s, "$var"), j-eq, undefined),
          raise-id-exn(self.get-loc(l), id.toname()),
          j-dot(s, "$var")),
        cl-empty)
    end
  end,

  method a-data-expr(self, l, name, namet, variants, shared):
    fun brand-name(base):
      js-id-of(compiler-name("brand-" + base)).toname()
    end

    visit-shared-fields = CL.map_list(_.visit(self), shared)
    shared-fields = visit-shared-fields.map(o-get-field)
    external-brand = j-id(js-id-of(namet))

    fun make-brand-predicate(loc :: Loc, b :: J.JExpr, pred-name :: String):
      val = fresh-id(compiler-name("val"))
      j-field(
        pred-name,
        rt-method("makeFunction", [clist:
            j-fun(
              [clist: val],
              j-block(
                arity-check(self.get-loc(loc), 1) +
                [clist: j-return(rt-method("makeBoolean", [clist: rt-method("hasBrand", [clist: j-id(val), b])]))]
                )
              )
          ])
        )
    end

    fun make-variant-constructor(l2, base-id, brands-id, members, refl-name, refl-ref-fields, refl-ref-fields-mask, refl-fields, constructor-id):

      nonblank-anns = for filter(m from members):
        not(A.is-a-blank(m.bind.ann)) and not(A.is-a-any(m.bind.ann))
      end
      compiled-anns = for fold(acc from {anns: cl-empty, others: cl-empty}, m from nonblank-anns):
        compiled = compile-ann(m.bind.ann, self)
        {
          anns: cl-snoc(acc.anns, compiled.exp),
          others: acc.others + compiled.other-stmts
        }
      end
      compiled-locs = for CL.map_list(m from nonblank-anns): self.get-loc(m.bind.ann.l) end
      compiled-vals = for CL.map_list(m from nonblank-anns): j-str(js-id-of(m.bind.id).tosourcestring()) end

      # NOTE(joe 6-14-2014): We cannot currently statically check for if an annotation
      # is a refinement because of type aliases.  So, we use checkAnnArgs, which takes
      # a continuation and manages all of the stack safety of annotation checking itself.

      # NOTE(joe 5-26-2015): This has been moved to a hybrid static/dynamic solution by
      # passing the check off to a runtime function that uses JavaScript's Function
      # to only do the refinement check once.
      c-exp(
        rt-method("makeVariantConstructor", [clist:
            self.get-loc(l2),
            # NOTE(joe): Thunked at the JS level because compiled-anns might contain
            # references to rec ids that should be resolved later
            j-fun(cl-empty, j-block1(j-return(j-list(false, compiled-anns.anns)))),
            j-list(false, compiled-vals),
            j-list(false, compiled-locs),
            j-list(false, CL.map_list(lam(m): j-bool(N.is-a-mutable(m.member-type)) end, members)),
            j-list(false, CL.map_list(lam(m): j-str(js-id-of(m.bind.id).tosourcestring()) end, members)),
            refl-ref-fields-mask,
            j-id(base-id),
            j-id(brands-id),
            refl-name,
            refl-ref-fields,
            refl-fields,
            constructor-id
          ]),
        cl-empty)
    end

    fun compile-variant(v :: N.AVariant):
      vname = v.name
      variant-base-id = js-id-of(compiler-name(vname + "-base"))
      variant-brand = rt-method("namedBrander", [clist: j-str(vname), self.get-loc(v.l)])
      variant-brand-id = js-id-of(compiler-name(vname + "-brander"))
      variant-brand-obj-id = js-id-of(compiler-name(vname + "-brands"))
      variant-brands = j-obj(cl-empty)
      visit-with-fields = v.with-members.map(_.visit(self))

      refl-base-fields =
        cases(N.AVariant) v:
          | a-singleton-variant(_, _, _) => cl-empty
          | a-variant(_, _, _, members, _) =>
            [clist:
              j-field("$fieldNames",
                j-list(false, CL.map_list(lam(m): j-str(m.bind.id.toname()) end, members)))]
        end

      f-id = const-id("f")
      refl-name = j-str(vname)
      refl-ref-fields-id = js-id-of(compiler-name(vname + "_getfieldsref"))
      refl-ref-fields =
        cases(N.AVariant) v:
          | a-variant(_, _, _, members, _) =>
            refmask-id = const-id("refmask")
            j-fun([clist: f-id, refmask-id], j-block([clist: j-return(j-app(j-id(f-id),
                for CL.map_list_n(n from 0, m from members):
                  field = get-dict-field(THIS, j-str(m.bind.id.toname()))
                  mask = j-bracket(j-id(refmask-id), j-num(n))
                  rt-method("derefField", [clist: field, j-bool(N.is-a-mutable(m.member-type)), mask])
                end))]))
          | a-singleton-variant(_, _, _) =>
            j-fun([clist: f-id], j-block1(j-return(j-app(j-id(f-id), cl-empty))))
        end

      refl-ref-fields-mask-id = js-id-of(compiler-name(vname + "_mutablemask"))
      refl-ref-fields-mask =
        cases(N.AVariant) v:
          | a-singleton-variant(_, _, _) => j-list(false, cl-empty)
          | a-variant(_, _, _, members, _) =>
            j-list(false,
              CL.map_list(lam(m): if N.is-a-mutable(m.member-type): j-true else: j-false end end, members))
        end

      refl-fields-id = js-id-of(compiler-name(vname + "_getfields"))
      refl-fields =
        cases(N.AVariant) v:
          | a-variant(_, _, _, members, _) =>
            j-fun([clist: const-id("f")], j-block1(j-return(j-app(j-id(f-id),
                    CL.map_list(lam(m):
                        get-dict-field(THIS, j-str(m.bind.id.toname()))
                      end, members)))))
          | a-singleton-variant(_, _, _) =>
            j-fun([clist: const-id("f")], j-block1(j-return(j-app(j-id(f-id), cl-empty))))
        end

      fun member-count(shadow v):
        cases(N.AVariant) v:
          | a-variant(_, _, _, members, _) => members.length()
          | a-singleton-variant(_, _, _) => 0
        end
      end

      match-field = j-field("_match", rt-method("makeMatch", [clist: refl-name, j-num(member-count(v))]))

      stmts =
        visit-with-fields.foldr(lam(vf, acc): vf.other-stmts + acc end,
          [clist:
            j-var(refl-fields-id, refl-fields),
            j-var(refl-ref-fields-id, refl-ref-fields),
            j-var(refl-ref-fields-mask-id, refl-ref-fields-mask),
            j-var(variant-base-id, j-obj(refl-base-fields + shared-fields + CL.map_list(o-get-field, visit-with-fields) + [clist: match-field])),
            j-var(variant-brand-id, variant-brand),
            j-var(variant-brand-obj-id, variant-brands),
            j-expr(j-bracket-assign(
                j-id(variant-brand-obj-id),
                j-dot(external-brand, "_brand"),
                j-true)),
            j-expr(j-bracket-assign(
                j-id(variant-brand-obj-id),
                j-dot(j-id(variant-brand-id), "_brand"),
                j-true))
          ])
      predicate = j-field(A.make-checker-name(vname), get-field(j-id(variant-brand-id), j-str("test"), self.get-loc(v.l))) #make-brand-predicate(v.l, j-dot(j-id(variant-brand-id), "_brand"), A.make-checker-name(vname))

      cases(N.AVariant) v:
        | a-variant(l2, constr-loc, _, members, with-members) =>
          constr-vname = js-id-of(const-id(vname))
          compiled-constr =
            make-variant-constructor(constr-loc, variant-base-id, variant-brand-obj-id, members,
              refl-name, j-id(refl-ref-fields-id), j-id(refl-ref-fields-mask-id), j-id(refl-fields-id), j-id(variant-base-id))
          {
            stmts: stmts + compiled-constr.other-stmts + [clist: j-var(constr-vname, compiled-constr.exp)],
            constructor: j-field(vname, j-id(constr-vname)),
            predicate: predicate
          }
        | a-singleton-variant(_, _, with-members) =>
          {
            stmts: stmts,
            constructor: j-field(vname, rt-method("makeDataValue", [clist: j-id(variant-base-id), j-id(variant-brand-obj-id), refl-name, j-id(refl-ref-fields-id), j-id(refl-fields-id), j-num(-1), j-id(refl-ref-fields-mask-id), j-id(variant-base-id)])),
            predicate: predicate
          }
      end
    end

    variant-pieces = variants.map(compile-variant)

    header-stmts = for fold(acc from cl-empty, piece from variant-pieces):
      acc + piece.stmts
    end
    obj-fields = for fold(acc from cl-empty, piece from variant-pieces):
      acc + [clist: piece.predicate, piece.constructor]
    end

    data-predicate = j-field(name, get-field(external-brand, j-str("test"), self.get-loc(l))) #make-brand-predicate(l, j-dot(external-brand, "_brand"), name)

    data-object = rt-method("makeObject", [clist: j-obj([clist: data-predicate] + obj-fields)])

    c-exp(data-object, header-stmts)
  end
}

remove-useless-if-visitor = N.default-map-visitor.{
  method a-if(self, l, c, t, e):
    cases(N.AVal) c:
      | a-bool(_, test) =>
        if test:
          visit-t = t.visit(self)
          if N.is-a-lettable(visit-t): visit-t.e else: N.a-if(l, c.visit(self), visit-t, e.visit(self)) end
        else:
          visit-e = e.visit(self)
          if N.is-a-lettable(visit-e): visit-e.e else: N.a-if(l, c.visit(self), t.visit(self), visit-e) end
        end
      | else => N.a-if(l, c.visit(self), t.visit(self), e.visit(self))
    end
  end
}

check:
  d = N.dummy-loc
  true1 = N.a-if(d, N.a-bool(d, true),
    N.a-lettable(d, N.a-val(d, N.a-num(d, 1))),
    N.a-lettable(d, N.a-val(d, N.a-num(d, 2))))
  true1.visit(remove-useless-if-visitor) is N.a-val(d, N.a-num(d, 1))

  false4 = N.a-if(d, N.a-bool(d, false),
    N.a-lettable(d, N.a-val(d, N.a-num(d, 3))),
    N.a-lettable(d, N.a-val(d, N.a-num(d, 4))))
  false4.visit(remove-useless-if-visitor) is N.a-val(d, N.a-num(d, 4))

  N.a-if(d, N.a-id(d, A.s-name(d, "x")), N.a-lettable(d, true1), N.a-lettable(d, false4)
    ).visit(remove-useless-if-visitor)
    is N.a-if(d, N.a-id(d, A.s-name(d, "x")),
    N.a-lettable(d, N.a-val(d, N.a-num(d, 1))),
    N.a-lettable(d, N.a-val(d, N.a-num(d, 4))))

end

fun mk-abbrevs(l):
  loc = const-id("loc")
  name = const-id("name")
  [clist:
    j-var(const-id("G"), rt-field("getFieldLoc")),
    j-var(const-id("U"), j-fun([clist: loc, name],
        j-block1(j-expr(j-method(rt-field("ffi"), "throwUninitializedIdMkLoc",
            [clist: j-id(loc), j-id(name)]))))),
    j-var(const-id("M"), j-str(l.source)),
    j-var(const-id("D"), rt-field("undefined"))
  ]
end

fun import-key(i): AU.import-to-dep-anf(i).key() end

fun compile-type-variant(variant):
  # TODO -- support with-members
  cases(T.TypeVariant) variant:
    | t-variant(name, members, with-members) =>
      j-list(true, [clist: j-str(name),
          j-list(false, for CL.map_list(mem from members):
              cases(T.TypeMember) mem:
                | t-member(mem-name, typ) =>
                  if T.is-t-ref(typ):
                    j-list(true, [clist: j-str("ref"), j-str(mem-name), compile-provided-type(typ.typ)])
                  else:
                    j-list(true, [clist: j-str(mem-name), compile-provided-type(typ)])
                  end
              end
            end)])
    | t-singleton-variant(name, with-members) =>
      j-list(true, [clist: j-str(name)])
  end
end

fun compile-type-member(member):
  cases(T.TypeMember) member:
    | t-member(name, typ) => j-field(name, compile-provided-type(typ))
  end
end

fun compile-provided-data(typ :: T.Type%(is-t-data), params):
  cases(T.Type) typ:
    | t-data(name, variants, members, l) =>
      j-list(false,
        [clist: j-str("data"), j-str(name),
          j-list(false, for CL.map_list(p from params):
              j-str(tostring(p))
            end),
          j-list(false, CL.map_list(compile-type-variant, variants)),
          j-obj(CL.map_list(compile-type-member, members))])
  end
end

fun compile-provided-type(typ):
  cases(T.Type) typ:
    | t-name(mod-name, id, l) =>
      cases(T.NameOrigin) mod-name:
        | local => j-obj([clist:
              j-field("tag", j-str("name")),
              j-field("origin", j-obj([clist: j-field("import-type", j-str("$ELF"))])),
              j-field("name", j-str(id.toname()))]) # TODO: toname or key?
        | module-uri(uri) =>
          j-obj([clist:
              j-field("tag", j-str("name")),
              j-field("origin", j-obj([clist: j-field("import-type", j-str("uri")), j-field("uri", j-str(uri))])),
              j-field("name", j-str(id.toname()))]) # TODO: toname or key?
        | dependency(dep) =>
          raise("Dependency-origin names in provided-types shouldn't be possible")
      end
    | t-var(name, l) => j-list(true, [clist: j-str("tid"), j-str(name.toname())])
    | t-arrow(args, ret, l) =>
      j-list(true,
        [clist: j-str("arrow"),
          j-list(true, CL.map_list(compile-provided-type, args)), compile-provided-type(ret)])
    | t-app(base, args, l) =>
      j-list(false,
        [clist: j-str("tyapp"), compile-provided-type(base),
          j-list(true, CL.map_list(compile-provided-type, args))])
    | t-top(_) => j-str("tany")
      # | t-bot(_) =>
    | t-record(fields, l) =>
      j-list(false,
        [clist: j-str("record"), j-obj(CL.map_list(compile-type-member, fields))])
    | t-forall(params, body, l) =>
      if T.is-t-data(body): compile-provided-data(body, params)
      else:
        j-list(true,
          [clist: j-str("forall"), CL.map_list(compile-provided-type, params), compile-provided-type(body)])
      end
      # | t-ref(_, _) =>
      # | t-existential(_, _) =>
    | t-data(_, _, _, _) => compile-provided-data(typ, empty)
      # | t-data-refinement(_, _, _) =>
    | else => j-ternary(j-false, j-str(tostring(typ)), j-str("tany"))
  end
end

fun compile-provides(provides):
  cases(CS.Provides) provides:
    | provides(thismod-uri, values, aliases, data-defs) =>
      value-fields = for CL.map_list(v from values.keys().to-list()):
        j-field(v, compile-provided-type(values.get-value(v)))
      end
      data-fields = for CL.map_list(d from data-defs.keys().to-list()):
        j-field(d, compile-provided-type(data-defs.get-value(d)))
      end
      alias-fields = for CL.map_list(a from aliases.keys().to-list()):
        j-field(a, compile-provided-type(aliases.get-value(a)))
      end
      j-obj([clist:
          j-field("values", j-obj(value-fields)),
          j-field("datatypes", j-obj(data-fields)),
          j-field("aliases", j-obj(alias-fields))
        ])
  end
end

fun compile-module(self, l, imports-in, prog, freevars, provides, env) block:
  js-names.reset()
  shadow freevars = freevars.unfreeze()
  fun inst(id): j-app(j-id(id), [clist: RUNTIME, NAMESPACE]) end
  imports = imports-in.sort-by(
      lam(i1, i2): import-key(i1.import-type) < import-key(i2.import-type)  end,
      lam(i1, i2): import-key(i1.import-type) == import-key(i2.import-type) end
    )

  for each(i from imports) block:
    freevars.remove-now(i.vals-name.key())
    freevars.remove-now(i.types-name.key())
  end

  import-keys = {vs: [mutable-string-dict:], ts: [mutable-string-dict:]}

  for each(i from imports) block:
    for each(v from i.values):
      import-keys.vs.set-now(v.key(), v)
    end
    for each(t from i.types):
      import-keys.ts.set-now(t.key(), t)
    end
  end

  free-ids = freevars.keys-list-now().map(freevars.get-value-now(_))
  module-and-global-binds = lists.partition(A.is-s-atom, free-ids)
  global-binds = for CL.map_list(n from module-and-global-binds.is-false):
    # NOTE(joe): below, we use the special case for globals for bootstrapping reasons,
    # because shared compiled files didn't agree on globals
    cases(A.Name) n:
      | s-global(s) =>
        dep = env.globals.values.get-value(n.toname())
        uri = cases(Option) env.mods.get(dep):
          | some(d) => d.from-uri
          | none => raise(dep + " not found in: " + torepr(env.mods))
        end
        j-var(js-id-of(n),
          rt-method("getField", [clist:
              rt-method("getField", [clist:
                  rt-method("getField", [clist:
                      j-bracket(j-dot(RUNTIME, "modules"), j-str(uri)),
                      j-str("provide-plus-types")
                    ]),
                  j-str("values")
                ]),
              j-str(n.toname())
            ]))
      | s-type-global(_) =>
        dep = env.globals.types.get-value(n.toname())
        uri = cases(Option) env.mods.get(dep):
          | some(d) => d.from-uri
          | none => raise(dep + " not found in: " + torepr(env.mods))
        end
        j-var(js-id-of(n),
          j-bracket(
              rt-method("getField", [clist:
                rt-method("getField", [clist:
                    j-bracket(j-dot(RUNTIME, "modules"), j-str(uri)),
                    j-str("provide-plus-types")
                  ]),
                j-str("types")]),
              j-str(n.toname())))
    end

#    j-var(js-id-of(n), j-method(NAMESPACE, "get", [clist: j-str(bind-name)]))
  end
  module-binds = for CL.map_list(n from module-and-global-binds.is-true):
    bind-name = cases(A.Name) n:
      | s-atom(_, _) =>
        if import-keys.vs.has-key-now(n.key()):
          n.toname()
        else if import-keys.ts.has-key-now(n.key()):
          type-name(n.toname())
        else:
          raise("Unaware of imported name: " + n.key())
        end
    end
    j-var(js-id-of(n), j-method(NAMESPACE, "get", [clist: j-str(bind-name)]))
  end
  fun clean-import-name(name):
    if A.is-s-atom(name) and (name.base == "$import"): fresh-id(name)
    else: js-id-of(name)
    end
  end
  ids = imports.map(lam(i): clean-import-name(i.vals-name) end)
  type-imports = imports.filter(N.is-a-import-complete)
  type-ids = type-imports.map(lam(i): clean-import-name(i.types-name) end)
  module-locators = imports.map(lam(i):
    cases(N.AImportType) i.import-type:
      | a-import-builtin(_, name) => CS.builtin(name)
      | a-import-special(_, typ, args) => CS.dependency(typ, args)
    end
  end)
  filenames = imports.map(lam(i):
      cases(N.AImportType) i.import-type:
        | a-import-builtin(_, name) => "trove/" + name
        | a-import-special(_, typ, args) =>
          if typ == "my-gdrive":
            "@my-gdrive/" + args.first
          else if typ == "shared-gdrive":
            "@shared-gdrive/" + args.first + "/" + args.rest.first
          else if typ == "js-http":
            "@js-http/" + args.first
          else if typ == "gdrive-js":
            "@gdrive-js/" + args.first + "/" + args.rest.first
          else:
            # NOTE(joe): under new module loading, this doesn't actually matter
            # NOTE(joe): yes it does, this is how we get a serialized rep of
            # the dependencies for the next time we need to check it
            CS.dependency(typ, args).key()
          end
      end
    end)
  # this needs to be freshened to support multiple repl interactions with the "same" source
  module-id = fresh-id(compiler-name(l.source)).tosourcestring()
  module-ref = lam(name): j-bracket(rt-field("modules"), j-str(name)) end
  input-ids = CL.map_list(lam(i):
      if A.is-s-atom(i) and (i.base == "$import"): js-names.make-atom("$$import")
      else: js-id-of(compiler-name(i.toname()))
      end
    end, ids)
  fun wrap-modules(modules, body-name, body-fun):
    mod-input-names = CL.map_list(_.input-id, modules)
    mod-input-ids = mod-input-names.map(j-id)
    mod-input-ids-list = mod-input-ids.to-list()
    mod-val-ids = modules.map(get-id)
    moduleVal = const-id("moduleVal")
    j-block(
      for lists.fold2(acc from cl-empty, m from mod-val-ids, in from mod-input-ids-list):
        if (in.id.base == "$$import"): acc
        else: acc ^ cl-snoc(_, j-var(m, rt-method("getField", [clist: in, j-str("values")])))
        end
      end +
      for lists.fold2(acc from cl-empty, mt from type-ids, in from mod-input-ids-list):
        if (in.id.base == "$$import"): acc
        else: acc ^ cl-snoc(_, j-var(mt, rt-method("getField", [clist: in, j-str("types")])))
        end
      end +
      for CL.map_list(m from modules):
        j-expr(j-assign(NAMESPACE.id, rt-method("addModuleToNamespace",
          [clist:
            NAMESPACE,
            j-list(false, CL.map_list(lam(i): j-str(i.toname()) end, m.imp.values)),
            j-list(false, CL.map_list(lam(i): j-str(i.toname()) end, m.imp.types)),
            j-id(m.input-id)])))
      end +
      module-binds +
      [clist:
        j-var(body-name, body-fun),
        j-return(rt-method(
            "safeCall", [clist:
              j-id(body-name),
              j-fun([clist: moduleVal],
                j-block([clist:
                    j-expr(j-bracket-assign(rt-field("modules"), j-str(module-id), j-id(moduleVal))),
                    j-return(j-id(moduleVal))
                  ])),
              j-str("Evaluating " + body-name.toname())
        ]))])
  end
  module-specs = for map3(i from imports, id from ids, in-id from input-ids.to-list()):
    { id: id, input-id: in-id, imp: i}
  end
  var locations = cl-empty
  var loc-count = 0
  var loc-cache = D.make-mutable-string-dict()
  LOCS = const-id("L")
  fun get-loc(shadow l :: Loc):
    as-str = l.key()
    if loc-cache.has-key-now(as-str) block:
      loc-cache.get-value-now(as-str)
    else:
      ans = j-bracket(j-id(LOCS), j-num(loc-count))
      loc-cache.set-now(as-str, ans)
      loc-count := loc-count + 1
      locations := cl-snoc(locations, obj-of-loc(l))
      ans
    end
  end

  fun wrap-new-module(module-body):
    module-locators-as-js = for CL.map_list(m from module-locators):
      cases(CS.Dependency) m:
        | builtin(name) =>
          j-obj([clist:
            j-field("import-type", j-str("builtin")),
            j-field("name", j-str(name))])
        | dependency(protocol, args) =>
          j-obj([clist:
            j-field("import-type", j-str("dependency")),
            j-field("protocol", j-str(protocol)),
            j-field("args", j-list(true, CL.map_list(j-str, args)))])
      end
    end
    # NOTE(joe): intentionally empty until we can generate the right
    # type information
    provides-obj = compile-provides(provides)
    the-module = j-fun([clist: RUNTIME.id, NAMESPACE.id, source-name.id] + input-ids, module-body)
    [D.string-dict:
      "requires", j-list(true, module-locators-as-js),
      "provides", provides-obj,
      "nativeRequires", j-list(true, [clist:]),
      "theModule", if self.options.collect-all: the-module else: J.j-raw-code(the-module.to-ugly-source()) end]
  end

  step = fresh-id(compiler-name("step"))
  toplevel-name = fresh-id(compiler-name("toplevel"))
  apploc = fresh-id(compiler-name("al"))
  resumer = compiler-name("resumer")
  resumer-bind = N.a-bind(l, resumer, A.a-blank)
  visited-body = compile-fun-body(l, step, toplevel-name,
    self.{get-loc: get-loc, cur-apploc: apploc, resumer: resumer}, # resumer gets js-id-of'ed in compile-fun-body
    [list: resumer-bind], none, prog, true)
  toplevel-fun = j-fun([clist: formal-shadow-name(resumer)], visited-body)
  define-locations = j-var(LOCS, j-list(true, locations))
  module-body = j-block(
#                    [clist: j-expr(j-str("use strict"))] +
                    mk-abbrevs(l) +
                    [clist: define-locations] +
                    global-binds +
                    [clist: wrap-modules(module-specs, toplevel-name, toplevel-fun)])
  wrap-new-module(module-body)
end

fun compile-program(self, l, imports-in, prog, freevars, env):
  raise("Use compile-module instead!  Pass the compile-module: true compiler option")
end

fun non-splitting-compiler(env, provides, options):
  compiler-visitor.{
    options: options,
    method a-program(self, l, _, imports, body):
      simplified = body.visit(remove-useless-if-visitor)
      freevars = N.freevars-e(simplified)
      if options.compile-module:
        compile-module(self, l, imports, simplified, freevars, provides, env)
      else:
        compile-program(self, l, imports, simplified, freevars, provides, env)
      end
    end
  }
end

splitting-compiler = non-splitting-compiler
