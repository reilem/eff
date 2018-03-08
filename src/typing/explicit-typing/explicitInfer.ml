module T = Type
module Typed = Typed
module Untyped = CoreSyntax
module TyParamSet = Set.Make (Params.Ty)
module DirtVarSet = Set.Make (Params.Dirt)

type state =
  { context: TypingEnv.t
  ; effects: (Types.target_ty * Types.target_ty) Untyped.EffectMap.t }

let empty = {context= TypingEnv.empty; effects= CoreSyntax.EffectMap.empty}

let ty_of_const = function
  | Const.Integer _ -> Type.int_ty
  | Const.String _ -> Type.string_ty
  | Const.Boolean _ -> Type.bool_ty
  | Const.Float _ -> Type.float_ty


let add_effect env eff (ty1, ty2) =
  {env with effects= Untyped.EffectMap.add eff (ty1, ty2) env.effects}


let add_def env x ty_sch =
  {env with context= TypingEnv.update env.context x ty_sch}


let apply_sub_to_env env sub =
  {env with context= TypingEnv.apply_sub env.context sub}


let rec source_to_target ty =
  match ty with
  | T.Apply (ty_name, []) -> source_to_target (T.Basic ty_name)
  | T.Apply (_, _) -> assert false
  | T.TyParam p -> Types.TyParam p
  | T.Basic s -> (
    match s with
    | "int" -> Types.PrimTy IntTy
    | "string" -> Types.PrimTy StringTy
    | "bool" -> Types.PrimTy BoolTy
    | "float" -> Types.PrimTy FloatTy )
  | T.Tuple l -> Types.Tuple (List.map source_to_target l)
  | T.Arrow (ty, dirty) ->
      Types.Arrow (source_to_target ty, source_to_target_dirty dirty)
  | T.Handler {value= dirty1; finally= dirty2} ->
      Types.Handler
        (source_to_target_dirty dirty1, source_to_target_dirty dirty2)


and source_to_target_dirty ty = (source_to_target ty, Types.empty_dirt)

let rec type_pattern p =
  { Typed.term= type_plain_pattern p.Untyped.term
  ; Typed.location= p.Untyped.location }


and type_plain_pattern = function
  | Untyped.PVar x -> Typed.PVar x
  | Untyped.PAs (p, x) -> Typed.PAs (type_pattern p, x)
  | Untyped.PNonbinding -> Typed.PNonbinding
  | Untyped.PConst const -> Typed.PConst const
  | Untyped.PTuple ps -> Typed.PTuple (List.map type_pattern ps)
  | Untyped.PRecord [] -> assert false
  | Untyped.PRecord ((fld, _) :: _ as lst) ->
      assert false
      (* in fact it is not yet implemented, but assert false gives us source location automatically *)
  | Untyped.PVariant (lbl, p) -> assert false


(* in fact it is not yet implemented, but assert false gives us source location automatically *)
(*

     ===========================
     Q; Γ ⊢ p : A ~> p' ⊣ Γ'; Q' 
     ===========================

  ---------------------------------
  Q; Γ ⊢ x : A ~> x ⊣ Γ,x:α; Q

  ---------------------------------
  Q; Γ ⊢ _ : A ~> _ ⊣ Γ; Q

  ⊢ c : B
  ------------------------------------ [we don't use ω, we just force the types to be equal]
  Q; Γ ⊢ c : A ~> c ⊣ Γ; Q, ω : B <: A

 *)
and type_pattern' in_cons st pat ty =
  let pat', st', out_cons =
    type_plain_pattern' in_cons st pat.Untyped.term ty
  in
  ({Typed.term= pat'; Typed.location= pat.Untyped.location}, st', out_cons)


and type_plain_pattern' in_cons st pat ty =
  match pat with
  | Untyped.PVar x ->
      let st' = add_def st x ty in
      (Typed.PVar x, st', in_cons)
  | Untyped.PNonbinding -> (Typed.PNonbinding, st, in_cons)
  | Untyped.PAs (p, v) -> assert false
  | Untyped.PTuple l -> assert false
  | Untyped.PRecord r -> assert false
  | Untyped.PVariant (l, p) -> assert false
  | Untyped.PConst c ->
      let ty_c = source_to_target (ty_of_const c) in
      let _omega, q = Typed.fresh_ty_coer (ty_c, ty) in
      (Typed.PConst c, st, q :: in_cons)


let extend_env vars env =
  List.fold_right
    (fun (x, ty_sch) env ->
      {env with context= TypingEnv.update env.context x ty_sch} )
    vars env


let print_env env =
  List.map
    (fun (x, ty_sch) ->
      Print.debug "%t : %t" (Typed.print_variable x)
        (Types.print_target_ty ty_sch) )
    env


let rec get_skel_vars_from_constraints = function
  | [] -> []
  | (Typed.TyParamHasSkel (_, Types.SkelParam sv)) :: xs ->
      sv :: get_skel_vars_from_constraints xs
  | _ :: xs -> get_skel_vars_from_constraints xs


let constraint_free_ty_vars = function
  | Typed.TyOmega (_, (Types.TyParam a, Types.TyParam b)) ->
      TyParamSet.of_list [a; b]
  | Typed.TyOmega (_, (Types.TyParam a, _)) -> TyParamSet.singleton a
  | Typed.TyOmega (_, (_, Types.TyParam a)) -> TyParamSet.singleton a
  | _ -> TyParamSet.empty


let constraint_free_row_vars = function
  | Types.ParamRow p -> DirtVarSet.singleton p
  | Types.EmptyRow -> DirtVarSet.empty


let constraint_free_dirt_vars = function
  | Typed.DirtOmega (_, (drt1, drt2)) ->
      DirtVarSet.union
        (constraint_free_row_vars drt1.Types.row)
        (constraint_free_row_vars drt2.Types.row)


let rec free_ty_vars_ty = function
  | Types.TyParam x -> [x]
  | Types.Arrow (a, c) -> free_ty_vars_ty a @ free_ty_var_dirty c
  | Types.Tuple tup -> List.flatten (List.map free_ty_vars_ty tup)
  | Types.Handler (c1, c2) -> free_ty_var_dirty c1 @ free_ty_var_dirty c2
  | Types.PrimTy _ -> []
  | Types.QualTy (_, a) -> free_ty_vars_ty a
  | Types.QualDirt (_, a) -> free_ty_vars_ty a
  | Types.TySchemeTy (ty_param, _, a) ->
      let free_a = free_ty_vars_ty a in
      List.filter (fun x -> not (List.mem x [ty_param])) free_a
  | Types.TySchemeDirt (dirt_param, a) -> free_ty_vars_ty a


and free_ty_var_dirty (a, _) = free_ty_vars_ty a

let rec free_dirt_vars_ty = function
  | Types.Arrow (a, c) -> free_dirt_vars_ty a @ free_dirt_vars_dirty c
  | Types.Tuple tup -> List.flatten (List.map free_dirt_vars_ty tup)
  | Types.Handler (c1, c2) -> free_dirt_vars_dirty c1 @ free_dirt_vars_dirty c2
  | Types.QualTy (_, a) -> free_dirt_vars_ty a
  | Types.QualDirt (_, a) -> free_dirt_vars_ty a
  | Types.TySchemeTy (ty_param, _, a) -> free_dirt_vars_ty a
  | Types.TySchemeDirt (dirt_param, a) ->
      let free_a = free_dirt_vars_ty a in
      List.filter (fun x -> not (List.mem x [dirt_param])) free_a
  | _ -> []


and free_dirt_vars_dirty (a, d) = free_dirt_vars_dirt d

and free_dirt_vars_dirt drt =
  DirtVarSet.elements (constraint_free_row_vars drt.Types.row)


let rec state_free_ty_vars st =
  List.fold_right
    (fun (_, ty) acc -> List.append (free_ty_vars_ty ty) acc)
    st []


let rec state_free_dirt_vars st =
  List.fold_right
    (fun (_, ty) acc -> List.append (free_dirt_vars_ty ty) acc)
    st []


(* free dirt variables in target terms *)

let rec free_dirt_vars_expression e =
  match e.Typed.term with
  | Typed.Var _ -> []
  | Typed.BuiltIn _ -> []
  | Typed.Const _ -> []
  | Typed.Tuple es -> List.concat (List.map free_dirt_vars_expression es)
  | Typed.Record _ -> assert false
  | Typed.Variant _ -> assert false
  | Typed.Lambda (pat, ty, c) ->
      free_dirt_vars_ty ty @ free_dirt_vars_computation c
  | Typed.Effect _ -> []
  | Typed.Handler h -> free_dirt_vars_abstraction_with_ty h.value_clause
  | Typed.BigLambdaTy (tp, sk, e) -> free_dirt_vars_expression e
  | Typed.BigLambdaDirt (dp, e) ->
      List.filter (fun x -> not (x == dp)) (free_dirt_vars_expression e)
  | Typed.BigLambdaSkel (skp, e) -> free_dirt_vars_expression e
  | Typed.CastExp (e, tc) ->
      free_dirt_vars_expression e @ free_dirt_vars_ty_coercion tc
  | Typed.ApplyTyExp (e, ty) ->
      free_dirt_vars_expression e @ free_dirt_vars_ty ty
  | Typed.LambdaTyCoerVar (tcp, ctty, e) -> free_dirt_vars_expression e
  | Typed.LambdaDirtCoerVar (dcp, ctd, e) -> free_dirt_vars_expression e
  | Typed.ApplyDirtExp (e, d) ->
      free_dirt_vars_expression e @ free_dirt_vars_dirt d
  | Typed.ApplySkelExp (e, sk) -> free_dirt_vars_expression e
  | Typed.ApplyTyCoercion (e, tc) ->
      free_dirt_vars_expression e @ free_dirt_vars_ty_coercion tc
  | Typed.ApplyDirtCoercion (e, dc) ->
      free_dirt_vars_expression e @ free_dirt_vars_dirt_coercion dc


and free_dirt_vars_computation c =
  match c.Typed.term with
  | Typed.Value e -> free_dirt_vars_expression e
  | Typed.LetVal (e, (p, ty, c)) ->
      free_dirt_vars_expression e @ free_dirt_vars_computation c
  | Typed.LetRec _ -> assert false
  | Typed.Match (e, cases) ->
      free_dirt_vars_expression e
      @ List.concat (List.map free_dirt_vars_abstraction cases)
  | Typed.Apply (e1, e2) ->
      free_dirt_vars_expression e1 @ free_dirt_vars_expression e2
  | Typed.Handle (e, c) ->
      free_dirt_vars_expression e @ free_dirt_vars_computation c
  | Typed.Call (_, e, awty) -> assert false
  | Typed.Op (_, e) -> free_dirt_vars_expression e
  | Typed.Bind (c, a) ->
      free_dirt_vars_computation c @ free_dirt_vars_abstraction a
  | Typed.CastComp (c, dc) ->
      free_dirt_vars_computation c @ free_dirt_vars_dirty_coercion dc
  | Typed.CastComp_ty (c, tc) ->
      free_dirt_vars_computation c @ free_dirt_vars_ty_coercion tc
  | Typed.CastComp_dirt (c, dc) ->
      free_dirt_vars_computation c @ free_dirt_vars_dirt_coercion dc


and free_dirt_vars_abstraction {term= _, c} = free_dirt_vars_computation c

and free_dirt_vars_abstraction_with_ty {term= _, ty, c} =
  free_dirt_vars_ty ty @ free_dirt_vars_computation c


and free_dirt_vars_ty_coercion = function
  | Typed.ReflTy ty -> free_dirt_vars_ty ty
  | Typed.ArrowCoercion (tc, dc) ->
      free_dirt_vars_ty_coercion tc @ free_dirt_vars_dirty_coercion dc
  | Typed.HandlerCoercion (dc1, dc2) ->
      free_dirt_vars_dirty_coercion dc1 @ free_dirt_vars_dirty_coercion dc2
  | Typed.TyCoercionVar tcp -> []
  | Typed.SequenceTyCoer (tc1, tc2) ->
      free_dirt_vars_ty_coercion tc1 @ free_dirt_vars_ty_coercion tc2
  | Typed.TupleCoercion tcs ->
      List.flatten (List.map free_dirt_vars_ty_coercion tcs)
  | Typed.LeftArrow tc -> free_dirt_vars_ty_coercion tc
  | Typed.ForallTy (_, tc) -> free_dirt_vars_ty_coercion tc
  | Typed.ApplyTyCoer (tc, ty) ->
      free_dirt_vars_ty_coercion tc @ free_dirt_vars_ty ty
  | Typed.ForallDirt (dp, tc) ->
      List.filter (fun x -> not (x == dp)) (free_dirt_vars_ty_coercion tc)
  | Typed.ApplyDirCoer (tc, d) ->
      free_dirt_vars_ty_coercion tc @ free_dirt_vars_dirt d
  | Typed.PureCoercion dc -> free_dirt_vars_dirty_coercion dc
  | Typed.QualTyCoer (ctty, tc) -> free_dirt_vars_ty_coercion tc
  | Typed.QualDirtCoer (ctd, tc) -> free_dirt_vars_ty_coercion tc
  | Typed.ApplyQualTyCoer (tc1, tc2) ->
      free_dirt_vars_ty_coercion tc1 @ free_dirt_vars_ty_coercion tc2
  | Typed.ApplyQualDirtCoer (tc, dc) ->
      free_dirt_vars_ty_coercion tc @ free_dirt_vars_dirt_coercion dc
  | Typed.ForallSkel (skp, tc) -> free_dirt_vars_ty_coercion tc
  | Typed.ApplySkelCoer (tc, sk) -> free_dirt_vars_ty_coercion tc


and free_dirt_vars_dirt_coercion = function
  | Typed.ReflDirt d -> free_dirt_vars_dirt d
  | Typed.DirtCoercionVar dcv -> []
  | Typed.Empty d -> free_dirt_vars_dirt d
  | Typed.UnionDirt (_, dc) -> free_dirt_vars_dirt_coercion dc
  | Typed.SequenceDirtCoer (dc1, dc2) ->
      free_dirt_vars_dirt_coercion dc1 @ free_dirt_vars_dirt_coercion dc2
  | Typed.DirtCoercion dc -> free_dirt_vars_dirty_coercion dc


and free_dirt_vars_dirty_coercion = function
  | Typed.BangCoercion (tc, dc) ->
      free_dirt_vars_ty_coercion tc @ free_dirt_vars_dirt_coercion dc
  | Typed.RightArrow tc -> free_dirt_vars_ty_coercion tc
  | Typed.RightHandler tc -> free_dirt_vars_ty_coercion tc
  | Typed.LeftHandler tc -> free_dirt_vars_ty_coercion tc
  | Typed.SequenceDirtyCoer (dc1, dc2) ->
      free_dirt_vars_dirty_coercion dc1 @ free_dirt_vars_dirty_coercion dc2


(* ... *)

let splitter st constraints simple_ty =
  Print.debug "Splitter Input Constraints: " ;
  Unification.print_c_list constraints ;
  Print.debug "Splitter Input Ty: %t" (Types.print_target_ty simple_ty) ;
  Print.debug "Splitter Env :" ;
  print_env st ;
  let skel_list = OldUtils.uniq (get_skel_vars_from_constraints constraints) in
  let simple_ty_freevars_ty = TyParamSet.of_list (free_ty_vars_ty simple_ty) in
  Print.debug "Simple type free vars: " ;
  List.iter
    (fun x -> Print.debug "%t" (Params.Ty.print x))
    (free_ty_vars_ty simple_ty) ;
  let simple_ty_freevars_dirt =
    DirtVarSet.of_list (free_dirt_vars_ty simple_ty)
  in
  let state_freevars_ty = TyParamSet.of_list (state_free_ty_vars st) in
  Print.debug "state free vars: " ;
  List.iter
    (fun x -> Print.debug "%t" (Params.Ty.print x))
    (state_free_ty_vars st) ;
  let state_freevars_dirt = DirtVarSet.of_list (state_free_dirt_vars st) in
  let local_cons =
    List.filter
      (fun cons ->
        let cons_freevars_ty = constraint_free_ty_vars cons in
        let cons_freevars_dirt = constraint_free_dirt_vars cons in
        let is_sub_ty =
          TyParamSet.subset cons_freevars_ty state_freevars_ty
          || TyParamSet.equal cons_freevars_ty state_freevars_ty
        in
        let is_sub_dirt =
          DirtVarSet.subset cons_freevars_dirt state_freevars_dirt
          || DirtVarSet.equal cons_freevars_dirt state_freevars_dirt
        in
        not (is_sub_ty && is_sub_dirt) )
      constraints
  in
  let constraints_freevars_ty =
    List.fold_right
      (fun cons acc -> TyParamSet.union (constraint_free_ty_vars cons) acc)
      constraints TyParamSet.empty
  in
  let constraints_freevars_dirt =
    List.fold_right
      (fun cons acc -> DirtVarSet.union (constraint_free_dirt_vars cons) acc)
      constraints DirtVarSet.empty
  in
  let alpha_list =
    TyParamSet.elements
      (TyParamSet.diff
         (TyParamSet.union constraints_freevars_ty simple_ty_freevars_ty)
         state_freevars_ty)
  in
  let delta_list =
    DirtVarSet.elements
      (DirtVarSet.diff
         (DirtVarSet.union constraints_freevars_dirt simple_ty_freevars_dirt)
         state_freevars_dirt)
  in
  let global_cons' = OldUtils.diff constraints local_cons in
  let global_cons =
    List.filter
      (fun c ->
        match c with
        | Typed.TyParamHasSkel (tyvar, skvar) ->
            not (List.mem tyvar alpha_list)
        | _ -> true )
      global_cons'
  in
  Print.debug "Splitter output free_ty_vars: " ;
  List.iter (fun x -> Print.debug "%t" (Params.Ty.print x)) alpha_list ;
  Print.debug "Splitter output free_dirt_vars: " ;
  List.iter (fun x -> Print.debug "%t" (Params.Dirt.print x)) delta_list ;
  Print.debug "Splitter global constraints list :" ;
  Unification.print_c_list local_cons ;
  Print.debug "Splitter global constraints list :" ;
  Unification.print_c_list global_cons ;
  (skel_list, alpha_list, delta_list, local_cons, global_cons)


let rec get_sub_of_ty ty_sch =
  match ty_sch with
  | Types.TySchemeSkel (s, t) ->
      let new_s = Params.Skel.fresh () in
      let skels, tys, dirts = get_sub_of_ty t in
      ((s, new_s) :: skels, tys, dirts)
  | Types.TySchemeTy (p, _, t) ->
      let new_p = Params.Ty.fresh () in
      let skels, tys, dirts = get_sub_of_ty t in
      (skels, (p, new_p) :: tys, dirts)
  | Types.TySchemeDirt (p, t) ->
      let new_p = Params.Dirt.fresh () in
      let skels, tys, dirts = get_sub_of_ty t in
      (skels, tys, (p, new_p) :: dirts)
  | _ -> ([], [], [])


let rec get_basic_type ty_sch =
  match ty_sch with
  | Types.TySchemeSkel (_, t) -> get_basic_type t
  | Types.TySchemeTy (typ, sk, t) ->
      let a, b = get_basic_type t in
      ((typ, sk) :: a, b)
  | Types.TySchemeDirt (_, t) -> get_basic_type t
  | Types.QualTy (_, t) -> get_basic_type t
  | Types.QualDirt (_, t) -> get_basic_type t
  | t -> ([], t)


let rec apply_sub_to_type ty_subs dirt_subs ty =
  match ty with
  | Types.TyParam p -> (
    match OldUtils.lookup p ty_subs with
    | Some p' -> Types.TyParam p'
    | None -> ty )
  | Types.Arrow (a, (b, d)) ->
      Types.Arrow
        ( apply_sub_to_type ty_subs dirt_subs a
        , (apply_sub_to_type ty_subs dirt_subs b, apply_sub_to_dirt dirt_subs d)
        )
  | Types.Tuple ty_list ->
      Types.Tuple
        (List.map (fun x -> apply_sub_to_type ty_subs dirt_subs x) ty_list)
  | Types.Handler ((a, b), (c, d)) ->
      Types.Handler
        ( (apply_sub_to_type ty_subs dirt_subs a, apply_sub_to_dirt dirt_subs b)
        , (apply_sub_to_type ty_subs dirt_subs c, apply_sub_to_dirt dirt_subs d)
        )
  | Types.PrimTy _ -> ty
  | _ -> assert false


and apply_sub_to_dirt dirt_subs drt =
  match drt.row with
  | Types.ParamRow p -> (
    match OldUtils.lookup p dirt_subs with
    | Some p' -> {drt with row= Types.ParamRow p'}
    | None -> drt )
  | Types.EmptyRow -> drt


let rec get_applied_cons_from_ty ty_subs dirt_subs ty =
  match ty with
  | Types.TySchemeTy (_, _, t) -> get_applied_cons_from_ty ty_subs dirt_subs t
  | Types.TySchemeDirt (_, t) -> get_applied_cons_from_ty ty_subs dirt_subs t
  | Types.QualTy (cons, t) ->
      let c1, c2 = get_applied_cons_from_ty ty_subs dirt_subs t in
      let ty1, ty2 = cons in
      let newty1, newty2 =
        ( apply_sub_to_type ty_subs dirt_subs ty1
        , apply_sub_to_type ty_subs dirt_subs ty2 )
      in
      let new_omega = Params.TyCoercion.fresh () in
      let new_cons = Typed.TyOmega (new_omega, (newty1, newty2)) in
      (new_cons :: c1, c2)
  | Types.QualDirt (cons, t) ->
      let c1, c2 = get_applied_cons_from_ty ty_subs dirt_subs t in
      let ty1, ty2 = cons in
      let newty1, newty2 =
        (apply_sub_to_dirt dirt_subs ty1, apply_sub_to_dirt dirt_subs ty2)
      in
      let new_omega = Params.DirtCoercion.fresh () in
      let new_cons = Typed.DirtOmega (new_omega, (newty1, newty2)) in
      (c1, new_cons :: c2)
  | _ -> ([], [])


let rec get_skel_constraints alphas_has_skels ty_subs skel_subs =
  match alphas_has_skels with
  | (tvar, skel) :: ss ->
      let new_skel = Unification.apply_substitution_skel skel_subs skel in
      let Some new_tyvar = OldUtils.lookup tvar ty_subs in
      Typed.TyParamHasSkel (new_tyvar, new_skel)
      :: get_skel_constraints ss ty_subs skel_subs
  | [] -> []


let apply_types alphas_has_skels skel_subs ty_subs dirt_subs var ty_sch =
  let new_skel_subs =
    List.map
      (fun (a, b) -> Unification.SkelParamToSkel (a, Types.SkelParam b))
      skel_subs
  in
  let skel_constraints =
    get_skel_constraints alphas_has_skels ty_subs new_skel_subs
  in
  let skel_apps =
    List.fold_left
      (fun a (_, b) ->
        Typed.annotate (Typed.ApplySkelExp (a, Types.SkelParam b))
          Location.unknown )
      (Typed.annotate (Typed.Var var) Location.unknown)
      skel_subs
  in
  let ty_apps =
    List.fold_left
      (fun a (_, b) ->
        Typed.annotate (Typed.ApplyTyExp (a, Types.TyParam b)) Location.unknown
        )
      skel_apps ty_subs
  in
  let dirt_apps =
    List.fold_left
      (fun a (_, b) ->
        Typed.annotate (Typed.ApplyDirtExp (a, Types.no_effect_dirt b))
          Location.unknown )
      ty_apps dirt_subs
  in
  let ty_cons, dirt_cons = get_applied_cons_from_ty ty_subs dirt_subs ty_sch in
  let ty_cons_apps =
    List.fold_left
      (fun a (Typed.TyOmega (omega, _)) ->
        Typed.annotate (Typed.ApplyTyCoercion (a, Typed.TyCoercionVar omega))
          Location.unknown )
      dirt_apps ty_cons
  in
  let dirt_cons_apps =
    List.fold_left
      (fun a (Typed.DirtOmega (omega, _)) ->
        Typed.annotate
          (Typed.ApplyDirtCoercion (a, Typed.DirtCoercionVar omega))
          Location.unknown )
      ty_cons_apps dirt_cons
  in
  (dirt_cons_apps, skel_constraints @ ty_cons @ dirt_cons)


let rec type_expr in_cons st ({Untyped.term= expr; Untyped.location= loc} as e) =
  Print.debug "type_expr: %t" (CoreSyntax.print_expression e) ;
  Print.debug "### Constraints Before ###" ;
  Unification.print_c_list in_cons ;
  Print.debug "##########################" ;
  let e, ttype, constraints, sub_list = type_plain_expr in_cons st expr in
  Print.debug "### Constraints After ####" ;
  Unification.print_c_list constraints ;
  Print.debug "##########################" ;
  (Typed.annotate e loc, ttype, constraints, sub_list)


and type_plain_expr in_cons st = function
  | Untyped.Var x -> (
    match TypingEnv.lookup st.context x with
    | Some ty_schi ->
        let bind_skelvar_sub, bind_tyvar_sub, bind_dirtvar_sub =
          get_sub_of_ty ty_schi
        in
        Print.debug "in Var" ;
        Print.debug " var : %t" (Typed.print_variable x) ;
        Print.debug " typeSch: %t " (Types.print_target_ty ty_schi) ;
        let alphas_has_skels, basic_type = get_basic_type ty_schi in
        Print.debug "basicTy: %t" (Types.print_target_ty basic_type) ;
        let applied_basic_type =
          apply_sub_to_type bind_tyvar_sub bind_dirtvar_sub basic_type
        in
        let returned_x, returnd_cons =
          apply_types alphas_has_skels bind_skelvar_sub bind_tyvar_sub
            bind_dirtvar_sub x ty_schi
        in
        Print.debug "returned: %t" (Typed.print_expression returned_x) ;
        Print.debug "returned_type: %t"
          (Types.print_target_ty applied_basic_type) ;
        (returned_x.term, applied_basic_type, returnd_cons @ in_cons, [])
    | None ->
        assert false
        (* in fact it is not yet implemented, but assert false gives us source location automatically *)
    )
  | Untyped.Const const -> (
    match const with
    | Integer _ -> (Typed.Const const, Types.PrimTy IntTy, in_cons, [])
    | String _ -> (Typed.Const const, Types.PrimTy StringTy, in_cons, [])
    | Boolean _ -> (Typed.Const const, Types.PrimTy BoolTy, in_cons, [])
    | Float _ -> (Typed.Const const, Types.PrimTy FloatTy, in_cons, []) )
  | Untyped.Tuple es ->
      let target_list = List.map (type_expr in_cons st) es in
      let target_terms =
        Typed.Tuple
          (List.fold_right (fun (x, _, _, _) xs -> x :: xs) target_list [])
      in
      let target_types =
        Types.Tuple
          (List.fold_right (fun (_, x, _, _) xs -> x :: xs) target_list [])
      in
      let target_cons =
        List.fold_right
          (fun (_, _, x, _) xs -> List.append x xs)
          target_list []
      in
      let target_sub =
        List.fold_right
          (fun (_, _, _, x) xs -> List.append x xs)
          target_list []
      in
      (target_terms, target_types, in_cons @ target_cons, target_sub)
  | Untyped.Record lst ->
      assert false
      (* in fact it is not yet implemented, but assert false gives us source location automatically *)
  | Untyped.Variant (lbl, e) ->
      assert false
      (* in fact it is not yet implemented, but assert false gives us source location automatically *)
  | Untyped.Lambda a ->
      Print.debug "in infer lambda" ;
      let p, c = a in
      let in_ty, in_ty_skel = Typed.fresh_ty_with_skel () in
      let new_in_cons = in_ty_skel :: in_cons in
      let Untyped.PVar x = p.Untyped.term in
      let target_pattern = type_pattern p in
      let new_st = add_def st x in_ty in
      let target_comp_term, target_comp_ty, target_comp_cons, target_comp_sub =
        type_comp new_in_cons new_st c
      in
      let target_ty =
        Types.Arrow
          ( Unification.apply_substitution_ty target_comp_sub in_ty
          , target_comp_ty )
      in
      let target_lambda =
        Typed.Lambda
          ( target_pattern
          , Unification.apply_substitution_ty target_comp_sub in_ty
          , target_comp_term )
      in
      Unification.print_c_list target_comp_cons ;
      Print.debug "lambda ty: %t" (Types.print_target_ty target_ty) ;
      (target_lambda, target_ty, target_comp_cons, target_comp_sub)
  | Untyped.Effect eff ->
      let in_ty, out_ty = Untyped.EffectMap.find eff st.effects in
      let s = Types.EffectSet.singleton eff in
      ( Typed.Effect (eff, (in_ty, out_ty))
      , Types.Arrow (in_ty, (out_ty, Types.closed_dirt s))
      , in_cons
      , [] )
  | Untyped.Handler h ->
      let out_dirt_var = Params.Dirt.fresh () in
      let in_dirt = Types.fresh_dirt ()
      and out_dirt = Types.no_effect_dirt out_dirt_var
      and in_ty, skel_cons_in = Typed.fresh_ty_with_skel ()
      and out_ty, skel_cons_out = Typed.fresh_ty_with_skel () in
      let target_type = Types.Handler ((in_ty, in_dirt), (out_ty, out_dirt)) in
      let r_ty, r_ty_skel_cons = Typed.fresh_ty_with_skel () in
      let r_cons = r_ty_skel_cons :: in_cons in
      let pr, cr = h.value_clause in
      let Untyped.PVar x = pr.Untyped.term in
      let r_st = add_def st x r_ty in
      let ( target_cr_term
          , (target_cr_ty, target_cr_dirt)
          , target_cr_cons
          , target_cr_sub ) =
        type_comp r_cons r_st cr
      in
      let r_subbed_st = apply_sub_to_env st target_cr_sub in
      let folder 
          (*
          (acc_terms, acc_tys, acc_st, acc_cons, acc_subs, acc_alpha_delta_i)
          (eff, abs2) =
   *)
          (eff, abs2)
          (acc_terms, acc_tys, acc_st, acc_cons, acc_subs, acc_alpha_delta_i) =
        let ( typed_c_op
            , typed_co_op_ty
            , s_st
            , co_op_cons
            , c_op_sub
            , (alpha_i, delta_i) ) =
          Print.debug "get_handler_op_clause: %t"
            (CoreSyntax.abstraction2 abs2) ;
          get_handler_op_clause eff abs2 acc_st acc_cons acc_subs
        in
        ( typed_c_op :: acc_terms
        , typed_co_op_ty :: acc_tys
        , s_st
        , co_op_cons (* @ acc_cons *)
        , c_op_sub @ acc_subs
        , (alpha_i, delta_i) :: acc_alpha_delta_i )
      in
      (*
      let folder_function =
        List.fold_left folder ([], [], r_subbed_st, target_cr_cons, [], [])
          h.effect_clauses
      in
*)
      let folder_function =
        List.fold_right folder h.effect_clauses
          ([], [], r_subbed_st, target_cr_cons, [], [])
      in
      let typed_op_terms, typed_op_terms_ty, _, cons_n, subs_n, alpha_delta_i_s =
        folder_function
      in
      let cons_1 =
        ( Unification.apply_substitution_ty (target_cr_sub @ subs_n)
            target_cr_ty
        , out_ty )
      in
      let cons_2 =
        (Unification.apply_substitution_dirt subs_n target_cr_dirt, out_dirt)
      in
      let cons_6 =
        (in_ty, Unification.apply_substitution_ty (target_cr_sub @ subs_n) r_ty)
      in
      let omega_1, omega_cons_1 = Typed.fresh_ty_coer cons_1
      and omega_2, omega_cons_2 = Typed.fresh_dirt_coer cons_2
      and omega_6, omega_cons_6 = Typed.fresh_ty_coer cons_6 in
      let y_var_name = Typed.Variable.fresh "fresh_var" in
      let y = Typed.PVar y_var_name in
      let annot_y = Typed.annotate y Location.unknown in
      let exp_y = Typed.annotate (Typed.Var y_var_name) Location.unknown in
      let coerced_y =
        Typed.annotate (Typed.CastExp (exp_y, omega_6)) exp_y.location
      in
      let substituted_c_r =
        Typed.subst_comp [(x, coerced_y.term)]
          (Unification.apply_substitution subs_n target_cr_term)
      in
      let coerced_substiuted_c_r =
        Typed.annotate
          (Typed.CastComp
             (substituted_c_r, Typed.BangCoercion (omega_1, omega_2)))
          Location.unknown
      in
      let mapper (op_term, (op_term_ty, op_term_dirt), (alpha_i, delta_i))
          (eff, abs2) =
        let in_op_ty, out_op_ty = Untyped.EffectMap.find eff st.effects in
        let x, k, c_op = abs2 in
        let Untyped.PVar x_var = x.Untyped.term in
        let Untyped.PVar k_var = k.Untyped.term in
        let cons_3 =
          (Unification.apply_substitution_ty subs_n op_term_ty, out_ty)
        in
        let cons_4 =
          (Unification.apply_substitution_dirt subs_n op_term_dirt, out_dirt)
        in
        let cons_5a = Types.Arrow (out_op_ty, (out_ty, out_dirt)) in
        let cons_5b =
          Types.Arrow
            ( out_op_ty
            , ( Unification.apply_substitution_ty subs_n alpha_i
              , Unification.apply_substitution_dirt subs_n delta_i ) )
        in
        let cons_5 = (cons_5a, cons_5b) in
        let omega_3, omega_cons_3 = Typed.fresh_ty_coer cons_3 in
        let omega_4, omega_cons_4 = Typed.fresh_dirt_coer cons_4 in
        let omega_5, omega_cons_5 = Typed.fresh_ty_coer cons_5 in
        let l_var_name = Typed.Variable.fresh "fresh_var" in
        let l = Typed.PVar l_var_name in
        let annot_l = Typed.annotate l Location.unknown in
        let exp_l = Typed.annotate (Typed.Var l_var_name) Location.unknown in
        let coerced_l =
          Typed.annotate (Typed.CastExp (exp_l, omega_5)) Location.unknown
        in
        let substituted_c_op =
          Typed.subst_comp [(k_var, coerced_l.term)]
            (Unification.apply_substitution subs_n op_term)
        in
        Print.debug "substituted_c_op [%t/%t]: %t"
          (CoreSyntax.Variable.print ~safe:true l_var_name)
          (CoreSyntax.Variable.print ~safe:true k_var)
          (Typed.print_computation substituted_c_op) ;
        let coerced_substiuted_c_op =
          Typed.annotate
            (Typed.CastComp
               (substituted_c_op, Typed.BangCoercion (omega_3, omega_4)))
            Location.unknown
        in
        let target_effect = (eff, (in_op_ty, out_op_ty)) in
        ( ( target_effect
          , Typed.abstraction2 (type_pattern x) annot_l coerced_substiuted_c_op
          )
        , [omega_cons_3; omega_cons_4; omega_cons_5] )
      in
      let mapper_input_a =
        List.map2 (fun a b -> (a, b)) typed_op_terms typed_op_terms_ty
      in
      let mapper_input =
        List.map2 (fun (a, b) c -> (a, b, c)) mapper_input_a alpha_delta_i_s
      in
      let new_op_clauses_with_cons =
        List.map2 mapper mapper_input h.effect_clauses
      in
      let new_op_clauses =
        List.map (fun (x, y) -> x) new_op_clauses_with_cons
      in
      let ops_cons =
        OldUtils.flatten_map (fun (x, y) -> y) new_op_clauses_with_cons
      in
      let y_type =
        Unification.apply_substitution_ty (target_cr_sub @ subs_n) r_ty
      in
      let typed_value_clause =
        Typed.abstraction_with_ty annot_y y_type coerced_substiuted_c_r
      in
      let target_handler =
        {Typed.effect_clauses= new_op_clauses; value_clause= typed_value_clause}
      in
      let typed_handler =
        Typed.annotate (Typed.Handler target_handler) Location.unknown
      in
      let for_set_handlers_ops =
        List.map (fun ((eff, (_, _)), _) -> eff) new_op_clauses
      in
      let ops_set = Types.EffectSet.of_list for_set_handlers_ops in
      let handlers_ops =
        Types.{effect_set= ops_set; row= ParamRow out_dirt_var}
      in
      let cons_7 = (in_dirt, handlers_ops) in
      let omega_7, omega_cons_7 = Typed.fresh_dirt_coer cons_7 in
      let handler_in_bang = Typed.BangCoercion (Typed.ReflTy in_ty, omega_7) in
      let handler_out_bang =
        Typed.BangCoercion (Typed.ReflTy out_ty, Typed.ReflDirt out_dirt)
      in
      let handler_coercion =
        Typed.HandlerCoercion (handler_in_bang, handler_out_bang)
      in
      let coerced_handler = Typed.CastExp (typed_handler, handler_coercion) in
      let all_cons =
        [ skel_cons_in
        ; skel_cons_out
        ; omega_cons_1
        ; omega_cons_2
        ; omega_cons_6
        ; omega_cons_7 ]
        @ ops_cons @ r_cons @ cons_n
      in
      Print.debug "### Handler r_cons             ###" ;
      Unification.print_c_list r_cons ;
      Print.debug "### Handler cons_n             ###" ;
      Unification.print_c_list cons_n ;
      Print.debug "### Constraints before Handler ###" ;
      Unification.print_c_list in_cons ;
      Print.debug "#################################" ;
      Print.debug "### Constraints after Handler ###" ;
      Unification.print_c_list all_cons ;
      Print.debug "#################################" ;
      (coerced_handler, target_type, all_cons, subs_n @ target_cr_sub)


and type_comp in_cons st {Untyped.term= comp; Untyped.location= loc} =
  let c, ttype, constraints, sub_list = type_plain_comp in_cons st comp in
  (Typed.annotate c loc, ttype, constraints, sub_list)


and type_plain_comp in_cons st = function
  | Untyped.Value e ->
      let typed_e, tt, constraints, subs_e = type_expr in_cons st e in
      let new_d_ty = (tt, Types.empty_dirt) in
      (Typed.Value typed_e, new_d_ty, constraints, subs_e)
  | Untyped.Match (e, cases) ->
      (*
           α,δ,ωi fresh

           Q;Γ ⊢ e : A | Q₀; σ₀ ~> e'

           forall i in 1..n:

             Qi₋₁;σi₋₁(Γ) ⊢ casei : A -> Bi ! Δi | Qi ; σi ~> casei'
 
             ωi : σ^n(Bi ! Δi) <:  (α ! δ)          
 
           -----------------------------------------------------------------
           Q;Γ ⊢ Match (e, cases) : σ^n(α ! δ) | σ^n(Q,Q₀,...,Qn) ~> Match (e', cases' |> ωi) 
      *)
      (* TODO: ignoring the substitutions for now *)
      let e', ty_A, cons0, sigma0 = type_expr in_cons st e in
      let ty_alpha, q_alpha = Typed.fresh_ty_with_skel () in
      let dirt_delta = Types.fresh_dirt () in
      let cases', cons1, sigma1 =
        type_cases (q_alpha :: cons0) st cases ty_A (ty_alpha, dirt_delta)
      in
      (Typed.Match (e', cases'), (ty_alpha, dirt_delta), cons1, sigma0 @ sigma1)
      (* in fact it is not yet implemented, but assert false gives us source location automatically *)
  | Untyped.Apply (e1, e2) -> (
      Print.debug "in infer apply" ;
      let typed_e1, tt_1, constraints_1, subs_e1 = type_expr in_cons st e1 in
      let st_subbed = apply_sub_to_env st subs_e1 in
      let typed_e2, tt_2, constraints_2, subs_e2 =
        type_expr constraints_1 st_subbed e2
      in
      Print.debug "e1 apply type : %t" (Types.print_target_ty tt_1) ;
      Print.debug "e2 apply type : %t" (Types.print_target_ty tt_2) ;
      match typed_e1.term
      with
      (* | Typed.Effect (eff, (eff_in,eff_out)) ->
           let cons1 = (tt_2, eff_in) in
           let coer1, omega_cons_1 = Typed.fresh_ty_coer cons1 in
           let e2_coerced = Typed.annotate (Typed.CastExp (typed_e2,coer1)) typed_e1.location in
           let constraints = List.append [omega_cons_1] constraints_2 in
           let dirt_of_out_ty = Types.EffectSet.singleton eff in 
           let new_var = Typed.Variable.fresh "cont_bind" in
           let continuation_comp = Untyped.Value ( Untyped.annotate (Untyped.Var new_var) typed_e2.location ) in 
           let new_st = add_def st new_var eff_out in 
           let (typed_cont_comp, typed_cont_comp_dirty_ty, cont_comp_cons, cont_comp_subs)= 
                    type_comp in_cons new_st (Untyped.annotate continuation_comp typed_e2.location) in 
           let (typed_comp_ty,typed_comp_dirt) = typed_cont_comp_dirty_ty in 
           let final_dirt = 
              begin match typed_comp_dirt with 
              | Types.SetVar (s,dv) -> Types.SetVar (Types.effect_set_union s (Types.EffectSet.singleton eff), dv)
              | Types.SetEmpty s -> Types.SetEmpty (Types.effect_set_union s (Types.EffectSet.singleton eff))
              end in 
          let cont_abstraction = Typed.annotate ((Typed.annotate (Typed.PVar new_var) typed_e2.location), typed_cont_comp) 
                                 typed_e2.location in
          Print.debug "THE FINAL DIRT :- %t" (Types.print_target_dirt final_dirt);
          ( Typed.Call( (eff, (eff_in,eff_out)) ,e2_coerced, cont_abstraction ),
            (typed_comp_ty,final_dirt),
            cont_comp_cons @ constraints,
             [])
       *)
      | _
      ->
        let new_ty_var, cons1 = Typed.fresh_ty_with_skel () in
        let fresh_dirty_ty = Types.make_dirty new_ty_var in
        let cons2 =
          ( Unification.apply_substitution_ty subs_e2 tt_1
          , Types.Arrow (tt_2, fresh_dirty_ty) )
        in
        let omega_1, omega_cons_1 = Typed.fresh_ty_coer cons2 in
        let e1_coerced =
          Typed.annotate
            (Typed.CastExp
               (Unification.apply_substitution_exp subs_e2 typed_e1, omega_1))
            typed_e1.location
        in
        ( Typed.Apply (e1_coerced, typed_e2)
        , fresh_dirty_ty
        , [cons1; omega_cons_1] @ constraints_2
        , subs_e2 @ subs_e1 ) )
  | Untyped.Handle (e, c) ->
      let alpha_1, cons_skel_1 = Typed.fresh_ty_with_skel () in
      let alpha_2, cons_skel_2 = Typed.fresh_ty_with_skel () in
      let delta_1 = Types.fresh_dirt () in
      let delta_2 = Types.fresh_dirt () in
      let dirty_1 = (alpha_1, delta_1) in
      let dirty_2 = (alpha_2, delta_2) in
      let typed_exp, exp_type, exp_constraints, sub_exp =
        type_expr in_cons st e
      in
      let st_subbed = apply_sub_to_env st sub_exp in
      let typed_comp, comp_dirty_type, comp_constraints, sub_comp =
        type_comp exp_constraints st_subbed c
      in
      let comp_type, comp_dirt = comp_dirty_type in
      let cons1 =
        ( Unification.apply_substitution_ty sub_comp exp_type
        , Types.Handler (dirty_1, dirty_2) )
      in
      let cons2 = (comp_type, alpha_1) in
      let cons3 = (comp_dirt, delta_1) in
      let coer1, omega_cons_1 = Typed.fresh_ty_coer cons1
      and coer2, omega_cons_2 = Typed.fresh_ty_coer cons2
      and coer3, omega_cons_3 = Typed.fresh_dirt_coer cons3 in
      let coer_exp =
        Typed.annotate (Typed.CastExp (typed_exp, coer1)) typed_exp.location
      in
      let coer_comp =
        Typed.annotate
          (Typed.CastComp (typed_comp, Typed.BangCoercion (coer2, coer3)))
          typed_comp.location
      in
      let constraints =
        [cons_skel_1; cons_skel_2; omega_cons_1; omega_cons_2; omega_cons_3]
        @ comp_constraints
      in
      ( Typed.Handle (coer_exp, coer_comp)
      , dirty_2
      , constraints
      , sub_comp @ sub_exp )
  | Untyped.Let (defs, c_2) -> (
      let [(p_def, c_1)] = defs in
      match c_1.term with
      | Untyped.Value e_1 ->
          let typed_e1, type_e1, cons_e1, sub_e1 = type_expr in_cons st e_1 in
          let sub_e1', cons_e1' = Unification.unify ([], [], cons_e1) in
          let typed_e1 = Unification.apply_substitution_exp sub_e1' typed_e1 in
          let st_subbed = apply_sub_to_env st (sub_e1' @ sub_e1) in
          let ( split_skel_vars
              , split_ty_vars
              , split_dirt_vars
              , split_cons1
              , split_cons2 ) =
            splitter
              (TypingEnv.return_context st_subbed.context)
              cons_e1'
              (Unification.apply_substitution_ty sub_e1' type_e1)
          in
          let Untyped.PVar x = p_def.Untyped.term in
          let qual_ty =
            List.fold_right
              (fun cons acc ->
                match cons with
                | Typed.TyOmega (_, t) -> Types.QualTy (t, acc)
                | Typed.DirtOmega (_, t) -> Types.QualDirt (t, acc) )
              split_cons1
              (Unification.apply_substitution_ty sub_e1' type_e1)
          in
          let ty_sc_dirt =
            List.fold_right
              (fun cons acc -> Types.TySchemeDirt (cons, acc))
              split_dirt_vars qual_ty
          in
          let ty_sc_ty =
            List.fold_right
              (fun cons acc ->
                Types.TySchemeTy
                  (cons, Unification.get_skel_of_tyvar cons cons_e1', acc) )
              split_ty_vars ty_sc_dirt
          in
          let ty_sc_skel =
            List.fold_right
              (fun cons acc -> Types.TySchemeSkel (cons, acc))
              split_skel_vars ty_sc_ty
          in
          let new_st = add_def st_subbed x ty_sc_skel in
          let typed_c2, type_c2, cons_c2, subs_c2 =
            type_comp split_cons2 new_st c_2
          in
          let var_exp =
            List.fold_right
              (fun cons acc ->
                match cons with
                | Typed.TyOmega (om, t) ->
                    Typed.annotate (Typed.LambdaTyCoerVar (om, t, acc))
                      typed_c2.location
                | Typed.DirtOmega (om, t) ->
                    Typed.annotate (Typed.LambdaDirtCoerVar (om, t, acc))
                      typed_c2.location )
              split_cons1 typed_e1
          in
          let var_exp_dirt_lamda =
            List.fold_right
              (fun cons acc ->
                Typed.annotate (Typed.BigLambdaDirt (cons, acc))
                  typed_c2.location )
              split_dirt_vars var_exp
          in
          let var_exp_ty_lambda =
            List.fold_right
              (fun cons acc ->
                Typed.annotate
                  (Typed.BigLambdaTy
                     (cons, Unification.get_skel_of_tyvar cons cons_e1', acc))
                  typed_c2.location )
              split_ty_vars var_exp_dirt_lamda
          in
          let var_exp_skel_lamda =
            List.fold_right
              (fun cons acc ->
                Typed.annotate (Typed.BigLambdaSkel (cons, acc))
                  typed_c2.location )
              split_skel_vars var_exp_ty_lambda
          in
          let return_term =
            Typed.LetVal
              ( var_exp_skel_lamda
              , ( Typed.annotate (Typed.PVar x) p_def.Untyped.location
                , ty_sc_skel
                , typed_c2 ) )
          in
          (return_term, type_c2, cons_c2, subs_c2 @ sub_e1' @ sub_e1)
      | _ ->
          let typed_c1, (type_c1, dirt_c1), cons_c1, subs_c1 =
            type_comp in_cons st c_1
          in
          match p_def.Untyped.term with
          | Untyped.PVar x ->
              let new_st = add_def (apply_sub_to_env st subs_c1) x type_c1 in
              let typed_c2, (type_c2, dirt_c2), cons_c2, subs_c2 =
                type_comp cons_c1 new_st c_2
              in
              let new_dirt_var = Types.fresh_dirt () in
              let cons1 =
                ( Unification.apply_substitution_dirt subs_c1 dirt_c1
                , new_dirt_var )
              in
              let cons2 = (dirt_c2, new_dirt_var) in
              let coer1, omega_cons_1 = Typed.fresh_dirt_coer cons1 in
              let coer2, omega_cons_2 = Typed.fresh_dirt_coer cons2 in
              let coer_c1 =
                Typed.annotate
                  (Typed.CastComp
                     ( Unification.apply_substitution subs_c2 typed_c1
                     , Typed.BangCoercion
                         ( Typed.ReflTy
                             (Unification.apply_substitution_ty subs_c2 type_c1)
                         , coer1 ) )) typed_c1.location
              in
              let coer_c2 =
                Typed.annotate
                  (Typed.CastComp
                     ( typed_c2
                     , Typed.BangCoercion (Typed.ReflTy type_c2, coer2) ))
                  typed_c2.location
              in
              let typed_pattern = type_pattern p_def in
              let abstraction =
                Typed.annotate (typed_pattern, coer_c2) typed_c2.location
              in
              let constraints = [omega_cons_1; omega_cons_2] @ cons_c2 in
              ( Typed.Bind (coer_c1, abstraction)
              , (type_c2, new_dirt_var)
              , constraints
              , subs_c2 @ subs_c1 )
          | Untyped.PNonbinding ->
              let new_st = apply_sub_to_env st subs_c1 in
              let typed_c2, (type_c2, dirt_c2), cons_c2, subs_c2 =
                type_comp cons_c1 new_st c_2
              in
              let new_dirt_var = Types.fresh_dirt () in
              let cons1 =
                ( Unification.apply_substitution_dirt subs_c1 dirt_c1
                , new_dirt_var )
              in
              let cons2 = (dirt_c2, new_dirt_var) in
              let coer1, omega_cons_1 = Typed.fresh_dirt_coer cons1 in
              let coer2, omega_cons_2 = Typed.fresh_dirt_coer cons2 in
              let coer_c1 =
                Typed.annotate
                  (Typed.CastComp
                     ( Unification.apply_substitution subs_c2 typed_c1
                     , Typed.BangCoercion
                         ( Typed.ReflTy
                             (Unification.apply_substitution_ty subs_c2 type_c1)
                         , coer1 ) )) typed_c1.location
              in
              let coer_c2 =
                Typed.annotate
                  (Typed.CastComp
                     ( typed_c2
                     , Typed.BangCoercion (Typed.ReflTy type_c2, coer2) ))
                  typed_c2.location
              in
              let typed_pattern = type_pattern p_def in
              let abstraction =
                Typed.annotate (typed_pattern, coer_c2) typed_c2.location
              in
              let constraints = [omega_cons_1; omega_cons_2] @ cons_c2 in
              ( Typed.Bind (coer_c1, abstraction)
              , (type_c2, new_dirt_var)
              , constraints
              , subs_c2 @ subs_c1 )
          | pat -> assert false )
  | Untyped.LetRec (defs, c) -> assert false


(* in fact it is not yet implemented, but assert false gives us source location automatically *)
and get_handler_op_clause eff abs2 in_st in_cons in_sub =
  let in_op_ty, out_op_ty = Untyped.EffectMap.find eff in_st.effects in
  let x, k, c_op = abs2 in
  let Untyped.PVar x_var = x.Untyped.term in
  let Untyped.PVar k_var = k.Untyped.term in
  let alpha_i_param = Params.Ty.fresh () in
  let alpha_i, alpha_cons = Typed.fresh_ty_with_skel () in
  let alpha_dirty = Types.make_dirty alpha_i in
  let st_subbed = apply_sub_to_env in_st in_sub in
  let temp_st = add_def st_subbed x_var in_op_ty in
  let new_st = add_def temp_st k_var (Types.Arrow (out_op_ty, alpha_dirty)) in
  let cons = alpha_cons :: in_cons in
  let typed_c_op, typed_co_op_ty, co_op_cons, c_op_sub =
    type_comp cons new_st c_op
  in
  (typed_c_op, typed_co_op_ty, st_subbed, co_op_cons, c_op_sub, alpha_dirty)


and type_cases in_cons st cases ty_in dty_out =
  match cases with
  | [] -> ([], in_cons, [])
  | case :: cases ->
      let case', cons1, sub1 = type_case in_cons st case ty_in dty_out in
      let cases', cons2, sub2 = type_cases cons1 st cases ty_in dty_out in
      (case' :: cases', cons2, sub1 @ sub2)


and type_case in_cons st case ty_in (ty_out, dirt_out) =
  let p, c = case in
  let p', st', cons1 = type_pattern' in_cons st p ty_in in
  let c', (ty_c, dirt_c), cons2, sublist = type_comp cons1 st' c in
  let tyco, q1 = Typed.fresh_ty_coer (ty_c, ty_out) in
  let dco, q2 = Typed.fresh_dirt_coer (dirt_c, dirt_out) in
  let c'' =
    { Typed.term= Typed.CastComp (c', BangCoercion (tyco, dco))
    ; Typed.location= c'.Typed.location }
  in
  ( {Typed.term= (p', c''); Typed.location= c''.Typed.location}
  , q1 :: q2 :: cons2
  , sublist )


(* Finalize a list of constraints, setting all dirt variables to the empty set. *)

let finalize_constraint sub = function
  | Typed.TyOmega (tcp, ctty) ->
      Error.typing ~loc:Location.unknown
        "Unsolved type inequality in top-level computation: %t"
        (Typed.print_omega_ct (Typed.TyOmega (tcp, ctty)))
  | Typed.DirtOmega
      ( dcp
      , ( {Types.effect_set= s1; Types.row= row1}
        , {Types.effect_set= s2; Types.row= row2} ) ) ->
      assert (Types.EffectSet.subset s1 s2) ;
      let effect_subst =
        Unification.CoerDirtVartoDirtCoercion
          ( dcp
          , Typed.UnionDirt
              (s1, Typed.Empty (Types.closed_dirt (Types.EffectSet.diff s2 s1)))
          )
      and row_substs =
        match (row1, row2) with
        | Types.EmptyRow, Types.ParamRow dv2 ->
            [Unification.DirtVarToDirt (dv2, Types.empty_dirt)]
        | Types.ParamRow dv1, Types.EmptyRow ->
            [Unification.DirtVarToDirt (dv1, Types.empty_dirt)]
        | Types.ParamRow dv1, Types.ParamRow dv2 ->
            [ Unification.DirtVarToDirt (dv1, Types.empty_dirt)
            ; Unification.DirtVarToDirt (dv2, Types.empty_dirt) ]
        | Types.EmptyRow, Types.EmptyRow -> []
      in
      effect_subst :: row_substs @ sub
  | Typed.SkelEq (sk1, sk2) -> assert false
  | Typed.TyParamHasSkel (tp, sk) -> assert false


let finalize_constraints c_list = List.fold_left finalize_constraint [] c_list

(* Typing top-level 

     Assumes it concerns a top-level computation.
*)

let type_toplevel ~loc st c =
  let c' = c.Untyped.term in
  match c'
  with
  (* | Untyped.Value e -> assert false
     let et, ttype,constraints, sub_list = type_expr [] st e in
    Print.debug "Expression : %t" (Typed.print_expression et);
    Print.debug "Expression type : %t " (Types.print_target_ty ttype);
    Print.debug "Starting Set of Constraints ";
    Unification.print_c_list constraints;
    let (sub,final) = Unification.unify ([],[],constraints) in
    let et' = Unification.apply_substitution_exp sub et in
    let ttype' = Unification.apply_substitution_ty sub ttype in
    let (split_ty_vars, split_dirt_vars, split_cons1, split_cons2)= splitter (TypingEnv.return_context st.context) final ttype' in 
    let qual_ty = List.fold_right (fun cons acc -> 
                                          begin match cons with 
                                          | Typed.TyOmega(_,t) -> Types.QualTy (t,acc)
                                          | Typed.DirtOmega(_,t) -> Types.QualDirt(t,acc) 
                                          end 
                                      ) split_cons1 ttype' in 
    let ty_sc_dirt = List.fold_right (fun cons acc -> Types.TySchemeDirt (cons,acc)) split_dirt_vars qual_ty in
    let ty_sc_ty = List.fold_right  (fun cons acc -> Types.TySchemeTy (cons,Types.PrimSkel Types.IntTy,acc)) split_ty_vars ty_sc_dirt in  
    let var_exp = List.fold_right(fun cons acc -> 
                                          begin match cons with 
                                          | Typed.TyOmega(om,t) -> Typed.annotate (Typed.LambdaTyCoerVar (om,t,acc)) Location.unknown
                                          | Typed.DirtOmega(om,t) -> Typed.annotate(Typed.LambdaDirtCoerVar(om,t,acc)) Location.unknown
                                          end 
                                      ) split_cons1 et' in 
    let var_exp_dirt_lamda = 
      List.fold_right (fun cons acc -> Typed.annotate ( Typed.BigLambdaDirt (cons,acc) ) Location.unknown )  split_dirt_vars var_exp in
    let var_exp_ty_lambda = 
      List.fold_right (fun cons acc -> Typed.annotate (Typed.BigLambdaTy (cons,acc) )Location.unknown ) split_ty_vars var_exp_dirt_lamda in
    Print.debug "New Expr : %t" (Typed.print_expression var_exp_ty_lambda);
    Print.debug "New Expr ty : %t" (Types.print_target_ty ty_sc_ty);
    let tch_ty = TypeChecker.type_check_exp (TypeChecker.new_checker_state) var_exp_ty_lambda.term in
    Print.debug "Type from Type Checker : %t" (Types.print_target_ty tch_ty);
    (Typed.annotate (Typed.Value var_exp_ty_lambda) Location.unknown), st *)
  | _
  ->
    let ct, (ttype, dirt), constraints, sub_list = type_comp [] st c in
    (* let x::xs = constraints in 
    Print.debug "Single constraint : %t" (Typed.print_omega_ct x); *)
    Print.debug "Computation : %t" (Typed.print_computation ct) ;
    Print.debug "Computation type : %t ! {%t}"
      (Types.print_target_ty ttype)
      (Types.print_target_dirt dirt) ;
    Print.debug "Starting Set of Constraints " ;
    Unification.print_c_list constraints ;
    let sub, final = Unification.unify ([], [], constraints) in
    Print.debug "Final Constraints:" ;
    Unification.print_c_list final ;
    let ct' = Unification.apply_substitution sub ct in
    Print.debug "New Computation : %t" (Typed.print_computation ct') ;
    let sub2 =
      List.map
        (fun dp -> Unification.DirtVarToDirt (dp, Types.empty_dirt))
        (List.sort_uniq compare (free_dirt_vars_computation ct'))
    in
    let ct2 = Unification.apply_substitution sub2 ct' in
    let sub3 = finalize_constraints (Unification.apply_sub sub2 final) in
    let ct3 = Unification.apply_substitution sub3 ct2 in
    Print.debug "New Computation : %t" (Typed.print_computation ct3) ;
    (* Print.debug "Remaining dirt variables "; *)
    (* List.iter (fun dp -> Print.debug "%t" (Params.Dirt.print dp)) (List.sort_uniq compare (free_dirt_vars_computation ct')); *)
    (*     let tch_ty, tch_dirt =
      TypeChecker.type_check_comp TypeChecker.new_checker_state ct3.term
    in
    Print.debug "Type from Type Checker : %t ! %t"
      (Types.print_target_ty tch_ty)
      (Types.print_target_dirt tch_dirt) ;
 *)
    (ct3, st)


let add_effect eff (ty1, ty2) st =
  Print.debug "%t ----> %t" (Type.print ([], ty1)) (Type.print ([], ty2)) ;
  let target_ty1 = source_to_target ty1 in
  let target_ty2 = source_to_target ty2 in
  let new_st = add_effect st eff (target_ty1, target_ty2) in
  new_st
