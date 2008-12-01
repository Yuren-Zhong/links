(*pp deriving *)
open Utility

module NormalForms =
struct
  (* 
     This module gives the datatype of normal forms for query
     expressions.

     Instead of using normal forms we use a single datatype t as it
     makes the implementation considerably simpler.
     
     At some point it might be interesting to try to target the normal
     form directly.
  *)

  type base =
      [ `If of base * base * base
      | `Project of (Var.var * StringSet.t) * string | `Erase of (Var.var * StringSet.t) * string
      | `Apply of string * base list
      | `Constant of Constant.constant ]

  type tail =
      [ `Where of base * tail
      | `SingletonRecord of base StringMap.t ]

  type generator = Var.var * Value.table
  type comprehension = generator list * base list * tail
  type query = comprehension list
end

type t =
    [ `For of (Var.var * t) list * t list * t
    | `If of t * t * t
    | `Table of Value.table
    | `Singleton of t | `Concat of t list
    | `Record of t StringMap.t | `Project of t * string | `Erase of t * string
    | `Variant of string * t
    | `Apply of string * t list
    | `Closure of (Ir.var list * Ir.computation) * env
    | `Primitive of string
    | `Var of (Var.var * StringSet.t) | `Constant of Constant.constant ]
and env = Value.env * t Env.Int.t


let labels_of_fields fields = StringMap.fold (fun name _ labels -> StringSet.add name labels) fields StringSet.empty
let table_labels (_, _, (fields, _)) = labels_of_fields fields
let rec labels_of_list =
  function
    | `Concat (v::vs) -> labels_of_list v
    | `Singleton (`Record fields) -> labels_of_fields fields
    | `Table (_, _, (fields, _)) -> labels_of_fields fields
    | _ -> assert false

(* Returns which database was used if any.

   Currently this assumes that at most one database is used.
*)
let used_database v : Value.database option =
  let rec generators =
    function
      | [] -> None
      | (_x, source)::gs ->
          begin
            match used source with
              | None -> generators gs
              | Some db -> Some db
          end
  and used =
    function
      | `For (gs, os, _body) -> generators gs
      | `Table ((db, _), _, _) -> Some db
      | _ -> None in
  let rec comprehensions =
    function
      | [] -> None
      | v::vs ->
          begin
            match used v with
              | None -> comprehensions vs
              | Some db -> Some db
          end
  in
    match v with
      | `Concat vs -> comprehensions vs
      | v -> used v

module S =
struct
  (* printable version of t *)
  type pt =
    [ `For of (Var.var * pt) list * pt list * pt
    | `If of pt * pt * pt
    | `Table of Value.table
    | `Singleton of pt | `Concat of pt list
    | `Record of pt StringMap.t | `Project of pt * string | `Erase of pt * string
    | `Variant of string * pt
    | `Apply of string * pt list
    | `Lam of Ir.var list * Ir.computation
    | `Primitive of string
    | `Var of (Var.var * StringSet.t) | `Constant of Constant.constant ]
      deriving (Show)

  let rec pt_of_t : t -> pt = fun v ->
    let bt = pt_of_t in
      match v with
        | `For (gs, os, b) -> `For (List.map (fun (x, source) -> (x, bt source)) gs, List.map bt os, bt b)
        | `If (c, t, e) -> `If (bt c, bt t, bt e)
        | `Table t -> `Table t
        | `Singleton v -> `Singleton (bt v)
        | `Concat vs -> `Concat (List.map bt vs)
        | `Record fields -> `Record (StringMap.map bt fields)
        | `Variant (name, v) -> `Variant (name, bt v)
        | `Project (v, name) -> `Project (bt v, name)
        | `Erase (v, name) -> `Erase (bt v, name)
        | `Apply (f, vs) -> `Apply (f, List.map bt vs)
        | `Closure ((xs, e), _) -> `Lam (xs, e)
        | `Primitive f -> `Primitive f
        | `Var v -> `Var v
        | `Constant c -> `Constant c
          
  let t = Show_pt.show -<- pt_of_t
end
let string_of_t = S.t

let rec tail_of_t : t -> t = fun v ->
  let tt = tail_of_t in
    match v with
      | `For (_gs, _os, `Singleton (`Record fields)) -> `Record fields
      | `For (_gs, _os, `If (c, t, `Concat [])) -> tt (`For (_gs, _os, t))
      | _ -> (* Debug.print ("v: "^string_of_t v); *) assert false

(* return the type of rows associated with a top-level non-empty expression *)
let rec type_of_expression : t -> Types.datatype = fun v ->
  let rec generators env : _ -> Types.datatype Env.Int.t =
    function
      | [] -> env
      | (x, `Table (_, _, row))::gs ->
          generators (Env.Int.bind env (x, `Record row)) gs
      | _ -> assert false in
  let rec base env : t -> Types.datatype =
    function
      | `Constant (`Bool b) -> Types.bool_type
      | `Constant (`Int i) -> Types.int_type
      | `Constant (`Char c) -> Types.char_type
      | `Constant (`Float f) -> Types.float_type
      | `Constant (`String s) -> Types.string_type
      | `Project (`Var (x, _), name) ->
          TypeUtils.project_type name (Env.Int.lookup env x)
      | `If (_, t, _) -> base env t
      | `Apply (f, _) -> TypeUtils.return_type (Env.String.lookup Lib.type_env f)
      | _ -> assert false in
  let record env fields : Types.datatype =
    Types.make_record_type (StringMap.map (base env) fields) in
  let rec tail env : t -> Types.datatype =
    function
      | `Singleton (`Record fields) -> record env fields
      | `If (_c, t, `Concat []) -> tail env t
      | `Table (_, _, row) -> `Record row
      | _ -> assert false
  in
    match v with
      | `Concat (v::vs) -> type_of_expression v
      | `For (gens, _os, body) -> tail (generators Env.Int.empty gens) body
      | _ -> tail Env.Int.empty v

let rec value_of_expression : t -> Value.t = fun v ->
  let ve = value_of_expression in
  let value_of_singleton = fun s ->
    match s with
      | `Singleton v -> ve v
      | _ -> assert false
  in
    match v with
      | `Constant (`Bool b) -> `Bool b
      | `Constant (`Int i) -> `Int i
      | `Constant (`Char c) -> `Char c
      | `Constant (`Float f) -> `Float f
      | `Constant (`String s) -> Value.box_string s
      | `Table t -> `Table t
      | `Concat vs -> `List (List.map value_of_singleton vs)
      | `Variant (name, v) -> `Variant (name, ve v)
      | `Record fields -> `Record (List.rev (StringMap.fold (fun name v fields -> (name, ve v)::fields) fields []))
      | _ -> assert false

module Eval =
struct
  exception DbEvaluationError of string

  let nil = `Concat []

  (* takes a normal form expression and returns true iff it has list type *)
  let is_list =
    function
      | `For _
      | `Table _
      | `Singleton _
      | `Concat _
      | `If (_, _, `Concat []) -> true
      | _ -> false    

  let eval_error fmt = 
    let error msg = raise (DbEvaluationError msg) in
      Printf.kprintf error fmt

  let env_of_value_env value_env = (value_env, Env.Int.empty)
  let (++) (venv, eenv) (venv', eenv') =
    Value.shadow venv ~by:venv', Env.Int.extend eenv eenv'  

  let rec expression_of_value : Value.t -> t =
    function
      | `Bool b -> `Constant (`Bool b)
      | `Int i -> `Constant (`Int i)
      | `Char c -> `Constant (`Char c)
      | `Float f -> `Constant (`Float f)
      | `Table t -> `Table t 
      | `List vs ->
          `Concat (List.map (fun v -> `Singleton (expression_of_value v)) vs)
      | `Record fields ->
          `Record
            (List.fold_left
               (fun fields (name, v) -> StringMap.add name (expression_of_value v) fields)
               StringMap.empty
               fields)
      | `Variant (name, v) -> `Variant (name, expression_of_value v)
      | `RecFunction ([(f, (xs, body))], env, f') ->
          assert (f=f');
          `Closure ((xs, body), env_of_value_env env)
      | `PrimitiveFunction f -> `Primitive f
          (*     | `XML of xmlitem  *)
          (*     | `NativeString of string ] *)
          (*     | `ClientFunction f ->  *)
          (*     | `Continuation cont ->  *)
      | _ -> failwith "Cannot convert value to expression"

  let bind (val_env, exp_env) (x, v) =
    (val_env, Env.Int.bind exp_env (x, v))

  let lookup (val_env, exp_env) var =
    match Value.lookup var val_env, Env.Int.find exp_env var with
      | None, Some v -> v
      | Some (`RecFunction ([(_, _)], _, f)), None when Env.String.lookup (val_of !Lib.prelude_nenv) "concatMap" = f ->
          `Primitive "ConcatMap"
      | Some (`RecFunction ([(_, _)], _, f)), None when Env.String.lookup (val_of !Lib.prelude_nenv) "map" = f ->
          `Primitive "Map"
      | Some (`RecFunction ([(_, _)], _, f)), None when Env.String.lookup (val_of !Lib.prelude_nenv) "sortBy" = f ->
          `Primitive "SortBy"
      | Some v, None -> expression_of_value v
      | None, None -> expression_of_value (Lib.primitive_stub (Lib.primitive_name var))
      | Some _, Some v -> v (*eval_error "Variable %d bound twice" var*)

  let lookup_lib_fun (val_env, _exp_env) var =
    match Value.lookup var val_env with
      | Some v -> expression_of_value v
      | None -> expression_of_value (Lib.primitive_stub (Lib.primitive_name var))

  let eta_expand_var (x, labels) =
    `Record
      (StringSet.fold
         (fun name fields ->
            StringMap.add name (`Project (`Var (x, labels), name)) fields)
         labels
         StringMap.empty)

  let eta_expand_list xs =
    let x = Var.fresh_raw_var () in
    let labels = labels_of_list xs in
      ([x, xs], [], `Singleton (eta_expand_var (x, labels)))        

  let rec value env : Ir.value -> t = function
    | `Constant c -> `Constant c
    | `Variable var ->
        begin
          match lookup env var with
            | `Var (x, labels) ->
                (* eta-expand record variables *)
                eta_expand_var (x, labels)
            | `Primitive "Nil" -> nil
            | v -> v
        end
    | `Extend (ext_fields, r) -> 
        begin
          match opt_app (value env) (`Record StringMap.empty) r with
            | `Record fields ->
                `Record (StringMap.fold 
                           (fun label v fields ->
                              if StringMap.mem label fields then 
                                eval_error
                                  "Error adding fields: label %s already present"
                                  label
                              else
                                StringMap.add label (value env v) fields)
                           ext_fields
                           fields)
            | _ -> eval_error "Error adding fields: non-record"
        end
    | `Project (label, r) ->
        let rec project (r, label) =
          match r with
            | `Record fields ->
                assert (StringMap.mem label fields);
                StringMap.find label fields
            | `If (c, t, e) ->
                `If (c, project (t, label), project (e, label))
            | `Var (x, labels) ->
                assert (StringSet.mem label labels);
                `Project (`Var (x, labels), label)
            | _ -> eval_error "Error projecting from record"
        in
          project (value env r, label)
    | `Erase (label, r) ->
        let rec erase (r, label) =
          match r with
            | `Record fields ->
                assert (StringMap.mem label fields);
                StringMap.find label fields
            | `If (c, t, e) ->
                `If (c, erase (t, label), erase (e, label))
            | `Var (x, labels) ->
                assert (StringSet.mem label labels);
                `Erase (`Var (x, labels), label)
            | _ -> eval_error "Error erasing from record"
        in
          erase (value env r, label)
    | `Inject (label, v, t) -> `Variant (label, value env v)
    | `TAbs (_, v) -> value env v
    | `TApp (v, _) -> value env v
        (*     | `XmlNode (tag, attrs, children) -> *)
        (*         let children = *)
        (*           List.fold_right *)
        (*             (fun v children -> *)
        (*                let v = value env v in *)
        (*                  List.map Value.unbox_xml (Value.unbox_list v) @ children) *)
        (*             children [] in *)
        (*         let children = *)
        (*           StringMap.fold  *)
        (*             (fun name v attrs -> *)
        (*                Value.Attr (name, Value.unbox_string (value env v)) :: attrs) *)
        (*             attrs children *)
        (*         in *)
        (*           Value.box_list [Value.box_xml (Value.Node (tag, children))] *)

    | `Inject _
    | `XmlNode _ -> assert false

    | `ApplyPure (f, ps) -> 
        apply env (value env f, List.map (value env) ps)
    | `Coerce (v, _) -> value env v
        (* TODO: replace comparisons with primitive functions *)
    | `Comparison _ -> assert false

  and apply env : t * t list -> t = function
    | `Closure ((xs, body), closure_env), args ->
(*         Debug.print ("closure: "^string_of_t (`Closure ((xs, body), closure_env))); *)
        let env = env ++ closure_env in
        let env = List.fold_right2 (fun x arg env -> bind env (x, arg)) xs args env in
          computation env body
    | `Primitive "asList", [xs] ->
        xs
    | `Primitive "Cons", [x; xs] ->
        reduce_concat env [`Singleton x; xs]
    | `Primitive "Concat", [xs; ys] ->
        reduce_concat env [xs; ys]
    | `Primitive "ConcatMap", [f; xs] ->
        begin
          match f with
            | `Closure (([x], body), closure_env) ->
                let env = env ++ closure_env in
                  reduce_for_source env computation (x, xs, body)
            | _ -> assert false
        end
    | `Primitive "Map", [f; xs] ->
        begin
          match f with
            | `Closure (([x], body), closure_env) ->
                let env = env ++ closure_env in
                  reduce_for_source env (fun env e -> `Singleton (computation env e)) (x, xs, body)
            | _ -> assert false
        end
    | `Primitive "SortBy", [f; xs] ->
        begin
          match xs with
            | `Concat [] -> `Concat []
            | _ ->
                let gs, os', body =
                  match xs with
                    | `For (gs, os', body) -> gs, os', body
                    | `Concat (_::_)
                    | `Singleton _
                    | `Table _ ->
                        (* eta-expand the list *)
                        eta_expand_list xs
                    | _ -> assert false in
                let xs = `For (gs, os', body) in
                  begin
                    match f with
                      | `Closure (([x], os), closure_env) ->                
                          let os =
                            let env = env ++ closure_env in
(*                               Debug.print ("xs: "^string_of_t xs); *)
                              let o = computation (bind env (x, tail_of_t xs)) os in
(*                                 Debug.print ("o: "^string_of_t o); *)
                                match o with
                                  | `Record fields ->
                                      List.rev (StringMap.fold (fun _ o os -> o::os) fields [])
                                  | _ -> assert false
                          in
                            `For (gs, os @ os', body)
                      | _ -> assert false
                  end
        end
    | `Primitive f, args ->
        `Apply (f, args)
    | `If (c, t, e), args ->
        reduce_if_condition env (c, apply env (t, args), apply env (e, args))
    | `Apply (f, args), args' ->
        `Apply (f, args @ args')
    | _ -> eval_error "Application of non-function"
  and computation env (binders, tailcomp) : t =
    match binders with
      | [] -> tail_computation env tailcomp
      | b::bs ->
          begin
            match b with
              | `Let (xb, (_, tc)) ->
                  let x = Var.var_of_binder xb in
                    computation (bind env (x, tail_computation env tc)) (bs, tailcomp)
              | `Fun ((f, _) as fb, (_, args, body), (`Client | `Native)) ->
                  eval_error "Client function"
              | `Fun ((f, _) as fb, (_, args, body), _) -> 
                  computation
                    (bind env (f, `Closure ((List.map fst args, body), env)))
                    (bs, tailcomp)
              | `Rec defs ->
                  eval_error "Recursive function"
              | `Alien _ 
              | `Alias _ -> (* just skip it *)
                  computation env (bs, tailcomp)
              | `Module _ -> failwith "Not implemented modules yet"
          end
  and tail_computation env : Ir.tail_computation -> t = function
    | `Return v -> value env v
    | `Apply (f, args) ->
        apply env (value env f, List.map (value env) args)
    | `Special s -> failwith "special not allowed in db block"
    | `Case (v, cases, default) ->
        assert false
          (*         (match value env v with *)
          (*            | `Variant (label, _) as v -> *)
          (*                (match StringMap.lookup label cases, default, v with *)
          (*                   | Some ((var,_), c), _, `Variant (_, v) *)
          (*                   | _, Some ((var,_), c), v -> *)
          (*                       computation (Value.bind var (v, `Local) env) cont c *)
          (*                   | None, _, #Value.t -> eval_error "Pattern matching failed" *)
          (*                   | _ -> assert false (\* v not a variant *\)) *)
          (*            | _ -> eval_error "Case of non-variant") *)
    | `If (c, t, e) ->
        let c = value env c in
        let t = computation env t in
        let e = computation env e in
          reduce_if_condition env (c, t, e)
            (*     | `Special (`For (x, source, body)) -> *)
            (*         reduce_for_source env computation (Var.var_of_binder x, value env source, body) *)
  and reduce_concat env vs =
    let vs =
      (concat_map
         (function
            | `Concat vs -> vs
            | v -> [v])
         vs)
    in
      match vs with
        | [`Singleton v] -> `Singleton v
        | vs -> `Concat vs
  and reduce_for_source env eval_body (x, source, body) =
    let rs = reduce_for_source env eval_body in
    let rb = reduce_for_body env in
      match source with
        | `Singleton v -> eval_body (bind env (x, v)) body
        | `Concat vs ->
            reduce_concat env (List.map (fun v -> rs (x, v, body)) vs)
        | `If (c, t, e) ->
            assert (e = nil);
            rb (x, t, reduce_if_condition env (c, eval_body env body, nil))
        | `For (gs, os, v) ->
            begin
              match rs (x, v, body) with
                | `For (gs', os', w) -> `For (gs @ gs', os @ os', w)
                | w -> `For (gs, os, w)
            end
        | `Table table ->
            let labels = table_labels table in
              rb (x, source, eval_body (bind env (x, `Var (x, labels))) body)
        | v -> eval_error "Bad source in for comprehension: %s" (string_of_t v)
  and reduce_for_body env (x, source, body) =
    match body with
      | `Concat vs ->
          reduce_concat env (List.map (fun v -> reduce_for_body env (x, source, v)) vs)
      | `For (gs, os, body) ->
          `For ((x, source)::gs, os, body)
      | _ ->
          `For ([x, source], [], body)
  and reduce_if_condition env (c, t, e) =
    (*     Debug.print ("if: "^string_of_t (`If (c, t, e))); *)
    match c with
      | `Constant (`Bool true) -> t
      | `Constant (`Bool false) -> e
      | c when is_list t ->
          (*           Debug.print "list if"; *)
          if e = nil then
            if t = nil then nil
            else
              reduce_if_then env (c, t, e)
          else
            reduce_concat env [reduce_if_condition env (c, t, nil); reduce_if_condition env (`Apply ("not", [c]), e, nil)]
      | `If (c', t', `Constant (`Bool false)) ->
          reduce_if_then env (`Apply ("&&", [c'; t']), t, e)
      | _ ->
          reduce_if_then env (c, t, e)
  and reduce_if_then env (c, t, e) =
    let rt = reduce_if_then env in
      match t with
        | `Concat vs ->
            reduce_concat env (List.map (fun v -> rt (c, v, e)) vs)
        | `For (gs, os, body) ->
            `For (gs, os, rt (c, body, e))
        | `Record then_fields ->
            begin
              match e with
                | `Record else_fields ->
                    assert (StringMap.equal (fun _ _ -> true) then_fields else_fields);
                    `Record
                      (StringMap.fold
                         (fun name t fields ->
                            let e = StringMap.find name else_fields in
                              StringMap.add name (rt (c, t, e)) fields)
                         then_fields
                         StringMap.empty)
                | _ -> eval_error "Mismatched fields"
            end
        | _ ->
            begin
              match e with
                | `Constant (`Bool false) ->
                    `Apply ("&&", [c; t])
                | _ ->
                    `If (c, t, e)
            end


  let eval env e =
(*    Debug.print ("e: "^Ir.Show_computation.show e);*)
    computation (env_of_value_env env) e
end


module Sql =
struct
  type query =
      [ `UnionAll of query list
      | `Select of (base * string) list * (string * Var.var) list * base * base list ]
  and base =
      [ `Case of (base * base * base)
      | `Constant of Constant.constant
      | `Project of Var.var * string
      | `Apply of string * base list ]          
  deriving (Show)

  (* Table variables that are actually used are always bound in a for
     comprehension. In this case the IR variable from the for
     comprehension is used to generate the table variable.
     
     e.g. if the IR variable 1485 then the table variable is t1485
  *)
  let fresh_table_var : unit -> Var.var = Var.fresh_raw_var
  let string_of_table_var var = "t" ^ string_of_int var

  (* Because of limitations of SQL we sometimes need to generate dummy
     table variables. These have the prefix "dummy" and have their own
     name source. *)
  let dummy_counter = ref 0
  let fresh_dummy_var () =
    incr dummy_counter;     
    "dummy" ^ string_of_int (!dummy_counter)

  let string_of_label label =
    if Str.string_match (Str.regexp "[0-9]+") label 0 then
      "'" ^ label ^ "'"
    else
      label

  let rec string_of_query q =
    let sq = string_of_query in
    let sb = string_of_base in
      match q with
        | `UnionAll [] -> assert false
        | `UnionAll [q] -> sq q
        | `UnionAll qs ->
            mapstrcat " union all " (fun q -> "(" ^ sq q ^ ")") qs
        | `Select (fields, [], `Constant (`Bool true), _os) ->
            let fields = mapstrcat "," (fun (b, l) -> "(" ^ sb b ^ ") as "^string_of_label l) fields in
              "select " ^ fields
        | `Select (fields, [], condition, _os) ->
            let fields = mapstrcat "," (fun (b, l) -> "(" ^ sb b ^ ") as "^string_of_label l) fields in
              "select * from (select " ^ fields ^ ") as " ^ fresh_dummy_var () ^ " where " ^ sb condition
        | `Select (fields, tables, condition, os) ->
            let tables = mapstrcat "," (fun (t, x) -> t ^ " as " ^ (string_of_table_var x)) tables in
            let fields = mapstrcat "," (fun (b, l) -> "(" ^ sb b ^ ") as "^string_of_label l) fields in
            let orderby =
              match os with
                | [] -> ""
                | _ -> " order by " ^ mapstrcat "," sb os in
            let where =
              match condition with
                | `Constant (`Bool true) -> ""
                | _ ->  " where " ^ sb condition
            in
              "select " ^ fields ^ " from " ^ tables ^ where ^ orderby
  and string_of_base b =
    let sb = string_of_base in
      match b with
        | `Case (c, t, e) ->
            "case when " ^ sb c ^ " then " ^sb t ^ " else "^ sb e ^ " end"
        | `Constant c -> Constant.string_of_constant c
        | `Project (var, label) ->
            string_of_table_var var ^ "." ^ label
        | `Apply (("intToString" | "stringToInt" | "intToFloat" | "floatToInt" | "floatToString" | "stringToFloat"), [v]) -> sb v
        | `Apply ("not", [v]) -> "not (" ^ sb v ^ ")"
        | `Apply ("&&", [v; w]) -> "(" ^ sb v ^ ")" ^ " and " ^ "(" ^ sb w ^ ")"
        | `Apply ("||", [v; w]) -> "(" ^ sb v ^ ")" ^ " or " ^ "(" ^ sb w ^ ")"
        | `Apply ("+", [v; w]) -> "(" ^ sb v ^ ")" ^ " + " ^ "(" ^ sb w ^ ")"
        | `Apply (">", [v; w]) -> "(" ^ sb v ^ ")" ^ " > " ^ "(" ^ sb w ^ ")"
        | `Apply ("==", [v; w]) -> "(" ^ sb v ^ ")" ^ " = " ^ "(" ^ sb w ^ ")"
        | `Apply ("<=", [v; w]) -> "(" ^ sb v ^ ")" ^ " <= " ^ "(" ^ sb w ^ ")"
        | `Apply ("tilde", [v; w]) -> "(" ^ sb v ^ ")" ^ " RLIKE " ^ "(" ^ sb w ^ ")"

  let string_of_query range q =
    let range =
      match range with
        | None -> ""
        | Some (limit, offset) -> " limit " ^Num.string_of_num limit^" offset "^Num.string_of_num offset
    in
      string_of_query q ^ range

  let rec prepare_clauses : t -> t list =
    function
      | `Concat vs -> vs
      | v -> [v]

  let rec query : t -> query = fun v ->
(*    Debug.print ("query: "^string_of_t v);*)
    match v with
      | `Concat _ -> assert false
      | `For ([], _, body) ->
          query body
      | `For ((x, `Table (_db, table, _row))::gs, os, body) ->
          let body = query (`For (gs, [], body)) in
          let os = List.map base os in
            begin
              match body with
                | `Select (fields, tables, condition, []) ->
                    `Select (fields, (table, x)::tables, condition, os)
                | _ -> assert false
            end
      | `If (c, body, `Concat []) ->
          let c = base c in
(*            Debug.print ("c: "^Show_base.show c);*)
          let body = query body in
(*            Debug.print ("body: "^Show_query.show body);*)
            begin
              match body with
                | `Select (fields, tables, c', os) ->
                    let c =
                      match c, c' with
                        | `Constant (`Bool true), c
                        | c, `Constant (`Bool true) -> c
                        | `Constant (`Bool false), _
                        | _, `Constant (`Bool false) -> `Constant (`Bool false)
                        | c, c' -> `Apply ("&&", [c; c'])
                    in
                      `Select (fields, tables, c, os)
                | _ -> assert false
            end
      | `Table (_db, table, (fields, _)) ->
          let var = fresh_table_var () in
          let fields =
            List.rev
              (StringMap.fold
                 (fun name _ fields ->
                    (`Project (var, name), name)::fields)
                 fields
                 [])
          in
            `Select (fields, [(table, var)], `Constant (`Bool true), [])
      | `Singleton (`Record fields) ->
          let fields =
            List.rev
              (StringMap.fold
                 (fun name v fields ->
                    (base v, name)::fields)
                 fields
                 [])
          in
            `Select (fields, [], `Constant (`Bool true), [])
      | _ -> assert false
  and base : t -> base =
    function
      | `If (c, t, e) ->
          `Case (base c, base t, base e)
      | `Apply ("tilde", [s; r]) ->
          let r =
            (* HACK:

               this only works if the regexp doesn't include any variables bound by the query
            *)
            `Constant (`String (Regex.string_of_regex (Linksregex.Regex.ofLinks (value_of_expression r))))
          in
            `Apply ("tilde", [base s; r])
      | `Apply (f, vs) ->
          `Apply (f, List.map base vs)
      | `Project (`Var (x, _labels), name) ->
          `Project (x, name)
      | `Constant c -> `Constant c
      | `Concat cs ->
          (* HACK: assume it's a string *)
          `Constant
            (`String
               (Value.unbox_string
                  (`List
                     (List.map (function
                                  | `Singleton (`Constant (`Char c)) -> `Char c
                                  | _ -> assert false) cs))))
      | _ -> assert false

  let query range v =
(*     Debug.print ("v: "^string_of_t v); *)
    dummy_counter := 0;
    let q = `UnionAll (List.map query (prepare_clauses v)) in
      string_of_query range q
end

let compile : Value.env -> (Num.num * Num.num) option * Ir.computation -> (Value.database * string * Types.datatype) option =
  fun env (range, e) ->
(*     Debug.print ("e: "^Ir.Show_computation.show e); *)
    let v = Eval.eval env e in
      match used_database v with
        | None -> None
        | Some db -> 
            let t = type_of_expression v in
            let q = Sql.query range v in
              Debug.print ("Generated query: "^q);
              Some (db, q, t)