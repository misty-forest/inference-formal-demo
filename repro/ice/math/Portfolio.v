(* Time evolution of the ordinary equal-profile buckets. A position stays in
   the mathematical list after expiry: its base is then constant, matching
   the dense engine's transfer to permanent_base. Amounts are unchanged
   during the interval, and all numerators here use mathematical integers. *)
From Coq Require Import ZArith List Lia.
Import ListNotations.
Open Scope Z_scope.

Definition horizon : Z := 94348800.  (* 156 * 604800 seconds *)
Lemma horizon_positive : 0 < horizon.
Proof. unfold horizon; lia. Qed.

Definition weight (expiry now : Z) : Z :=
  horizon + 9 * Z.min horizon (Z.max 0 (expiry - now)).

(* Length in seconds of the intersection of the two intervals. *)
Definition overlap (expiry t0 t1 : Z) : Z :=
  Z.max 0 (Z.min t1 expiry - Z.max t0 (expiry - horizon)).

Definition portfolio := list (Z * Z).  (* (amount, expiry) *)
Fixpoint numerator (p : portfolio) (now : Z) : Z :=
  match p with
  | [] => 0
  | (amount, expiry) :: rest => amount * weight expiry now + numerator rest now
  end.

Fixpoint exposure (p : portfolio) (t0 t1 : Z) : Z :=
  match p with
  | [] => 0
  | (amount, expiry) :: rest =>
      amount * overlap expiry t0 t1 + exposure rest t0 t1
  end.

Lemma weight_loss : forall expiry t0 t1,
  t0 <= t1 ->
  weight expiry t0 - weight expiry t1 = 9 * overlap expiry t0 t1.
Proof.
  intros expiry t0 t1 Hordered. pose proof horizon_positive.
  unfold weight, overlap.
  repeat match goal with
  | |- context [Z.max ?x ?y] =>
      destruct (Z.max_spec x y) as [[? E]|[? E]]; rewrite E; clear E; try lia
  | |- context [Z.min ?x ?y] =>
      destruct (Z.min_spec x y) as [[? E]|[? E]]; rewrite E; clear E; try lia
  end.
Qed.

(* The identity even holds for signed coefficients. Nonnegative principals
   give monotonicity as a corollary. *)
Theorem portfolio_exact_loss : forall p t0 t1,
  t0 <= t1 ->
  numerator p t0 - numerator p t1 = 9 * exposure p t0 t1.
Proof.
  induction p as [|[amount expiry] rest IH]; intros t0 t1 Hordered.
  - reflexivity.
  - cbn [numerator exposure].
    specialize (IH t0 t1 Hordered).
    pose proof (weight_loss expiry t0 t1 Hordered). nia.
Qed.

Lemma exposure_nonnegative : forall p t0 t1,
  Forall (fun entry => 0 <= fst entry) p -> 0 <= exposure p t0 t1.
Proof.
  intros p t0 t1 H. induction H as [|[amount expiry] rest Hamount _ IH].
  - reflexivity.
  - cbn [exposure]. cbn [fst] in Hamount.
    assert (0 <= overlap expiry t0 t1) by (unfold overlap; apply Z.le_max_l).
    nia.
Qed.

Corollary numerator_monotone : forall p t0 t1,
  Forall (fun entry => 0 <= fst entry) p -> t0 <= t1 ->
  numerator p t1 <= numerator p t0.
Proof.
  intros p t0 t1 Hamount Htime.
  pose proof (portfolio_exact_loss p t0 t1 Htime).
  pose proof (exposure_nonnegative p t0 t1 Hamount). lia.
Qed.

(* The equal head stores the Euclidean quotient and the remainder. Each
   checkpoint reconstructs the preceding numerator before subtracting the
   exact loss over the next interval, then stores a fresh canonical pair. *)
Definition encode (n : Z) : Z * Z := (n / horizon, n mod horizon).
Definition decode (qr : Z * Z) : Z := horizon * fst qr + snd qr.

Lemma decode_encode : forall n, decode (encode n) = n.
Proof.
  intro n. unfold decode, encode. cbn [fst snd]. symmetry.
  apply Z.div_mod. pose proof horizon_positive; lia.
Qed.

Lemma remainder_canonical : forall n, 0 <= snd (encode n) < horizon.
Proof.
  intro n. unfold encode. cbn [snd]. apply Z.mod_pos_bound, horizon_positive.
Qed.

Fixpoint checkpoints (p : portfolio) (now : Z) (qr : Z * Z) (times : list Z)
    : Z * Z :=
  match times with
  | [] => qr
  | next :: rest =>
      let next_qr := encode (decode qr - 9 * exposure p now next) in
      checkpoints p next next_qr rest
  end.

Fixpoint ordered_from (now : Z) (times : list Z) : Prop :=
  match times with
  | [] => True
  | next :: rest => now <= next /\ ordered_from next rest
  end.

Fixpoint final_time (now : Z) (times : list Z) : Z :=
  match times with [] => now | next :: rest => final_time next rest end.

(* No upper bound on the number of checkpoints, buckets, or horizon crossings.
   In particular every two valid paths with the same endpoint store exactly
   the same whole and the same remainder. *)
Theorem checkpoints_path_independent : forall p times now,
  ordered_from now times ->
  checkpoints p now (encode (numerator p now)) times =
  encode (numerator p (final_time now times)).
Proof.
  intros p times. induction times as [|next rest IH]; intros now Hordered.
  - reflexivity.
  - destruct Hordered as [Hstep Hrest]. cbn [checkpoints final_time].
    rewrite decode_encode.
    replace (numerator p now - 9 * exposure p now next) with (numerator p next)
      by (pose proof (portfolio_exact_loss p now next Hstep); lia).
    apply IH, Hrest.
Qed.

(* Two successive one-second advances from the horizon boundary. Starting
   at a week-aligned time, 1 principal has whole 10. Its first checkpoint has
   whole 9. Clearing its remainder then incorrectly produces whole 8 one
   second later; the correct whole is still 9. *)
Example discarded_remainder_counterexample :
  let t0 := 345600 + horizon in
  let p := [(1, t0 + horizon)] in
  let first := checkpoints p t0 (encode (numerator p t0)) [t0 + 1] in
  let correct := checkpoints p (t0 + 1) first [t0 + 2] in
  let truncated := checkpoints p (t0 + 1) (fst first, 0) [t0 + 2] in
  fst first = 9 /\ fst correct = 9 /\ fst truncated = 8.
Proof. vm_compute; repeat split. Qed.
