open Notfound

open Utility

module Session = struct
  type apid = int              (* access point id *)
  type portid = int
  type pid = int               (* process id *)
  type chan = portid * portid  (* a channel is a pair of ports *)

  type ap_state = Balanced | Accepting of chan list | Requesting of chan list

  let flip_chan (outp, inp) = (inp, outp)

  let access_points = (Hashtbl.create 10000 : (apid, ap_state) Hashtbl.t)

  let buffers = (Hashtbl.create 10000 : (portid, Value.t Queue.t) Hashtbl.t)
  let blocked = (Hashtbl.create 10000 : (portid, pid) Hashtbl.t)
  let forward = (Hashtbl.create 10000 : (portid, portid Unionfind.point) Hashtbl.t)

  let generator () =
    let i = ref 0 in
      fun () -> incr i; !i

  let fresh_apid = generator ()
  let fresh_portid = generator ()
  let fresh_chan () =
    let outp = fresh_portid () in
    let inp = fresh_portid () in
      (outp, inp)

  let new_channel () =
    let (outp, inp) as c = fresh_chan () in
      Hashtbl.add buffers outp (Queue.create ());
      Hashtbl.add buffers inp (Queue.create ());
      Hashtbl.add forward outp (Unionfind.fresh outp);
      Hashtbl.add forward inp (Unionfind.fresh inp);
      c

  let new_access_point () =
    let apid = fresh_apid () in
      Hashtbl.add access_points apid Balanced;
      apid

  let accept : apid -> chan * bool =
    fun apid ->
      let state = Hashtbl.find access_points apid in
      let (c, state', blocked) =
        match state with
        | Balanced             -> let c = new_channel () in (c, Accepting [c], true)
        | Accepting cs         -> let c = new_channel () in (c, Accepting (cs @ [c]), true)
        | Requesting [c]       -> (c, Balanced, false)
        | Requesting (c :: cs) -> (c, Requesting cs, false)
      in
        Hashtbl.replace access_points apid state';
        c, blocked

  let request : apid -> chan * bool =
    fun apid ->
      let state = Hashtbl.find access_points apid in
      let (c, state', blocked) =
        match state with
        | Balanced            -> let c = new_channel () in (c, Requesting [c], true)
        | Requesting cs       -> let c = new_channel () in (c, Requesting (cs @ [c]), true)
        | Accepting [c]       -> (c, Balanced, false)
        | Accepting (c :: cs) -> (c, Accepting cs, false)
      in
        Hashtbl.replace access_points apid state';
        flip_chan c, blocked

  let rec find_active p =
    Unionfind.find (Hashtbl.find forward p)

  let forward inp outp =
    Unionfind.union (Hashtbl.find forward inp) (Hashtbl.find forward outp)

  let block portid pid =
    let portid = find_active portid in
      Hashtbl.add blocked portid pid
  let rec unblock portid =
    let portid = find_active portid in
      if Hashtbl.mem blocked portid then
        begin
          let pid = Hashtbl.find blocked portid in
            Hashtbl.remove blocked portid;
            Some pid
        end
      else
        None

  let rec send msg p =
    (* Debug.print ("Sending along: " ^ string_of_int p); *)
    let p = find_active p in
      Queue.push msg (Hashtbl.find buffers p)

  let rec receive p =
    (* Debug.print ("Receiving on: " ^ string_of_int p); *)
    let p = find_active p in
    let buf = Hashtbl.find buffers p in
      if not (Queue.is_empty buf) then
        Some (Queue.pop buf)
      else
        None

  let fuse (out1, in1) (out2, in2) =
    let out1 = find_active out1 in
    let in1 = find_active in1 in
    let out2 = find_active out2 in
    let in2 = find_active in2 in
      Queue.transfer (Hashtbl.find buffers in1) (Hashtbl.find buffers out2);
      Queue.transfer (Hashtbl.find buffers in2) (Hashtbl.find buffers out1);
      forward in1 out2;
      forward in2 out1

  let unbox_port = Num.int_of_num -<- Value.unbox_int
  let unbox_chan' chan =
    let (outp, inp) = Value.unbox_pair chan in
      (Value.unbox_int outp, Value.unbox_int inp)
  let unbox_chan chan =
    let (outp, inp) = Value.unbox_pair chan in
      (unbox_port outp, unbox_port inp)
end

let hempty = [] (* Empty handler stack *)
let hpush h hs = h :: hs
let hpop = function
  | h :: hs -> (Some h, hs)
  | [] -> (None, [])

module Eval = struct
  open Ir

  exception EvaluationError of string
  exception Wrong
  exception TopLevel of (Value.env * Value.t)

  let eval_error fmt =
    let error msg = raise (EvaluationError msg) in
      Printf.kprintf error fmt

  let db_connect : Value.t -> Value.database * string = fun db ->
    let driver = Value.unbox_string (Value.project "driver" db)
    and name = Value.unbox_string (Value.project "name" db)
    and args = Value.unbox_string (Value.project "args" db) in
    let params =
      (if args = "" then name
       else name ^ ":" ^ args)
    in
      Value.db_connect driver params
(*
   let lookup_var var env =
     match Value.lookup var env with
       | Some v -> v
       | None -> (Lib.primitive_stub_by_code var)
*)

(* Alternative, faster version *)
   let lookup_var var env =
     if Lib.is_primitive_var var
     then Lib.primitive_stub_by_code var
     else Value.find var env


   let serialize_call_to_client (continuation, handlers, name, arg) =
     Json.jsonize_call continuation handlers name arg

   let client_call : string -> Value.gcontinuation -> Value.handlers -> Value.t list -> 'a =
     fun name cont hs args ->
       if not(Settings.get_value Basicsettings.web_mode) then
         failwith "Can't make client call outside web mode.";
       if not(Proc.singlethreaded()) then
         failwith "Remaining procs on server at client call!";
(*        Debug.print("Making client call to " ^ name); *)
(*        Debug.print("Call package: "^serialize_call_to_client (cont, name, args)); *)
       let call_package = Utility.base64encode
                            (serialize_call_to_client (cont, hs, name, args)) in
         Lib.print_http_response ["Content-type", "text/plain"] call_package;
         exit 0

  (** {0 Scheduling} *)

  (** {1 Scheduler parameters} *)
  (** [switch_granularity]: The number of steps to take before
      switching threads.  *)
  let switch_granularity = 5

  (* If this flag is set then context switching is prohibited.
     It is currently used for running pure functions. *)
  let atomic = ref false

  let toplevel_val = ref None

  let rec switch_context env =
    assert (not (!atomic));
    match Proc.pop_ready_proc() with
    | Some((cont, hs, value), pid) when Proc.active_main() || Proc.active_angels() ->
      begin
        Proc.activate pid;
        apply_cont cont hs env value
      end
    | _ ->
      if not(Proc.singlethreaded()) then
        failwith("Server stuck with suspended threads, none runnable.")
        (* Outside web mode, this case indicates deadlock:
           all running processes are blocked. *)
      else
        match !toplevel_val with
        | None -> exit 0
        | Some v -> raise (TopLevel v)

  and scheduler env state stepf =
    if !atomic || Proc.singlethreaded() then stepf()
    else (* No need to schedule if we're in an atomic section or there are no threads *)
      let step_ctr = Proc.count_step() in
        if step_ctr mod switch_granularity == 0 then
          begin
            (* Debug.print ("Scheduled context switch"); *)
            (* Debug.print ("  Continuation: " ^ Value.string_of_cont (fst state)); *)
            (* Debug.print ("  Value: " ^ Value.string_of_value (snd state)); *)
            Proc.reset_step_counter();
            Proc.suspend_current state;
            switch_context env
          end
        else
          stepf()

  (** {0 Evaluation} *)
  and value env : Ir.value -> Value.t = function
    | `Constant `Bool b -> `Bool b
    | `Constant `Int n -> `Int n
    | `Constant `Char c -> `Char c
    | `Constant `String s -> Value.box_string s
    | `Constant `Float f -> `Float f
    | `Variable var -> lookup_var var env
(*
        begin
          match lookup_var var env with
            | Some v -> v
            | _      -> eval_error "Variable not found: %d" var
        end
*)
    | `Extend (fields, r) ->
        begin
          match opt_app (value env) (`Record []) r with
            | `Record fs ->
                (* HACK

                   Pre-pending the fields to r in this order shouldn't
                   be necessary but without the List.rev, deriving
                   somehow manages to serialise things in the wrong
                   order on the "Your Shopping Cart" page of the
                   winestore example. *)
                `Record (List.rev
                           (StringMap.fold
                              (fun label v fs ->
                                 if List.mem_assoc label fs then
                                   (* (label, value env v) :: (List.remove_assoc label fs) *)
                                   eval_error
                                     "Error adding fields: label %s already present" label
                                 else
                                   (label, value env v)::fs)
                              fields
                              []) @ fs)
(*                 `Record (StringMap.fold  *)
(*                            (fun label v fs -> *)
(*                               (label, value env v)::fs) *)
(*                            fields *)
(*                            fs) *)
            | _ -> eval_error "Error adding fields: non-record"
        end
    | `Project (label, r) ->
        begin
          match value env r with
            | `Record fields when List.mem_assoc label fields ->
                List.assoc label fields
            | _ -> eval_error "Error projecting label %s" label
        end
    | `Erase (labels, r) ->
        begin
          match value env r with
            | `Record fields when
                StringSet.for_all (fun label -> List.mem_assoc label fields) labels ->
                `Record (StringSet.fold (fun label fields -> List.remove_assoc label fields) labels fields)
            | _ -> eval_error "Error erasing labels {%s}" (String.concat "," (StringSet.elements labels))
        end
    | `Inject (label, v, t) -> `Variant (label, value env v)
    | `TAbs (_, v) -> value env v
    | `TApp (v, _) -> value env v
    | `XmlNode (tag, attrs, children) ->
        let children =
          List.fold_right
            (fun v children ->
               let v = value env v in
                 List.map Value.unbox_xml (Value.unbox_list v) @ children)
            children [] in
        let children =
          StringMap.fold
            (fun name v attrs ->
               Value.Attr (name, Value.unbox_string (value env v)) :: attrs)
            attrs children
        in
          Value.box_list [Value.box_xml (Value.Node (tag, children))]
    | `ApplyPure (f, args) ->
      let previousAtomic = !atomic in
        begin
          try (
            atomic := true;
            (* Debug.print ("Applying pure function"); *)
	    let cont = Value.toplevel_gcont in (* Empty continuation *)
            ignore (apply cont hempty env (value env f, List.map (value env) args));
            failwith "boom"
          ) with
            | TopLevel (_, v) -> atomic := previousAtomic; v
        end
    | `Coerce (v, t) -> value env v

  and apply cont hs env : Value.t * Value.t list -> Value.t =
    function
    | `RecFunction (recs, locals, n, scope), ps ->
        begin match lookup n recs with
          | Some (args, body) ->
              (* unfold recursive definitions once *)

              (* extend env with locals *)
              let env = Value.shadow env ~by:locals in

              (* extend env with recs *)

              let env =
	        List.fold_right
                  (fun (name, _) env ->
                      Value.bind name
			(`RecFunction (recs, locals, name, scope), scope) env)
                    recs env in

              (* extend env with arguments *)
              let env = List.fold_right2 (fun arg p -> Value.bind arg (p, `Local)) args ps env in
              computation env cont hs body
          | None -> eval_error "Error looking up recursive function definition"
        end
    | `PrimitiveFunction ("Send",_), [pid; msg] ->
        if Settings.get_value Basicsettings.web_mode && not (Settings.get_value Basicsettings.concurrent_server) then
           client_call "_SendWrapper" cont hs [pid; msg]
        else
          let pid = Num.int_of_num (Value.unbox_int pid) in
            (try
               Proc.send_message msg pid;
               Proc.awaken pid
             with
                 Proc.UnknownProcessID pid ->
                   (* FIXME: printing out the message might be more useful. *)
                   failwith("Couldn't deliver message because destination process has no mailbox."));
            apply_cont cont hs env (`Record [])
    | `PrimitiveFunction ("spawn",_), [func] ->
        if Settings.get_value Basicsettings.web_mode && not (Settings.get_value Basicsettings.concurrent_server) then
           client_call "_spawnWrapper" cont hs [func]
        else
          apply_cont cont hs env (Lib.apply_pfun "spawn" [func])
    | `PrimitiveFunction ("spawnAngel",_), [func] ->
        if Settings.get_value Basicsettings.web_mode && not (Settings.get_value Basicsettings.concurrent_server) then
           client_call "_spawnWrapper" cont hs [func]
        else
          apply_cont cont hs env (Lib.apply_pfun "spawnAngel" [func])
    | `PrimitiveFunction ("recv",_), [] ->
        (* If there are any messages, take the first one and apply the
           continuation to it.  Otherwise, block the process (put its
           continuation in the blocked_processes table) and let the
           scheduler choose a different thread.  *)
(*         if (Settings.get_value Basicsettings.web_mode) then *)
(*             Debug.print("receive in web server mode--not implemented."); *)
        if Settings.get_value Basicsettings.web_mode && not (Settings.get_value Basicsettings.concurrent_server) then
           client_call "_recvWrapper" cont hs []
        else
        begin match Proc.pop_message() with
            Some message ->
              Debug.print("delivered message.");
              apply_cont cont hs env message
          | None ->
              let recv_frame = Value.expr_to_contframe
                env (Lib.prim_appln "recv" [])
              in
              (* the value passed to block_current is ignored, so can be anything *)
	      let cont = Value.append_cont_frame recv_frame cont in
              Proc.block_current (cont, hs, `Record []);
              switch_context env
        end
    (* Session stuff *)
    | `PrimitiveFunction ("new", _), [] ->
      let apid = Session.new_access_point () in
        apply_cont cont hs env (`Int (Num.num_of_int apid))
    | `PrimitiveFunction ("accept", _), [ap] ->
      let apid = Num.int_of_num (Value.unbox_int ap) in
      let (c, d), blocked = Session.accept apid in
      Debug.print ("accepting: (" ^ string_of_int c ^ ", " ^ string_of_int d ^ ")");
      let c' = Num.num_of_int c in
      let d' = Num.num_of_int d in
        if blocked then
          let accept_frame =
              Value.expr_to_contframe env
                (`Return (`Extend (StringMap.add "1" (`Constant (`Int c'))
                                     (StringMap.add "2" (`Constant (`Int d'))
                                        StringMap.empty), None)))
          in
	  let cont = Value.append_cont_frame accept_frame cont in
          Proc.block_current (cont, hs, `Record []);
          (* block my end of the channel *)
          Session.block c (Proc.get_current_pid ());
          switch_context env
        else
          begin
            begin
              (* unblock the other end of the channel *)
              match Session.unblock d with
              | Some pid -> Proc.awaken pid
              | None     -> assert false
            end;
            apply_cont cont hs env (Value.box_pair
                                   (Value.box_int (Num.num_of_int c))
                                   (Value.box_int (Num.num_of_int d)))
          end
    | `PrimitiveFunction ("request", _), [ap] ->
      let apid = Num.int_of_num (Value.unbox_int ap) in
      let (c, d), blocked = Session.request apid in
      Debug.print ("requesting: (" ^ string_of_int c ^ ", " ^ string_of_int d ^ ")");
      let c' = Num.num_of_int c in
      let d' = Num.num_of_int d in
        if blocked then
          let request_frame =
              Value.expr_to_contframe env
                (`Return (`Extend (StringMap.add "1" (`Constant (`Int c'))
                                     (StringMap.add "2" (`Constant (`Int d'))
                                        StringMap.empty), None)))
          in
	  let cont = Value.append_cont_frame request_frame cont in 
          Proc.block_current (cont, hs, `Record []);
          (* block my end of the channel *)
          Session.block c (Proc.get_current_pid ());
          switch_context env
        else
          begin
            begin
              (* unblock the other end of the channel *)
              match Session.unblock d with
              | Some pid -> Proc.awaken pid
              | None     -> assert false
            end;
            apply_cont cont hs env (Value.box_pair
                                   (Value.box_int (Num.num_of_int c))
                                   (Value.box_int (Num.num_of_int d)))
          end
    | `PrimitiveFunction ("send", _), [v; chan] ->
      Debug.print ("sending: " ^ Value.string_of_value v ^ " to channel: " ^ Value.string_of_value chan);
      let (outp, _) = Session.unbox_chan chan in
      Session.send v outp;
      begin
        match Session.unblock outp with
          Some pid -> Proc.awaken pid
        | None     -> ()
      end;
      apply_cont cont hs env chan
    | `PrimitiveFunction ("receive", _), [chan] ->
      begin
        Debug.print("receiving from channel: " ^ Value.string_of_value chan);
        let (out', in') = Session.unbox_chan' chan in
        let inp = Num.int_of_num in' in
          match Session.receive inp with
          | Some v ->
            Debug.print ("grabbed: " ^ Value.string_of_value v);
            apply_cont cont hs env (Value.box_pair v chan)
          | None ->
            let grab_frame =
              Value.expr_to_contframe env (Lib.prim_appln "receive" [`Extend (StringMap.add "1" (`Constant (`Int out'))
                                                                                (StringMap.add "2" (`Constant (`Int in'))
                                                                                   StringMap.empty), None)])
            in
	    let cont = Value.append_cont_frame grab_frame cont in
            Proc.block_current (cont, hs, `Record []);
            Session.block inp (Proc.get_current_pid ());
            switch_context env
      end
    | `PrimitiveFunction ("link", _), [chanl; chanr] ->
      let unblock p =
        match Session.unblock p with
        | Some pid -> (*Debug.print("unblocked: "^string_of_int p); *)
                      Proc.awaken pid
        | None     -> () in
      Debug.print ("linking channels: " ^ Value.string_of_value chanl ^ " and: " ^ Value.string_of_value chanr);
      let (out1, in1) = Session.unbox_chan chanl in
      let (out2, in2) = Session.unbox_chan chanr in
      (* HACK *)
      let end_bang = `Variable (Env.String.lookup (val_of !Lib.prelude_nenv) "makeEndBang") in
        Session.fuse (out1, in1) (out2, in2);
        unblock out1;
        unblock out2;
        apply cont hs env (value env end_bang, [])
    (*****************)
    | `PrimitiveFunction (n,None), args ->
	apply_cont cont hs env (Lib.apply_pfun n args)
    | `PrimitiveFunction (n,Some code), args ->
	apply_cont cont hs env (Lib.apply_pfun_by_code code args)
    | `ClientFunction name, args   -> client_call name cont hs args
    (* | `GContinuation (c, []), [p]  -> apply_cont c hs env p        (* TODO: This needs to be fixed, it breaks the invariant that |cont| - |hs| <= 1 *)*)
    | `GContinuation (c, [h]), [p] -> apply_cont (c @ cont) (h :: hs) env p
    | `GContinuation (c, hs), [p]  -> apply_cont c hs env p
    | `Continuation c,      p      -> let gcont = `GContinuation (c :: cont, hs) in
				      apply cont hs env (gcont, p) (* Legacy / backwards compatibility *)
    | `GContinuation _,       _    ->
        eval_error "Continuation applied to multiple (or zero) arguments"
    | _                        -> eval_error "Application of non-function"
  and apply_cont cont hs env v : Value.t =
    let stepf() =
      match cont, hs with
      | [] :: conts, h :: hs ->
	 invoke_return_clause conts hs env h v
      | [], [] ->
	 if !atomic then
           raise (TopLevel (Value.globals env, v))
	 else if Proc.current_is_main() then
           if not (Proc.active_angels() || Settings.get_value Basicsettings.wait_for_child_processes) || Proc.singlethreaded () then
             raise (TopLevel (Value.globals env, v))
           else
             begin
	       Debug.print ("Finished top level process (other processes still active)");
	       toplevel_val := Some (Value.globals env, v);
	       Proc.finish_current();
	       switch_context env
             end  
	 else
	   begin
             Debug.print ("Finished process: " ^ string_of_int (Proc.get_current_pid()));
             Proc.finish_current();
             switch_context env
	   end
      | [] :: conts, [] -> apply_cont conts hs env v
      | cont :: conts, _ ->
	 let (scope, var, locals, comp) = List.hd cont in 
         let env = Value.bind var (v, scope) (Value.shadow env ~by:locals) in
	 let conts = (List.tl cont) :: conts in
         computation env conts hs comp
      | _   -> failwith ("evalir.ml: apply_cont: Edge case: Ooops, what happened?")
    in
    scheduler env (cont, hs, v) stepf  (* TODO: What about state in a multithreaded context? *)
  and computation env cont hs (bindings, tailcomp) : Value.t =
    match bindings with
      | [] -> tail_computation env cont hs tailcomp
      | b::bs -> match b with
		 | `Let ((var, _) as b, (_, tc)) ->
		    let locals = Value.localise env var in	     
		    let contf  = Value.make_cont_frame (Var.scope_of_binder b) var locals (bs, tailcomp) in
		    let cont   = Value.append_cont_frame contf cont in
                    tail_computation env cont hs tc
		 | `Fun ((f, _) as fb, (_, args, body), `Client) ->
		    let env' = Value.bind f (`ClientFunction
                                              (Js.var_name_binder fb),
					     Var.scope_of_binder fb) env in
                    computation env' cont hs (bs, tailcomp)		    
		 | `Fun ((f, _) as fb, (_, args, body), _) ->
		    let scope = Var.scope_of_binder fb in
		    let locals = Value.localise env f in
		    let env' =
                      Value.bind f
				 (`RecFunction ([f, (List.map fst args, body)],
						locals, f, scope), scope) env
		    in
                    computation env' cont hs (bs, tailcomp)
		 | `Rec defs ->
		    (* partition the defs into client defs and non-client defs *)
		    let client_defs, defs =
                      List.partition (function
                                       | (_fb, _lam, (`Client | `Native)) -> true
                                       | _ -> false) defs in
		    
		    let locals =
                      match defs with
                      | [] -> Value.empty_env (Value.get_closures env)
                      | ((f, _), _, _)::_ -> Value.localise env f in
		    
		    (* add the client defs to the environments *)
		    let env =
                      List.fold_left
			(fun env ((f, _) as fb, _lam, _location) ->
			 let v = `ClientFunction (Js.var_name_binder fb),
				 Var.scope_of_binder fb
			 in Value.bind f v env)
			env client_defs in

		    (* add the server defs to the environment *)
		    let bindings = List.map (fun ((f,_), (_, args, body), _) ->
                                             f, (List.map fst args, body)) defs in
		    let env =
                      List.fold_right
			(fun ((f, _) as fb, _, _) env ->
			 let scope = Var.scope_of_binder fb in
			 Value.bind f
				    (`RecFunction (bindings, locals, f, scope),
				     scope)
				    env) defs env
		    in
                    computation env cont hs (bs, tailcomp)
		 | `Alien _ -> (* just skip it *)
		    computation env cont hs (bs, tailcomp)
		 | `Module _ -> failwith "Not implemented interpretation of modules yet"
  and tail_computation env cont hs : Ir.tail_computation -> Value.t = function
    (* | `Return (`ApplyPure _ as v) -> *)
    (*   let w = (value env v) in *)
    (*     Debug.print ("ApplyPure"); *)
    (*     Debug.print ("  value term: " ^ Show.show Ir.show_value v); *)
    (*     Debug.print ("  cont: " ^ Value.string_of_cont cont); *)
    (*     Debug.print ("  value: " ^ Value.string_of_value w); *)
    (*     apply_cont cont env w *)
    | `Return v      -> apply_cont cont hs env (value env v)
    | `Apply (f, ps) -> apply cont hs env (value env f, List.map (value env) ps)
    | `Special s     -> special env cont hs s
    | `Case (v, cases, default) ->
        begin match value env v with
           | `Variant (label, _) as v ->
               (match StringMap.lookup label cases, default, v with
                  | Some ((var,_), c), _, `Variant (_, v)
                  | _, Some ((var,_), c), v ->
                      computation (Value.bind var (v, `Local) env) cont hs c
                  | None, _, #Value.t -> eval_error "Pattern matching failed"
                  | _ -> assert false (* v not a variant *))
           | _ -> eval_error "Case of non-variant"
        end
    | `If (c,t,e)    ->
        computation env cont hs
          (match value env c with
             | `Bool true     -> t
             | `Bool false    -> e
             | _              -> eval_error "Conditional was not a boolean")
  and special env cont hs : Ir.special -> Value.t = function
    | `Wrong _                    -> raise Wrong
    | `Database v                 -> apply_cont cont hs env (`Database (db_connect (value env v)))
    | `Table (db, name, (readtype, _, _)) ->
      begin
        (* OPTIMISATION: we could arrange for concrete_type to have
           already been applied here *)
        match value env db, value env name, (TypeUtils.concrete_type readtype) with
          | `Database (db, params), name, `Record row ->
            apply_cont cont hs env (`Table ((db, params), Value.unbox_string name, row))
          | _ -> eval_error "Error evaluating table handle"
      end
    | `Query (range, e, _t) ->
      let range =
        match range with
          | None -> None
          | Some (limit, offset) ->
            Some (Value.unbox_int (value env limit), Value.unbox_int (value env offset)) in
      let result =
        match Query.compile env (range, e) with
          | None -> computation env cont hs e
          | Some (db, q, t) ->
            let (fieldMap, _, _), _ =
              Types.unwrap_row(TypeUtils.extract_row t) in
            let fields =
              StringMap.fold
                (fun name t fields ->
                  match t with
                    | `Present t -> (name, t)::fields
                    | `Absent -> assert false
                    | `Var _ -> assert false)
                fieldMap
                []
            in
              Database.execute_select fields q db
      in
        apply_cont cont hs env result
    | `Update ((xb, source), where, body) ->
      let db, table, field_types =
        match value env source with
          | `Table ((db, _), table, (fields, _, _)) ->
            db, table, (StringMap.map (function
                                        | `Present t -> t
                                        | _ -> assert false) fields)
          | _ -> assert false in
      let update_query =
        Query.compile_update db env ((Var.var_of_binder xb, table, field_types), where, body) in
      let () = ignore (Database.execute_command update_query db) in
        apply_cont cont hs env (`Record [])
    | `Delete ((xb, source), where) ->
      let db, table, field_types =
        match value env source with
          | `Table ((db, _), table, (fields, _, _)) ->
            db, table, (StringMap.map (function
                                        | `Present t -> t
                                        | _ -> assert false) fields)
          | _ -> assert false in
      let delete_query =
        Query.compile_delete db env ((Var.var_of_binder xb, table, field_types), where) in
      let () = ignore (Database.execute_command delete_query db) in
        apply_cont cont hs env (`Record [])
    | `CallCC f ->
       apply cont hs env (value env f, [`GContinuation (cont, hs)])
    (* Handlers *)
    | `Handle (v, cases, isclosed) ->
       let hs = (cases, isclosed) :: hs in
       let cont = [] :: cont in 
       let comp = value env v in
       apply cont hs env (comp, [])
    | `DoOperation (v, t) ->
       let op = value env v in
       handle env cont hs op
    (* Session stuff *)
    | `Select (name, v) ->
      let chan = value env v in
      Debug.print ("selecting: " ^ name ^ " from: " ^ Value.string_of_value chan);
      let (outp, _) = Session.unbox_chan chan in
      Session.send (Value.box_string name) outp;
      begin
        match Session.unblock outp with
          Some pid -> Proc.awaken pid
        | None     -> ()
      end;
      apply_cont cont hs env chan
    | `Choice (v, cases) ->
      begin
        let chan = value env v in
        Debug.print("choosing from: " ^ Value.string_of_value chan);
        let (out', in') = Session.unbox_chan' chan in
        let inp = Num.int_of_num in' in
          match Session.receive inp with
          | Some v ->
            Debug.print ("chose: " ^ Value.string_of_value v);
            let label = Value.unbox_string v in
              begin
                match StringMap.lookup label cases with
                | Some ((var,_), body) ->
                  computation (Value.bind var (chan, `Local) env) cont hs body
                | None -> eval_error "Choice pattern matching failed"
              end
            (* apply_cont cont env (Value.box_pair v chan) *)
          | None ->
            let choice_frame =
              Value.expr_to_contframe env (`Special (`Choice (v, cases)))
            in
	    let cont = Value.append_cont_frame choice_frame cont in
              Proc.block_current (cont, hs, `Record []);
              Session.block inp (Proc.get_current_pid ());
              switch_context env
      end
  (*****************)
  and  handle env cont hs op =
    let restore cont hs s = (* Restores handler stack by merging state s with cont & hs *)
      List.fold_left (fun (cont, hs) (delim, h) -> (delim :: cont, h :: hs))
				     (cont,hs) s     
    in    
    let rec handle env cont hs op s = 
      let transform (delim :: cont) ((h,isclosed) :: hs) op =
	match op with
	| `Variant (label, v) ->
	   begin
	     match StringMap.lookup label h with
	       Some ((var,_) as b, comp) -> let (cont,hs) = restore cont hs s in
	                                    let p    = v in
					    let k    = `GContinuation ([delim], [(h,isclosed)]) in
					    let pair = Value.box_pair p k in
					    let env  = Value.bind var (pair, `Local) env in
					    computation env cont hs comp
             | None  when isclosed == true  -> eval_error "Pattern matching failed"
	     | None  when isclosed == false -> handle env cont hs op ((delim, (h,false)) :: s)
	   end
	| _ -> assert false (* This can never happen as all operations are variants. *)
      in
      match hs with
	h :: _  -> transform cont hs op
      | []      -> eval_error "Unhandled operation: %s"  (Value.string_of_value op)
    in
    handle env cont hs op []
  and invoke_return_clause cont hs env (h,_) v =    
    match StringMap.lookup "Return" h with
      Some ((var,_), comp) -> let env = Value.bind var (v, `Local) env in
			      computation env cont hs comp
    | None -> eval_error "Pattern matching failed"      

  let eval : Value.env -> program -> Value.t =
    fun env ->
    computation env Value.toplevel_gcont Value.toplevel_hs
end

let run_program_with_cont : Value.continuation -> Value.env -> Ir.program ->
  (Value.env * Value.t) =
  fun cont env program ->
  let cont = Value.generalise_cont cont in
    try (
      ignore	
        (Eval.computation env cont hempty program); (* TODO: Figure out whether the handler stack should be an input parameter *)
      failwith "boom"
    ) with
      | Eval.TopLevel (env, v) -> (env, v)
      | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                   " while interpreting.")

let run_program : Value.env -> Ir.program -> (Value.env * Value.t) =
  fun env program ->
    try (
      ignore
        (Eval.eval env program);
      failwith "boom"
    ) with
      | Eval.TopLevel (env, v) -> (env, v)
      | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                   " while interpreting.")
      | Not_found  -> failwith ("Internal error: Not_found while interpreting.")

let run_defs : Value.env -> Ir.binding list -> Value.env =
  fun env bs ->
    let env, _value =
      run_program env (bs, `Return(`Extend(StringMap.empty, None))) in
      env

(** [apply_cont_toplevel cont env v] applies a continuation to a value
    and returns the result. Finishing the main thread normally comes
    here immediately. *)
let apply_cont_toplevel cont env v =
  let cont = Value.generalise_cont cont in
  try Eval.apply_cont cont hempty env v
  with
    | Eval.TopLevel s -> snd s
    | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                " while interpreting.")

let apply_toplevel env (f, vs) =
  try Eval.apply Value.toplevel_gcont hempty env (f, vs)
  with
    | Eval.TopLevel s -> snd s
    | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                " while interpreting.")

let eval_toplevel env program =
  try Eval.eval env program
  with
    | Eval.TopLevel s -> snd s
    | NotFound s -> failwith ("Internal error: NotFound " ^ s ^
                                " while interpreting.")
