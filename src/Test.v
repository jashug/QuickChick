Require Import Show RoseTrees.
Require Import ModuleGen GenCombinators SemChecker.
Require Import Checker.
Require Import State.
Require Import Arbitrary.
Require Import Axioms.

Require Import String.
Require Import Coq.Strings.Ascii.
Require Import Coq.Strings.String.
Require Import Coq.Numbers.Natural.Peano.NPeano.
Require Import List.

Require Import Recdef.

Require Import Arith.EqNat.

Import Gen GenComb.

Definition gte n m := leb m n.

Set Implicit Arguments.

Record Args := MkArgs {
  replay     : option (RandomGen * nat);
  maxSuccess : nat;
  maxDiscard : nat;
  maxShrinks : nat;
  maxSize    : nat;
  chatty     : bool
}.

Inductive Result :=
  | Success : nat -> nat -> list (string * nat) -> string -> Result
  | GaveUp  : nat -> list (string * nat) -> string -> Result
  | Failure : nat -> nat -> nat -> RandomGen -> nat -> string ->
              list (string * nat) -> string -> Result
  | NoExpectedFailure : nat -> list (string * nat) -> string -> Result.

Definition isSuccess (r : Result) : bool :=
  match r with
    | Success _ _ _ _ => true
    | _         => false
  end.

(* Representing large constants in CoQ is not a good idea... :) *)
Axiom defNumTests    : nat.
Extract Constant defNumTests    => "1000".
Axiom defNumDiscards : nat.
Extract Constant defNumDiscards => "50000".
Axiom defNumShrinks  : nat.
Extract Constant defNumShrinks  => "1000".
Axiom defSize        : nat.
Extract Constant defSize        => "100".

Definition stdArgs := MkArgs None defNumTests defNumDiscards
                             defNumShrinks defSize true.

Definition roundTo n m := mult (div n m) m.
Definition computeSize' (a : Args) (n : nat) (d : nat) : nat :=
  if (orb (gte n (maxSuccess a))
          (gte (maxSuccess a) (roundTo n (maxSize a) + (maxSize a)))) then
    (modulo n (maxSize a)) + (div d 10)
  else
    (div (mult (modulo n (maxSize a)) (maxSize a)) (modulo (maxSuccess a) (maxSize a)))
    + (div d 10).

Definition at0 f (s : nat) n d :=
  if andb (beq_nat n 0) (beq_nat d 0) then s
  else f n d.

Fixpoint prependToAll {A : Type} (sep : A) (ls : list A) : list A :=
  match ls with
    | nil => nil
    | h :: t => sep :: h :: prependToAll sep t
  end.

Definition intersperse {A : Type} (sep : A) (ls : list A) : list A :=
  match ls with
    | nil => nil
    | h :: t => h :: prependToAll sep t
  end.

Definition notNull (ls : list string) : bool :=
  match ls with
    | nil => false
    | _ => true
  end.

Fixpoint insertBy A (compare : A -> A -> bool) (x : A) (l : list A) : list A :=
  match l with
    | nil => x :: nil
    | h :: t => if compare x h then x :: l else h :: insertBy compare x t
  end.

Fixpoint insSortBy A (compare : A -> A -> bool) (l : list A) : list A :=
  match l with
    | nil => nil
    | h :: t => insertBy compare h (insSortBy compare t)
  end.

Local Open Scope string.
Fixpoint concatStr (l : list string) : string :=
  match l with
    | nil => ""
    | (h :: t) => h ++ concatStr t
  end.

Definition summary (st : State) : list (string * nat) :=
  let res := Map.fold (fun key elem acc => (key,elem) :: acc) (labels st) nil
  in insSortBy (fun x y => snd y <=? snd x) res .

Definition doneTesting (st : State) (f : RandomGen -> nat -> QProp) : Result :=
 if expectedFailure st then
    Success (numSuccessTests st + 1) (numDiscardedTests st) (summary st)
            ("+++ OK, passed " ++ (show (numSuccessTests st)) ++ " tests"
                               ++ newline)
  else
    NoExpectedFailure (numSuccessTests st) (summary st)
                      ("*** Failed! Passed " ++ (show (numSuccessTests st))
                                             ++ " tests (expected Failure)"
                                             ++ newline).
  (* TODO: success st - labels *)

Definition giveUp (st : State) (_ : RandomGen -> nat -> QProp) : Result :=
  GaveUp (numSuccessTests st) (summary st)
         ("*** Gave up! Passed only " ++ (show (numSuccessTests st)) ++ " tests"
          ++  newline ++ "Discarded: " ++ (show (numDiscardedTests st)) ++ newline).

Definition callbackPostFinalFailure (st : State) (res : Checker.Result)
: nat :=
match res with
  | MkResult o e r i s c =>
  fold_left (fun acc callback =>
               match callback with
                 | PostFinalFailure _ call =>
                   (call st (MkSmallResult o e r i s)) + acc
                 | _ => acc
               end) c 0
end.

Fixpoint roseSize (r : Rose Checker.Result) : nat :=
  match r with
    | MkRose _ ts =>
      1 + fold_left (fun acc rose => acc + (roseSize rose)) (force ts) 0
  end.

Function localMin (st : State) (r : Rose Checker.Result)
          {measure roseSize r}
: (nat * Checker.Result) :=
  match r with
    | MkRose res ts =>
      match (force ts) return (nat * Checker.Result) with
        | nil =>
          let zero := callbackPostFinalFailure st res in
          (numSuccessShrinks st + zero, res)
        | cons (MkRose res' ts') t =>
          match ok res' with
            | Some x =>
              if (negb x) then
                  localMin (updSuccessShrinks st (fun x => x + 1))
                           (MkRose res' ts')
              else
                localMin (updTryShrinks st (fun x => x + 1)) (MkRose res (lazy t))
            | None =>
              localMin (updTryShrinks st (fun x => x + 1)) (MkRose res (lazy t))
          end
      end
  end.
Admitted.

Definition decr (st : State) : nat :=
  ((maxSuccessTests st) + (maxDiscardedTests st))
  - ((numSuccessTests st) + (numDiscardedTests st)).

Function runATest (st : State) (f : RandomGen -> nat -> QProp)
         {measure decr st} : Result :=
  let size := (computeSize st) (numSuccessTests st) (numDiscardedTests st) in
  let (rnd1, rnd2) := rndSplit (randomSeed st) in
  let test (st : State) (f : RandomGen -> nat -> QProp) :=
        if (gte (numSuccessTests st) (maxSuccessTests st)) then
          doneTesting st f
        else if (gte (numDiscardedTests st) (maxDiscardedTests st)) then
               giveUp st f
        else runATest st f
 in
  match st with
    | MkState mst mdt ms cs nst ndt ls e r nss nts =>
    match f rnd1 size with
    | MkProp (MkRose res ts) =>
      (* TODO: CallbackPostTest *)
      match res with
        | MkResult (Some x) e reas _ s _ =>
          if x then (* Success *)
            let ls' := fold_left (fun stamps stamp =>
                                     let oldBind := Map.find stamp stamps in
                                     match oldBind with
                                       | None   => Map.add stamp 1 stamps
                                       | Some k => Map.add stamp (k+1) stamps
                                     end
                                  ) s ls in
            test (MkState mst mdt ms cs (nst + 1) ndt ls' e rnd2 nss nts) f
          else (* Failure *)
            let pre : string := (if expect res then "*** Failed! "
                       else "+++ OK, failed as expected. ")%string in
            let (numShrinks, res') := localMin st (MkRose res ts) in
            let suf := ("After " ++ (show (S nst)) ++ " tests and "
                                ++ (show numShrinks) ++ " shrinks")%string in
            (* TODO: Output *)
            if (negb (expect res)) then
              Success (nst + 1) ndt (summary st) (pre ++ suf)
            else
              Failure (nst + 1) numShrinks ndt r size (pre ++ suf) (summary st) reas
        | MkResult None e reas _ s _ =>
          (* Ignore labels of discarded tests? *)
          test (MkState mst mdt ms cs nst (ndt + 1) ls e rnd2 nss nts) f
      end
    end
  end.
Admitted. (* I think I *could* actually prove this *)

Definition test (st : State) (f : RandomGen -> nat -> QProp) : Result :=
  if (gte (numSuccessTests st) (maxSuccessTests st)) then
    doneTesting st f
  else if (gte (numDiscardedTests st) (maxDiscardedTests st)) then
         giveUp st f
  else runATest st f.

Require Import ZArith.
(* Axiom unsafeRandomSeed : Z. *)
Axiom newStdGen : RandomGen.


(* ZP: This was quickCheckResult before but since we always return result
       return result there is no reason for such distinction *)
Definition quickCheckWith {prop : Type} {_ : Checkable prop}
           (a : Args) (p : prop) : Result :=
  (* ignore terminal - always use trace :D *)
  let (rnd, computeFun) :=
      match replay a with
        | Some (rnd, s) => (rnd, at0 (computeSize' a) s)
        | None          => (newStdGen, computeSize' a)
        (* make it more random...? need IO action *)
      end in
  test (MkState (maxSuccess a)  (* maxSuccessTests   *)
                (maxDiscard a)  (* maxDiscardTests   *)
                (maxShrinks a)  (* maxShrinks        *)
                computeFun      (* computeSize       *)
                0               (* numSuccessTests   *)
                0               (* numDiscardTests   *)
                (Map.empty nat) (* labels            *)
                false           (* expectedFailure   *)
                rnd             (* randomSeed        *)
                0               (* numSuccessShrinks *)
                0               (* numTryShrinks     *)
       ) (run (checker p)).

Fixpoint showCollectStatistics (l : list (string * nat)) :=
  match l with
    | nil => ""
    | cons (s,n) l' =>
      show n ++ " : " ++ s ++ newline ++ showCollectStatistics l'
  end.

Definition showResult (r : Result) :=
  match r with
  | Success _ _ l s => showCollectStatistics l ++ s
  | GaveUp _ l s => showCollectStatistics l ++ s
  | Failure _ _ _ _ _ s l _ => showCollectStatistics l ++ s
  | NoExpectedFailure _ l s => showCollectStatistics l ++ s
  end ++ newline.

Definition quickCheck {prop : Type} {_ : Checkable prop}
           (p : prop) : Result :=
  quickCheckWith stdArgs p.
