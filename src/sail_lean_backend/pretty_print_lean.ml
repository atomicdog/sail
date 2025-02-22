open Libsail

open Type_check
open Ast
open Ast_defs
open Ast_util
open Reporting
open Rewriter
open PPrint
open Pretty_print_common

type global_context = { effect_info : Effects.side_effect_info }

type context = {
  global : global_context;
  env : Type_check.env;
      (** The typechecking environment of the current function. This environment is reset using [initial_context] when
          we start processing a new function.  *)
  kid_id_renames : id option KBindings.t;
      (** Associates a kind variable to the corresponding argument of the function, used for implicit arguments. *)
  kid_id_renames_rev : kid Bindings.t;  (** Inverse of the [kid_id_renames] mapping. *)
}

let initial_context env =
  {
    global = { effect_info = Effects.empty_side_effect_info };
    env;
    kid_id_renames = KBindings.empty;
    kid_id_renames_rev = Bindings.empty;
  }

let add_single_kid_id_rename ctx id kid =
  let kir =
    match Bindings.find_opt id ctx.kid_id_renames_rev with
    | Some kid -> KBindings.add kid None ctx.kid_id_renames
    | None -> ctx.kid_id_renames
  in
  {
    ctx with
    kid_id_renames = KBindings.add kid (Some id) kir;
    kid_id_renames_rev = Bindings.add id kid ctx.kid_id_renames_rev;
  }

let implicit_parens x = enclose (string "{") (string "}") x

let doc_id_ctor (Id_aux (i, _)) =
  match i with Id i -> string i | Operator x -> string (Util.zencode_string ("op " ^ x))

let doc_kid ctx (Kid_aux (Var x, _) as ki) =
  match KBindings.find_opt ki ctx.kid_id_renames with
  | Some (Some i) -> string (string_of_id i)
  | _ -> string ("k_" ^ String.sub x 1 (String.length x - 1))

(* TODO do a proper renaming and keep track of it *)

let is_enum env id = match Env.lookup_id id env with Enum _ -> true | _ -> false

let pat_is_plain_binder env (P_aux (p, _)) =
  match p with
  | (P_id id | P_typ (_, P_aux (P_id id, _))) when not (is_enum env id) -> Some (Some id)
  | P_wild | P_typ (_, P_aux (P_wild, _)) -> Some None
  | P_var (_, _) -> Some (Some (Id_aux (Id "var", Unknown)))
  | P_app (_, _) -> Some (Some (Id_aux (Id "app", Unknown)))
  | P_vector _ -> Some (Some (Id_aux (Id "vect", Unknown)))
  | P_tuple _ -> Some (Some (Id_aux (Id "tuple", Unknown)))
  | P_list _ -> Some (Some (Id_aux (Id "list", Unknown)))
  | P_cons (_, _) -> Some (Some (Id_aux (Id "cons", Unknown)))
  | P_lit _ -> Some (Some (Id_aux (Id "lit", Unknown)))
  | _ -> None

(* Copied from the Coq PP *)
let args_of_typ l env typs =
  let arg i typ =
    let id = mk_id ("arg" ^ string_of_int i) in
    ((P_aux (P_id id, (l, mk_tannot env typ)), typ), E_aux (E_id id, (l, mk_tannot env typ)))
  in
  List.split (List.mapi arg typs)

(* Copied from the Coq PP *)
(* Sail currently has a single pattern to match against a list of
   argument types.  We need to tweak everything to match up,
   especially so that the function is presented in curried form.  In
   particular, if there's a single binder for multiple arguments
   (which rewriting can currently introduce) then we need to turn it
   into multiple binders and reconstruct it in the function body. *)
let rec untuple_args_pat typs (P_aux (paux, ((l, _) as annot)) as pat) =
  let env = env_of_annot annot in
  let identity body = body in
  match (paux, typs) with
  | P_tuple [], _ ->
      let annot = (l, mk_tannot Env.empty unit_typ) in
      ([(P_aux (P_lit (mk_lit L_unit), annot), unit_typ)], identity)
  (* The type checker currently has a special case for a single arg type; if
     that is removed, then remove the next case. *)
  | P_tuple pats, [typ] -> ([(pat, typ)], identity)
  | P_tuple pats, _ -> (List.combine pats typs, identity)
  | P_wild, _ ->
      let wild typ = (P_aux (P_wild, (l, mk_tannot env typ)), typ) in
      (List.map wild typs, identity)
  | P_typ (_, pat), _ -> untuple_args_pat typs pat
  | P_as _, _ :: _ :: _ | P_id _, _ :: _ :: _ ->
      let argpats, argexps = args_of_typ l env typs in
      let argexp = E_aux (E_tuple argexps, annot) in
      let bindargs (E_aux (_, bannot) as body) = E_aux (E_let (LB_aux (LB_val (pat, argexp), annot), body), bannot) in
      (argpats, bindargs)
  (* TODO Occurrences of the unit literal are removed right now, in order to be able to compile `initialize_registers`. *)
  | P_lit (L_aux (L_unit, _)), _ -> ([], identity)
  | _, [typ] -> ([(pat, typ)], identity)
  | _, _ -> unreachable l __POS__ "Unexpected pattern/type combination"

let string_of_nexp_con (Nexp_aux (n, l)) =
  match n with
  | Nexp_constant _ -> "NExp_constant"
  | Nexp_id _ -> "Nexp_id"
  | Nexp_var _ -> "Nexp_var"
  | Nexp_app _ -> "Nexp_app"
  | Nexp_if _ -> "Nexp_if"
  | Nexp_times _ -> "Nexp_times"
  | Nexp_sum _ -> "Nexp_sum"
  | Nexp_minus _ -> "Nexp_minus"
  | Nexp_neg _ -> "Nexp_neg"
  | Nexp_exp _ -> "Nexp_exp"

let doc_nexp ctx (Nexp_aux (n, l) as nexp) =
  match n with
  | Nexp_constant i -> string (Big_int.to_string i)
  | Nexp_var ki -> doc_kid ctx ki
  | _ -> failwith ("NExp " ^ string_of_nexp_con nexp ^ " " ^ string_of_nexp nexp ^ " not translatable yet.")

let string_of_typ_con (Typ_aux (t, _)) =
  match t with
  | Typ_app _ -> "Typ_app"
  | Typ_var _ -> "Typ_var"
  | Typ_fn _ -> "Typ_fn"
  | Typ_tuple _ -> "Typ_tuple"
  | Typ_exist _ -> "Typ_exist"
  | Typ_bidir _ -> "Typ_bidir"
  | Typ_internal_unknown -> "Typ_internal_unknown"
  | Typ_id _ -> "Typ_id"

let provably_nneg ctx x = Type_check.prove __POS__ ctx.env (nc_gteq x (nint 0))

let rec doc_typ ctx (Typ_aux (t, _) as typ) =
  match t with
  | Typ_id (Id_aux (Id "unit", _)) -> string "Unit"
  | Typ_id (Id_aux (Id "int", _)) -> string "Int"
  | Typ_id (Id_aux (Id "bool", _)) -> string "Bool"
  | Typ_id (Id_aux (Id "bit", _)) -> parens (string "BitVec 1")
  | Typ_id (Id_aux (Id "nat", _)) -> string "Nat"
  | Typ_app (Id_aux (Id "bitvector", _), [A_aux (A_nexp m, _)]) | Typ_app (Id_aux (Id "bits", _), [A_aux (A_nexp m, _)])
    ->
      parens (string "BitVec " ^^ doc_nexp ctx m)
  | Typ_app (Id_aux (Id "atom", _), [A_aux (A_nexp x, _)]) -> if provably_nneg ctx x then string "Nat" else string "Int"
  | Typ_app (Id_aux (Id "register", _), t_app) ->
      string "RegisterRef Unit Unit "
      (* TODO: Replace units with real types. *) ^^ separate_map comma (doc_typ_app ctx) t_app
  | Typ_app (Id_aux (Id "implicit", _), [A_aux (A_nexp (Nexp_aux (Nexp_var ki, _)), _)]) ->
      underscore (* TODO check if the type of implicit arguments can really be always inferred *)
  | Typ_tuple ts -> parens (separate_map (space ^^ string "×" ^^ space) (doc_typ ctx) ts)
  | Typ_id (Id_aux (Id id, _)) -> string id
  | Typ_app (Id_aux (Id "range", _), [A_aux (A_nexp low, _); A_aux (A_nexp high, _)]) ->
      if provably_nneg ctx low then string "Nat" else string "Int"
  | _ -> failwith ("Type " ^ string_of_typ_con typ ^ " " ^ string_of_typ typ ^ " not translatable yet.")

and doc_typ_app ctx (A_aux (t, _) as typ) =
  match t with
  | A_typ t' -> doc_typ ctx t'
  | A_bool nc -> failwith ("Constraint " ^ string_of_n_constraint nc ^ "not translatable yet.")
  | A_nexp m -> doc_nexp ctx m

let rec captured_typ_var ((i, Typ_aux (t, _)) as typ) =
  match t with
  | Typ_app (Id_aux (Id "atom", _), [A_aux (A_nexp (Nexp_aux (Nexp_var ki, _)), _)])
  | Typ_app (Id_aux (Id "implicit", _), [A_aux (A_nexp (Nexp_aux (Nexp_var ki, _)), _)]) ->
      Some (i, ki)
  | _ -> None

let doc_typ_id ctx (typ, fid) = flow (break 1) [doc_id_ctor fid; colon; doc_typ ctx typ]

let doc_kind (K_aux (k, _)) =
  match k with
  | K_int -> string "Int"
  | K_bool -> string "Bool"
  | _ -> failwith ("Kind " ^ string_of_kind_aux k ^ " not translatable yet.")

let doc_typ_arg ctx ta = string "foo" (* TODO implement *)

let rec doc_nconstraint ctx (NC_aux (nc, _)) =
  match nc with
  | NC_and (n1, n2) -> flow (break 1) [doc_nconstraint ctx n1; string "∧"; doc_nconstraint ctx n2]
  | NC_or (n1, n2) -> flow (break 1) [doc_nconstraint ctx n1; string "∨"; doc_nconstraint ctx n2]
  | NC_equal (a1, a2) -> flow (break 1) [doc_typ_arg ctx a1; string "="; doc_typ_arg ctx a2]
  | NC_not_equal (a1, a2) -> flow (break 1) [doc_typ_arg ctx a1; string "≠"; doc_typ_arg ctx a2]
  | NC_app (f, args) -> string (string_of_id f) ^^ parens (separate_map comma_sp (doc_typ_arg ctx) args)
  | NC_false -> string "false"
  | NC_true -> string "true"
  | NC_ge (n1, n2) -> flow (break 1) [doc_nexp ctx n1; string "≥"; doc_nexp ctx n2]
  | NC_le (n1, n2) -> flow (break 1) [doc_nexp ctx n1; string "≤"; doc_nexp ctx n2]
  | NC_gt (n1, n2) -> flow (break 1) [doc_nexp ctx n1; string ">"; doc_nexp ctx n2]
  | NC_lt (n1, n2) -> flow (break 1) [doc_nexp ctx n1; string "<"; doc_nexp ctx n2]
  | NC_id i -> string (string_of_id i)
  | NC_set (n, vs) ->
      flow (break 1)
        [
          doc_nexp ctx n;
          string "∈";
          implicit_parens (separate_map comma_sp (fun x -> string (Nat_big_num.to_string x)) vs);
        ]
  | NC_var ki -> doc_kid ctx ki

let doc_quant_item ctx (QI_aux (qi, _)) =
  match qi with
  | QI_id (KOpt_aux (KOpt_kind (k, ki), _)) -> flow (break 1) [doc_kid ctx ki; colon; doc_kind k]
  | QI_constraint c -> doc_nconstraint ctx c

let doc_typ_quant ctx tq = match tq with TypQ_tq qs -> List.map (doc_quant_item ctx) qs | TypQ_no_forall -> []

let lean_escape_string s = Str.global_replace (Str.regexp "\"") "\"\"" s

let doc_lit (L_aux (lit, l)) =
  match lit with
  | L_unit -> string "()"
  | L_zero -> string "0#1"
  | L_one -> string "1#1"
  | L_false -> string "false"
  | L_true -> string "true"
  | L_num i ->
      let s = Big_int.to_string i in
      string s
  | L_hex n -> utf8string ("0x" ^ n)
  | L_bin n -> utf8string ("0b" ^ n)
  | L_undef -> utf8string "(Fail \"undefined value of unsupported type\")"
  | L_string s -> utf8string ("\"" ^ lean_escape_string s ^ "\"")
  | L_real s -> utf8string s (* TODO test if this is really working *)

let string_of_exp_con (E_aux (e, _)) =
  match e with
  | E_block _ -> "E_block"
  | E_ref _ -> "E_ref"
  | E_app_infix _ -> "E_app_infix"
  | E_if _ -> "E_if"
  | E_loop _ -> "E_loop"
  | E_for _ -> "E_for"
  | E_vector_access _ -> "E_vector_access"
  | E_vector_subrange _ -> "E_vector_subrange"
  | E_vector_update _ -> "E_vector_update"
  | E_vector_update_subrange _ -> "E_vector_update_subrange"
  | E_vector_append _ -> "E_vector_append"
  | E_list _ -> "E_list"
  | E_cons _ -> "E_cons"
  | E_struct _ -> "E_struct"
  | E_struct_update _ -> "E_struct_update"
  | E_field _ -> "E_field"
  | E_match _ -> "E_match"
  | E_assign _ -> "E_assign"
  | E_sizeof _ -> "E_sizeof"
  | E_constraint _ -> "E_constraint"
  | E_exit _ -> "E_exit"
  | E_throw _ -> "E_throw"
  | E_try _ -> "E_try"
  | E_return _ -> "E_return"
  | E_assert _ -> "E_assert"
  | E_var _ -> "E_var"
  | E_internal_plet _ -> "E_internal_plet"
  | E_internal_return _ -> "E_internal_return"
  | E_internal_assume _ -> "E_internal_assume"
  | E_internal_value _ -> "E_internal_value"
  | E_id _ -> "E_id"
  | E_lit _ -> "E_lit"
  | E_typ _ -> "E_typ"
  | E_app _ -> "E_app"
  | E_tuple _ -> "E_tuple"
  | E_vector _ -> "E_vector"
  | E_let _ -> "E_let"

let wrap_with_pure (needs_return : bool) (d : document) =
  if needs_return then parens (nest 2 (flow space [string "pure"; d])) else d

let wrap_with_left_arrow (needs_return : bool) (d : document) =
  if needs_return then parens (nest 2 (flow space [string "←"; d])) else d

let rec doc_exp (as_monadic : bool) ctx (E_aux (e, (l, annot)) as full_exp) =
  let env = env_of_tannot annot in
  let d_of_arg arg =
    let arg_monadic = effectful (effect_of arg) in
    wrap_with_left_arrow arg_monadic (doc_exp arg_monadic ctx arg)
  in
  let d_of_field (FE_aux (FE_fexp (field, e), _) as fexp) =
    let field_monadic = effectful (effect_of e) in
    doc_fexp field_monadic ctx fexp
  in
  match e with
  | E_id id ->
      (* TODO replace by a translating via a binding map *)
      wrap_with_pure as_monadic (string (string_of_id id))
  | E_lit l -> wrap_with_pure as_monadic (doc_lit l)
  | E_app (Id_aux (Id "undefined_int", _), _) (* TODO remove when we handle imports *)
  | E_app (Id_aux (Id "undefined_bit", _), _) (* TODO remove when we handle imports *)
  | E_app (Id_aux (Id "undefined_bitvector", _), _) (* TODO remove when we handle imports *)
  | E_app (Id_aux (Id "internal_pick", _), _) ->
      (* TODO replace by actual implementation of internal_pick *)
      string "sorry"
  | E_internal_plet _ -> string "sorry" (* TODO replace by actual implementation of internal_plet *)
  | E_app (f, args) ->
      let d_id =
        if Env.is_extern f env "lean" then string (Env.get_extern f env "lean")
        else doc_exp false ctx (E_aux (E_id f, (l, annot)))
      in
      let d_args = List.map d_of_arg args in
      let fn_monadic = not (Effects.function_is_pure f ctx.global.effect_info) in
      nest 2 (wrap_with_pure (as_monadic && fn_monadic) (parens (flow (break 1) (d_id :: d_args))))
  | E_vector vals -> failwith "vector found"
  | E_typ (typ, e) ->
      if effectful (effect_of e) then
        parens (separate space [doc_exp false ctx e; colon; string "SailM"; doc_typ ctx typ])
      else wrap_with_pure as_monadic (parens (separate space [doc_exp false ctx e; colon; doc_typ ctx typ]))
  | E_tuple es -> wrap_with_pure as_monadic (parens (separate_map (comma ^^ space) d_of_arg es))
  | E_let (LB_aux (LB_val (lpat, lexp), _), e) ->
      let id =
        match pat_is_plain_binder env lpat with
        | Some (Some (Id_aux (Id id, _))) -> id
        | Some None -> "x" (* TODO fresh name or wildcard instead of x *)
        | _ -> failwith "Let pattern not translatable yet."
      in
      let decl_val =
        if effectful (effect_of lexp) then [string "←"; string "do"; doc_exp true ctx lexp]
        else [coloneq; doc_exp false ctx lexp]
      in
      nest 2 (flow (break 1) ([string "let"; string id] @ decl_val)) ^^ hardline ^^ doc_exp as_monadic ctx e
  | E_internal_return e -> doc_exp false ctx e (* ??? *)
  | E_struct fexps ->
      let args = List.map d_of_field fexps in
      wrap_with_pure as_monadic (braces (space ^^ align (separate hardline args) ^^ space))
  | E_field (exp, id) ->
      (* TODO *)
      wrap_with_pure as_monadic (doc_exp false ctx exp ^^ dot ^^ doc_id_ctor id)
  | E_struct_update (exp, fexps) ->
      let args = List.map d_of_field fexps in
      (* TODO *)
      wrap_with_pure as_monadic
        (braces (space ^^ doc_exp false ctx exp ^^ string " with " ^^ separate (comma ^^ space) args ^^ space))
  | _ -> failwith ("Expression " ^ string_of_exp_con full_exp ^ " " ^ string_of_exp full_exp ^ " not translatable yet.")

and doc_fexp with_arrow ctx (FE_aux (FE_fexp (field, e), _)) =
  doc_id_ctor field ^^ string " := " ^^ wrap_with_left_arrow with_arrow (doc_exp false ctx e)

let doc_binder ctx i t =
  let paranthesizer =
    match t with
    | Typ_aux (Typ_app (Id_aux (Id "implicit", _), [A_aux (A_nexp (Nexp_aux (Nexp_var ki, _)), _)]), _) ->
        implicit_parens
    | _ -> parens
  in
  (* Overwrite the id if it's captured *)
  let ctx = match captured_typ_var (i, t) with Some (i, ki) -> add_single_kid_id_rename ctx i ki | _ -> ctx in
  (ctx, separate space [string (string_of_id i); colon; doc_typ ctx t] |> paranthesizer)

let doc_funcl_init (FCL_aux (FCL_funcl (id, pexp), annot)) =
  let env = env_of_tannot (snd annot) in
  let TypQ_aux (tq, l), typ = Env.get_val_spec_orig id env in
  let arg_typs, ret_typ, _ =
    match typ with
    | Typ_aux (Typ_fn (arg_typs, ret_typ), _) -> (arg_typs, ret_typ, no_effect)
    | _ -> failwith ("Function " ^ string_of_id id ^ " does not have function type")
  in
  let pat, _, exp, _ = destruct_pexp pexp in
  let pats, _ = untuple_args_pat arg_typs pat in
  let binders : (id * typ) list =
    pats
    |> List.map (fun (pat, typ) ->
           match pat_is_plain_binder env pat with
           | Some (Some id) -> (id, typ)
           | Some None -> (Id_aux (Id "x", l), typ) (* TODO fresh name or wildcard instead of x *)
           | _ -> failwith "Argument pattern not translatable yet."
       )
  in
  let ctx = initial_context env in
  let ctx, binders =
    List.fold_left
      (fun (ctx, bs) (i, t) ->
        let ctx, d = doc_binder ctx i t in
        (ctx, bs @ [d])
      )
      (ctx, []) binders
  in
  let typ_quants = doc_typ_quant ctx tq in
  let typ_quant_comment =
    if List.length typ_quants > 0 then
      string "/-- Type quantifiers: " ^^ nest 2 (flow comma_sp typ_quants) ^^ string " -/" ^^ hardline
    else empty
  in
  (* Use auto-implicits for type quanitifiers for now and see if this works *)
  let doc_ret_typ = doc_typ ctx ret_typ in
  let is_monadic = effectful (effect_of exp) in
  (* Add monad for stateful functions *)
  let doc_ret_typ = if is_monadic then string "SailM " ^^ doc_ret_typ else doc_ret_typ in
  let decl_val = [doc_ret_typ; coloneq] in
  (* Add do block for stateful functions *)
  let decl_val = if is_monadic then decl_val @ [string "do"] else decl_val in
  (typ_quant_comment, separate space ([string "def"; string (string_of_id id)] @ binders @ [colon] @ decl_val), env)

let doc_funcl_body (FCL_aux (FCL_funcl (id, pexp), annot)) =
  let env = env_of_tannot (snd annot) in
  let ctx = initial_context env in
  let _, _, exp, _ = destruct_pexp pexp in
  let is_monadic = effectful (effect_of exp) in
  doc_exp is_monadic ctx exp

let doc_funcl ctx funcl =
  let comment, signature, env = doc_funcl_init funcl in
  comment ^^ nest 2 (signature ^^ hardline ^^ doc_funcl_body funcl)

let doc_fundef ctx (FD_aux (FD_function (r, typa, fcls), fannot)) =
  match fcls with
  | [] -> failwith "FD_function with empty function list"
  | [funcl] -> doc_funcl ctx funcl
  | _ -> failwith "FD_function with more than one clause"

let string_of_type_def_con (TD_aux (td, _)) =
  match td with
  | TD_abbrev _ -> "TD_abbrev"
  | TD_record _ -> "TD_record"
  | TD_variant _ -> "TD_variant"
  | TD_abstract _ -> "TD_abstract"
  | TD_bitfield _ -> "TD_bitfield"
  | TD_enum _ -> "TD_enum"

let doc_typdef ctx (TD_aux (td, tannot) as full_typdef) =
  match td with
  | TD_enum (Id_aux (Id id, _), fields, _) ->
      let derivers = if List.length fields > 0 then [string "Inhabited"] else [] in
      let fields = List.map doc_id_ctor fields in
      let fields = List.map (fun i -> space ^^ pipe ^^ space ^^ i) fields in
      let enums_doc = concat fields in
      nest 2
        (flow (break 1) [string "inductive"; string id; string "where"]
        ^^ enums_doc ^^ hardline ^^ string "deriving" ^^ space
        ^^ separate (comma ^^ space) derivers
        )
  | TD_record (Id_aux (Id id, _), TypQ_aux (tq, _), fields, _) ->
      let fields = List.map (doc_typ_id ctx) fields in
      let enums_doc = separate hardline fields in
      let rectyp = doc_typ_quant ctx tq in
      (* TODO don't ignore type quantifiers *)
      nest 2 (flow (break 1) [string "structure"; string id; string "where"] ^^ hardline ^^ enums_doc)
  | TD_abbrev (Id_aux (Id id, _), tq, A_aux (A_typ t, _)) ->
      nest 2 (flow (break 1) [string "def"; string id; coloneq; doc_typ ctx t])
  | TD_abbrev (Id_aux (Id id, _), tq, A_aux (A_nexp ne, _)) ->
      nest 2 (flow (break 1) [string "def"; string id; colon; string "Int"; coloneq; doc_nexp ctx ne])
  | _ -> failwith ("Type definition " ^ string_of_type_def_con full_typdef ^ " not translatable yet.")

let doc_def ctx (DEF_aux (aux, def_annot) as def) =
  match aux with
  | DEF_fundef fdef -> group (doc_fundef ctx fdef) ^/^ hardline
  | DEF_type tdef -> group (doc_typdef ctx tdef) ^/^ hardline
  | _ -> empty

(* Remove all imports for now, they will be printed in other files. Probably just for testing. *)
let rec remove_imports (defs : (Libsail.Type_check.tannot, Libsail.Type_check.env) def list) depth =
  match defs with
  | [] -> []
  | DEF_aux (DEF_pragma ("include_start", _, _), _) :: ds -> remove_imports ds (depth + 1)
  | DEF_aux (DEF_pragma ("include_end", _, _), _) :: ds -> remove_imports ds (depth - 1)
  | d :: ds -> if depth > 0 then remove_imports ds depth else d :: remove_imports ds depth

let pp_ast_lean (env : Type_check.env) ({ defs; _ } as ast : Libsail.Type_check.typed_ast) o =
  let defs = remove_imports defs 0 in
  let output : document = separate_map empty (doc_def (initial_context env)) defs in
  print o output;
  ()
