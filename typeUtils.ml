open Utility
open Types

module Env = Env.String

(** type destructors *)
exception TypeDestructionError of string

let error t = raise (TypeDestructionError t)

let rec unAlias = function
  | `Alias (_, t) -> unAlias t
  | t             -> t

let normalize = unAlias ->- concrete_type

let split_row name row =
  let (field_env, row_var) = fst (unwrap_row row) in
  let t =
    if StringMap.mem name field_env then
      match (StringMap.find name field_env) with
        | `Present t -> t
        | `Absent -> 
            error ("Attempt to split row "^string_of_row row ^" on absent field" ^ name)
    else
      error ("Attempt to split row "^string_of_row row ^" on absent field" ^ name)
  in
    t, (StringMap.remove name field_env, row_var)

let rec split_variant_type name t = match normalize t with
  | `ForAll (_, t) -> split_variant_type name t
  | `Variant row ->
      let t, row = split_row name row in
        `Variant (make_singleton_closed_row (name, `Present t)), `Variant row
  | t ->
      error ("Attempt to split non-variant type "^string_of_datatype t)

let rec project_type name t = match normalize t with
  | `ForAll (_, t) -> project_type name t
  | `Record row ->
      let t, _ = split_row name row in
        t
  | t -> 
      error ("Attempt to project non-record type "^string_of_datatype t)
    
let rec erase_type name t = match normalize t with
  | `ForAll (_, t) -> erase_type name t
  | `Record row ->
      let t, row = split_row name row in
        `Record row
  | t -> error ("Attempt to erase field from non-record type "^string_of_datatype t)

let rec return_type t = match normalize t with
  | `ForAll (_, t) -> return_type t
  | `Function (_, _, t) -> t
  | t -> 
      error ("Attempt to take return type of non-function: " ^ string_of_datatype t)

let rec arg_types t = match normalize t with
  | `ForAll (_, t) -> arg_types t
  | `Function (`Record row, _, _) ->
      extract_tuple row
  | t ->
      error ("Attempt to take arg types of non-function: " ^ string_of_datatype t)

let rec element_type t = match normalize t with
  | `ForAll (_, t) -> element_type t
  | `Application ("List", [t]) -> t
  | t ->
      error ("Attempt to take element type of non-list: " ^ string_of_datatype t)

let inject_type name t =
  `Variant (make_singleton_open_row (name, `Present t))

let abs_type _ = assert false
let app_type _ _ = assert false
