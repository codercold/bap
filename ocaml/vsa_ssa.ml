(** Value-Set Analysis / Value-Set Arithmetic

    See Gogul Balakrishnan's thesis at
    http://pages.cs.wisc.edu/~bgogul/Research/Thesis/thesis.html

    TODO:
    * Alternate memstore implementation
    * Add a real interface; automatically call simplify_cond
    * Big int support
    * Idea: Use copy propagation information to maintain equivalence
      classes, and use intersection over equivalence class members at
      edge transfer
    * Partial/overlapping memory
    * Special case memory writes of Top: since we will be removing
      entries, we do not have to iterate through all addresses
    * Unified interface to Arithmetic for singleton values
    * Strided-interval aware applicative data type:
      It would store values as strided intervals, rather than
      individual points.
*)

module VM = Var.VarMap

open Big_int_convenience
open Big_int_Z
module CS = Cfg.SSA
open Vsa
open Util
open Type
open Ssa

module D = Debug.Make(struct let name = "Vsa_ssa" and default=`NoDebug end)
open D
module DV = Debug.Make(struct let name = "VsaVerbose_ssa" and default=`NoDebug end)

(* A default stack pointer to put in options so that we can verify the
   user actually changed it to a real one *)
let default_sp = Var.newvar "default_sp" reg_1;;

(* Treat unsigned comparisons the same as signed: should be okay as
   long as overflow does not occur. Should be false for soundness. *)
let signedness_hack = ref true

(* Set memory to top once it surpasses this number of entries *)
let mem_max = ref (Some(1 lsl 16))

module SI = SI
module VS = VS

(** Abstract Store *)
module MemStore = struct
  type aloc = VS.region * big_int
  module M1 = BatMap.Make(struct type t = VS.region let compare = Var.compare end)
  module M2 = BatMap.Make(struct type t = big_int let compare = Big_int_Z.compare_big_int end)

  (** This implementation may change... *)
  type t = VS.t M2.t M1.t


  let top = M1.empty

  (** Fold over all addresses in the MemStore *)
  let fold f ae i =
    M1.fold (fun r m2 a -> M2.fold (fun i vs a -> f (r,i) vs a) m2 a) ae i

  let pp p a =
    p "Memory contents:\n";
    fold (fun (r,i) vs () ->
      let region = if r == VS.global then "$" else Pp.var_to_string r in
      p (Printf.sprintf " %s[%s] -> %s\n" region (~% i) (VS.to_string vs))) a ();
    p "End contents.\n"

  let rec read_concrete k ?o ae (r,i) =
    try
      let v = M2.find i (M1.find r ae) in
      let w = VS.width v in
      assert (w mod 8 = 0);
      if w = k then v
      else (
        (* We wanted to read k bits, but read w instead. Let's try to
           read from i+w/8 and get the rest. *)
        if w > k then
          (* We read too many bytes: use extract *)
          VS.top k
        else
          (* We read too few bytes: use concat
             XXX: Handle address wrap-around properly
          *)
          let rest = read_concrete (k-w) ?o ae (r, i+%((bi w)/% bi8)) in
          (* XXX: Endianness *)
          (* let () = dprintf "Concatenating %Ld %s and %s ->" i (VS.to_string rest) (VS.to_string v) in *)
          VS.concat k rest v)
    with Not_found ->
      VS.top k

  let read k ?o ae = function
    | v when v = VS.empty k -> VS.empty k
    | addrs -> (* FIXME: maybe shortcut this *)
      try
        let res =
          VS.fold
            (fun v a ->
              match a with
            | None -> Some (read_concrete k ?o ae v)
            | Some a ->
              if a = VS.top k then raise Exit
              else
                Some (VS.union (read_concrete k ?o ae v) a)
            ) addrs None
        in
        match res with
        | Some x -> x
        | None -> failwith "MemStore.read impossible address"
      with Exit -> VS.top k

  let widen_region r =
    match !mem_max with
    | Some m ->
      if M2.cardinal r > m then M2.empty
      else r
    | None -> r

  let widen_mem m =
    M1.map (fun r -> widen_region r) m

  let write_concrete_strong k ae (r,i) vl =
    if vl = VS.top k then
      try
        let m2 = M1.find r ae in
        let m2' = M2.remove i m2 in
        if M2.is_empty m2' then M1.remove r ae else M1.add r m2' ae
      with Not_found -> ae
    else
      let m2 = try M1.find r ae with Not_found -> M2.empty in
      (* Don't overwrite the old value if it's the same; this wastes
         memory in the applicative data structure. *)
      if (try M2.find i m2 = vl with Not_found -> false)
      then ae
      else M1.add r (M2.add i vl m2) ae

  let write_concrete_weak k ae addr vl =
    write_concrete_strong k ae addr (VS.union vl (read_concrete k ae addr))

  let write_concrete_intersection k ae addr vl =
    write_concrete_strong k ae addr (VS.intersection vl (read_concrete k ae addr))

  let write_concrete_weak_widen k ae addr vl =
    write_concrete_strong k ae addr (VS.widen vl (read_concrete k ae addr))

  let write k ae addr vl =
    let width = VS.width addr in
    if addr = VS.top width then (
      if vl = VS.top k then top
      else match !mem_max with
      | None -> fold (fun addr v a -> write_concrete_weak k a addr vl) ae ae
      | Some _ -> top
    ) else match addr with
      | [(r, ((k,_,_,_) as o))] when o = SI.top k ->
        (* Set this entire region to Top *)
        M1.remove r ae
      | [(r, (_,z,x,y))] when x = y && z = bi0 ->
        write_concrete_strong k ae (r,x) vl
      | _ ->
        (match !mem_max with
        | Some m ->
          if VS.size k addr > bi m then top
          else widen_mem (VS.fold (fun v a -> write_concrete_weak k a v vl) addr ae)
        | None -> widen_mem (VS.fold (fun v a -> write_concrete_weak k a v vl) addr ae))

  let write_intersection k ae addr vl =
    match addr with
    | [(r, (_,z,x,y))] when x = y && z = bi0 ->
      write_concrete_intersection k ae (r,x) vl
    | _ ->
      (* Since we don't know what location is getting the
         intersection, we can't do anything. *)
      ae

  let equal x y =
    if x == y then true
    else M1.equal (M2.equal (=)) x y

  let merge_region ~inclusive ~f x y =
    if M2.equal (=) x y then x
    else
      M2.merge (fun a v1 v2 -> match v1, v2, inclusive with
      | Some v1, Some v2, _ ->
        (* Note: Value sets are not guaranteed to be the same width *)
        (try Some(f v1 v2)
         with Invalid_argument "bitwidth" -> None)
      | (Some _ as s), None, true
      | None, (Some _ as s), true -> s
      | Some _, None, false
      | None, Some _, false -> None
      | None, None, _ -> None) x y

  let merge_mem ~inclusive ~f =
    M1.merge (fun r v1 v2 -> match v1, v2, inclusive with
    | Some v1, Some v2, _ -> Some (merge_region ~inclusive ~f v1 v2)
    | (Some _ as s), None, true
    | None, (Some _ as s), true -> s
    | Some _, None, false
    | None, Some _, false -> None
    | None, None, _ -> None)

  let intersection (x:t) (y:t) =
    if equal x y then x
    else merge_mem ~inclusive:true ~f:VS.intersection x y

  let union (x:t) (y:t) =
    if equal x y then x
    else merge_mem ~inclusive:false ~f:VS.union x y

  let widen (x:t) (y:t) =
    if equal x y then x
    else merge_mem ~inclusive:true ~f:VS.widen x y

end

(** Abstract Environment *)
module AbsEnv = struct

  type value = [ `Scalar of VS.t | `Array of MemStore.t ]

  (** This implementation may change *)
  type t = value VM.t

  let empty = VM.empty

  let pp_value p = function
    | `Scalar s -> VS.pp p s
    | `Array a -> MemStore.pp p a

  let value_to_string v =
    let b = Buffer.create 57 in
    let p = Buffer.add_string b in
    pp_value p v;
    Buffer.contents b

  let pp p m =
    VM.iter (fun k v ->
      p ("\n " ^ (Pp.var_to_string k) ^ " -> ");
      pp_value p v;
    ) m

  let to_string m =
    let b = Buffer.create 57 in
    let p = Buffer.add_string b in
    pp p m;
    Buffer.contents b

  let value_equal x y = match x,y with
    | (`Scalar x, `Scalar y) -> VS.equal x y
    | (`Array x, `Array y) -> MemStore.equal x y
    | _ -> failwith "value_equal"

  let equal x y =
    if x == y then true
    else VM.equal (value_equal) x y

  let do_find_vs_int ae v =
    match VM.find v ae with
    | `Scalar vs -> vs
    | _ -> failwith "type mismatch"

  let do_find_vs ae v =
    try do_find_vs_int ae v
    with Not_found -> VS.top (bits_of_width (Var.typ v))

  let do_find_vs_opt ae v =
    try Some(do_find_vs_int ae v )
    with Not_found -> None

  (* let astval2vs ae = function *)
  (*   | Int(i,t) -> VS.of_bap_int (int64_of_big_int i) t *)
  (*   | Lab _ -> raise(Unimplemented "No VS for labels (should be a constant)") *)
  (*   | Var v -> do_find_vs ae v *)

  let do_find_ae_int ae v =
    match VM.find v ae with
      | `Array ae -> ae
      | _ -> failwith "type mismatch"

  let do_find_ae ae v =
    try do_find_ae_int ae v
    with Not_found -> MemStore.top

  let do_find_ae_opt ae v =
    try Some(do_find_ae_int ae v)
    with Not_found -> None
end  (* module AE *)

type options = { initial_mem : (addr * char) list;
                 sp : Var.t;
                 mem : Var.t;
               }

(** This does most of VSA, except the loop handling and special dataflow *)
module AlmostVSA =
struct
  module DFP =
  struct
    module CFG = Cfg.SSA
    module L =
    struct
      type t = AbsEnv.t option
      let top = None
      let equal = BatOption.eq ~eq:AbsEnv.equal
      let meet (x:t) (y:t) =
        if equal x y then x
        else match x, y with
        | None, None -> None
        | (Some _ as s), None
        | None, (Some _ as s) -> s
        | Some x, Some y ->
          Some (VM.merge
                  (fun k v1 v2 -> match v1, v2 with
                  | Some (`Scalar a), Some (`Scalar b) -> Some(`Scalar(VS.union a b ))
                  | Some (`Array a), Some (`Array b) -> Some(`Array(MemStore.union a b))
                  | Some (`Scalar _), Some (`Array _)
                  | Some (`Array _), Some (`Scalar _) -> failwith "Tried to meet scalar and array"
                  | (Some _ as sa), None
                  | None, (Some _ as sa) ->
                    (* Defined on one side; undefined on the other -> top
                       for ast vsa.  For ssa vsa, this just means the
                       definition always comes from one particular
                       predecessor, and we can take the defined value,
                       because any merging happens at phi. *)
                    sa
                  | None, None -> None) x y)
      let widen (x:t) (y:t) =
        if equal x y then x
        else match x, y with
        | None, None -> None
        | (Some _ as s), None
        | None, (Some _ as s) -> s
        | Some x, Some y ->
          Some (VM.merge
                  (fun k v1 v2 -> match v1, v2 with
                  | Some (`Scalar a), Some (`Scalar b) -> dprintf "widening %s" (Pp.var_to_string k); Some(`Scalar(VS.widen a b ))
                  | Some (`Array a), Some (`Array b) -> dprintf "widening %s" (Pp.var_to_string k); Some(`Array(MemStore.widen a b))
                  | Some (`Scalar _), Some (`Array _)
                  | Some (`Array _), Some (`Scalar _) -> failwith "Tried to widen scalar and array"
                  | (Some _ as sa), None
                  | None, (Some _ as sa) ->
                    (* Defined on one side; undefined on the other -> top
                       for ast vsa.  For ssa vsa, this just means the
                       definition always comes from one particular
                       predecessor, and we can take the defined value,
                       because any merging happens at phi. *)
                    sa
                  | None, None -> None) x y)

(*      let widen x y =
        let v = widen x y in
        print_string "x\n";
        AbsEnv.pp print_string x;
        print_string "\ny\n";
        AbsEnv.pp print_string y;
        print_string "\nwiden\n";
        AbsEnv.pp print_string v;
        print_string "\n";
        v *) 
    end
    (* VSA optional interface: specify a "real" memory read function *)
    module O = struct
      type t = options
      let default = { initial_mem = [];
                      (* pick something that doesn't make sense so we
                         can make sure the user changed it later *)
                      sp = default_sp;
                      mem = default_sp;
                    }
    end

    let s0 _ _ = CFG.G.V.create Cfg.BB_Entry

    (** Creates a lattice element that maps each of the given variables to
        it's own region. (For use as an inital value in the dataflow problem.)
    *)
    let init_vars vars =
      List.fold_left (fun vm x -> VM.add x (`Scalar [(x, SI.zero (bits_of_width (Var.typ x)))]) vm) AbsEnv.empty vars

    let init_mem vm {initial_mem; mem} =
      let write_mem m (a,v) =
        DV.dprintf "Writing %#x to %s" (Char.code v) (~% a);
        let v = bi (Char.code v) in
        let index_bits = Typecheck.bits_of_width (Typecheck.index_type_of (Var.typ mem)) in
        let value_bits = Typecheck.bits_of_width (Typecheck.value_type_of (Var.typ mem)) in
        if value_bits <> 8
        then failwith "VSA assumes memory is byte addressable";
        MemStore.write 8 m (VS.single index_bits a) (VS.single 8 v)
      in
      let m = List.fold_left write_mem (MemStore.top) initial_mem in
      if Var.equal mem default_sp
      then failwith "Vsa: Non-default memory must be provided";
      VM.add mem (`Array m) vm

    let init ({sp} as o) g : L.t =
      if Var.equal sp default_sp
      then failwith "Vsa: Non-default stack pointer must be given";
      let vm = init_vars [sp] in
      Some(init_mem vm o)

    let dir _ = GraphDataflow.Forward

    let find v l = VM.find v l
    let do_find = AbsEnv.do_find_vs
    let do_find_opt = AbsEnv.do_find_vs_opt
    let do_find_ae = AbsEnv.do_find_ae
    let do_find_ae_opt = AbsEnv.do_find_ae_opt

    (* aev = abstract environment value *)
    let rec exp2vs ?o l e =
      match exp2aev ?o l e with
      | `Scalar vs -> vs
      | _ -> failwith "exp2vs: Expected scalar"
    and exp2aev ?o l e : AbsEnv.value =
      match Typecheck.infer_ssa e with
      | Reg nbits -> (
        let new_vs = try (match e with
          | Int(i,t)->
            VS.of_bap_int i t
          | Lab _ -> raise(Unimplemented "No VS for labels (should be a constant)")
          | Var v -> do_find l v
          | Phi vl -> BatList.reduce VS.union (BatList.filter_map (do_find_opt l) vl)
          | BinOp(op, x, y) ->
            let f = VS.binop_to_vs_function op in
            let k = bits_of_exp x in
            f k (exp2vs ?o l x) (exp2vs ?o l y)
          | UnOp(op, x) ->
            let f = VS.unop_to_vs_function op in
            let k = bits_of_exp x in
            f k (exp2vs ?o l x)
          | Load(Var m, i, _e, t) ->
            (* FIXME: assumes deendianized.
               ie: _e and _t should be the same for all loads and
               stores of m. *)
            DV.dprintf "doing a read from %s" (VS.to_string (exp2vs ?o l i));
            MemStore.read (bits_of_width t) ?o (do_find_ae l m) (exp2vs ?o l i)
          | Cast (ct, t, x) ->
            let f = VS.cast_to_vs_function ct in
            let k = Typecheck.bits_of_width t in
            f k (exp2vs ?o l x)
          | Load _ | Concat _ | Extract _ | Ite _ | Unknown _ | Store _ ->
            raise(Unimplemented "unimplemented expression type"))
          with Unimplemented s | Invalid_argument s -> DV.dprintf "unimplemented %s %s!" s (Pp.ssa_exp_to_string e); VS.top nbits
        in `Scalar new_vs
      )
      | TMem _ | Array _ -> (
        let new_vs = try (match e with
          | Var v ->
            do_find_ae l v
          | Store(Var m,i,v,_e,t) ->
            (* FIXME: assumes deendianized.
               ie: _e and _t should be the same for all loads and
               stores of m. *)
            DV.dprintf "doing a write... to %s of %s." (VS.to_string (exp2vs ?o l i)) (VS.to_string (exp2vs ?o l v));
            (* dprintf "size %#Lx" (VS.numconcrete (exp2vs ?o l i)); *)
            MemStore.write (bits_of_width t)  (do_find_ae l m) (exp2vs ?o l i) (exp2vs ?o l v)
          | Phi vl -> BatList.reduce MemStore.union (BatList.filter_map (do_find_ae_opt l) vl)
          | _ ->
            raise(Unimplemented "unimplemented memory expression type"))
          with Unimplemented _ | Invalid_argument _ -> MemStore.top
        in `Array new_vs
      )

    let get_map = function
      | Some l -> l
      | None -> failwith "Unable to get absenv; this should be impossible!"

    let rec stmt_transfer_function o _ _ s l =
      dprintf "Executing %s" (Pp.ssa_stmt_to_string s);
      match s with
        | Assert(Var _, _)  (* FIXME: Do we want to say v is true? *)
        | Assert _ | Assume _ | Jmp _ | CJmp _ | Label _ | Comment _
        | Halt _ ->
            l
        | Special(_,{Var.defs},_) ->
          let l = get_map l in
          let update_map l v = match v with
            | Var.V(_,_,Reg n) -> VM.add v (`Scalar (VS.top n)) l
            | _ -> l (* Don't try to update memory, you have no idea what's happened *) in
          Some (List.fold_left update_map l defs)
        | Move(v, e, _) ->
          let l = get_map l in
          try
            let new_vs = exp2aev ~o l e in
            if DV.debug () then
            (match new_vs with
            | `Scalar new_vs ->
              DV.dprintf "Assign %s <- %s" (Pp.var_to_string v) (VS.to_string new_vs)
            | _ -> ());
            Some (VM.add v new_vs l)
          with Invalid_argument _ | Not_found ->
            Some l

    let edge_transfer_function o g edge _ l =
      dprintf "edge from %s to %s" (Cfg_ssa.v2s (Cfg.SSA.G.E.src edge)) (Cfg_ssa.v2s (Cfg.SSA.G.E.dst edge));
      let l = get_map l in
      let accept_signed_bop bop =
        match !signedness_hack, bop with
        | false, (SLE|SLT) -> true
        | true, (SLE|SLT|LE|LT) -> true
        | _, _ -> false
      in
      let l = match CFG.G.E.label edge with
      (* Because strided intervals represent signed numbers, we
         cannot convert unsigned inequalities to strided intervals (try
         it). *)
      | Some(_, BinOp(EQ, (BinOp((SLE|SLT|LE|LT) as bop, Var v, Int(i, t)) as be), Int(i', t')))
      | Some(_, BinOp(EQ, (BinOp((SLE|SLT|LE|LT) as bop, Int(i, t), Var v) as be), Int(i', t')))
          when accept_signed_bop bop ->

        let dir = match be with
          | BinOp(_, Var _, Int _) -> `Below
          | BinOp(_, Int _, Var _) -> `Above
          | _ -> failwith "impossible"
        in

        (* Reverse if needed *)
        let e, dir, bop =
          if bi_is_one i' then be, dir, bop
          else
            let newbop = match bop with
              | SLE -> SLT
              | SLT -> SLE
              | LE -> LT
              | LT -> LE
              | _ -> failwith "impossible"
            in
            match dir with
            | `Below -> BinOp(newbop, Int(i, t), Var v), `Above, newbop
            | `Above -> BinOp(newbop, Var v, Int(i, t)), `Below, newbop
        in
        let vsf = match dir, bop with
          | `Below, SLE -> VS.beloweq
          | `Below, LE -> VS.beloweq_unsigned
          | `Below, SLT -> VS.below
          | `Below, LT -> VS.below_unsigned
          | `Above, SLE -> VS.aboveeq
          | `Above, LE -> VS.aboveeq_unsigned
          | `Above, SLT -> VS.above
          | `Above, LT -> VS.above_unsigned
          | _ -> failwith "impossible"
        in
        let vs_v = do_find l v in
        let vs_c = vsf (bits_of_width t) i in
        let vs_int = VS.intersection vs_v vs_c in
        dprintf "%s dst %s vs_v %s vs_c %s vs_int %s" (Pp.var_to_string v) (Cfg_ssa.v2s (CFG.G.E.dst edge)) (VS.to_string vs_v) (VS.to_string vs_c) (VS.to_string vs_int);
        VM.add v (`Scalar vs_int) l
      | Some(_, BinOp(EQ, (BinOp((SLE|SLT|LE|LT) as bop, (Load(Var m, ind, _e, t) as le), Int(i, t')) as be), Int(i', t'')))
      | Some(_, BinOp(EQ, (BinOp((SLE|SLT|LE|LT) as bop, Int(i, t'), (Load(Var m, ind, _e, t) as le)) as be), Int(i', t'')))
          when accept_signed_bop bop ->
        let dir = match be with
          | BinOp(_, Load _, Int _) -> `Below
          | BinOp(_, Int _, Load _) -> `Above
          | _ -> failwith "impossible"
        in

        (* Reverse if needed *)
        let e, dir, bop =
          if bi_is_one i' then be, dir, bop
          else
            let newbop = match bop with
              | SLE -> SLT
              | SLT -> SLE
              | LT -> LE
              | LE -> LT
              | _ -> failwith "impossible"
            in
            match dir with
            | `Below -> BinOp(newbop, Int(i, t), Load(Var m, ind, _e, t)), `Above, newbop
            | `Above -> BinOp(newbop, Load(Var m, ind, _e, t), Int(i, t)), `Below, newbop
        in
        let vsf = match dir, bop with
          | `Below, SLE -> VS.beloweq
          | `Below, LE -> VS.beloweq_unsigned
          | `Below, SLT -> VS.below
          | `Below, LT -> VS.below_unsigned
          | `Above, SLE -> VS.aboveeq
          | `Above, LE -> VS.aboveeq_unsigned
          | `Above, SLT -> VS.above
          | `Above, LT -> VS.above_unsigned
          | _ -> failwith "impossible"
        in
        let vs_v = exp2vs ~o l le in
        let vs_c = vsf (bits_of_width t) i in
        let vs_int = VS.intersection vs_v vs_c in
        dprintf "%s dst %s vs_v %s vs_c %s vs_int %s" (Pp.ssa_exp_to_string le) (Cfg_ssa.v2s (CFG.G.E.dst edge)) (VS.to_string vs_v) (VS.to_string vs_c) (VS.to_string vs_int);
        let orig_mem = do_find_ae l m in
        let new_mem = MemStore.write_intersection (bits_of_width t) orig_mem (exp2vs l ind) vs_int in
        VM.add m (`Array new_mem) l
      | Some(_, BinOp(EQ, (BinOp(EQ|NEQ as bop, Var v, Int(i, t))), Int(i', t')))
      | Some(_, BinOp(EQ, (BinOp(EQ|NEQ as bop, Int(i, t), Var v)), Int(i', t'))) ->

        (* We can make a SI for equality, but not for not for
           inequality *)
        let vs_c =
          let s = VS.of_bap_int i t in
          match bop with
          | EQ when i' = bi1 -> s
          | NEQ when i' = bi0 -> s
          | _ -> VS.top (bits_of_width t)
        in

        let vs_v = do_find l v in
        let vs_int = VS.intersection vs_v vs_c in
        dprintf "%s dst %s vs_v %s vs_c %s vs_int %s" (Pp.var_to_string v) (Cfg_ssa.v2s (CFG.G.E.dst edge)) (VS.to_string vs_v) (VS.to_string vs_c) (VS.to_string vs_int);
        VM.add v (`Scalar vs_int) l

      | Some(_, BinOp((SLT|SLE), Var v2, Var v1)) ->
        (* XXX: Can we do something different for SLT? *)
        let vs_v1 = do_find l v1
        and vs_v2 = do_find l v2 in
        let vs_lb = VS.remove_upper_bound vs_v2
        and vs_ub = VS.remove_lower_bound vs_v1 in
        let vs_v1 = VS.intersection vs_v1 vs_lb
        and vs_v2 = VS.intersection vs_v2 vs_ub in
        let l = VM.add v1 (`Scalar vs_v1) l in
        VM.add v2 (`Scalar vs_v2) l
      | Some(_, e) -> dprintf "no edge match %s" (Pp.ssa_exp_to_string e); l
      | _ -> l
      in Some l

  end

  module DF = CfgDataflow.MakeWide(DFP)

end

let prepare_ssa_indirect ?vs ssacfg =

  let jumpe g v =
    match List.rev (CS.get_stmts g v) with
    | Ssa.Jmp(e, _)::_ -> e
    | _ -> failwith "jumpe: Unable to find jump"
  in

  let vs = match vs with
    | Some vs -> vs
    | None ->
      CS.G.fold_vertex (fun v l ->
        match List.rev (CS.get_stmts ssacfg v) with
        | Jmp(e, _)::_ when Ssa.lab_of_exp e = None -> v::l
        | _ -> l
      ) ssacfg []
  in

  (* Start by converting to SSA three address code. *)
  let ssacfg = Cfg_ssa.do_tac_ssacfg ssacfg in
  (* Cfg_pp.SsaStmtsDot.output_graph (open_out "vsapre.dot") ssacfg; *)

  (* Do an initial optimization pass.  This is important so that
     simplifycond_ssa can recognize syntactically equal
     computations. *)
  let ssacfg = Ssa_simp.simp_cfg ssacfg in

  (* Simplify the SSA conditions so they can be parsed by VSA *)

  (* Get ssa expression *)
  let get_ssae = jumpe ssacfg in
  let ssaes = List.map get_ssae vs in
  let ssacfg = Ssa_cond_simplify.simplifycond_targets_ssa ssaes ssacfg in
  (* Cfg_pp.SsaStmtsDot.output_graph (open_out "vsacond.dot") ssacfg; *)

  (* Redo TAC so that we can simplify the SSA conditions. This
     should ensure that all variables are their canonical form.  This
     is important so that the edge conditions are consistent with the
     rest of the program. *)
  let ssacfg = Cfg_ssa.do_tac_ssacfg ssacfg in
  (* Cfg_pp.SsaStmtsDot.output_graph (open_out "vsatac.dot") ssacfg; *)

  (* Simplify. *)
  let ssacfg = Ssa_simp.simp_cfg ssacfg in
  (* Cfg_pp.SsaStmtsDot.output_graph (open_out "vsasimp.dot") ssacfg; *)

  (* Now our edge conditions look like (Var temp).  We need to use
     shadow copy propagation to convert them to something like (EAX
     < 10). *)

  (* XXX: Should this go elsewhere? *)
  let fix_edges g =
    let _, m, _ = Copy_prop.copyprop_ssa g in
    CS.G.fold_edges_e
      (fun e g ->
        match CS.G.E.label e with
        | None -> g
        | Some(b, Ssa.BinOp(EQ, Ssa.Var v, e2)) ->
          (try let cond = Some(b, Ssa.BinOp(EQ, VM.find v m, e2)) in
               let src = CS.G.E.src e in
               let dst = CS.G.E.dst e in
               let e' = CS.G.E.create src cond dst in
               CS.add_edge_e (CS.remove_edge_e g e) e'
           with Not_found -> g)
        | Some(_, e) -> (* Sometimes we might see a constant like true/false *) g
      ) g g
  in

  let ssacfg = fix_edges ssacfg in

  let ssacfg = Coalesce.coalesce_ssa ~nocoalesce:vs ssacfg in
  (* Cfg_pp.SsaStmtsDot.output_graph (open_out "vsafinal.dot") ssacfg; *)

  ssacfg

let exp2vs = AlmostVSA.DFP.exp2vs ?o:None

(* Main vsa interface *)
let vsa ?nmeets opts g =
  Checks.connected_ssacfg g "VSA";
  AlmostVSA.DF.worklist_iterate_widen_stmt ?nmeets ~opts g

let last_loc = AlmostVSA.DF.last_loc

let build_default_arch_options arch =
  {
    initial_mem = [];
    sp=Arch.sp_of_arch arch;
    mem=Arch.mem_of_arch arch;
  }

let build_default_prog_options asmp =
  let x = build_default_arch_options (Asmir.get_asmprogram_arch asmp) in
  { x with initial_mem=Asmir.get_readable_mem_contents_list asmp
  }
