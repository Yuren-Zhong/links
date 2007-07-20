(*pp deriving *)
(**** Various utility functions ****)

let fst3(x, _, _) = x
let snd3(_, y, _) = y
let thd3(_, _, z) = z

(** {1 Functional combinators} *)
module Functional =
struct
  
  (** "compose" operators (arrow indicates direction of composition) *)
  let (-<-) f g x = f (g x)
  let (->-) f g x = g (f x)
    
  let curry f a b = f (a, b)
  let uncurry f (a, b) = f a b
  let identity x = x
  let flip f x y = f y x
  let const x _ = x
    
  let cross f g = fun (x, y) -> f x, g y
end    
include Functional

(* Maps and sets *)
module type OrderedShow = sig
  type t
  val compare : t -> t -> int
  module Show_t : Show.Show 
    with type a = t
end

exception NotFound of string

module type Map = 
sig
  include Map.S
  exception Not_disjoint of key * string

  val singleton : key -> 'a -> 'a t 
  (** create a singleton map *)

  val filter : ('a -> bool) -> 'a t -> 'a t
  (** filter by value *)

  val filteri : (key -> 'a -> bool) -> 'a t -> 'a t
  (** filter by key and value *)

  val for_all : ('a -> bool) -> 'a t -> bool
  (** return true if p holds for all values in the range of m *)

  val size : 'a t -> int
  (** the number of distinct keys in the map *)

  val to_alist : 'a t -> (key * 'a) list
  (** convert the map to an association list *)

  val from_alist : (key * 'a) list -> 'a t
  (** construct a map from an association list *)

  val to_list : (key -> 'a -> 'b) -> 'a t -> 'b list
  (** construct a new map from two existing maps *)

  val pop : key -> 'a t -> ('a * 'a t)
  (** remove the item with the given key from the map and return the remainder. *)

  val lookup : key -> 'a t -> 'a option
  (** as `find', but return an option instead of raising an exception *)

  val union_disjoint : 'a t -> 'a t -> 'a t
  (** disjoint union *)

  val superimpose : 'a t -> 'a t -> 'a t
  (** Extend the second map with the first *)

  val partition : (key -> 'a -> bool) -> 'a t -> ('a t * 'a t)
  (** divide the map by a predicate *)

  module Show_t (V : Show.Show) :
    Show.Show with type a = V.a t

  module Functor_t : 
    Functor.Functor with type 'a f = 'a t
end

module String = struct
  include String
  module Show_t = Primitives.Show_string
end

module Int = struct
  type t = int
  let compare = Pervasives.compare
  module Show_t = Primitives.Show_int
end

module Map :
sig
  module type OrderedType = OrderedShow
  module type S = Map
  module Make (Ord : OrderedType) : S with type key = Ord.t
end = 
struct
  module type OrderedType = OrderedShow
  module type S = Map
  module Make (Ord : OrderedType) = struct
    include Map.Make(Ord)

    let singleton i v =
      add i v empty

    let filter f map =
      fold (fun name v map ->
              if f v then add name v map
              else map) map empty

    let filteri f map =
      fold (fun name v map ->
              if f name v then add name v map
              else map) map empty

    let find elem map = 
      try find elem map 
      with Not_found -> raise (NotFound (Ord.Show_t.show elem))
      
    let for_all p m =
      fold (fun _ v b -> b && p v) m true
        
    let size m =
      fold (fun _ _ n -> n+1) m 0
        
    let to_alist map =
      List.rev (fold (fun x y l -> (x, y) :: l) map [])
        
    let to_list f map =
      List.rev (fold (fun x y l -> (f x y) :: l) map [])
        
    let from_alist l =
      List.fold_right (uncurry add) l empty 
        
    let pop item map = 
      (find item map, remove item map)
        
    let lookup item map =
      try Some (find item map) 
      with NotFound _ -> None
        
    exception Not_disjoint of key * string
      
    let union_disjoint a b = 
      fold
        (fun k v r -> 
           if (mem k r) then raise (Not_disjoint (k, Ord.Show_t.show k)) 
           else
             add k v r) b a

    let superimpose a b = fold add b a

    let partition f m =
      fold
        (fun i v (p, q) ->
           if (f i v) then
             add i v p, q
           else
             p, add i v q)
        m (empty, empty)

    module Show_t (V : Show.Show) = Show.Show_map(Ord)(Ord.Show_t)(V)

    module Functor_t =
    struct
      type 'a f = 'a t
      let map = map
    end
  end
end

module type Set =
sig
  include Set.S
  
  val union_all : t list -> t
  (** Take the union of a collection of sets *)

  val from_list : elt list -> t
  (** Construct a set from a list *)

  module Show_t : Show.Show
    with type a = t
end

module Set :
sig
  module type OrderedType = OrderedShow
  module type S = Set
  module Make (Ord : OrderedType) : S with type elt = Ord.t
end =
struct
  module type OrderedType = OrderedShow
  module type S = Set
  module Make (Ord : OrderedType) = struct
    include Set.Make(Ord)
    let union_all sets = List.fold_right union sets empty
    let from_list l = List.fold_right add l empty
    module Show_t = Show.Show_set(Ord)(Ord.Show_t)
  end
end

module type INTSET = Set with type elt = int
module IntSet : INTSET = Set.Make(Int)
module IntMap = Map.Make(Int)

module type STRINGMAP = Map with type key = string
module StringSet = Set.Make(String)
module StringMap : STRINGMAP = Map.Make(String)

type 'a stringmap = 'a StringMap.t
    deriving (Show)

module Typeable_stringmap (A : Typeable.Typeable) : Typeable.Typeable with type a = A.a stringmap = 
Typeable.Typeable_defaults(struct
  type a = A.a stringmap
  let typeRep = 
    let t = Typeable.TypeRep (Typeable.Tag.fresh(), [A.typeRep()])
    in fun _ -> t
end)
module Pickle_stringmap (A : Pickle.Pickle) = Pickle.Pickle_unpicklable (struct type a = A.a stringmap let tname ="stringmap"  end)
module Functor_stringmap = StringMap.Functor_t
module Eq_stringmap (E : Eq.Eq) = Eq.Eq_map_s_t (E)(StringMap)
module Shelve_stringmap (S : Shelve.Shelve) = 
struct
  module Typeable = Typeable_stringmap(S.Typeable)
  module Eq = Eq_stringmap(S.Eq)
  type a = S.a stringmap
  let shelve  _ = failwith "shelve stringmap nyi"
end


(** {1 Lists} *)
module ListUtils = 
struct
  let fromTo f t = 
    let rec aux f t result = 
      if f = t then result
      else aux (f+1) t (f::result)
    in if t < f then raise (Invalid_argument "fromTo")
      else List.rev (aux f t [])

  (** [all_equiv rel list]: given an equiv. rel'n [rel], determine
      whether all elements of [list] are equivalent. *)
  let all_equiv (cmp : 'a -> 'a -> bool) : 'a list -> bool = function
      [] -> true
    | (one::others) ->
        List.for_all (fun x -> cmp one x) others
          
  (** [span pred list]: partition [list] into an initial sublist
      satisfying [pred] and the remainder.  *)
  let span (p : 'a -> bool) : 'a list -> ('a list * 'a list) =
    let rec span = function
      | x::xs' when p x -> let ys, zs = span xs' in x::ys, zs
      | xs              -> [], xs in
      span
        
  (** [groupBy rel list]: given a binary rel'n [rel], partition [list]
      into chunks s.t. successive elements [x], [y] in a chunk give the
      same value under [rel]. *)
  let groupBy eq : 'a list -> 'a list list = 
    let rec group = function
      | [] -> []
      | x::xs -> (let ys, zs = span (eq x) xs in 
                    (x::ys)::group zs) 
    in group

  (** [groupByPred pred] partitions [list] into chunks where all
      elements in the chunk give the same value under [pred]. *)
  let groupByPred pred list = 
  let rec group state result = function
    | [] -> List.rev (List.map List.rev result)
    | x::etc -> let predx = pred x in
      let new_result = (if (predx = state) then
                            (x::List.hd result) :: List.tl result
                        else
                            [x] :: result)
      in
        group predx new_result etc
  in if (list == []) then [] else  group (pred (List.hd list)) [] list
      
  (** [groupByPred']: Alternate implementation of groupByPred. *)
  let groupByPred' pred : 'a list -> 'a list list = 
    let rec group = function
      | [] -> []
      | x::xs -> 
          let predx = pred x in
            (let ys, zs = span (fun y -> pred y = predx) xs in 
               (x::ys)::group zs) 
    in group
      
  (** [unsnoc list]: Partition [list] into its last element and all the
      others. @return (others, lastElem) *)
  let rec unsnoc = 
    function
      |  [x] -> [], x
      | (x::xs) -> let ys, y = unsnoc xs in x :: ys, y
      | []   -> raise (Invalid_argument "unsnoc")
          
  (** [last list]: Return the last element of a list *)
  let last l = 
    try 
      snd (unsnoc l)
    with Invalid_argument _ -> invalid_arg "last"
    
  (** [butlast list]: Return a copy of the list with the last element removed. *)
  let butlast l = 
    try
      fst (unsnoc l)
    with Invalid_argument _ -> invalid_arg "butlast"

  let difference list1 list2 = 
    List.filter (fun x -> not (List.mem x list2)) list1

  let remove_all list1 list2 = difference list2 list1

  let subset list1 list2 : bool= 
    List.for_all (fun x -> List.mem x list2) list1

  (** Convert a (bivalent) less-than function into a (three-valued)
      comparison function. *)
  let less_to_cmp less l r = 
    if less r l then 1
    else if less l r then -1
    else 0
      
  (** Remove duplicates from a list, using the given relation to
      determine `duplicates' *)
  let rec unduplicate equal = function
    | [] -> []
    | elem :: elems -> (let _, others = List.partition (equal elem) elems in
                          elem :: unduplicate equal others)
        
  let rec ordered_consecutive = function
    | [] -> true
    | [_] -> true
    | one :: (two :: _ as rest) -> one + 1 = two && ordered_consecutive rest
    
  let rec drop n = if n = 0 then identity else function
    | []     -> []
    | _ :: t -> drop (n - 1) t
        
  let rec take n list = match n, list with 
    | 0, _ -> []
    | _, [] -> []
    | _, h :: t -> h :: take (n - 1) t
        
  let remove x = List.filter ((<>)x)

  let concat_map f l = 
    let rec aux = function
      | _, [] -> []
      | f, x :: xs -> f x @ aux (f, xs)
    in aux (f,l)
      
  let concat_map_uniq f l = unduplicate (=) (concat_map f l)
    
  let concat_map_undup cmp f l = unduplicate cmp (concat_map f l)
    
  let for_each l f = List.iter f l

  let push_back f list = list := !list @ [f]
  let push_front f list = list := f :: !list
end
include ListUtils
  
(** {1 Association-list utilities} *)
module AList = 
struct
  let rec rassoc_eq eq : 'b -> ('a * 'b) list -> 'a = fun value ->
    function
      | (k, v) :: _ when eq v value -> k
      | _ :: rest -> rassoc_eq eq value rest
      | [] -> raise Not_found
          
  let rassoc i l = rassoc_eq (=) i l
  and rassq i l = rassoc_eq (==) i l
    
  let rec rremove_assoc_eq eq : 'b -> ('a * 'b) list -> ('a * 'b) list = 
    fun value ->
      function
        | (_, v) :: rest when eq v value -> rest
        | other :: rest -> other :: rremove_assoc_eq eq value rest
        | [] -> []
          
  let rremove_assoc i l = rremove_assoc_eq (=) i l
  and rremove_assq i l = rremove_assoc_eq (==) i l

  let remove_keys alist keys =
    List.filter (fun (x,_) -> not (List.mem x keys)) alist
    
  (** alistmap maps f on the contents-parts of the entries, producing a
      new alist *)
  let alistmap f = List.map (cross identity f)

  let alistmapstrcat glue f = 
    (List.map (fun (k, v) -> k ^ " => " ^ f v))
    ->- (String.concat glue) 
    
  (** alistmap' produces an alist by applying f to each element of the
      alist--f should produce a new contents-part for the entry. *)
  let alistmap' f = List.map (fun (x, y) -> (x, f(x, y)))
    
  (** [[map2alist f list]]
      makes an alist that maps [[x]] to [[f x]] for each item in [[list]].
      In category theory this is called the `graph' of f (restricted by [list]).
  *)
  let map2alist f list = List.map (fun x -> (x, f x)) list
  let graph_func = map2alist

  let rng alist = List.map snd alist
  let dom alist = List.map fst alist

end
include AList

(** {1 Strings} *)
module StringUtils = 
struct
  let string_of_char = String.make 1
    
  let string_of_alist = String.concat ", " -<- List.map (fun (x,y) -> x ^ " => " ^ y)
    
  let rec split_string source delim =
    if String.contains source delim then
      let delim_index = String.index source delim in
        (String.sub source 0 delim_index) :: 
          (split_string (String.sub source (delim_index+1) 
                           ((String.length source) - delim_index - 1)) delim)
    else source :: []
      
  let explode : string -> char list = 
    let rec explode' list n string = 
      if n = String.length string then list
      else explode' (string.[n] :: list) (n + 1) string
    in List.rev -<- (explode' [] 0)
      
  let implode : char list -> string = 
    (String.concat "") -<- (List.map (String.make 1))

  let contains p = explode ->- List.exists p
      
  (* Find all occurrences of a character within a string *)
  let find_char (s : string) (c : char) : int list =
    let rec aux offset occurrences = 
      try let index = String.index_from s offset c in
            aux (index + 1) (index :: occurrences)
      with Not_found -> occurrences
    in List.rev (aux 0 [])
      
  let mapstrcat glue f list = String.concat glue (List.map f list)

  let start_of ~is s =
    Str.string_match (Str.regexp_string is) s 0 

  let end_of ~is s = 
    let ilen = String.length is
    and slen = String.length s in
      if ilen > slen then false 
      else
        try ignore (Str.search_forward (Str.regexp_string is) s (slen - ilen));
          true
        with Not_found -> 
          false
end
include StringUtils

(** Given a list-of-lists, [groupingsToString] concatenates them using
    [", "] as the delimiter between elements and ["; "] as the delimiter
    between lists. *)
let groupingsToString : ('a -> string) -> 'a list list -> string =
  fun f -> 
    mapstrcat "; " (mapstrcat ", " f)

let numberp s = try ignore (int_of_string s); true with _ -> false

let lines (channel : in_channel) : string list = 
  let input () = 
    try Some (input_line channel)
    with End_of_file -> None
  in
  let rec next_line lines =
    match input () with 
      | Some s -> next_line (s :: lines)
      | None -> lines
  in List.rev (next_line [])

let call_with_open_infile,
  call_with_open_outfile = 
  let call opener closer filename f = 
    let fd = opener filename in
      try
        let rv = f fd in
          closer fd;
          rv
      with x -> 
        closer fd;
        raise x
  in ((fun x ?(binary=false) -> call (if binary then open_in_bin else open_in) close_in x),
      (fun x ?(binary=false) -> call (if binary then open_out_bin else open_out) close_out x))

let process_output : string -> string
  = String.concat "\n" -<- lines -<- Unix.open_process_in

(** [lookup_in alist] is a function that looks up its argument in [alist] *)
let lookup_in alist x = List.assoc x alist

(** lookup is like assoc but uses option types instead of
   exceptions to signal absence *)
let lookup k alist = try Some (List.assoc k alist) with Not_found -> None

let mem_assoc3 key : ('a * 'b * 'c) list -> bool = 
  List.exists (fun (x,_,_) -> x = key)

(*** either type ***)
type ('a, 'b) either = Left of 'a | Right of 'b
  deriving (Show, Eq, Typeable, Pickle, Shelve)

let inLeft l = Left l
let inRight r = Right r
let fromLeft = function
  | Left l -> l
  | _ -> assert false
let fromRight = function
  | Right  r -> r
  | _ -> assert false

let either_partition (f : 'a -> ('b, 'c) either) (l : 'a list)
    : 'b list * 'c list =
  let rec aux (lefts, rights) = function
    | [] -> (List.rev lefts, List.rev rights)
    | x::xs ->
        match f x with 
          | Left l  -> aux (l :: lefts, rights) xs
          | Right r -> aux (lefts, r :: rights) xs
  in aux ([], []) l


module EitherMonad = Monad.MonadPlusUtils(
  struct
    type 'a m = (string, 'a) either
    let return v = Right v
    let (>>=) m k = match m with
      | Left _ as l -> l
      | Right r     -> k r
    let fail msg = Left msg
    let (>>) x y = x >>= fun _ -> y
    let mzero = Left "no error"
    let mplus l r = match l with 
      | Left _ -> r
      | m      -> m
  end)

    
module OptionUtils = 
struct
  exception EmptyOption
  let valOf = function
    | Some x -> x
    | None -> raise EmptyOption
        
  let isSome = function
    | None -> false
    | Some _ -> true
        
  let opt_app f default = function
    | None -> default
    | Some a -> f a

  let opt_map f = function
    | None -> None
    | Some x -> Some (f x)

  let fromOption default = function
    | None -> default
    | Some x -> x

  let perhaps_apply f p =
    match f p with
      | None -> p
      | Some x -> x  
(*
  [NOTE][SL]
  
  The following equations hold

            opt_map f = opt_app (fun x -> Some (f x)) None
           fromOption = opt_app (fun x -> x)
    perhaps_apply f p = fromOption p (f p)
                      = opt_app (fun x -> x) p (f p)

  I've left the explicit definitions because they are more perspicuous
  than the derived versions and hardly verbose.
*)

  let opt_sequence e =  (* sequence *)
    let rec aux accum = function
      | []             -> Some (List.rev accum)
      | Some x :: rest -> aux (x::accum) rest
      | None :: _      -> None
    in aux [] e
end
include OptionUtils

module Char = 
struct
  include Char
  let isAlpha = function 'a'..'z' | 'A'..'Z' -> true | _ -> false
  let isAlnum = function 'a'..'z' | 'A'..'Z' | '0'..'9' -> true | _ -> false
  let isLower = function 'a'..'z' -> true | _ -> false
  let isUpper = function 'A'..'Z' -> true | _ -> false
  let isDigit = function '0'..'9' -> true | _ -> false
  let isXDigit = function '0'..'9'|'a'..'f'|'A'..'F' -> true | _ -> false
  let isBlank = function ' '|'\t' -> true | _ -> false
end

(*** character encoding ***)

(* Read a three-digit octal escape sequence and return the
   corresponding char *)
let read_octal c =
  let octal_char = function
    | '0' -> 0 | '1' -> 1 | '2' -> 2 | '3' -> 3
    | '4' -> 4 | '5' -> 5 | '6' -> 6 | '7' -> 7 | _ -> invalid_arg "read_octal"
  in Char.chr ((octal_char c.[0]) * 64 + (octal_char c.[1]) * 8 + (octal_char c.[2]))

let read_hex c =
  let hex_char = function
    | '0' -> 0 | '1' -> 1 | '2' -> 2 | '3' -> 3 | '4' -> 4
    | '5' -> 5 | '6' -> 6 | '7' -> 7 | '8' -> 8 | '9' -> 9
    | 'a' | 'A' -> 10
    | 'b' | 'B' -> 11
    | 'c' | 'C' -> 12
    | 'd' | 'D' -> 13
    | 'e' | 'E' -> 14
    | 'f' | 'F' -> 15 | _ -> invalid_arg "read_hex"
  in Char.chr ((hex_char c.[0]) * 16 + (hex_char c.[1]))

(* Handle escape sequences in string literals.

   I would describe them here but the O'Caml lexer gets too confused,
   even though they're in a comment.

   This is here rather than in sl_lexer.mll because the ocamllex gets
   confused by all the backslashes and quotes and refuses to translate
   the file.
*)
let escape_regexp = Str.regexp "\\\\n\\|\\\\r\\|\\\\t\\|\\\\\"\\|\\\\\\\\\\|\\\\[0-3][0-7][0-7]\\|\\\\[xX][0-9a-fA-F][0-9a-fA-F]" 
let decode_escapes s =
  let unquoter s = 
    (* Yes, the Str interface is stateful.  A pretty poor show.  PCRE
       is better, but we'd rather avoid the dependency and stick with
       the standard library. *)
    let s = Str.matched_string s in
      match s with
        | "\\\"" -> "\""
        | "\\\\" -> "\\"
        | "\\n" -> "\n"
        | "\\r" -> "\r"
        | "\\t" -> "\t"
        | other when other.[1] = 'x' || other.[1] = 'X' -> String.make 1 (read_hex (String.sub other 2 2)) 
        | other -> String.make 1 (read_octal (String.sub other 1 3)) in
    Str.global_substitute escape_regexp unquoter s

(** xml_escape
    xml_unescape
    Escape/unescape for XML escape sequences (e.g. &amp;)
*)
let xml_escape s = 
  Str.global_replace (Str.regexp "<") "&lt;" 
    (Str.global_replace (Str.regexp "&") "&amp;" s)

let xml_unescape s =
  Str.global_replace (Str.regexp "&amp;") "&"
    (Str.global_replace (Str.regexp "&lt;") "<" s)

(* base64 *)
let base64decode s = 
  try Netencoding.Base64.decode (Str.global_replace (Str.regexp " ") "+" s)
  with Invalid_argument "Netencoding.Base64.decode" 
      -> raise (Invalid_argument ("base64 decode gave error: " ^ s))

and base64encode s = Netencoding.Base64.encode s

(*** ocaml versions ***)
let ocaml_version_number = (List.map int_of_string
                              (split_string Sys.ocaml_version '.'))

(* Ocaml team says string comparison would work here. Do we believe them? *)
let rec version_atleast a b =
  match a, b with
      _, [] -> true
    | [], _ -> false
    | (ah::at), (bh::bt) -> ah > bh or (ah = bh && version_atleast at bt)
let ocaml_version_atleast min_vsn = version_atleast ocaml_version_number min_vsn

(* Any two calls to `gensym' return distinct strings.  The optional
   `prefix' argument can be used to supply a prefix for the string.
*)
let gensym = 
  let counter = ref 0 in
    fun ?prefix:(pref="") () ->
      begin
        incr counter;
        pref ^ "_g" ^ string_of_int !counter
      end

(** gensyms a new symbol for each item in the list and returns the
    pairs of each item with its new name.
    The "graph" of the gensym function, if you will.
*)
let pair_fresh_names ?prefix:pfx list = 
  graph_func
    (match pfx with
       | Some pfx -> (fun _ -> gensym ~prefix:pfx ())
       | None     -> (fun _ -> gensym ()))
    list 

let refresh_names = 
  graph_func (fun x -> gensym ~prefix:x ())

let any_true = List.exists identity

let getenv : string -> string option =
  fun name ->
    try Some (Sys.getenv name)
    with Not_found -> None

(* {0 Exception-handling helpers} *)

let catch_notfound msg f a =
  try
    f a
  with Not_found -> failwith ("Internal error: Not_found caught ("^msg^")")

let catch_notfound_l msg e =
  try
    Lazy.force e
  with Not_found -> failwith ("Internal error: Not_found caught ("^msg^")")


(** {0 Simulating infix function words (a la Haskell backticks)} *)

(** left-associative *)
let ( <| ) arg f = f arg
let ( |> ) f arg = f arg

