open Mixed_solver
open Theory_model
open LA_SMT
open LA_SMT.Formula

module Solver = Mixed_solver(LA_SMT)

type additional_defs = 
  | Card of LA_SMT.Formula.card
  | Def of Lisp.lisp

let fresh_var =
  let i = ref 0 in
  fun () ->
    (incr i; let n = "card!" ^ string_of_int !i
     in
     LA_SMT.use_var n Int; n)

exception Out
exception Not_allowed of string
exception Not_allowed_for_type of string * string

let rec lisp_to_bool_texpr =
  let open Lisp in
  function
  | Lisp_true -> BValue true
  | Lisp_false -> BValue false
  | Lisp_string(z) -> (ensure_bool z; BVar(z, true))
  | a -> raise (Not_allowed_for_type(lisp_to_string a, "bool"))


let rec ensure_int_expr z =
  let open Lisp in
  function
  | Lisp_rec(Lisp_string "-" :: a :: b :: []) | Lisp_rec(Lisp_string "+" :: a :: b :: []) ->
    (ensure_int_expr z a; ensure_int_expr z b)
  | Lisp_int(v) -> ()
  | Lisp_string(v) ->
    if v = z then raise Not_found
    else ensure_int v

let rec lisp_to_int_texpr ?z:(z="") ctx =
  let open Lisp in
  function
  | Lisp_string(z) -> (ensure_int z; IVar(z, 0))
  | Lisp_int (v) -> IValue v
  | Lisp_rec(Lisp_string "+" :: Lisp_string z :: Lisp_int i :: []) -> (ensure_int z; IVar(z, i))
  | Lisp_rec(Lisp_string "-" :: Lisp_string z :: Lisp_int i :: []) -> (ensure_int z; IVar(z, -i))
  | Lisp_rec(Lisp_string "+" :: Lisp_int i :: Lisp_string z :: []) -> (ensure_int z; IVar(z, i))
  | Lisp_rec(Lisp_string "+" :: a :: b :: []) as e -> (
      let subs = fresh_var () in
      ctx := (Def (Lisp_rec (Lisp_string "=" :: Lisp_string subs :: e :: []))) :: !ctx;
      ensure_int_expr z a; ensure_int_expr z b;
      IVar(subs, 0)
      )
  | a -> raise (Not_allowed (lisp_to_string a))

let rec lisp_to_expr ?z:(z="") ctx l =
  let open Lisp in
  match l with
  | Lisp_rec(Lisp_string "and" :: a :: b :: []) -> And (lisp_to_expr ~z ctx a, lisp_to_expr ~z ctx b)
  | Lisp_rec(Lisp_string "and" :: a :: q) -> And (lisp_to_expr ~z ctx a, lisp_to_expr ~z ctx (Lisp_rec (Lisp_string "and" :: q)))
  | Lisp_rec(Lisp_string "or" :: a :: b :: []) -> Or (lisp_to_expr ~z ctx a, lisp_to_expr ~z ctx b)
  | Lisp_rec(Lisp_string "or" :: a :: q) -> Or (lisp_to_expr ~z ctx a, lisp_to_expr ~z ctx (Lisp_rec (Lisp_string "or" :: q)))
  | Lisp_rec(Lisp_string ">=" :: a :: b :: []) ->
    (*
    let count_quantified_a, others_a = lisp_to_int_texpr a in
    let count_quantified_b, others_b = lisp_to_int_texpr b in
    let total_count = count_quantified a - count_quantified b in
    if total_count = 1 then
      Theory_expr (Greater (lisp_to_int_texpr a, lisp_to_int_texpr b))
    else if total_count = -1 then*)
      Theory_expr (Greater (lisp_to_int_texpr ~z ctx a, lisp_to_int_texpr ~z ctx b))
   (* else failwith "non unit coefficient in front of the quantified"*)
  | Lisp_rec(Lisp_string "=" :: a :: b :: []) -> Theory_expr (Greater (lisp_to_int_texpr ~z ctx a, lisp_to_int_texpr ~z ctx b))
  | Lisp_true -> Theory_expr (Bool (BValue true))
  | Lisp_false -> Theory_expr (Bool (BValue false))
  | Lisp_string b -> Theory_expr (Bool (BVar(b, true)))
  | _ -> raise (Not_allowed (lisp_to_string l))

let rec extract_cards l =
  let open Lisp in
  match l with
  | Lisp_int _ | Lisp_string _ | Lisp_true | Lisp_false -> l, []
  | Lisp_rec (Lisp_string "#" :: Lisp_string z :: Lisp_string sort :: formula :: []) ->
    let y = fresh_var () in
    let sort = match sort with
      | "Int" -> Int
      | "Bool" -> Bool
      | a -> raise (Not_allowed_for_type(z, a))
    in
    let ctx = ref [] in
    let formula = use_quantified_var z (fun () -> lisp_to_expr ~z ctx formula) sort in
    Lisp_string (y), Card {var_name = y; expr = formula; quantified_var = z} :: !ctx
  | Lisp_rec (l) ->
    let l, cards = List.map extract_cards l |> List.split in
    Lisp_rec (l), List.concat cards


let lexing stdin =
    stdin |> Lexing.from_channel

let rec runner stdout lexing_stdin cards' =
  let cards = ref cards' in
  try
    while true do
      let open Lisp in
      lexing_stdin
      |> Lisp_parser.prog Lisp_lexer.read
      |> (fun lisp ->
          match lisp with
          | Lisp_rec (Lisp_string "set-logic" :: _) ->
            lisp_to_string lisp
            |> LA_SMT.send_to_solver
          | Lisp_rec (Lisp_string "get-model" :: []) ->
            begin
              try
                Solver.solve_context !cards  |> LA_SMT.print_model stdout
              with
              | LA_SMT.Unsat -> Printf.fprintf stdout "unsat\n"
            end
          | Lisp_rec (Lisp_string "declare-fun" :: Lisp_string x :: Lisp_rec ([]) :: Lisp_string "Int" :: []) ->
            LA_SMT.use_var x Int
          | Lisp_rec (Lisp_string "declare-fun" :: Lisp_string x :: Lisp_rec ([]) :: Lisp_string "Bool" :: []) ->
            LA_SMT.use_var x Bool
          | Lisp_rec (Lisp_string "push" :: Lisp_int 1 :: []) ->
            LA_SMT.push (fun () -> runner stdout lexing_stdin !cards)
          | Lisp_rec (Lisp_string "pop" :: Lisp_int 1 :: []) ->
            raise Out
          | Lisp_rec (Lisp_string "assert" :: a :: []) ->
            begin
              let assertion_cardless, new_card_vars = extract_cards a in
              let new_vars =
                List.filter (function
                    | Card _ -> false
                    | Def _ -> true) new_card_vars |>
                List.map (function
                    | Card _ -> raise Not_found
                    | Def a -> a)
              in
              let new_cards =
                List.filter (function
                  | Card _ -> true
                  | Def _ -> false) new_card_vars
                |> List.map (function
                    | Card a -> a
                    | Def _ -> raise Not_found)
              in
              Lisp_rec (Lisp_string "assert" :: Lisp_rec (Lisp_string "and" :: assertion_cardless :: new_vars) :: [])
              |> lisp_to_string
              |> send_to_solver;
              cards := new_cards @ !cards
            end
          | Lisp_rec (Lisp_string "check-sat" :: []) ->
            begin
              try
                let _ = Solver.solve_context !cards in
                Printf.fprintf stdout "sat\n"
              with
              | LA_SMT.Unsat -> Printf.fprintf stdout "unsat\n"
            end
          | a -> raise (Not_allowed (lisp_to_string a))
        )
    done
  with
  | Out -> ()


