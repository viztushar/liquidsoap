(** "Values", as manipulated by SAML. *)

open Utils.Stdlib
open Lang_values

module B = Saml_backend

(* Builtins are handled as variables, a special prefix is added to recognize
   them. *)
let builtin_prefix = "#saml_"
let builtin_prefix_re = Str.regexp ("^"^builtin_prefix)
let is_builtin_var x = Str.string_match builtin_prefix_re x 0
let remove_builtin_prefix x =
  let bpl = String.length builtin_prefix in
  String.sub x bpl (String.length x - bpl)

(* We add some helper functions. *)
module Lang_types = struct
  include Lang_types

  let fresh_evar () = fresh_evar ~level:(-1) ~pos:None

  let unit = make (Ground Unit)

  let bool = make (Ground Bool)

  let event t = make (Constr { name = "event" ; params = [Invariant,t] })

  let event_type t =
    match (T.deref t).descr with
      | Constr { name = "event" ; params = [_, t] } -> t
      | _ -> assert false

  let ref t = Lang_values.ref_t ~pos:None ~level:(-1) t

  let is_unit t =
    match (T.deref t).T.descr with
      | Ground Unit -> true
      | _ -> false

  let is_evar t =
    match (T.deref t).T.descr with
      | EVar _ -> true
      | _ -> false
end

module T = Lang_types

module V = struct
  include Lang_values

  let make ~t term = { term = term ; t = t }

  let unit = make ~t:Lang_types.unit Unit

  let bool b = make ~t:Lang_types.bool (Bool b)

  let var ~t x = make ~t (Var x)

  (* If then else. *)
  (* TODO: there are lots of hardcoded things here, can we do better? *)
  let ite b t e =
    let tret =
      match (T.deref t.t).T.descr with
        | T.Arrow (_, t) -> t
        | _ -> assert false
    in
    let ite =
      let t_branch = T.make (T.Arrow ([], tret)) in
      let t = T.make (T.Arrow ([false,"",Lang_types.bool;false,"then",t_branch;false,"else",t_branch], tret)) in
      make ~t (Var (builtin_prefix ^ "if_then_else"))
    in
    make ~t:tret (App (ite, ["",b;"then",t;"else",e]))

  let ref v = make ~t:(Lang_types.ref v.t) (Ref v)
end

type t = V.term

let meta_vars = ["period"]

let keep_vars = ref []

let make_term ?t tm =
  let t =
    match t with
      | Some t -> t
      | None -> T.fresh_evar ()
  in
  V.make ~t tm

let make_let x v t =
  let l =
    {
      doc = (Doc.none (), []);
      var = x;
      gen = [];
      def = v;
      body = t;
    }
  in
  V.make ~t:t.t (Let l)

let make_field ?t ?opt r x =
  let t =
    match t with
      | Some _ -> t
      | None ->
        match (T.deref r.t).T.descr with
          | T.Record r -> Some (snd (fst (T.Fields.find x r.T.fields)))
          | _ -> None
  in
  make_term ?t (Field (r, x, opt))

let make_var ?t x =
  make_term ?t (Var x)

(** Generate a fresh reference name. *)
let fresh_ref =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "saml_ref%d" !n

let fresh_var =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "saml_x%d" !n

let rec free_vars tm =
  (* Printf.printf "free_vars: %s\n%!" (print_term tm); *)
  let fv = free_vars in
  let u v1 v2 = v1@v2 in
  let r xx v = List.diff v xx in
  match tm.term with
    | Var x -> [x]
    | Unit | Bool _ | Int _ | String _ | Float _ -> []
    | Seq (a,b) -> u (fv a) (fv b)
    | Ref r | Get r -> fv r
    | Set (r,v) -> u (fv r) (fv v)
    | Record r -> T.Fields.fold (fun _ v f -> u (fv v.rval) f) r []
    | Field (r,x,o) ->
      let o = match o with Some o -> fv o | None -> [] in
      u (fv r) o
    | Let l -> u (fv l.def) (r [l.var] (fv l.body))
    | Fun (_, p, v) ->
      let o = List.fold_left (fun f (_,_,_,o) -> match o with None -> f | Some o -> u (fv o) f) [] p in
      let p = List.map (fun (_,x,_,_) -> x) p in
      u o (r p (fv v))
    | App (f,a) ->
      let a = List.fold_left (fun f (_,v) -> u f (fv v)) [] a in
      u (fv f) a

let occurences x tm =
  let ans = ref 0 in
  List.iter (fun y -> if y = x then incr ans) (free_vars tm);
  !ans

(** Is a term pure (ie does not contain side effects)? *)
let rec is_pure ~env tm =
  (* Printf.printf "is_pure: %s\n%!" (print_term tm); *)
  let is_pure ?(env=env) = is_pure ~env in
  match tm.term with
    (* TODO: use env for vars *)
    | Var _ | Unit | Bool _ | Int _ | String _ | Float _ -> true
    (* | App ({ term = Var x }, args) when is_builtin_var x -> *)
    (* TODO: we suppose for now that all builtins are pure, we should actually
       specify this somewhere for each external. *)
    (* List.for_all (fun (_,v) -> is_pure v) args *)
    | Get _ | Set _ -> false
    (* TODO: handle more cases *)
    | _ -> false

let rec fresh_let fv l =
  let reserved = ["main"] in
  if List.mem l.var fv || List.mem l.var reserved then
    let var = fresh_var () in
    var, subst l.var (make_term ~t:l.def.t (Var var)) l.body
  else
    l.var, l.body

(** Apply a list of substitutions to a term. *)
and substs ss tm =
  (* Printf.printf "substs: %s\n%!" (print_term ~no_records:true tm); *)
  let fv ss = List.fold_left (fun fv (_,v) -> (free_vars v)@fv) [] ss in
  let s = substs ss in
  let term =
    match tm.term with
      | Var x ->
        let rec aux = function
          | (x',v)::ss when x' = x ->
            (* TODO: too many free vars but correct *)
            let tm = if free_vars v = [] then v else substs ss v in
            tm.term
          | _::ss -> aux ss
          | [] -> tm.term
        in
        aux ss
      | Unit | Bool _ | Int _ | String _ | Float _ -> tm.term
      | Seq (a,b) -> Seq (s a, s b)
      | Ref r -> Ref (s r)
      | Get r -> Get (s r)
      | Set (r,v) -> Set (s r, s v)
      | Record r ->
        let r = T.Fields.map (fun v -> { v with rval = s v.rval }) r in
        Record r
      | Field (r,x,d) -> Field (s r, x, Utils.may s d)
      | Replace_field (r,x,v) ->
        let v = { v with rval = s v.rval } in
        Replace_field (s r, x, v)
      | Let l ->
        let def = s l.def in
        let ss = List.remove_all_assoc l.var ss in
        (* TODO: too many free vars but correct *)
        let s = substs ss in
        let var, body = if List.mem l.var (meta_vars @ !keep_vars) then l.var, l.body else fresh_let (fv ss) l in
        let body = s body in
        let l = { l with var = var; def = def; body = body } in
        Let l
      | Fun (_,p,v) ->
        let ss = ref ss in
        let sp = ref [] in
        let p =
          List.map
            (fun (l,x,t,v) ->
              let x' = if List.mem x (fv !ss) then fresh_var () else x in
              ss := List.remove_all_assoc x !ss;
              if x <> x' then sp := (x, make_term (Var x')) :: !sp;
              l,x',t,Utils.may s v
            ) p
        in
        let v = substs !sp v in
        let ss = !ss in
        let v = substs ss v in
        Fun (Vars.empty,p,v)
      | App (a,l) ->
        let a = s a in
        let l = List.map (fun (l,v) -> l, s v) l in
        App (a,l)
  in
  make_term ~t:tm.t term

and subst x v tm = substs [x,v] tm

(* Convert values to terms. This is a hack necessary becausse FFI are values and
   not terms (we should change this someday...). *)
let rec term_of_value v =
  (* Printf.printf "term_of_value: %s\n%!" (V.V.print_value v); *)
  let term =
    match v.V.V.value with
      | V.V.Record r ->
        let r =
          let ans = ref T.Fields.empty in
          T.Fields.iter
            (fun x v ->
              try
                ans := T.Fields.add x { V.rgen = v.V.V.v_gen; V.rval = term_of_value v.V.V.v_value } !ans
              with
                | Failure _ -> ()
                | e ->
                  Printf.printf "term_of_value: ignoring %s = %s (%s).\n" x (V.V.print_value v.V.V.v_value) (Printexc.to_string e);
                  ()
            ) r;
          !ans
        in
        Record r
      | V.V.FFI ffi ->
        (
          match ffi.V.V.ffi_external with
            | Some x ->
              (* TODO: regexp *)
              if List.mem x ["event.channel"; "event.emit"; "event.handle"] then
                Var x
              else
                Var (builtin_prefix^x)
            | None -> failwith "TODO: don't know how to emit code for this operation"
        )
      | V.V.Fun (params, applied, venv, t) ->
        let params = List.map (fun (l,x,v) -> l,x,T.fresh_evar (),Utils.may term_of_value v) params in
        let applied = List.may_map (fun (x,(_,v)) -> try Some (x,term_of_value v) with _ -> None) applied in
        let venv = List.may_map (fun (x,(_,v)) -> try Some (x,term_of_value v) with _ -> None) venv in
        let venv = applied@venv in
        let t = substs venv t in
        (* TODO: fill vars? *)
        Fun (V.Vars.empty, params, t)
      | V.V.Unit -> Unit
      | V.V.Product (a, b) -> Product (term_of_value a, term_of_value b)
      | V.V.Ref a -> Ref (term_of_value !a)
      | V.V.Int n -> Int n
      | V.V.Float f -> Float f
      | V.V.Bool b -> Bool b
      | V.V.String s -> String s
  in
  make_term ~t:v.V.V.t term

let rec is_value ~env tm =
  (* Printf.printf "is_value: %s\n%!" (print_term tm); *)
  let is_value ?(env=env) = is_value ~env in
  match tm.term with
    | Var _ | Unit | Bool _ | Int _ | String _ | Float _ -> true
    (* TODO: handle more cases, for instance: let x = ... in 3 *)
    | _ ->  false

type state =
    {
      refs : (string * term) list;
      (* List of event variables together with the currently known
         handlers. These have to be reset after each round. *)
      events : (string * term list) list;
    }

let empty_state = { refs = [] ; events = [] }

(** Raised by "Liquidsoap" implementations of functions when no reduction is
    possible. *)
exception Cannot_reduce

(** Functions to reduce builtins. *)
let builtin_reducers = ref
  [
    "add",
    (fun args ->
      match args.(0).term, args.(1).term with
        | Float x, Float y -> make_term (Float (x+.y))
        | Float 0., _ -> args.(1)
        | _, Float 0. -> args.(0)
        | _ -> raise Cannot_reduce
    );
    "sub",
    (fun args ->
      match args.(0).term, args.(1).term with
        | Float x, Float y -> make_term (Float (x-.y))
        | _, Float 0. -> args.(0)
        | _ -> raise Cannot_reduce
    );
    "mul",
    (fun args ->
      match args.(0).term, args.(1).term with
        | Float x, Float y -> make_term (Float (x*.y))
        | Float 1., _ -> args.(1)
        | _, Float 1. -> args.(0)
        | _ -> raise Cannot_reduce
    )
  ]

let rec reduce ?(env=[]) ?(bound_vars=[]) tm =
  (* Printf.printf "reduce: %s\n%!" (V.print_term tm); *)
  (* Printf.printf "reduce: %s : %s\n%!" (V.print_term tm) (T.print tm.t); *)
  let reduce ?(env=env) ?(bound_vars=bound_vars) = reduce ~env ~bound_vars in
  let fresh_let ?(bv=[]) l =
    (* TODO: I think that bv is not necessary because it is always included in
       bound_vars, remove bv *)
    let l = fresh_let (bv@bound_vars) l in
    l
  in
  let merge s1 s2 =
    let events =
      let l1 = List.map fst s1.events in
      let l2 = List.map fst s2.events in
      let l1 = List.filter (fun x -> not (List.mem x l2)) l1 in
      let l = l1@l2 in
      let a x l =
        try
          List.assoc x l
        with
          | Not_found -> []
      in
      List.map (fun x -> x, (a x s1.events)@(a x s2.events)) l
    in
    {
      refs = s1.refs@s2.refs;
      events = events;
    }
  in
  let mk ?(t=tm.t) = make_term ~t in
  let reduce_list l =
    let st = ref empty_state in
    let l = List.map (fun v -> let s, v = reduce v in st := merge !st s; v) l in
    !st, l
  in
  let s, term =
    match tm.term with
      | Var "event.channel" ->
        let t =
          match (T.deref tm.t).T.descr with
            | T.Arrow (_, t) -> T.event_type t
            | _ -> assert false
        in
        (* We impose that channels with unknown types carry unit values. *)
        if T.is_evar t then (T.deref t).T.descr <- T.Ground (T.Unit);
        (* TODO: otherwise have another ref for the value *)
        assert (T.is_unit t);
        let s, e = reduce (V.ref (V.bool false)) in
        let s =
          let x =
            match s.refs with
              | [x,_] -> x
              | _ -> assert false
          in
          { s with events = (x,[])::s.events }
        in
        s, Fun (Vars.empty, [], e)
      | Var "event.handle" ->
        let te, th =
          match (T.deref tm.t).T.descr with
            | T.Arrow ([_,_,te;_,_,th], _) -> te, th
            | _ -> assert false
        in
        assert (T.is_unit (T.event_type te));
        let f =
          let b = V.make ~t:T.bool (Get (V.var ~t:(T.ref T.bool) "e")) in
          let t_branch = T.make (T.Arrow ([], T.unit)) in
          let t =
            V.make ~t:t_branch
              (Fun (Vars.empty, [], V.make ~t:T.unit (App (V.var ~t:th "h", ["",V.unit]))))
          in
          let e = V.make ~t:t_branch (Fun (Vars.empty, [], V.unit)) in
          V.ite b t e
        in
        empty_state, Fun (Vars.empty, ["","e",te,None;"","h",th,None], f)
      | Var "event.emit" ->
        let t =
          match (T.deref tm.t).T.descr with
            | T.Arrow ([_;_,_,t], _) -> t
            | _ -> assert false
        in
        assert (T.is_unit t);
        let f = V.make ~t:T.unit (Set (V.var ~t:(T.ref T.bool) "e", V.bool true)) in
        empty_state, Fun (Vars.empty, ["","e",T.event t,None;"","v",t,None], f)
      | Var _ | Unit | Bool _ | Int _ | String _ | Float _ -> empty_state, tm.term
      | Let l ->
        let sdef, def = reduce l.def in
        if (
          (match (T.deref def.t).T.descr with
            | T.Arrow _ | T.Record _ -> true
            | _ -> is_value ~env def
          ) || (
            let o = occurences l.var l.body in
            o = 0 || (o = 1 && is_pure ~env def)
           )
        )
          (* We can rename meta-variables here because we are in weak-head
             reduction, so we know that any value using the meta-variable below
             will already be substituted. *)
          (* However, we have to keep the variables defined by lets that we want to
             keep, which are also in meta_vars. *)
          && not (List.mem l.var !keep_vars)
        then
          let env = (l.var,def)::env in
          let body = subst l.var def l.body in
          let sbody, body = reduce ~env body in
          merge sdef sbody, body.term
        else
          let var, body = fresh_let l in
          let env = (l.var,def)::env in
          let bound_vars = var::bound_vars in
          let sbody, body = reduce ~env ~bound_vars body in
          let l = { l with var = var; def = def; body = body } in
          merge sdef sbody, Let l
      | Ref v ->
        let sv, v = reduce v in
        let x = fresh_ref () in
        merge { empty_state with refs = [x,v] } sv, Var x
      | Get r ->
        let sr, r = reduce r in
        sr, Get r
      | Set (r,v) ->
        let sr, r = reduce r in
        let sv, v = reduce v in
        merge sr sv, Set (r, v)
      | Seq (a, b) ->
        let sa, a = reduce a in
        let sb, b = reduce b in
        let tm =
          let rec aux a =
            match a.term with
              | Unit -> b
              | Let l ->
                let var, body = fresh_let ~bv:(free_vars b) l in
                mk (Let { l with var = var; body = aux body })
              | _ -> mk (Seq (a, b))
          in
          (aux a).term
        in
        merge sa sb, tm
      | Record r ->
        (* Records get lazily evaluated in order not to generate variables for
           the whole standard library. *)
        empty_state, tm.term
      (*
        let sr = ref [] in
        let r =
        T.Fields.map
        (fun v ->
        let s, v' = reduce v.rval in
        sr := merge !sr s;
        { v with rval = v' }
        ) r
        in
        !sr, Record r
      *)
      | Field (r,x,o) ->
        let sr, r = reduce r in
        let sr = ref sr in
        let rec aux r =
          (* Printf.printf "aux field (%s): %s\n%!" x (print_term r); *)
          match r.term with
            | Record r ->
              (* TODO: use o *)
              let s, v = reduce (try T.Fields.find x r with Not_found -> failwith (Printf.sprintf "Field %s not found" x)).rval in
              sr := merge s !sr;
              v
            | Let l ->
              let fv = match o with Some o -> free_vars o | None -> [] in
              let var, body = fresh_let ~bv:fv l in
              mk (Let { l with var = var ; body = aux body })
            | Seq (a, b) ->
              mk (Seq (a, aux b))
        in
        !sr, (aux r).term
      | Fun (vars, args, v) ->
        (* We have to use weak head reduction because some refs might use the
           arguments, e.g. fun (x) -> ref x. However, we need to reduce toplevel
           declarations... *)
        (* let bound_vars = (List.map (fun (_,x,_,_) -> x) args)@bound_vars in *)
        (* let sv, v = reduce ~bound_vars v in *)
        (* sv, Fun (vars, args, v) *)
        (* TODO: we should extrude variables in order to be able to handle
           handle(c,fun(x)->emit(c',x)). *)
        (* TODO: instead of this, we should see when variables are not used in
           impure positions (in argument of refs). *)
        let fv = free_vars v in
        let args_vars = List.map (fun (_,x,_,_) -> x) args in
        if args_vars = [] || not (List.included args_vars fv) then
          let s, v = reduce v in
          s, Fun (vars, args, v)
        else
          empty_state, Fun (vars, args, v)
      | App (f,a) ->
        let sf, f = reduce f in
        let sa, a =
          let sa = ref empty_state in
          let ans = ref [] in
          List.iter
            (fun (l,v) ->
              let sv, v = reduce v in
              sa := merge !sa sv;
              ans := (l,v) :: !ans
            ) a;
          !sa, List.rev !ans
        in
        let s = ref (merge sf sa) in
        let rec aux f =
          (* Printf.printf "aux app: %s\n\n%!" (print_term f); *)
          match f.term with
            | Fun (vars, args, v) ->
              (
                match a with
                  | (l,va)::a ->
                    (* TODO: avoid those useless conversions on args *)
                    let args = List.map (fun (l,x,t,v) -> l,(x,t,v)) args in
                    let x,_,_ = List.assoc l args in
                    let args = List.remove_assoc l args in
                    let args = List.map (fun (l,(x,t,v)) -> l,x,t,v) args in
                    (* TODO: The type f.t is not correct. Does it really matter? *)
                    let body = mk (App (make_term ~t:f.t (Fun (vars, args, v)), a)) in
                    let l =
                      {
                        doc = Doc.none (), [];
                        var = x;
                        gen = [];
                        def = va;
                        body = body;
                      }
                    in
                    (* TODO: one reduce should be enough for multiple arguments... *)
                    let sv, v = reduce (mk (Let l)) in
                    s := merge sv !s;
                    v
                  | [] ->
                    if args = [] then
                      let sv, v = reduce v in
                      s := merge sv !s;
                      v
                    else if List.for_all (fun (_,_,_,v) -> v <> None) args then
                      let a = List.map (fun (l,_,_,v) -> l, Utils.get_some v) args in
                      let sv, v = reduce (mk (App (f, a))) in
                      s := merge sv !s;
                      v
                    else
                      mk (Fun (vars, args, v))
              )
            | Let l ->
              let fv = List.fold_left (fun fv (_,v) -> (free_vars v)@fv) [] a in
              let var, body = fresh_let ~bv:fv l in
              mk (Let { l with var = var ; body = aux body })
            | Seq (a, b) ->
              mk (Seq (a, aux b))
            | Var x ->
              (
                try
                  if is_builtin_var x then
                    let x = remove_builtin_prefix x in
                    let r = List.assoc x !builtin_reducers in
                    let a = List.map (fun (l,v) -> assert (l = ""); v) a in
                    let a = Array.of_list a in
                    r a
                  else
                    mk (App (f, a))
                with
                  | Not_found
                  | Cannot_reduce -> mk (App (f, a))
              )
        in
        !s, (aux f).term
  in
  (* Printf.printf "reduce: %s => %s\n%!" (print_term tm) (print_term (mk term)); *)
  (* This is important in order to preserve types. *)
  s, V.make ~t:tm.t term

and beta_reduce tm =
  (* Printf.printf "beta_reduce: %s\n%!" (print_term tm); *)
  let r, tm = reduce tm in
  assert (r = empty_state);
  tm

let rec emit_type t =
  (* Printf.printf "emit_type: %s\n%!" (T.print t); *)
  match (T.deref t).T.descr with
    | T.Ground T.Unit -> B.T.Void
    | T.Ground T.Bool -> B.T.Bool
    | T.Ground T.Float -> B.T.Float
    | T.Ground T.Int -> B.T.Int
    | T.Constr { T.name = "ref"; params = [_,t] }
    | T.Constr { T.name = "event"; params = [_,t] } -> B.T.Ptr (emit_type t)
    | T.Arrow (args, t) ->
      let args = List.map (fun (o,l,t) -> assert (not o); assert (l = ""); emit_type t) args in
      B.T.Arr (args, emit_type t)
    | T.EVar _ -> assert false; failwith "Cannot emit programs with universal types"

let rec emit_prog tm =
  (* Printf.printf "emit_prog: %s\n%!" (V.print_term tm); *)
  let rec focalize_app tm =
    match tm.term with
      | App (x,l2) ->
        let x, l1 = focalize_app x in
        x, l1@l2
      | x -> x,[]
  in
  match tm.term with
    | Bool b -> [B.Bool b]
    | Float f -> [B.Float f]
    | Var x -> [B.Ident x]
    | Ref r ->
      let tmp = fresh_ref () in
      [B.Let (tmp, [B.Alloc (emit_type r.t)]); B.Store ([B.Ident tmp], emit_prog r); B.Ident tmp]
    | Get r -> [B.Load (emit_prog r)]
    | Set (r,v) -> [B.Store (emit_prog r, emit_prog v)]
    | Seq (a,b) -> (emit_prog a)@(emit_prog b)
    | App _ ->
      let x, l = focalize_app tm in
      (
        (* Printf.printf "emit_prog app: %s\n%!" (print_term (make_term x)); *)
        match x with
          | Var x when is_builtin_var x ->
            let x = remove_builtin_prefix x in
            (
              match x with
                | "if_then_else" ->
                  let br v = beta_reduce (make_term (App (v, []))) in
                  let p = List.assoc "" l in
                  let p1 = br (List.assoc "then" l) in
                  let p2 = br (List.assoc "else" l) in
                  let p, p1, p2 = emit_prog p, emit_prog p1, emit_prog p2 in
                  [ B.If (p, p1, p2)]
                | _ ->
                  let l = List.map (fun (l,v) -> assert (l = ""); emit_prog v) l in
                  let l = Array.of_list l in
                  let op =
                    match x with
                      (* TODO: handle integer operations *)
                      | "add" -> B.FAdd
                      | "sub" -> B.FSub
                      | "mul" -> B.FMul
                      | "div" -> B.FDiv
                      | "mod" -> B.FMod
                      | "eq" -> B.FEq
                      | "lt" -> B.FLt
                      | "ge" -> B.FGe
                      | "and" -> B.BAnd
                      | "or" -> B.BOr
                      | _ -> B.Call x
                  in
                  [B.Op (op, l)]
            )
          | _ -> Printf.printf "unhandled app: %s(...)\n%!" (print_term (make_term x)); assert false
      )
    | Field (r,x,_) ->
      (* Records are always passed by reference. *)
      [B.Field ([B.Load (emit_prog r)], x)]
    | Let l ->
      (B.Let (l.var, emit_prog l.def))::(emit_prog l.body)
    | Unit -> []
    | Int n -> [B.Int n]
    | Fun _ -> assert false
    | Record _ ->
      (* We should not emit records since they are lazily evaluated (or
         evaluation should be forced somehow). *)
      assert false
    | Replace_field _ | Open _ -> assert false

(** Emit a prog which might start by decls (toplevel lets). *)
let rec emit_decl_prog tm =
  (* Printf.printf "emit_decl_prog: %s\n%!" (print_term tm); *)
  match tm.term with
    (* Hack to keep top-level declarations that we might need. We should
       explicitly flag them instead of keeping them all... *)
    | Let l when (match (T.deref l.def.t).T.descr with T.Arrow _ -> true | _ -> false) ->
      Printf.printf "def: %s = %s : %s\n%!" l.var (print_term l.def) (T.print l.def.t);
      let t = emit_type l.def.t in
      (
        match t with
          | B.T.Arr (args, t) ->
            let args =
              let n = ref 0 in
              List.map (fun t -> incr n; Printf.sprintf "x%d" !n, t) args
            in
            let proto = l.var, args, t in
            let def =
              let args = List.map (fun (x, _) -> "", make_term (Var x)) args in
              let def = make_term (App (l.def, args)) in
              beta_reduce def
            in
            let d = B.Decl (proto, emit_prog def) in
            let dd, p = emit_decl_prog l.body in
            d::dd, p
          | _ ->
            let dd, p = emit_decl_prog l.body in
            let e =
              match emit_prog l.def with
                | [e] -> e
                | _ -> assert false
            in
            (B.Decl_cst (l.var, e))::dd, p
      )
    | _ -> [], emit_prog tm

let substs ss tm =
  Printf.printf "substs: %s\n%!" (print_term tm);
  Printf.printf "\nComputing substs (%d)... %!" (List.length ss);
  let ans = substs ss tm in
  Printf.printf "done!\n\n%!";
  ans

let emit name ?(keep_let=[]) ~env ~venv tm =
  keep_vars := keep_let;
  Printf.printf "emit: %s : %s\n\n%!" (V.print_term ~no_records:true tm) (T.print tm.t);
  (* Inline the environment. *)
  let venv =
    List.may_map
      (fun (x,v) ->
        try
          Some (x, term_of_value v)
        with
          | e ->
            (* Printf.printf "venv: ignoring %s = %s (%s).\n" x (V.V.print_value v) (Printexc.to_string e); *)
            None
      ) venv
  in
  let env = env@venv in
  (* Printf.printf "env: %s\n%!" (String.concat " " (List.map fst env)); *)
  let prog = tm in
  let prog = substs env prog in
  Printf.printf "closed term: %s\n\n%!" (print_term ~no_records:true prog);
  (* Reduce the term and compute references. *)
  let state, prog = reduce ~env prog in
  Printf.printf "reduced: %s\n\n%!" (print_term ~no_records:true prog);

  (* Compute the state. *)
  let refs = state.refs in
  let refs = refs in
  let refs_t = List.map (fun (x,v) -> x, emit_type v.V.t) refs in
  let refs_t = ("period", B.T.Float)::refs_t in
  let refs = List.map (fun (x,v) -> x, emit_prog v) refs in
  let state_t = B.T.Struct refs_t in
  let state_decl = B.Decl_type ("saml_state", state_t) in

  (* Emit the program. *)
  let decls, prog = emit_decl_prog prog in
  Printf.printf "\n\n";
  let prog =
    (* Reset the events. *)
    let e = List.map (fun (x,_) -> B.Store ([B.Ident x], [B.Bool false])) state.events in
    let rec aux = function
      | [x] -> e@[x]
      | x::xx -> x::(aux xx)
      | [] -> assert false
    in
    aux prog
  in
  let prog = B.Decl ((name, [], emit_type tm.t), prog) in
  let decls = decls@[prog] in

  (* Add state to emitted functions. *)
  let decls =
    let alias_state =
      let f x =
        let s = [B.Load [B.Ident "state"]] in
        let r = [B.Field(s,x)] in
        let r = [B.Address_of r] in
        B.Let (x, r)
      in
      List.map (fun (x,_) -> f x) refs
    in
    let alias_period =
      let s = [B.Load [B.Ident "state"]] in
      let r = [B.Field(s,"period")] in
      B.Let ("period", r)
    in
    let alias_state = alias_period::alias_state in
    List.map
      (function
        | B.Decl ((name, args, t), prog) ->
          B.Decl ((name, ("state", B.T.Ptr state_t)::args, t), alias_state@prog)
        | decl -> decl
      ) decls
  in

  (* Declare generic functions for manipulating state. *)
  let reset =
    List.map
      (fun (x,p) ->
        let s = [B.Load [B.Ident "state"]] in
        let r = [B.Field (s, x)] in
        let r = [B.Address_of r] in
        B.Store (r, p)
      ) refs
  in
  let reset = B.Decl ((name^"_reset", ["state", B.T.Ptr state_t], B.T.Void), reset) in
  let alloc =
    [
      B.Let ("state", [B.Alloc state_t]);
      B.Op (B.Call (name^"_reset"), [|[B.Ident "state"]|]);
      B.Ident "state"
    ]
  in
  let alloc = B.Decl ((name^"_alloc", [], B.T.Ptr state_t), alloc) in
  let free = [B.Free [B.Ident "state"]] in
  let free = B.Decl ((name^"_free", ["state", B.T.Ptr state_t], B.T.Void), free) in

  let ans = state_decl::reset::alloc::free::decls in
  Printf.printf "emitted:\n%s\n\n%!" (B.print_decls ans);
  ans